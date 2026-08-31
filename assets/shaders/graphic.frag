// Shader B from the artist's code.txt (the second of the three concatenated there),
// used at cue 17. GLSL ES 1.00 -- texture2D / gl_FragColor -- so the host runs a WebGL1
// context rather than translating it.
//
// u_prevFrame and u_window are declared and sampled, but the lines that used them are
// commented out in the artist's own source (gl_FragColor = col; //mix(1.-col,
// previousColor, 1.-col)), so nothing they return reaches the output. The host binds a
// 1x1 black texture to each so the samplers are valid rather than reading undefined.
//
// KEEP THIS FILE PURE ASCII, COMMENTS INCLUDED. GLSL ES 1.00 restricts the source
// character set, and ANGLE enforces it at the lexer: one em dash in a comment fails the
// whole compile, and getShaderInfoLog comes back EMPTY, so the window is simply black
// with nothing logged anywhere. That is what the three em dashes in here did.
#ifdef GL_ES
precision mediump float;
#endif

uniform vec2 u_resolution;
uniform float u_time;
uniform float u_vol;
uniform float drop;
uniform float midi;
uniform sampler2D u_prevFrame;
uniform sampler2D u_window;

const float PI       = 3.14159265359;
const float PI2      = 6.28318530718;
const float MAX_DIST = 100.;
const float MIN_DIST = .001;

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(27.609, 57.583)))*43758.5453);
}

mat2 rot(float a) {
    return mat2(cos(a),sin(a),-sin(a),cos(a));
}

float box(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
}

float torus(vec3 p, vec2 t) {
    vec2 q = vec2(length(p.xy)-t.x,p.z);
    return length(q)-t.y;
}

vec3 hash3w(vec3 p) {
    p = fract(p * vec3(127.1,311.7,74.7));
    p += dot(p, p.yzx + 19.19);
    return fract((p.xxy + p.yxx)*p.zyx);
}

float worleyPeak(vec3 p, float freq) {
    vec3 pp = p * freq;
    vec3 i = floor(pp), f = fract(pp);
    float minD = 1e9;
    for(int x=-1;x<=1;x++) for(int y=-1;y<=1;y++) for(int z=-1;z<=1;z++) {
        vec3 cell = vec3(x,y,z);
        float d = length(f - (cell + hash3w(i+cell)));
        minD = min(minD, d);
    }
    return pow(clamp(1.0 - minD*1.4, 0.0, 1.0), 2.5);
}

vec2 frostGrad(vec3 p) {
    float eps = 0.04;
    float dxF = worleyPeak(p+vec3(eps,0,0),18.) - worleyPeak(p-vec3(eps,0,0),18.);
    float dyF = worleyPeak(p+vec3(0,eps,0),18.) - worleyPeak(p-vec3(0,eps,0),18.);
    float dxC = worleyPeak(p+vec3(eps,0,0), 7.) - worleyPeak(p-vec3(eps,0,0), 7.);
    float dyC = worleyPeak(p+vec3(0,eps,0), 7.) - worleyPeak(p-vec3(0,eps,0), 7.);
    return vec2(dxF*0.7+dxC*0.3, dyF*0.7+dyC*0.3);
}

vec3 frostNormal(vec3 n, vec3 p, float roughness) {
    vec3 tangent   = normalize(cross(n, abs(n.y)>.9 ? vec3(1,0,0) : vec3(0,1,0)));
    vec3 bitangent = cross(n, tangent);
    vec2 grad = frostGrad(p);
    vec3 offset = tangent*grad.x + bitangent*grad.y;
    offset -= n * dot(offset, n);
    return normalize(n + roughness * offset);
}

vec3 frostRefractDir(vec3 rd, vec3 n, vec3 p, float roughness, float ior) {
    vec3 fn = frostNormal(n, p, roughness);
    vec3 r = refract(rd, fn, 1.0/ior);
    if(length(r) < 0.001) r = rd;
    return normalize(r);
}

