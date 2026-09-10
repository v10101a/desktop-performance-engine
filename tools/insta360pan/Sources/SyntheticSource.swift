import CoreVideo
import Foundation

/// The test scene, as a source: switching to it turns the renderer's synthetic camera on,
/// which paints a graticule world through the lens model instead of waiting for frames.
/// A stitch of it with the default calibration is seamless by construction; every control
/// then shows its effect against that.
final class SyntheticSource: FrameSource {
    let name = "Test scene"
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String?) -> Void)?
    private weak var renderer: StitchRenderer?

    init(renderer: StitchRenderer) {
        self.renderer = renderer
    }

    func start() {
        renderer?.synthetic = true
    }

    func stop() {
        renderer?.synthetic = false
    }
}
