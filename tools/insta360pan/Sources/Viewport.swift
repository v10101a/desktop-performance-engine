import Foundation

/// Where the output frame is looking: a yaw and pitch on the sphere and a zoom, drawn
/// either as a band of the equirectangular sphere (the loop) or as a rectilinear virtual
/// camera. Degrees throughout; nothing here knows about lenses except how far up and down
/// the transmitted band reaches.
struct Viewport: Equatable {
    /// 0 = the front lens's axis, positive = right, in (−180, 180].
    var yaw: Double = 0
    /// Positive = up.
    var pitch: Double = 0
    /// 1 = the band's full height fills the frame; 2 = twice as close.
    var zoom: Double = 1
    var rectilinear = false
    var outputSize = SIMD2<Double>(1920, 1080)
    /// Half the band's vertical field, from the calibration.
    var bandHalfPitch: Double = 45

    static let minZoom = 0.25
    static let maxZoom = 40.0
    /// A rectilinear frame cannot show 180°; past this it is all stretch.
    static let maxRectilinearField = 150.0

    var aspect: Double { outputSize.x / max(1, outputSize.y) }

    /// Vertical extent of the frame, degrees — the field of view when rectilinear.
    var verticalSpan: Double {
        let span = 2 * bandHalfPitch / zoom
        return rectilinear ? min(Viewport.maxRectilinearField, span) : min(360, span)
    }

    var horizontalSpan: Double {
        if rectilinear {
            return 2 * atan(aspect * tan(verticalSpan / 2 * .pi / 180)) * 180 / .pi
        }
        return verticalSpan * aspect
    }

    /// For the shader: half spans in radians when equirectangular, tan of the half field
    /// when rectilinear.
    var halfSpanX: Double {
        rectilinear ? aspect * tan(verticalSpan / 2 * .pi / 180) : horizontalSpan / 2 * .pi / 180
    }
    var halfSpanY: Double {
        rectilinear ? tan(verticalSpan / 2 * .pi / 180) : verticalSpan / 2 * .pi / 180
    }

    /// Degrees per output pixel at the frame centre.
    var degreesPerPixel: Double {
        if rectilinear {
            return 2 * tan(verticalSpan / 2 * .pi / 180) / outputSize.y * 180 / .pi
        }
        return verticalSpan / outputSize.y
    }

    /// Angular offset (yaw, pitch) of an output pixel from the frame centre. Exact for the
    /// equirectangular band; on the rectilinear frame it is exact on the axes and close
    /// enough elsewhere for a pinch to feel anchored.
    func angles(atOutputPixel p: SIMD2<Double>) -> SIMD2<Double> {
        let nx = p.x / outputSize.x - 0.5
        let ny = 0.5 - p.y / outputSize.y
        if rectilinear {
            return [atan(nx * 2 * halfSpanX) * 180 / .pi, atan(ny * 2 * halfSpanY) * 180 / .pi]
        }
        return [nx * horizontalSpan, ny * verticalSpan]
    }

    /// Drag by `d` output pixels: the picture follows the pointer.
    mutating func pan(byOutputPixels d: SIMD2<Double>) {
        let k = degreesPerPixel
        yaw -= d.x * k
        pitch += d.y * k
        normalise()
    }

    /// Multiply the zoom by `factor`, keeping whatever is under `anchor` (an output pixel)
    /// where it is.
    mutating func zoom(by factor: Double, anchor: SIMD2<Double>) {
        let before = angles(atOutputPixel: anchor)
        zoom = min(Viewport.maxZoom, max(Viewport.minZoom, zoom * factor))
        let after = angles(atOutputPixel: anchor)
        yaw += before.x - after.x
        pitch += before.y - after.y
        normalise()
    }

    mutating func reset() {
        yaw = 0
        pitch = 0
        zoom = 1
        normalise()
    }

    /// Wrap the yaw and keep the frame on the band vertically: when the frame is taller
    /// than the band it is centred, otherwise it may not scroll past the top or bottom.
    mutating func normalise() {
        zoom = min(Viewport.maxZoom, max(Viewport.minZoom, zoom))
        yaw = yaw.truncatingRemainder(dividingBy: 360)
        if yaw > 180 { yaw -= 360 }
        if yaw <= -180 { yaw += 360 }
        let limit = max(0, bandHalfPitch - verticalSpan / 2)
        pitch = min(limit, max(-limit, pitch))
    }
}
