import AVFoundation
import CoreVideo
import Foundation
import QuartzCore

/// A video file looped as if it were the camera — a screen recording of the webcam feed
/// is enough to set the stitch up without the camera in the room.
final class FileSource: FrameSource {
    let name: String
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String?) -> Void)?

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private var timer: Timer?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        name = url.lastPathComponent
        item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func start() {
        player.play()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pull() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.pause()
    }

    private func pull() {
        if let error = item.error {
            onStatus?("Could not play \(name): \(error.localizedDescription)")
            stop()
            return
        }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        onFrame?(pb)
    }
}
