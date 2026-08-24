import Metal
import simd

/// Laid out to match `struct Uniforms` in the Metal source below.
/// 64 + 64 + 48 + 16×11 = 336 bytes on both sides. Time rides in `camera.w`,
/// which keeps a bare `float3` + trailing scalar (whose padding rules differ
/// between Swift and MSL) out of the struct.
struct Uniforms {
    var modelViewProjection: float4x4
    var model: float4x4
    var normalMatrix: float3x3
    var camera: SIMD4<Float>      // xyz = eye, w = elapsed seconds
    var material: SIMD4<Float>    // x = roughness, y = env intensity, z = ambient, w = unused
    var tint: SIMD4<Float>        // rgb = F0 (metal base reflectance), w = highlight strength
    var windowRect: SIMD4<Float>  // window on the display, in points, top-left origin
    var displaySize: SIMD4<Float> // x,y = display size in points; z = mirror enabled; w = unused
    var lens: SIMD4<Float>        // x = tan(fovy/2), y = aspect, z = eye distance, w = desktop plane depth
    var glass: SIMD4<Float>       // x = is glass, y = ior, z = dispersion, w = unused
    var glassTint: SIMD4<Float>   // rgb = transmission tint, w = body opacity
    var shape: SIMD4<Float>       // x = lobes, y = lobe depth, z = twists, w = phase
    var shape2: SIMD4<Float>      // x = major radius, y = minor radius, z = ring wobble, w = wobble freq
}

/// A named surface. Conductors use `f0` as their colour and have no diffuse and
/// no transmission; dielectrics ignore `f0` (glass is a flat 0.04) and instead
/// refract, tinting whatever comes through by `transmissionTint`.
struct MaterialPreset {
    let name: String
    let f0: SIMD3<Float>
    var isGlass = false
    var ior: Float = 1.0
    /// Spread between the per-channel refraction indices — the source of the
    /// coloured fringing at the edges.
    var dispersion: Float = 0
    var transmissionTint = SIMD3<Float>(1, 1, 1)
    /// How much of the index to actually apply. Below 1 stands in for the exit
    /// interface, which bends the ray back the other way.
    var refractionStrength: Float = 0.75
    /// Only used when there is no capture to refract: how milky the glass is, so
    /// it does not vanish entirely against the desktop.
    var bodyOpacity: Float = 0.10

    static let all: [MaterialPreset] = [
        // Near-clear: the point is the distortion, not a tint over the top.
        MaterialPreset(
            name: "glass", f0: SIMD3<Float>(0.04, 0.04, 0.04),
            isGlass: true, ior: 1.52, dispersion: 0.018,
            transmissionTint: SIMD3<Float>(0.97, 0.99, 1.00),
            refractionStrength: 0.80, bodyOpacity: 0.09
        ),
        MaterialPreset(
            name: "crystal", f0: SIMD3<Float>(0.04, 0.04, 0.04),
            isGlass: true, ior: 1.90, dispersion: 0.055,
            transmissionTint: SIMD3<Float>(1.00, 1.00, 1.00),
            refractionStrength: 0.95, bodyOpacity: 0.11
        ),
        MaterialPreset(name: "chrome",   f0: SIMD3<Float>(0.95, 0.96, 0.98)),
        MaterialPreset(name: "gold",     f0: SIMD3<Float>(1.00, 0.77, 0.34)),
        MaterialPreset(name: "copper",   f0: SIMD3<Float>(0.96, 0.64, 0.54)),
        MaterialPreset(name: "titanium", f0: SIMD3<Float>(0.62, 0.66, 0.72)),
    ]
}

struct RenderSettings {
    var aspect: Float = 1
    var elapsed: Double = 0
    var cameraDistance: Float = 4.0
    var roughness: Float = 0.04
    var envIntensity: Float = 1.15
    var ambient: Float = 0.12
    var material: MaterialPreset = MaterialPreset.all[0]
    var highlightStrength: Float = 2.0

