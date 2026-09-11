import AppKit
import AVFoundation

/// A looping, muted video in a window — a desktop animation playing as scenery.
///
/// `AVQueuePlayer` + `AVPlayerLooper` for a seamless loop (rather than seeking to zero on
/// the end notification, which drops a frame at the seam), drawn by an `AVPlayerLayer`.
/// Muted, because the show has its own soundtrack — the same rule the segmenter's file
/// source follows.
///
/// Like every other live surface here it is **scenery**: `hitTest` returns nil so clicks
/// fall through to the desktop, and it pauses the player when it leaves the window so a
/// closed window is not left decoding frames.
final class VideoContentView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var status: String?

    init(size: NSSize, content: ContentSpec) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Fill the window edge to edge; the clips are 16:9 and the windows nearly so, so
        // the crop is a sliver rather than a letterbox.
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)

        player.isMuted = true
        player.volume = 0
        playerLayer.player = player

        guard let path = content.path else { status = "no clip"; return }
        let url = URL(fileURLWithPath: resolveResourcePath(path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "no clip at \(url.lastPathComponent)"
            return
        }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Scenery, like every other live surface here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player.pause() } else if looper != nil { player.play() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let status else { return }
        NSColor.black.setFill()
        bounds.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: status, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let h = string.boundingRect(with: NSSize(width: bounds.width - 40,
                                                 height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin]).height
        string.draw(with: NSRect(x: 20, y: bounds.midY - h / 2, width: bounds.width - 40, height: h),
                    options: [.usesLineFragmentOrigin])
    }

    deinit { player.pause() }

    // MARK: - Test seams
    var hasClipForTesting: Bool { looper != nil }
    var statusForTesting: String? { status }
}
