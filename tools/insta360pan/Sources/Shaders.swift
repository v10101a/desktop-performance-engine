/// All the GPU work. Compiled at launch with `MTLDevice.makeLibrary(source:)`, because the
/// Metal compiler is part of Xcode, not the Command Line Tools, and this app builds with
/// nothing but the latter.
///
/// Coordinates: world x right, y up, z forward along the front lens's axis. Yaw is positive
/// to the right, pitch positive up. Each lens has its own frame with the lens looking
/// down its +z; `LensParams.row0…2` are the rows of the world → lens rotation.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct LensParams {
    float4 row0, row1, row2;   // world → lens rotation, as rows; the lens looks down its +z
    float4 circle;             // image circle in the half: centre x, y and radii x, y, in half-uv units
    float4 shape;              // x: θmax (rad) · y: pupil offset along world z (m) · z: mirror (±1) · w: which half (0 top, 1 bottom)
};

struct StitchUniforms {
    float4 view;      // x: yaw, y: pitch (rad) · z, w: half spans (rad for equirect, tan(half field) for rectilinear)
    float4 stitch;    // x: blend width (rad) · y: stitch distance (m) — the scene distance when synthesising
    float4 misc;      // x: overlay line width (uv-x) · y: aspect of a half (w/h) · z: time (s)
    uint flags;       // 1 rectilinear · 2 raw view · 4 flip vertically · 8 draw the lens overlay
    uint projection;  // 0 equidistant · 1 equisolid · 2 stereographic · 3 orthographic
    uint pad0, pad1;
    LensParams lens[2];
};

struct Varyings {
    float4 position [[position]];
    float2 uv;        // 0…1 across the target, y down
};

// One triangle that covers the whole target; uv is derived from it.
vertex Varyings fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    Varyings out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// MARK: - Lens projection

// Normalised radius (0…1 at θmax) for a lens angle.
static float projectRadius(float theta, float thetaMax, uint projection) {
    switch (projection) {
        case 1u: return sin(theta * 0.5) / sin(thetaMax * 0.5);
        case 2u: return tan(theta * 0.5) / tan(thetaMax * 0.5);
        case 3u: return sin(min(theta, M_PI_F * 0.5)) / sin(min(thetaMax, M_PI_F * 0.5));
        default: return theta / thetaMax;
    }
}

// Lens angle for a normalised radius: the inverse of the above.
static float unprojectTheta(float r, float thetaMax, uint projection) {
    switch (projection) {
        case 1u: return 2.0 * asin(clamp(r * sin(thetaMax * 0.5), -1.0, 1.0));
        case 2u: return 2.0 * atan(r * tan(thetaMax * 0.5));
        case 3u: return asin(clamp(r * sin(min(thetaMax, M_PI_F * 0.5)), -1.0, 1.0));
        default: return r * thetaMax;
    }
}

static float3 hsv(float h, float s, float v) {
    float3 k = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

// MARK: - Output pixel → world direction

static float3 directionForPixel(float2 uv, constant StitchUniforms &U, thread bool &valid) {
    float nx = uv.x - 0.5;
    float ny = 0.5 - uv.y;                    // up
    float yaw0 = U.view.x, pitch0 = U.view.y;
    if (U.flags & 1u) {
        // Rectilinear: a point on the tangent plane, turned by pitch then yaw.
        float3 d0 = normalize(float3(nx * 2.0 * U.view.z, ny * 2.0 * U.view.w, 1.0));
        float cp = cos(pitch0), sp = sin(pitch0), cy = cos(yaw0), sy = sin(yaw0);
        float3 d1 = float3(d0.x, cp * d0.y + sp * d0.z, -sp * d0.y + cp * d0.z);
        valid = true;
        return float3(cy * d1.x + sy * d1.z, d1.y, -sy * d1.x + cy * d1.z);
    }
    // Equirectangular: angles are linear across the frame.
    float yaw = yaw0 + nx * 2.0 * U.view.z;
    float pitch = pitch0 + ny * 2.0 * U.view.w;
    valid = fabs(pitch) <= M_PI_F * 0.5;
    return float3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw));
}

// MARK: - World direction → a lens's pixels

struct LensSample {
    float3 rgb;
    float weight;
};