vec3 hp, hitPoint;
mat2 rt;

vec2 map(vec3 p)
{
    float time = u_time * mix(1.,4.,drop);
    vec2 res = vec2(1e5, 0.);
    vec3 q = p + vec3(0,0,1);
    vec3 q3 = q;

    float bf = box(q3, vec3(55., 35.0, 25.));
    float cx = box(q3, vec3(8.35, 5.25, 60.));
    bf = max(bf, -cx);
    if(bf < res.x) { res = vec2(bf, 1.); hp = q3; }

    float qd = floor((q3.z+1.5)/3.);
    q3.z = mod(q3.z+1.5, 3.) - 1.5;
    float rdx = .65 + .2*sin(qd + time*1.25);
    float ddx = (rdx*2.) - 1.;

    vec3 qr = q - vec3(rdx, ddx, 0);
    float id = floor((qr.z+1.5)/3.);
    qr.xy *= rot(time*.3 + id*.1);
    qr.z   = mod(qr.z+1.5, 3.) - 1.5;
    qr.zx *= rot(time*.5 + id*.2);

    float bx = box(qr, vec3(.5,.5,.5));
    if(bx < res.x) {
        float boxMat = mod(id, 2.) < .5 ? 5. : 4.;
        res = vec2(bx, boxMat);
        hp = q;
    }

    vec3 nq = q;
    float nd = floor((nq.z+1.5)/3.);
    nq.z = mod(nq.z+1.5, 3.) - 1.5;
    mat2 rota = rot(time*.3 + ddx);
    mat2 rotb = rot(time*.2 + nd*.5);

    nq.yz *= rota; nq.xz *= rotb;
    float tr = torus(nq, vec2(.95, .15));
    nq.yz *= rota; nq.xz *= rotb;
    tr = min(tr, torus(nq, vec2(.45, .15)));

    if(tr < res.x) {
        float torMat = mod(nd, 2.) < .5 ? 3. : 2.;
        res = vec2(tr, torMat);
        hp = q;
    }

    float f = p.y + (sin(q.x) + cos(q.z))*0.2 + 2.5;
    if(f < res.x) { res = vec2(f, 1.); hp = p; }

    return res + rand(q.xz)*0.001;
}

vec3 normal(vec3 p, float t)
{
    t *= MIN_DIST;
    float d = map(p).x;
    vec2 e = vec2(t, 0);
    vec3 n = d - vec3(
        map(p-e.xyy).x,
        map(p-e.yxy).x,
        map(p-e.yyx).x);
    return normalize(n);
}

// ---- the show's palette -------------------------------------------------------
// Straight off the three the rest of the piece is built from (tools/generate_horse.py
// PALETTE, and DJ_BLUE in the generator): the signature blue, the sky blue, the paper
// white. Everything this shader lights is mixed out of these, so cue 17 belongs to the
// same show as the desktop it comes up on.
// The output gamma, applied BOTH to the opaque surfaces and to the blurred scene
// inside the glass. It was 1.9 in each, written out twice -- one number now, because
// the two paths sit next to each other in frame and a gamma that differed between them
// would read as the glass being a different material rather than a different exponent.
// 1.9 crushed the midtones so hard the piece was near-black. 1.0 is the identity -- no
// crush at all -- and is where this landed; it stays a named knob rather than deleting
// the pow, because dropping below 1 washes the blues out toward white very quickly.
const float GAMMA = 1.0;

const vec3 DJ_BLUE = vec3(0.008, 0.039, 0.961);   // #020AF5
const vec3 SKY     = vec3(0.408, 0.741, 0.973);   // #68BDF8
const vec3 PAPER   = vec3(0.949, 0.957, 0.996);   // #F2F4FE

