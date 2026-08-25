import AppKit

/// The boot screen itself: black, the glyph, and a progress bar that is hidden until
/// the machine has "found its disk". Shared by the live controller and the still
/// renderer, which is why it is a view with a `progress` and not part of the tick.
final class BootView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private let trackWidth: CGFloat

    /// 0…1. Setting it moves the fill; nothing else animates.
    var progress: Double = 0 {
        didSet {
            // A real boot bar stalls and lurches; ease it so it slows toward the end.
            let eased = 1 - pow(1 - min(1, max(0, progress)), 1.8)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame.size.width = trackWidth * CGFloat(eased)
            CATransaction.commit()
        }
    }

    var showsBar: Bool = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.isHidden = !showsBar
            CATransaction.commit()
        }
    }

    init(size: NSSize, glyph: String, color: NSColor) {
        trackWidth = min(size.width * 0.20, 330)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // The glyph. U+F8FF is the Apple-logo private-use character in every Apple
        // system font; an authored `glyph` can be anything else.
        let label = NSTextField(labelWithString: glyph)
        label.font = .systemFont(ofSize: size.height * 0.17, weight: .medium)
        label.textColor = color
        label.alignment = .center
        label.sizeToFit()
        label.frame = NSRect(x: (size.width - label.frame.width) / 2, y: size.height * 0.50,
                             width: label.frame.width, height: label.frame.height)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(label)

        // The bar: a dark track a fifth of the screen wide, a light fill that grows
        // from the left.
        let trackH: CGFloat = 6
        track.frame = CGRect(x: (size.width - trackWidth) / 2, y: size.height * 0.415,
                             width: trackWidth, height: trackH)
        track.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
        track.cornerRadius = trackH / 2
        track.masksToBounds = true
        track.isHidden = true
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: trackH)
        fill.backgroundColor = color.cgColor
        fill.cornerRadius = trackH / 2
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// The fake reboot: the screen goes black, the boot glyph comes up, a progress bar
/// fills — and then nothing happens until the timeline says the desktop comes back.
///
/// One fullscreen window, click-through, above everything. The bar is driven from the
/// show clock like every other pump-fed effect, so it scrubs with the playhead and
/// freezes on pause. `closeWindow` by `id` ends it; the generator usually puts a black
/// window under that moment so the cut back to the desktop reads as the machine
/// "coming up" rather than a window closing.
///
/// **Reversibility.** One window; nothing in system state. The machine does not, of
/// course, reboot.
final class RebootController {
    private struct Boot {
        let id: String
        let window: NSWindow
        let view: BootView
        let start: Double
        let delay: Double
        let duration: Double
    }

    private var boot: Boot?
    var bpm: Double = 120

    func begin(_ p: RebootParams, at now: Double, bpm: Double) {
        teardown()
        let screen = ScreenGeometry.screen(p.screen)
        let sf = screen.frame

        let window = NSPanel(contentRect: sf, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = BootView(size: sf.size, glyph: p.glyph ?? "\u{F8FF}",
                            color: NSColor(hex: p.color ?? "#FFFFFF") ?? .white)
        window.contentView = view
        window.orderFrontRegardless()

        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm) ?? 8 * 60 / bpm
        let delay = Beats.seconds(p.delayBeats, or: nil, bpm: bpm) ?? 60 / bpm
        boot = Boot(id: p.id, window: window, view: view, start: now, delay: delay,
                    duration: max(0.1, duration))
    }

    func stop(id: String) {
        guard boot?.id == id else { return }
        teardown()
    }

    func closeAll() { teardown() }

    private func teardown() {
        guard let b = boot else { return }
        b.window.orderOut(nil)
        b.window.close()
        boot = nil
    }

    // MARK: - Tick

    func update(now: Double) {
        guard let b = boot else { return }
        let t = now - b.start - b.delay
        let shows = t >= 0
        if shows != b.view.showsBar { b.view.showsBar = shows }
        let progress = min(1.0, max(0.0, t / b.duration))
        if abs(progress - b.view.progress) > 0.0005 { b.view.progress = progress }
    }
}
