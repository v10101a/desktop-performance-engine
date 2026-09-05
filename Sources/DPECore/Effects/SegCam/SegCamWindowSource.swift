import AppKit
import CoreVideo

/// A third source for the segmenter: **another one of the show's own windows**.
///
/// The camera and a clip both hand over frames somebody else produced. This one reads a
/// window the piece already has on screen — cue 14's map, falling out of orbit — and
/// feeds that to the segmenter, so an act can be run through the segmenter rather than
/// played beside it.
///
/// **No Screen Recording.** It never captures the screen: it asks one view we own to
/// draw itself into a bitmap (`cacheDisplay`), which is an in-process drawing call and
/// needs no permission at all. Measured on a live `MKMapView` before it was built —
/// 15996 of 16000 sampled pixels came back lit, so MapKit does render into a cached
/// bitmap even though it composites on the GPU.
///
/// Two costs to know about. Drawing a view has to happen on the **main thread**, so the
/// capture is paced deliberately slowly (`hz`, default 15) and scaled down (`maxWidth`)
/// — the segmenter reduces to a 192-wide luma grid anyway, and the crops that end up in
/// the swarm's windows are meant to look like fragments. And the frame is handed to the
/// engine on a background queue, because the engine expects to do its work off main and
/// the pump cannot afford Vision on the beat.
final class SegCamWindowSource: SegCamSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String?) -> Void)?

    private weak var view: NSView?
    private let hz: Double
    private let maxWidth: CGFloat
    private var timer: Timer?
    private let work = DispatchQueue(label: "dpe.segcam.window", qos: .userInitiated)
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    init(view: NSView, hz: Double = 15, maxWidth: CGFloat = 640) {
        self.view = view
        self.hz = max(1, hz)
        self.maxWidth = maxWidth
    }

    func start() {
        guard view != nil else { onStatus?("no window to segment"); return }
        onStatus?(nil)
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in self?.grab() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }

    /// Main thread: AppKit drawing is not optional about that.
    private func grab() {
        guard let view, view.window != nil, view.bounds.width > 1 else { return }
        let scale = min(1, maxWidth / view.bounds.width)
        let size = CGSize(width: (view.bounds.width * scale).rounded(),
                          height: (view.bounds.height * scale).rounded())
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return }
        guard let buffer = makeBuffer(size) else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // Off main for the segmenting, like every other source.
        work.async { [weak self] in self?.onFrame?(buffer) }
    }

    private func makeBuffer(_ size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            pool = made
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