static LensSample sampleLens(float3 d, constant LensParams &L, constant StitchUniforms &U,
                             texture2d<float> cam, sampler smp) {
    LensSample s;
    s.rgb = float3(0.0);
    s.weight = 0.0;
    // The point at stitch distance along d, seen from this lens's own pupil rather than
    // from the centre of the camera: that is the parallax.
    float3 p = d * U.stitch.y - float3(0.0, 0.0, L.shape.y);
    float3 dl = normalize(float3(dot(L.row0.xyz, p), dot(L.row1.xyz, p), dot(L.row2.xyz, p)));
    float theta = acos(clamp(dl.z, -1.0, 1.0));
    float thetaMax = L.shape.x;
    if (theta >= thetaMax) return s;
    float r = projectRadius(theta, thetaMax, U.projection);
    float phi = atan2(dl.y, dl.x);
    float2 q = float2(L.circle.x + L.shape.z * r * cos(phi) * L.circle.z,
                      L.circle.y - r * sin(phi) * L.circle.w);          // half-uv, y down
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) return s;      // outside the transmitted band
    // Fade out towards the edge of the lens's field so the two lenses cross-fade, and
    // feather the band's crop lines so they never cut hard through a blend.
    float w = 1.0 - smoothstep(thetaMax - U.stitch.x, thetaMax, theta);
    float feather = min(min(q.x, 1.0 - q.x) * 50.0, min(q.y, 1.0 - q.y) * 25.0);
    w *= clamp(feather, 0.0, 1.0);
    float2 uv = float2(q.x, L.shape.w > 0.5 ? 0.5 + q.y * 0.5 : q.y * 0.5);
    s.rgb = cam.sample(smp, uv).rgb;
    s.weight = w;
    return s;
}

// MARK: - Raw view, with the lens model drawn over the frame

static float4 rawView(float2 uv, texture2d<float> cam, constant StitchUniforms &U, sampler smp) {
    float3 rgb = cam.sample(smp, uv).rgb;
    if (!(U.flags & 8u)) return float4(rgb, 1.0);
    float which = uv.y < 0.5 ? 0.0 : 1.0;
    float2 q = float2(uv.x, (uv.y - 0.5 * which) * 2.0);
    float lw = U.misc.x;
    for (int i = 0; i < 2; i++) {
        constant LensParams &L = U.lens[i];
        if (L.shape.w != which) continue;
        float2 e = (q - L.circle.xy) / L.circle.zw;
        float rr = length(e);
        float radial = lw / L.circle.z;
        float equator = projectRadius(M_PI_F * 0.5, L.shape.x, U.projection);
        float inner = projectRadius(max(0.0, L.shape.x - U.stitch.x), L.shape.x, U.projection);
        if (fabs(rr - 1.0) < radial) rgb = float3(1.0, 0.2, 0.9);              // edge of the field: magenta
        else if (fabs(rr - equator) < radial) rgb = float3(0.2, 0.9, 1.0);     // 90° from the axis: cyan
        else if (fabs(rr - inner) < radial) rgb = float3(1.0, 0.9, 0.2);       // where the blend starts: yellow
        else if (rr < 1.0 && (fabs(q.x - L.circle.x) < lw || fabs(q.y - L.circle.y) < lw * U.misc.y))
            rgb = float3(0.3, 1.0, 0.4);                                        // the axis: green
    }
    return float4(rgb, 1.0);
}

// MARK: - Pass 1: the stitched view

