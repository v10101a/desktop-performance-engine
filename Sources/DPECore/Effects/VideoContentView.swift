import AppKit
import AVFoundation

/// A looping, muted video in a window — a desktop animation playing as scenery.
///
/// `AVQueuePlayer` + `AVPlayerLooper` for a seamless loop (rather than seeking to zero on
/// the end notification, which drops a frame at the seam), drawn by an `AVPlayerLayer`.
/// `loop: false` plays the clip once and holds its last frame. Muted, because the show
/// has its own soundtrack — the same rule the segmenter's file source follows.
///
/// It only DECODES while its window is on screen. Every window the timeline names is
/// built at prewarm, before the clock starts, so a player that ran from creation would
/// burn a decoder per clip through the whole show for a few seconds of picture. The view
/// watches its window's occlusion state instead: it starts from its first frame the
/// moment the window becomes visible, pauses when the window is ordered out (or
/// completely covered), and dies with the window — nothing here touches disk or outlives
/// the process.
///
/// Like every other live surface here it is **scenery**: `hitTest` returns nil so clicks
/// fall through, and an `interactive` window can still be dragged by its picture.
final class VideoContentView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var status: String?
    private var occlusion: NSObjectProtocol?
    private var started = false
    private var hasItem: Bool { looper != nil || player.currentItem != nil }

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
            NSLog("[DPE] video: no file at \(url.path)")
            return
        }
        let item = AVPlayerItem(url: url)
        if content.loop ?? true {
            // The looper owns the queue; it must not also be handed the item.
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            player.actionAtItemEnd = .pause          // hold the last frame
        }
        // Not played here: `sync()` starts it once the window is actually on screen.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    /// Scenery, like every other live surface here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Follow the window: play when it is on screen, pause when it is not. Occlusion is
    /// the one signal that covers `orderFront`, `orderOut` and being buried alike.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusion { NotificationCenter.default.removeObserver(o); occlusion = nil }
        guard let window else { player.pause(); return }
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.sync() }
        sync()
    }

    private func sync() {
        guard let window, hasItem else { return }
        if window.occlusionState.contains(.visible) {
            if !started {
                started = true
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
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

    deinit {
        if let o = occlusion { NotificationCenter.default.removeObserver(o) }
        player.pause()
    }

    // MARK: - Test seams
    var hasClipForTesting: Bool { hasItem }
    var statusForTesting: String? { status }
}
