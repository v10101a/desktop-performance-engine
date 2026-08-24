import AppKit
import UniformTypeIdentifiers

/// A thin strip of color-coded ticks (section boundaries / drops / breaks) aligned to
/// the scrubber. Click a tick region to seek there.
final class MarkerStrip: NSView {
    var markers: [Marker] = [] { didSet { needsDisplay = true } }
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 420, height: 20) }

    static func color(_ m: Marker) -> NSColor {
        switch m.kind {
        case "drop":            return .systemRed
        case "break", "start":  return .systemGray
        default:                return (m.label?.contains("high") == true) ? .systemTeal : .systemBlue
        }
    }

    override func draw(_ dirty: NSRect) {
        guard duration > 0 else { return }
        let w = bounds.width, h = bounds.height
        for m in markers {
            let x = CGFloat(min(max(m.t / duration, 0), 1)) * w
            MarkerStrip.color(m).setStroke()
            let path = NSBezierPath()
            path.lineWidth = (m.kind == "drop" || m.label?.contains("high") == true) ? 2.5 : 1
            path.move(to: NSPoint(x: x, y: 2))
            path.line(to: NSPoint(x: x, y: h - 2))
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onSeek?(Double(min(max(x / bounds.width, 0), 1)) * duration)
    }
}

/// Control surface: load / play / stop, a scrubbable timeline with a live playhead,
/// and a position readout (time · beat · frame). The JSON timeline is still the
/// authoring surface; this is transport + navigation.
final class MainWindowController: NSWindowController {
    private let engine: PerformanceEngine
    private let fps: Double = 30   // nominal project frame rate for the frame counter

    private let timeLabel = NSTextField(labelWithString: "0:00.00 / 0:00.00")
    private let frameLabel = NSTextField(labelWithString: "beat 0.0 · frame 0 / 0")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let infoLabel = NSTextField(labelWithString: "")
    private var playButton: NSButton!
    private var positionSlider: NSSlider!
    private var volumeSlider: NSSlider!
    private var muteButton: NSButton!
    private let volumeLabel = NSTextField(labelWithString: "100%")
    /// Level to come back to when unmuting. Mute is a toggle over the slider rather
    /// than a separate engine state, so the two can't disagree.
    private var preMuteVolume: Float = 1.0

    /// Remembered across launches — a performer sets the level once for the room.
    private static let volumeKey = "DPEMasterVolume"
    private let markerStrip = MarkerStrip()
    private var scrubbing = false

    init(engine: PerformanceEngine) {
        self.engine = engine
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 290),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Desktop Performance Engine"
        win.center()
        super.init(window: win)
        buildUI()