// Was a full rainbow -- .5 + .45*cos(13. + PI2*t*(c*d)), a different cosine frequency
// per channel, which swept the entire hue circle and landed on green more often than
// anything else. One axis now: deep blue -> sky -> a paper-white crest. `t` still varies
// per surface and with time, so the movement through the palette is unchanged; only
// where it lands is.
// The thresholds are set against GAMMA above. They had to be pushed up the range hard
// when that was 1.9 -- otherwise the whole image collapsed to one flat deep blue and the
// other two palette colours never showed at all. At 1.15 the gamma no longer eats the
// midtones, so they sit back closer to the middle.
vec3 hue(float t) {
    float k = .5 + .5*cos(13. + PI2*t);
    vec3 base = mix(DJ_BLUE, SKY, smoothstep(0., .62, k));
    return mix(base, PAPER, smoothstep(.68, 1., k) * .55);
}

// Renders the scene at a given screen UV, skipping frosted surfaces.
// Returns actual color -- not binary -- so kawase gets real values to blur.
vec3 renderScene(vec2 screenUV) {
    float time = u_time / 5.0;
    vec2 uv = (2.0*screenUV*u_resolution - u_resolution) / max(u_resolution.x, u_resolution.y);
    vec3 ro = vec3(0, 0, 4.25);
    vec3 rd = normalize(vec3(uv, -1));
    float dist = 0.01, m = 0.;
    vec3 p = ro + rd;

    for(int i = 0; i < 48; i++) {
        vec2 ray = map(p);
        dist += ray.x;
        m     = ray.y;
        p    += rd * ray.x * .76;
        if(dist > MAX_DIST) break;
        if(abs(ray.x) < .0005) {
            if(abs(ray.x) < .0005) {
    if(m > 3.) {
        p    += rd * 1.;  // big enough to clear torus thickness (~0.15*2)
        dist += .4;
    } else {
        break;
    }
}
        }
    }

    if(dist >= MAX_DIST) return DJ_BLUE * 0.16; // dim background, blue not neutral

    // floor/wall -> dark, same as main
    if(m < 2.) return vec3(0);

    // capture hp before normal() trashes it
    vec3 localHp = hp;

    vec3 n = normal(p, dist);

    vec3 lpos = vec3(3.*sin(time*.4), 10., 5.);
    vec3 l    = normalize(lpos - p);

    // simple diffuse, no shadows (too expensive for 4x blur samples)
    float diff = clamp(dot(n, l), 0., 1.) * 0.8 + 0.2;

    vec3 baseColor = hue(hash21(localHp.xz * .1) * .5 + time*.05);

    vec3 view = normalize(p - ro);
    vec3 ref  = reflect(normalize(lpos), n);
    float spec = 0.85 * pow(max(dot(view, ref), 0.), 32.);

    vec3 col = baseColor * diff + spec;
    return pow(max(col, vec3(0)), vec3(GAMMA));
}

vec3 kawaseScene(vec2 centerUV, float offsetPx) {
    vec2 st = vec2(offsetPx) / u_resolution;
    vec3 col = vec3(0);
    col += renderScene(centerUV + vec2( st.x,  st.y));
    col += renderScene(centerUV + vec2(-st.x,  st.y));
    col += renderScene(centerUV + vec2( st.x, -st.y));
    col += renderScene(centerUV + vec2(-st.x, -st.y));
    return col * 0.25;
}

