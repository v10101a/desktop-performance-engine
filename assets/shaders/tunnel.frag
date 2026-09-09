// The torus dimension: a cloudy tunnel, running under cue 13.
//
// The magic torus used to hang transparently over the viewer's own blue desktop, which
// made it an ornament sitting on their machine. It is supposed to take them somewhere.
// This is the somewhere: cloud flying past the camera, in the show's own three colours,
// with the middle washed out to white so the torus is framed by a bright hole rather
// than parked on a flat field.
//
// IT IS A ZOOM, NOT A POLAR TUNNEL MAP, and that is the whole design note. The obvious
// construction is to read the screen in polar coordinates and invert the radius, so 1/r
// is the distance down the tunnel; it is two noise lookups a pixel and it is what this
// file did first. It cannot make cloud. Depth is monotonic in r along every radius, so
// every feature is stretched along its own radius and the picture reads as a warp-speed
// starburst -- raising the angular resolution and shearing the wall by depth made the
// spokes finer and left them spokes.
//
// So the cloud is built the way a zoom is: four slabs of fbm, each scaled from far to
// near across its own life and cross-faded with a sine so nothing pops in or out, offset
// a quarter of a life apart. Features GROW out of the middle and pass the camera, which
// is flying through weather rather than down a pipe, and there is no preferred direction
// anywhere in it. Sixteen noise taps a pixel, no raymarch -- which matters, because
// unlike cue 17's raymarcher this runs FULL SCREEN and shares the phrase with a live
// Metal torus, a typing window and the oracle.
//
// KEEP THIS FILE PURE ASCII, COMMENTS INCLUDED. GLSL ES 1.00 restricts the source
// character set and ANGLE enforces it in the lexer: one em dash in a comment fails the
// whole compile, getShaderInfoLog comes back EMPTY, and the window is simply black with
// nothing logged. dpe-tests checks every shipped .frag for this.
#ifdef GL_ES
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#endif

uniform vec2 u_resolution;
uniform float u_time;
// The artist's scalar, used here the way cue 17 uses it: it scales the flight speed, so
// a cue can fly the tunnel harder without touching the file.
uniform float drop;

// The show's own palette, the same three the raymarcher was recoloured to.
const vec3 DEEP = vec3(0.008, 0.039, 0.961);   // #020AF5
const vec3 SKY  = vec3(0.408, 0.741, 0.973);   // #68BDF8
const vec3 PALE = vec3(0.949, 0.957, 0.996);   // #F2F4FE

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(27.609, 57.583))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Four octaves, rotated a little between each so the lattice never lines up into a grid
// -- value noise on axis-aligned cells is the one thing that gives fbm away as noise.
float fbm(vec2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * noise(p);
        p = mat2(0.80, 0.60, -0.60, 0.80) * p * 2.03;
        amp *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * u_resolution) / min(u_resolution.x, u_resolution.y);
    float r = length(uv);

    // The whole field rolls as it flies. Slow enough that it never comes back round in
    // the fifteen seconds the torus is up, for the same reason cue 17's raymarcher turns
    // at 8 degrees a second: a shot that returns to where it started reads as a loop.
    float a = u_time * 0.05;
    uv = mat2(cos(a), sin(a), -sin(a), cos(a)) * uv;

    float t = u_time * mix(0.09, 0.32, clamp(drop, 0.0, 1.0));

    // The four slabs. `life` runs 0 to 1 and the scale goes from far (small features, a
    // long way off) to near (huge, about to pass the camera); `w` is a sine over the same
    // life, so a slab is silent at birth and at death and nothing is ever seen appearing.
    float acc = 0.0;
    float wsum = 0.0;
    for (int k = 0; k < 4; k++) {
        float life = fract(t + float(k) * 0.25);
        float sc = mix(7.0, 0.55, life);
        float w = sin(life * 3.14159265);
        acc += w * fbm(uv * sc + vec2(float(k) * 13.7, float(k) * 7.3));
        wsum += w;
    }
    float d = acc / max(0.001, wsum);

    // The ramp is wide and low because fbm lives mostly between 0.3 and 0.7 -- clipped
    // tighter than this the cloud is two flat colours with a hard line where they meet,
    // which is the one thing cloud must not have.
    vec3 col = mix(DEEP, SKY, smoothstep(0.26, 0.68, d));
    col = mix(col, PALE, smoothstep(0.52, 0.90, d) * 0.9);

    // The middle washes out to white. This is Sarah's note taken literally -- the ground
    // behind the torus wanted to be white -- and it puts the brightest part of the frame
    // exactly where the torus sits, so the glass has something to bend.
    col = mix(col, PALE, pow(1.0 - smoothstep(0.0, 0.34, r), 1.5));

    // ...and the corners fall back toward the deep blue, so the shot has a vignette and
    // the full-screen window does not read as a flat sheet at its edges.
    col = mix(col, DEEP, smoothstep(0.62, 1.35, r) * 0.6);

    gl_FragColor = vec4(col, 1.0);
}
