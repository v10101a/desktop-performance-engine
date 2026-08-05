import AppKit
import UniformTypeIdentifiers

/// Minimal control surface: load / play / stop, live clock, panic hint.
/// Deliberately thin — the JSON timeline is the authoring surface, and a
/// visual editor can be layered on later against the same document model.
final class MainWindowController: NSWindowController {
    private let engine: PerformanceEngine

    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let infoLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "0.00s")
    private var playButton: NSButton!

    init(engine: PerformanceEngine) {
        self.engine = engine
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Desktop Performance Engine"
        win.center()
        super.init(window: win)
        buildUI()

        engine.onTick = { [weak self] t in
            self?.timeLabel.stringValue = String(format: "%.2fs", t)
        }
        engine.onFinished = { [weak self] in
            self?.setStatus("Stopped — desktop restored")
            self?.playButton.title = "Play"
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        playButton = NSButton(title: "Play", target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = " "

        let panicButton = NSButton(title: "PANIC / Stop", target: self, action: #selector(panic))
        panicButton.bezelStyle = .rounded

        let loadButton = NSButton(title: "Load Timeline…", target: self, action: #selector(loadTimeline))
        loadButton.bezelStyle = .rounded

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: "Global panic hotkey: ⌃⌥⌘Esc")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [playButton, panicButton, loadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [timeLabel, statusLabel, infoLabel, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])

        refresh()
    }

    func refresh() {
        infoLabel.stringValue = engine.loadedInfo
    }

    func setStatus(_ s: String) {
        statusLabel.stringValue = s
    }

    @objc private func togglePlay() {
        if engine.isPlaying {
            panic()
        } else {
            engine.play()
            playButton.title = "Stop"
            let src = engine.usingClickTrack ? "synth click track (no audio file found)" : "audio file"
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