void main(void)
{
    vec2 normCoord = gl_FragCoord.xy / u_resolution;
    float time = u_time / 5.0;
    rt = rot(time*.5);

    vec3 C = vec3(0);
    vec2 uv = (2.*gl_FragCoord.xy - u_resolution.xy) / max(u_resolution.x, u_resolution.y);

    vec3 ro = vec3(0, 0, time);
    vec3 rd = normalize(vec3(uv, -1));

    float x = 0.;
    float y = 0.;
    mat2 rx = rot(y);
    mat2 ry = rot(x);
    ro.zy *= rx; ro.xz *= ry;
    rd.zy *= rx; rd.xz *= ry;

    float dist = 0.01, m = 0.;
    float bnc = 0.;
    vec3 p = ro + rd;

    for(int i = 0; i < 64; i++)
    {
        vec2 ray = map(p);
        dist += ray.x;
        m = ray.y;
        p += rd * ray.x * .76;
        if(dist > MAX_DIST) break;

        if(abs(ray.x) < .0005)
        {
            if((m == 2. || m == 4.) && bnc < 4.)
            {
                bnc += 1.;
                rd = reflect(rd, normal(p, dist));
                p += rd * .001;
            }
        }
    }

    hitPoint = hp;

    if(dist < MAX_DIST)
    {
        vec3 n = normal(p, dist);
        vec4 h = vec4(SKY * .95, .5);   // was vec4(.5) -- neutral grey. h.w is the
                                        // specular exponent, so only rgb moves.

        if(m < 3.)
        {
            hitPoint.z -= time*1.5;
            hitPoint *= .45;
            vec3 fid = floor(hitPoint) - .5;
            h = vec4(0, 0, 0, 1);
        }

        if(m > 3.)
        {
            float roughness = 1.2;
            float ior       = .45;

            vec3 frd = frostRefractDir(rd, n, hp * 6.0, roughness, ior);

            vec2 refractOffset = frd.xy * 0.04;
            vec2 refractUV = clamp(normCoord + refractOffset, 0.001, 0.999);

            // blur the live scene at the refracted UV
            vec3 blurred = kawaseScene(refractUV, .10);

            float thickness = 1.3 + 0.3*worleyPeak(hp * 4.0, 7.);
            // Inert -- the line below that would apply it is commented out in the
            // artist's source. Coefficients flipped anyway (they absorbed BLUE
            // hardest, so re-enabling it would have tinted the glass warm).
            vec3 tint = exp(-vec3(0.16, 0.10, 0.04) * thickness * 3.0);
            // blurred *= tint;

            float cosI    = max(0., dot(-rd, n));
            float r0      = pow((1.-ior)/(1.+ior), 2.);
            float fresnel = r0 + (1.-r0)*pow(1.-cosI, 5.);

            vec3 lpos2 = vec3(3.*sin(time*.4), 10., 5.);
            vec3 l2    = normalize(lpos2 - p);
            float spec2 = 0.6 * pow(max(dot(reflect(-l2, n), -rd), 0.), 24.);

            C = blurred * (1.-fresnel*0.6) + vec3(spec2);
            gl_FragColor = vec4(C, 1.);
            return;
        }

        vec3 lpos = vec3(3.*sin(time*.4), 10., 5.);
        vec3 l = normalize(lpos - p);

        float diff = clamp(dot(n, l), 0., 1.) * .80 + .28;   // ambient floor, so the
                                                             // unlit side is not void
        float shadow = 0.;
        for(int i = 0; i < 8; i++)
        {
            vec3 sq = (p + n*.2) + l*shadow;
            float sh = map(sq).x;
            if(sh < MIN_DIST*dist || shadow > MAX_DIST) break;
            shadow += sh;
        }
        if(shadow < length(p-lpos)) diff *= .1;

        vec3 view = normalize(p - ro);
        vec3 ref  = reflect(normalize(lpos), n);
        float spec = 0.85 * pow(max(dot(view, ref), 0.), h.w);

        C += mix(h.rgb, l, drop) * diff + spec;
    }

    vec4 ret = vec4(pow(C, vec3(GAMMA)), 0.8);

    vec2 windowCoord = gl_FragCoord.xy / u_resolution;
    windowCoord.y = 1.0 - windowCoord.y;
    vec4 windowColor = texture2D(u_window, windowCoord);

    vec4 previousColor = texture2D(u_prevFrame, 1.01*gl_FragCoord.xy / u_resolution);
    vec4 col = clamp(ret,0.,1.);;

    gl_FragColor = col;//mix(1.-col, previousColor,1.-col);
}
