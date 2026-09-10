import Foundation
import simd

/// The lens model: what the camera does to the sphere on its way into the frame, and how
/// the two lenses sit relative to each other. Everything the stitch needs, all of it live,
/// and saved to disk as soon as it changes.
///
/// Circle values are in pixels of a 1920×1080 frame — so of a 1920×540 half — whatever
/// frame actually arrives; the renderer scales them.
struct Calibration: Codable, Equatable {
    enum Projection: String, Codable, CaseIterable {
        case equidistant, equisolid, stereographic, orthographic

        var title: String {
            switch self {
            case .equidistant: return "Equidistant (f·θ)"
            case .equisolid: return "Equisolid"
            case .stereographic: return "Stereographic"
            case .orthographic: return "Orthographic"
            }
        }

        var index: UInt32 { UInt32(Projection.allCases.firstIndex(of: self) ?? 0) }
    }

    /// How the lens maps angle-from-axis to radius on the sensor.
    var projection: Projection = .equidistant
    /// Full angular field of the lens at the edge of its image circle, degrees.
    var fovDegrees: Double = 200
    /// The image circle as it lands in each half: centre and radii, in pixels of a 1920×540
    /// half. The default has the circle spanning the half's width, with the transmitted
    /// band being the middle of it.
    var circleCenterX: Double = 960
    var circleCenterY: Double = 270
    var circleRadiusX: Double = 960
    var circleRadiusY: Double = 960
    /// Small rotations of each lens from its nominal axis, degrees. The front lens's yaw
    /// defines heading zero, so it has none.
    var frontPitch: Double = 0
    var frontRoll: Double = 0
    var rearYaw: Double = 0
    var rearPitch: Double = 0
    var rearRoll: Double = 0
    /// Distance between the two lenses' entrance pupils, metres. The parallax.
    var baselineMetres: Double = 0.03
    /// The subject distance the seams are aligned for, metres. Things at this distance
    /// join up across a seam; nearer or farther things drift by the parallax.
    var stitchDistanceMetres: Double = 2
    /// Width of the cross-fade at each seam, degrees of lens angle.
    var blendDegrees: Double = 6
    /// Layout switches: which half is which lens, and whether a half reads backwards.
    var swapHalves = false
    var mirrorFront = false
    var mirrorRear = false

    static let referenceFrame = SIMD2<Double>(1920, 1080)

    init() {}

    // MARK: - Geometry

    var thetaMaxRadians: Double { fovDegrees / 2 * .pi / 180 }

    /// Lens angle (radians) at a normalised radius on the image circle: the inverse of the
    /// projection.
    func theta(atNormalisedRadius r: Double) -> Double {
        let r = min(1, max(0, r))
        let tm = thetaMaxRadians
        switch projection {
        case .equidistant: return r * tm
        case .equisolid: return 2 * asin(min(1, r * sin(tm / 2)))
        case .stereographic: return 2 * atan(r * tan(tm / 2))
        case .orthographic: return asin(min(1, r * sin(min(tm, .pi / 2))))
        }
    }

    /// Half the band's vertical field, degrees: how far above (or below) the horizon the
    /// front lens can see at its centre column before the transmitted band runs out.
    var bandHalfPitchDegrees: Double {
        let halfHeight = Calibration.referenceFrame.y / 2
        let up = circleCenterY / max(1, circleRadiusY)
        let down = (halfHeight - circleCenterY) / max(1, circleRadiusY)
        let theta = self.theta(atNormalisedRadius: min(up, down))
        return max(5, min(90, theta * 180 / .pi))
    }

    // MARK: - Persistence

