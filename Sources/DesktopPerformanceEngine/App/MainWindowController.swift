import AppKit
import UniformTypeIdentifiers

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

        playButton = NSButton(title: "Play", target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = " "
        let panicButton = NSButton(title: "PANIC / Stop", target: self, action: #selector(panic))
        panicButton.bezelStyle = .rounded
        let loadButton = NSButton(title: "Load Timeline…", target: self, action: #selector(loadTimeline))
        loadButton.bezelStyle = .rounded

        let hint = NSTextField(wrappingLabelWithString: "Global panic hotkey: ⌃⌥⌘Esc  ·  drag the bar to scrub")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [playButton, panicButton, loadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [timeLabel, positionSlider, frameLabel,
                                        statusLabel, infoLabel, buttons, hint])
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
        updatePosition(engine.startPosition)
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    private func updatePosition(_ t: Double) {
        let dur = engine.duration
        let beat = t * engine.bpm / 60.0
        let frame = Int((t * fps).rounded(.down))
        let totalFrames = Int((dur * fps).rounded(.down))
        timeLabel.stringValue = "\(Self.clock(t)) / \(Self.clock(dur))"
        frameLabel.stringValue = String(format: "beat %.1f · frame %d / %d", beat, frame, totalFrames)
    }

    private static func clock(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = s - Double(m * 60)
        return String(format: "%d:%05.2f", m, sec)
    }

    // MARK: - Actions

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

    @objc private func togglePlay() {
        if engine.isPlaying {
            panic()
        } else {
            engine.play()
            playButton.title = "Stop"
            let src = engine.usingClickTrack ? "synth click track (no audio file found)" : "backing track"
            setStatus("Playing — \(src)")
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
