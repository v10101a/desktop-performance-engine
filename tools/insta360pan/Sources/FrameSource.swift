import CoreVideo
import Foundation

/// Anything that produces camera-shaped frames: the Insta360 itself, a recording of its
/// feed, or the test pattern. The renderer does not care which.
protocol FrameSource: AnyObject {
    /// Shown in the title bar and the status line.
    var name: String { get }
    /// Called with each new BGRA frame, on whatever thread the source uses.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// Called on the main queue with something to tell the user, or nil when all is well.
    var onStatus: ((String?) -> Void)? { get set }
    func start()
    func stop()
}