        engine.onTick = { [weak self] t in
            guard let self = self else { return }
            if !self.scrubbing { self.positionSlider.doubleValue = t }
            self.updatePosition(t)
        }
        engine.onFinished = { [weak self] in
            self?.setStatus("Stopped — desktop restored")
            self?.playButton.title = "Play"
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabelColor

        positionSlider = NSSlider(value: 0, minValue: 0, maxValue: 1,
                                  target: self, action: #selector(scrub))
        positionSlider.isContinuous = true
        positionSlider.controlSize = .small
        positionSlider.translatesAutoresizingMaskIntoConstraints = false
        positionSlider.widthAnchor.constraint(equalToConstant: 420).isActive = true

        markerStrip.translatesAutoresizingMaskIntoConstraints = false
        markerStrip.widthAnchor.constraint(equalToConstant: 420).isActive = true
        markerStrip.heightAnchor.constraint(equalToConstant: 18).isActive = true
        markerStrip.onSeek = { [weak self] t in
            guard let self = self else { return }
            self.positionSlider.doubleValue = t
            self.updatePosition(t)
            self.engine.seek(to: t)
        }

        // --- volume ---
        let stored = UserDefaults.standard.object(forKey: MainWindowController.volumeKey) as? Double
        let initial = Float(stored ?? 1.0)
        engine.volume = initial
        preMuteVolume = initial > 0 ? initial : 1.0

        volumeSlider = NSSlider(value: Double(initial), minValue: 0, maxValue: 1,
                                target: self, action: #selector(changeVolume))
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        muteButton = NSButton(title: "Mute", target: self, action: #selector(toggleMute))
        muteButton.bezelStyle = .rounded
        muteButton.setButtonType(.pushOnPushOff)

        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        // Reflect the restored level in the label and the mute button, or a stored 30%
        // would show "100%" until the slider was first touched.
        applyVolume(initial)
        muteButton.state = initial == 0 ? .on : .off

        let volumeRow = NSStackView(views: [
            NSTextField(labelWithString: "Volume"), volumeSlider, volumeLabel, muteButton])
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8
        volumeRow.alignment = .centerY

        playButton = NSButton(title: "Play", target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = " "
        let panicButton = NSButton(title: "PANIC / Stop", target: self, action: #selector(panic))
        panicButton.bezelStyle = .rounded
        let loadButton = NSButton(title: "Load Timeline…", target: self, action: #selector(loadTimeline))
        loadButton.bezelStyle = .rounded

        let hint = NSTextField(wrappingLabelWithString: "Global panic hotkey: ⌃⌥⌘Esc  ·  drag the bar to scrub  ·  volume is output level only, never the clock")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [playButton, panicButton, loadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [timeLabel, positionSlider, markerStrip, frameLabel,
                                        statusLabel, infoLabel, buttons, volumeRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
        ])

        refresh()
    }

    func refresh() {
        infoLabel.stringValue = engine.loadedInfo
        positionSlider.maxValue = max(engine.duration, 0.01)
        positionSlider.doubleValue = engine.startPosition
        markerStrip.duration = engine.duration
        markerStrip.markers = engine.markers
        updatePosition(engine.startPosition)
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    private func updatePosition(_ t: Double) {
        let dur = engine.duration
        let beat = t * engine.bpm / 60.0
        let frame = Int((t * fps).rounded(.down))
        let totalFrames = Int((dur * fps).rounded(.down))
        timeLabel.stringValue = "\(Self.clock(t)) / \(Self.clock(dur))"
        var line = String(format: "beat %.1f · frame %d / %d", beat, frame, totalFrames)
        if let m = engine.currentMarker(at: t) {
            line += " · ⟩ \(m.label ?? "section")"
            if let bar = m.bar { line += " (bar \(bar))" }
        }
        frameLabel.stringValue = line
    }

    private static func clock(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = s - Double(m * 60)
        return String(format: "%d:%05.2f", m, sec)
    }

    // MARK: - Actions

    @objc private func changeVolume(_ sender: NSSlider) {
        applyVolume(Float(sender.doubleValue))
        // Dragging off zero is an implicit unmute; leaving it at zero is a mute.
        muteButton.state = sender.doubleValue == 0 ? .on : .off
        if sender.doubleValue > 0 { preMuteVolume = Float(sender.doubleValue) }
    }

    @objc private func toggleMute(_ sender: NSButton) {
        if sender.state == .on {
            preMuteVolume = engine.volume > 0 ? engine.volume : preMuteVolume
            applyVolume(0)
            volumeSlider.doubleValue = 0
        } else {
            applyVolume(preMuteVolume)
            volumeSlider.doubleValue = Double(preMuteVolume)
        }
    }

    private func applyVolume(_ v: Float) {
        engine.volume = v
        volumeLabel.stringValue = "\(Int((v * 100).rounded()))%"
        UserDefaults.standard.set(Double(v), forKey: MainWindowController.volumeKey)
    }

    @objc private func scrub(_ sender: NSSlider) {
        scrubbing = true
        let t = sender.doubleValue
        updatePosition(t)
        engine.seek(to: t)
        // NSSlider fires continuously during the drag; clear the flag on mouse-up.
        if let event = sender.window?.currentEvent, event.type == .leftMouseUp {
            scrubbing = false
        }
    }

    /// Start from the current playhead. Also the intro gate's "yes" path, so the
    /// transport UI stays in sync however the show was started.
    func startShow() {
        guard !engine.isPlaying else { return }
        engine.play()
        playButton.title = "Stop"
        let src = engine.usingClickTrack ? "synth click track (no audio file found)" : "backing track"
        setStatus("Playing — \(src)")
    }

    @objc private func togglePlay() {
        if engine.isPlaying {
            panic()
        } else {
            startShow()
        }
    }

    @objc private func panic() {
        engine.stopAndRestore()
        setStatus("Stopped — desktop restored")
        playButton.title = "Play"
    }

    @objc private func loadTimeline() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let json = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [json]
        }
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self = self else { return }
            do {
                try self.engine.loadTimeline(at: url)
                self.refresh()
                self.setStatus("Loaded \(url.lastPathComponent)")
            } catch {
                self.setStatus("Load error: \(error)")
            }
        }
    }
}