fragment float4 stitch_fragment(Varyings in [[stage_in]],
                                texture2d<float> cam [[texture(0)]],
                                constant StitchUniforms &U [[buffer(0)]]) {
    constexpr sampler smp(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    if (U.flags & 4u) uv.y = 1.0 - uv.y;          // Syphon surfaces are bottom row first
    if (U.flags & 2u) return rawView(uv, cam, U, smp);
    bool valid;
    float3 d = directionForPixel(uv, U, valid);
    if (!valid) return float4(0.0, 0.0, 0.0, 1.0);
    LensSample a = sampleLens(d, U.lens[0], U, cam, smp);
    LensSample b = sampleLens(d, U.lens[1], U, cam, smp);
    float sum = a.weight + b.weight;
    if (sum <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
    return float4((a.rgb * a.weight + b.rgb * b.weight) / sum, 1.0);
}

// MARK: - The synthetic camera

// A world painted on a sphere: hue by yaw, a 15° graticule, the horizon and the front
// axis bold, the rear axis black, magenta discs on the seams at (±90°, 0°) and (±90°, ±20°),
// a checkered band above the horizon and a solid blue one below so orientation reads, and a dot that
// circles the horizon once every twelve seconds.
static float3 scene(float yaw, float pitch, float time) {
    float yd = yaw * (180.0 / M_PI_F), pd = pitch * (180.0 / M_PI_F);
    float band = floor((yd + 180.0) / 30.0);
    float3 rgb = hsv(band / 12.0, 0.55, 0.5);
    float gy = fabs(fract(yd / 15.0 + 0.5) - 0.5) * 15.0;      // degrees to the nearest yaw line
    float gp = fabs(fract(pd / 15.0 + 0.5) - 0.5) * 15.0;      // …and pitch line
    if (gy < 0.3 || gp < 0.3) rgb = float3(0.85);
    if (fabs(pd) < 0.6) rgb = float3(1.0);                                     // horizon
    if (fabs(yd) < 0.8) rgb = float3(1.0);                                     // front axis
    if (fabs(fabs(yd) - 180.0) < 0.8) rgb = float3(0.0);                       // rear axis
    if (pd > 18.0 && pd < 24.0) rgb = (fmod(floor(yd / 10.0) + floor(pd / 3.0), 2.0) == 0.0) ? float3(1.0) : float3(0.0);
    if (pd < -18.0 && pd > -24.0) rgb = float3(0.1, 0.3, 1.0);
    for (int s = -1; s <= 1; s += 2) {
        float dy = fabs(yd - 90.0 * float(s));
        if (dy < 4.0 && fabs(pd) < 4.0 && dy * dy + pd * pd < 16.0) rgb = float3(1.0, 0.1, 0.9);
        for (int t = -1; t <= 1; t += 2) {
            float dp = pd - 20.0 * float(t);
            if (dy * dy + dp * dp < 6.25) rgb = float3(1.0, 0.1, 0.9);
        }
    }
    float dotYaw = fract(time / 12.0) * 360.0 - 180.0;
    float ddy = yd - dotYaw;
    ddy -= 360.0 * round(ddy / 360.0);
    float ddp = pd - 10.0;
    if (ddy * ddy + ddp * ddp < 9.0) rgb = float3(1.0);
    if (ddy * ddy + ddp * ddp < 4.0) rgb = float3(0.0);
    return rgb;
}

// Renders what the camera would send of that world: each half is one lens's view through
// the lens model in the uniforms, from that lens's own pupil, of a sphere at the stitch
// distance — so the parallax is real too.
fragment float4 synth_fragment(Varyings in [[stage_in]], constant StitchUniforms &U [[buffer(0)]]) {
    float2 uv = in.uv;
    float which = uv.y < 0.5 ? 0.0 : 1.0;
    float2 q = float2(uv.x, (uv.y - 0.5 * which) * 2.0);
    for (int i = 0; i < 2; i++) {
        constant LensParams &L = U.lens[i];
        if (L.shape.w != which) continue;
        float2 e = float2((q.x - L.circle.x) / L.circle.z * L.shape.z, -(q.y - L.circle.y) / L.circle.w);
        float rr = length(e);
        if (rr > 1.0) return float4(0.04, 0.04, 0.05, 1.0);                  // beyond the lens's field
        float theta = unprojectTheta(rr, L.shape.x, U.projection);
        float phi = atan2(e.y, e.x);
        float3 dl = float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
        float3 d = dl.x * L.row0.xyz + dl.y * L.row1.xyz + dl.z * L.row2.xyz;   // lens → world
        float3 o = float3(0.0, 0.0, L.shape.y);                                 // this lens's pupil
        float D = U.stitch.y;
        float od = dot(o, d);
        float t = -od + sqrt(max(0.0, od * od - dot(o, o) + D * D));
        float3 n = normalize(o + t * d);
        return float4(scene(atan2(n.x, n.z), asin(clamp(n.y, -1.0, 1.0)), U.misc.z), 1.0);
    }
    return float4(0.0, 0.0, 0.0, 1.0);
}

// MARK: - Pass 2: the output frame, letterboxed into the window

vertex Varyings blit_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]],
                            constant uint &flipped [[buffer(1)]]) {
    float2 unit = float2(vid & 1, (vid >> 1) & 1);      // four corners, as a strip
    Varyings out;
    out.position = float4(mix(rect.xy, rect.zw, unit), 0.0, 1.0);
    out.uv = float2(unit.x, flipped ? unit.y : 1.0 - unit.y);
    return out;
}

fragment float4 blit_fragment(Varyings in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler smp(address::clamp_to_edge, filter::linear);
    return float4(tex.sample(smp, in.uv).rgb, 1.0);
}
"""