    /// Equirectangular fallback for rays that miss the desktop.
    var surround: MTLTexture
    /// Screen capture, sampled as a flat plane behind the window. When the
    /// mirror is off this is just `surround` again, to keep the binding valid.
    var screen: MTLTexture
    var mirrorEnabled = false
    /// Window position and size on the display, in points, top-left origin.
    var windowRect = SIMD4<Float>(0, 0, 1, 1)
    var displaySize = SIMD2<Float>(1, 1)
    /// How far behind the torus the desktop plane sits, in world units.
    var planeDistance: Float = 2.0

    // Shape, evaluated per-vertex on the GPU. The two amplitudes below are 0,
    // which collapses the surface to a plain torus: R + r·cos v. Raise
    // `lobeDepth` to put ridges around the tube and `twists` to shear them along
    // the ring, and the twist comes straight back — `twistPhase` already
    // animates, it just has nothing to act on at zero amplitude.
    /// Ridges running around the tube. No effect while `lobeDepth` is 0.
    var lobes: Float = 5
    /// How far those ridges stand out, as a fraction of the tube radius.
    var lobeDepth: Float = 0
    /// Turns of shear along the ring — this is the twist.
    var twists: Float = 0
    var twistPhase: Float = 0
    var majorRadius: Float = 1.0
    var minorRadius: Float = 0.38
    /// Breathing of the ring radius. No effect while 0.
    var ringWobble: Float = 0
    var wobbleFrequency: Float = 3
}

enum SceneError: Error, CustomStringConvertible {
    case noDevice
    case libraryFailed(String)
    case missingFunction(String)
    case setupFailed(String)

    var description: String {
        switch self {
        case .noDevice: return "no Metal device available"
        case .libraryFailed(let m): return "shader compile failed: \(m)"
        case .missingFunction(let n): return "shader function '\(n)' not found"
        case .setupFailed(let m): return m
        }
    }
}

/// Owns everything needed to draw one torus: pipeline, depth state, geometry,
/// environment sampler. Deliberately independent of MTKView so the offscreen
/// snapshot path can reuse it verbatim.
final class TorusScene {
    static let colorFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let sampleCount = 4

    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let surroundSampler: MTLSamplerState
    private let screenSampler: MTLSamplerState
    private static let fovyRadians: Float = 50 * .pi / 180
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int

    init(device: MTLDevice) throws {
        self.device = device

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw SceneError.libraryFailed("\(error)")
        }
        guard let vertexFunction = library.makeFunction(name: "torus_vertex") else {
            throw SceneError.missingFunction("torus_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "torus_fragment") else {
            throw SceneError.missingFunction("torus_fragment")
        }

        // A vertex is just its (u, v) parameter pair; position and normal are
        // derived in the vertex shader.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TorusVertex>.stride

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = Self.sampleCount
        descriptor.colorAttachments[0].pixelFormat = Self.colorFormat
        descriptor.depthAttachmentPixelFormat = Self.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

        // Surround is equirectangular: longitude wraps, latitude clamps at the poles.
        let surroundDescriptor = MTLSamplerDescriptor()
        surroundDescriptor.sAddressMode = .repeat
        surroundDescriptor.tAddressMode = .clampToEdge
        surroundDescriptor.minFilter = .linear
        surroundDescriptor.magFilter = .linear
        surroundDescriptor.mipFilter = .linear
        surroundSampler = device.makeSamplerState(descriptor: surroundDescriptor)!

        // The screen is a finite plane — clamp on both axes, never wrap.
        let screenDescriptor = MTLSamplerDescriptor()
        screenDescriptor.sAddressMode = .clampToEdge
        screenDescriptor.tAddressMode = .clampToEdge
        screenDescriptor.minFilter = .linear
        screenDescriptor.magFilter = .linear
        screenDescriptor.mipFilter = .linear
        screenSampler = device.makeSamplerState(descriptor: screenDescriptor)!

        let mesh = TorusMesh.make(majorSegments: 180, minorSegments: 72)
        vertexBuffer = device.makeBuffer(
            bytes: mesh.vertices,
            length: MemoryLayout<TorusVertex>.stride * mesh.vertices.count,
            options: .storageModeShared
        )!
        indexBuffer = device.makeBuffer(
            bytes: mesh.indices,
            length: MemoryLayout<UInt16>.stride * mesh.indices.count,
            options: .storageModeShared
        )!
        indexCount = mesh.indices.count
    }