    /// Missing keys fall back to the defaults, so a file from an older build still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = Calibration()
        projection = get(.projection, d.projection)
        fovDegrees = get(.fovDegrees, d.fovDegrees)
        circleCenterX = get(.circleCenterX, d.circleCenterX)
        circleCenterY = get(.circleCenterY, d.circleCenterY)
        circleRadiusX = get(.circleRadiusX, d.circleRadiusX)
        circleRadiusY = get(.circleRadiusY, d.circleRadiusY)
        frontPitch = get(.frontPitch, d.frontPitch)
        frontRoll = get(.frontRoll, d.frontRoll)
        rearYaw = get(.rearYaw, d.rearYaw)
        rearPitch = get(.rearPitch, d.rearPitch)
        rearRoll = get(.rearRoll, d.rearRoll)
        baselineMetres = get(.baselineMetres, d.baselineMetres)
        stitchDistanceMetres = get(.stitchDistanceMetres, d.stitchDistanceMetres)
        blendDegrees = get(.blendDegrees, d.blendDegrees)
        swapHalves = get(.swapHalves, d.swapHalves)
        mirrorFront = get(.mirrorFront, d.mirrorFront)
        mirrorRear = get(.mirrorRear, d.mirrorRear)
    }

    /// `~/Library/Application Support/insta360pan/calibration.json`
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("insta360pan", isDirectory: true)
            .appendingPathComponent("calibration.json")
    }

    static func load(from url: URL) throws -> Calibration {
        try JSONDecoder().decode(Calibration.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - What the shader sees

/// Mirrors `LensParams` in Shaders.swift, field for field.
struct LensParams {
    var row0: SIMD4<Float>
    var row1: SIMD4<Float>
    var row2: SIMD4<Float>
    var circle: SIMD4<Float>
    var shape: SIMD4<Float>
}

/// Mirrors `StitchUniforms` in Shaders.swift, field for field.
struct StitchUniforms {
    var view: SIMD4<Float>
    var stitch: SIMD4<Float>
    var misc: SIMD4<Float>
    var flags: UInt32
    var projection: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var lens0: LensParams
    var lens1: LensParams

    static let rectilinear: UInt32 = 1
    static let rawView: UInt32 = 2
    static let flipVertical: UInt32 = 4
    static let overlay: UInt32 = 8
}

extension Calibration {
    private static func rotationY(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        // Ry · (0,0,1) = (sin a, 0, cos a): positive yaw turns the axis to the right.
        return simd_double3x3(columns: (SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c)))
    }

    private static func rotationX(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        // Rx · (0,0,1) = (0, sin a, cos a): positive pitch tilts the axis up.
        return simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, c, -s), SIMD3(0, s, c)))
    }

    private static func rotationZ(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
    }

    /// The parameters for one lens. `index` 0 is the front lens (axis +z), 1 the rear
    /// (axis −z). `frameSize` scales the circle from the reference frame to the real one.
    func lensParams(index: Int, frameSize: SIMD2<Double>) -> LensParams {
        let rad = Double.pi / 180
        let front = index == 0
        // The lens's orientation in the world: yaw, then pitch, then roll about its axis.
        let yaw = front ? 0 : .pi + rearYaw * rad
        let pitch = (front ? frontPitch : rearPitch) * rad
        let roll = (front ? frontRoll : rearRoll) * rad
        let m = Calibration.rotationY(yaw) * Calibration.rotationX(pitch) * Calibration.rotationZ(roll)
        // The shader wants world → lens, which is the transpose; its rows are m's columns.
        let r0 = m.columns.0, r1 = m.columns.1, r2 = m.columns.2

        let scale = frameSize / Calibration.referenceFrame
        let halfWidth = frameSize.x, halfHeight = frameSize.y / 2
        let circle = SIMD4<Float>(
            Float(circleCenterX * scale.x / halfWidth),
            Float(circleCenterY * scale.y / halfHeight),
            Float(circleRadiusX * scale.x / halfWidth),
            Float(circleRadiusY * scale.y / halfHeight))
        let pupilZ = (front ? 1.0 : -1.0) * baselineMetres / 2
        let mirror: Float = (front ? mirrorFront : mirrorRear) ? -1 : 1
        let half: Float = (front != swapHalves) ? 0 : 1        // front in the top half unless swapped
        return LensParams(
            row0: SIMD4<Float>(Float(r0.x), Float(r0.y), Float(r0.z), 0),
            row1: SIMD4<Float>(Float(r1.x), Float(r1.y), Float(r1.z), 0),
            row2: SIMD4<Float>(Float(r2.x), Float(r2.y), Float(r2.z), 0),
            circle: circle,
            shape: SIMD4<Float>(Float(thetaMaxRadians), Float(pupilZ), mirror, half))
    }

    /// The whole uniform block for a viewport onto this calibration.
    func uniforms(viewport: Viewport, frameSize: SIMD2<Double>, flags: UInt32,
                  lineWidthPixels: Double = 3, time: Double = 0, sceneDistance: Double? = nil) -> StitchUniforms {
        let rad = Double.pi / 180
        var f = flags
        if viewport.rectilinear { f |= StitchUniforms.rectilinear }
        let halfAspect = frameSize.x / max(1, frameSize.y / 2)
        return StitchUniforms(
            view: SIMD4<Float>(Float(viewport.yaw * rad), Float(viewport.pitch * rad),
                               Float(viewport.halfSpanX), Float(viewport.halfSpanY)),
            stitch: SIMD4<Float>(Float(blendDegrees * rad), Float(sceneDistance ?? stitchDistanceMetres), 0, 0),
            misc: SIMD4<Float>(Float(lineWidthPixels / frameSize.x), Float(halfAspect), Float(time), 0),
            flags: f,
            projection: projection.index,
            lens0: lensParams(index: 0, frameSize: frameSize),
            lens1: lensParams(index: 1, frameSize: frameSize))
    }
}