    /// Tumble about three axes at incommensurate rates, so the silhouette never
    /// settles into a loop the eye can predict.
    func modelMatrix(elapsed: Double) -> float4x4 {
        let t = Float(elapsed)
        return rotationMatrix(axis: SIMD3<Float>(0, 1, 0), angle: t * 0.62)
            * rotationMatrix(axis: SIMD3<Float>(1, 0, 0), angle: t * 0.27 + 0.9)
            * rotationMatrix(axis: SIMD3<Float>(0, 0, 1), angle: t * 0.15)
    }

    func encode(into encoder: MTLRenderCommandEncoder, settings: RenderSettings) {
        let model = modelMatrix(elapsed: settings.elapsed)
        let eye = SIMD3<Float>(0, 0, settings.cameraDistance)
        let view = translationMatrix(-eye)
        let projection = perspectiveMatrix(
            fovyRadians: Self.fovyRadians,
            aspect: settings.aspect,
            near: 0.1,
            far: 100
        )

        var uniforms = Uniforms(
            modelViewProjection: projection * view * model,
            model: model,
            normalMatrix: upperLeft3x3(model),
            camera: SIMD4<Float>(eye.x, eye.y, eye.z, Float(settings.elapsed)),
            material: SIMD4<Float>(
                settings.roughness, settings.envIntensity, settings.ambient, 0
            ),
            tint: SIMD4<Float>(
                settings.material.f0.x, settings.material.f0.y, settings.material.f0.z,
                settings.highlightStrength
            ),
            windowRect: settings.windowRect,
            displaySize: SIMD4<Float>(
                settings.displaySize.x, settings.displaySize.y,
                settings.mirrorEnabled ? 1 : 0, 0
            ),
            lens: SIMD4<Float>(
                tan(Self.fovyRadians * 0.5),
                settings.aspect,
                settings.cameraDistance,
                settings.planeDistance
            ),
            glass: SIMD4<Float>(
                settings.material.isGlass ? 1 : 0,
                settings.material.ior,
                settings.material.dispersion,
                settings.material.refractionStrength
            ),
            glassTint: SIMD4<Float>(
                settings.material.transmissionTint.x,
                settings.material.transmissionTint.y,
                settings.material.transmissionTint.z,
                settings.material.bodyOpacity
            ),
            shape: SIMD4<Float>(
                settings.lobes, settings.lobeDepth, settings.twists, settings.twistPhase
            ),
            shape2: SIMD4<Float>(
                settings.majorRadius, settings.minorRadius,
                settings.ringWobble, settings.wobbleFrequency
            )
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        // Closed opaque surface: the depth test alone resolves the interior,
        // so culling is left off rather than depending on index winding.
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(settings.surround, index: 0)
        encoder.setFragmentTexture(settings.screen, index: 1)
        encoder.setFragmentSamplerState(surroundSampler, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float PI = 3.14159265358979323846;

    struct VertexIn {
        float2 uv [[attribute(0)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldPos;
        float3 normal;
    };

    struct Uniforms {
        float4x4 modelViewProjection;
        float4x4 model;
        float3x3 normalMatrix;
        float4   camera;      // xyz = eye position, w = elapsed seconds
        float4   material;    // x = roughness, y = env intensity, z = ambient
        float4   tint;        // rgb = F0, w = highlight strength
        float4   windowRect;  // xy = window origin on display (points, top-left), zw = size
        float4   displaySize; // xy = display size in points, z = mirror enabled
        float4   lens;        // x = tan(fovy/2), y = aspect, z = eye distance, w = plane depth
        float4   glass;       // x = is glass, y = ior, z = dispersion
        float4   glassTint;   // rgb = transmission tint, w = body opacity
        float4   shape;       // x = lobes, y = lobe depth, z = twists, w = phase
        float4   shape2;      // x = major radius, y = minor radius, z = wobble, w = wobble freq
    };

    // The surface, evaluated per vertex rather than baked into the mesh — which
    // is what lets the twist turn over time for free.
    static float3 surfacePoint(float2 p, constant Uniforms &u)
    {
        float U = p.x, V = p.y;

        float lobes      = u.shape.x;
        float lobeDepth  = u.shape.y;
        float twists     = u.shape.z;
        float phase      = u.shape.w;

        float major      = u.shape2.x;
        float minor      = u.shape2.y;
        float wobble     = u.shape2.z;
        float wobbleFreq = u.shape2.w;

        // Ridges around the tube (lobes * V), sheared along it (twists * U).
        // That shear is the twist: each cross-section is rolled a little further
        // than the one before, so the ridges spiral instead of lining up.
        float tube = minor * (1.0 + lobeDepth * cos(lobes * V + twists * U + phase));

        // And the ring breathes, so the silhouette is never a plain circle.
        float ring = major + wobble * sin(wobbleFreq * U + phase * 0.7);

        float radial = ring + tube * cos(V);
        return float3(radial * cos(U), radial * sin(U), tube * sin(V));
    }

    vertex VertexOut torus_vertex(VertexIn in [[stage_in]],
                                  constant Uniforms &u [[buffer(1)]])
    {
        // Normal by central difference. An analytic normal for a surface this
        // deformed is painful to keep in sync with the position, and four extra
        // evaluations per vertex cost nothing — this one can never go stale.
        const float h = 0.003;
        float3 position = surfacePoint(in.uv, u);
        float3 dU = surfacePoint(in.uv + float2(h, 0), u) - surfacePoint(in.uv - float2(h, 0), u);
        float3 dV = surfacePoint(in.uv + float2(0, h), u) - surfacePoint(in.uv - float2(0, h), u);
        float3 normal = normalize(cross(dV, dU));

        VertexOut out;
        out.position = u.modelViewProjection * float4(position, 1.0);
        out.worldPos = (u.model * float4(position, 1.0)).xyz;
        out.normal   = u.normalMatrix * normal;
        return out;
    }

    // Equirectangular lookup. The LOD is passed explicitly rather than derived
    // from screen-space gradients: uv.x wraps at the atan2 seam, and gradient
    // based mip selection would read that wrap as a huge derivative and blur a
    // visible line down the model.
    static float3 sampleEnvironment(texture2d<float> environment,
                                    sampler environmentSampler,
                                    float3 direction,
                                    float lod)
    {
        float3 d = normalize(direction);
        float2 uv;
        uv.x = atan2(d.z, d.x) / (2.0 * PI) + 0.5;
        uv.y = acos(clamp(d.y, -1.0, 1.0)) / PI;
        float3 sampled = environment.sample(environmentSampler, uv, level(lod)).rgb;
        return pow(sampled, 2.2);   // stored sRGB-ish, shade in linear
    }

    // Intersects a reflected ray with the desktop, modelled as a plane at
    // z = -lens.w, and converts the hit point to a UV on the captured display.
    //
    // The window is a viewport onto this scene, so a point on that plane maps
    // back through the same frustum the torus is drawn with: at the plane's
    // distance from the eye the frustum is `halfHeight` tall, which turns the
    // hit into window-normalised coordinates. Offsetting by where the window
    // actually sits on the display turns those into display coordinates — which
    // is what makes the reflection line up with what is really behind the glass.
    static bool desktopHit(float3 origin, float3 direction,
                           constant Uniforms &u, thread float2 &uv)
    {
        // Only rays travelling away from the viewer can reach the desktop.
        if (direction.z > -1e-4) { return false; }

        float planeZ = -u.lens.w;
        float t = (planeZ - origin.z) / direction.z;
        if (t <= 0.0) { return false; }

        float3 hit = origin + t * direction;

        float eyeToPlane = u.lens.z + u.lens.w;
        float halfHeight = eyeToPlane * u.lens.x;
        float halfWidth  = halfHeight * u.lens.y;

        // -1…1 across the window, y up.
        float2 ndc = float2(hit.x / halfWidth, hit.y / halfHeight);

        // 0…1 across the window, y down to match texture rows.
        float2 windowUV = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);

        float2 point = u.windowRect.xy + windowUV * u.windowRect.zw;
        uv = point / u.displaySize.xy;
        return true;
    }

    // Follows a ray out into the world and returns what it sees. Used for both
    // the reflected ray and, for glass, the refracted ones — a reflection and a
    // refraction differ only in the direction handed to this.
    static float3 traceEnvironment(float3 origin, float3 direction,
                                   constant Uniforms &u,
                                   texture2d<float> environment, sampler environmentSampler,
                                   texture2d<float> screen, sampler screenSampler,
                                   float roughness)
    {
        bool mirroring = u.displaySize.z > 0.5;
        float maxLod = float(max(environment.get_num_mip_levels(), 1u) - 1u);
        float screenMaxLod = float(max(screen.get_num_mip_levels(), 1u) - 1u);
        float lod = mix(0.75, maxLod, sqrt(saturate(roughness)));

        // Ambient surround, for rays that never reach the desktop — they point
        // back past the viewer, where there is no screen to see. When mirroring,
        // this is the capture itself at a high mip, so the surface picks up the
        // colour of your screen rather than an unrelated grey studio.
        float3 result = mirroring
            ? sampleEnvironment(screen, environmentSampler, direction, max(screenMaxLod * 0.60, lod))
            : sampleEnvironment(environment, environmentSampler, direction, lod);

        // Where the ray does land on the desktop plane, the real screen wins.
        if (mirroring) {
            float2 uv;
            if (desktopHit(origin, direction, u, uv)) {
                // Full strength anywhere on the display, fading out only once the
                // hit runs past its edge — where clamped sampling is just
                // smearing the border pixel and no longer means anything.
                float2 outsideBy = max(-uv, uv - 1.0);
                float inside = 1.0 - smoothstep(0.0, 0.25, max(max(outsideBy.x, outsideBy.y), 0.0));
                if (inside > 0.0) {
                    float screenLod = mix(0.5, screenMaxLod, sqrt(saturate(roughness)));
                    float3 desktop = pow(
                        screen.sample(screenSampler, uv, level(screenLod)).rgb, 2.2
                    );
                    result = mix(result, desktop, inside);
                }
            }
        }
        return result;
    }

    // refract() returns zero under total internal reflection.
    static float3 orFallback(float3 v, float3 fallback) {
        return dot(v, v) < 1e-6 ? fallback : v;
    }

    fragment float4 torus_fragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(1)]],
                                   texture2d<float> environment [[texture(0)]],
                                   texture2d<float> screen [[texture(1)]],
                                   sampler environmentSampler [[sampler(0)]],
                                   sampler screenSampler [[sampler(1)]])
    {
        float3 N = normalize(in.normal);
        float3 V = normalize(u.camera.xyz - in.worldPos);
        if (dot(N, V) < 0.0) { N = -N; }   // back faces survive; flip them forward

        float roughness    = u.material.x;
        float envIntensity = u.material.y;
        float ambient      = u.material.z;
        float highlight    = u.tint.w;

        bool mirroring = u.displaySize.z > 0.5;
        float cosTheta = saturate(dot(N, V));

        float3 R = reflect(-V, N);
        float3 reflection = traceEnvironment(
            in.worldPos, R, u, environment, environmentSampler, screen, screenSampler, roughness
        );

        // One sharp virtual key light, common to both materials. Without it a
        // dark desktop leaves nothing to read the form by.
        float3 keyDir = normalize(float3(-0.45, 0.85, 0.60));
        float3 halfKey = normalize(keyDir + V);
        float shininess = mix(2048.0, 24.0, saturate(roughness));
        float glint = pow(saturate(dot(N, halfKey)), shininess);

        float3 color;
        float alpha = 1.0;

        if (u.glass.x > 0.5) {
            // Dielectric. Reflectance is a flat 0.04 head-on and climbs to 1 at
            // grazing angles, so the rim turns mirror while the middle stays
            // see-through — that contrast is most of what reads as "glass".
            float3 F0 = float3(0.04);
            float3 fresnel = F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
            float dispersion = u.glass.z;

            // Only the entry interface is traced, but a solid ring refracts
            // twice — in and out — and the exit bends the ray back most of the
            // way. Softening the index towards 1 approximates that second
            // interface; refracting at full strength here reads as a fisheye
            // lens rather than as glass.
            float ior = 1.0 + (max(u.glass.y, 1.001) - 1.0) * u.glass.w;
            float eta = 1.0 / ior;

            if (mirroring) {
                // Each channel bends by a slightly different amount — that is
                // where the coloured fringing comes from. Three traces, one per
                // wavelength, through the same machinery the reflection uses.
                float3 dirR = orFallback(refract(-V, N, eta * (1.0 - dispersion)), R);
                float3 dirG = orFallback(refract(-V, N, eta), R);
                float3 dirB = orFallback(refract(-V, N, eta * (1.0 + dispersion)), R);

                float3 through = float3(
                    traceEnvironment(in.worldPos, dirR, u, environment, environmentSampler,
                                     screen, screenSampler, roughness).r,
                    traceEnvironment(in.worldPos, dirG, u, environment, environmentSampler,
                                     screen, screenSampler, roughness).g,
                    traceEnvironment(in.worldPos, dirB, u, environment, environmentSampler,
                                     screen, screenSampler, roughness).b
                );
                through *= u.glassTint.rgb;

                color = reflection * fresnel + through * (1.0 - fresnel);
            } else {
                // Nothing captured to refract, so hand the job to the window
                // compositor instead: emit only what the glass itself adds and
                // let the real desktop come through the alpha. No lensing this
                // way — the compositor can blend, but it cannot bend.
                //
                // Clear glass reflects 4% head-on, which alone is all but
                // invisible against the desktop, so it also gets a faint body.
                // That body is tinted by the environment rather than flat white,
                // so it still picks up the light around it. Keep it low: this is
                // the only thing standing between "glass" and "grey blob".
                float body = u.glassTint.w;
                color = reflection * fresnel + reflection * u.glassTint.rgb * body * 0.5;
                alpha = saturate(dot(fresnel, float3(1.0 / 3.0)) + body);
            }

            // Kept small on glass — a big highlight is opaque light, and opaque
            // light is the opposite of what this material is for.
            color += glint * highlight * 0.3;
            // It still has to raise alpha with it, or it reads as a washed-out
            // patch rather than a glint.
            alpha = saturate(alpha + glint * highlight * 0.3);
        } else {
            // Conductor: F0 is the colour, and there is no diffuse term and no
            // transmission at all.
            float3 F0 = u.tint.rgb;
            float3 fresnel = F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);

            float maxLod = float(max(environment.get_num_mip_levels(), 1u) - 1u);
            float screenMaxLod = float(max(screen.get_num_mip_levels(), 1u) - 1u);
            // Widest mip along N stands in for irradiance, so the metal picks up
            // the average colour of its surroundings instead of going black.
            float3 irradiance = mirroring
                ? sampleEnvironment(screen, environmentSampler, N, screenMaxLod)
                : sampleEnvironment(environment, environmentSampler, N, maxLod);

            color = reflection * fresnel * envIntensity + irradiance * F0 * ambient;
            color += F0 * glint * highlight;
        }

        color = color / (1.0 + color * 0.25);   // gentle knee
        color = pow(color, float3(1.0 / 2.2));  // manual gamma: target is .bgra8Unorm

        return float4(color, alpha);
    }
    """
}
