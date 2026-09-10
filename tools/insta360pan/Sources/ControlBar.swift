import AppKit

/// The strip of controls under the picture: source, output size, how the frame is drawn,
/// the layout switches, and a status line. Everything here is also on a key or a menu;
/// this is the version that can be read.
final class ControlBar: NSView {
    enum SourceChoice {
        case camera(id: String)
        case testScene
        case openFile
    }

    var onSource: ((SourceChoice) -> Void)?
    var onOutputSize: ((SIMD2<Int>) -> Void)?
    var onRectilinear: ((Bool) -> Void)?
    var onRaw: ((Bool) -> Void)?
    var onLayout: ((_ swap: Bool, _ mirrorFront: Bool, _ mirrorRear: Bool) -> Void)?
    var onCalibrate: (() -> Void)?
    var onReset: (() -> Void)?

    static let outputSizes: [SIMD2<Int>] = [[1280, 720], [1920, 1080], [2560, 1440], [3840, 2160]]

    // Set from outside to keep the controls in step; none of these fire callbacks.
    var outputSize = SIMD2<Int>(1920, 1080) {
        didSet { syncSize() }
    }
    var rectilinear = false {
        didSet { sync { viewPopup.selectItem(at: rectilinear ? 1 : 0) } }
    }
    var raw = false {
        didSet { sync { rawBox.state = raw ? .on : .off } }
    }
    var swapHalves = false {
        didSet { sync { swapBox.state = swapHalves ? .on : .off } }
    }
    var mirrorFront = false {
        didSet { sync { mirrorFrontBox.state = mirrorFront ? .on : .off } }
    }
    var mirrorRear = false {
        didSet { sync { mirrorRearBox.state = mirrorRear ? .on : .off } }
    }
    var status = "" {
        didSet { syncStatus() }
    }
    /// Something the user needs to know (permission, a camera that would not open).
    var message: String? {
        didSet { syncStatus() }
    }

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let viewPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rawBox = NSButton(checkboxWithTitle: "Raw", target: nil, action: nil)
    private let swapBox = NSButton(checkboxWithTitle: "Swap", target: nil, action: nil)
    private let mirrorFrontBox = NSButton(checkboxWithTitle: "Mirror F", target: nil, action: nil)
    private let mirrorRearBox = NSButton(checkboxWithTitle: "Mirror R", target: nil, action: nil)
    private let calibrateButton = NSButton(title: "Calibrate…", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset view", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var syncing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        appearance = NSAppearance(named: .darkAqua)

        for popup in [sourcePopup, sizePopup, viewPopup] {
            popup.controlSize = .small
            popup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        // A popup sizes itself to its widest item, and "Open video file…" would take the
        // status line's room; the selected title truncates instead.
        sourcePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        sourcePopup.lineBreakMode = .byTruncatingTail
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        for size in ControlBar.outputSizes {
            sizePopup.addItem(withTitle: "\(size.x)×\(size.y)")
        }
        viewPopup.addItems(withTitles: ["Loop", "Rectilinear"])
        viewPopup.target = self
        viewPopup.action = #selector(viewChanged)

        for box in [rawBox, swapBox, mirrorFrontBox, mirrorRearBox] {
            box.controlSize = .small
            box.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            box.target = self
        }
        rawBox.action = #selector(rawChanged)
        swapBox.action = #selector(layoutChanged)
        mirrorFrontBox.action = #selector(layoutChanged)
        mirrorRearBox.action = #selector(layoutChanged)
        rawBox.toolTip = "Show the camera frame as it arrives, with the lens model drawn over it"

        for button in [calibrateButton, resetButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
        }
        calibrateButton.action = #selector(calibratePressed)
        resetButton.action = #selector(resetPressed)

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            label("Source"), sourcePopup,
            label("Out"), sizePopup,
            label("View"), viewPopup,
            rawBox, swapBox, mirrorFrontBox, mirrorRearBox,
            calibrateButton, resetButton,
            statusLabel,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        syncSize()
        syncStatus()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func sync(_ body: () -> Void) {
        syncing = true
        body()
        syncing = false
    }

    // MARK: - Sources

    /// Rebuilds the source list. `current` is the camera in use, if a camera is.
    func setSources(cameras: [(id: String, name: String)], current: String?, testScene: Bool, file: String?) {
        sync {
            sourcePopup.removeAllItems()
            for camera in cameras {
                sourcePopup.addItem(withTitle: camera.name)
                sourcePopup.lastItem?.representedObject = camera.id
            }
            if cameras.isEmpty {
                sourcePopup.addItem(withTitle: "No camera")
                sourcePopup.lastItem?.isEnabled = false
            }
            sourcePopup.menu?.addItem(.separator())
            sourcePopup.addItem(withTitle: "Test scene")
            sourcePopup.lastItem?.tag = -1
            if let file {
                sourcePopup.addItem(withTitle: file)
                sourcePopup.lastItem?.tag = -3
            }
            sourcePopup.addItem(withTitle: "Open video file…")
            sourcePopup.lastItem?.tag = -2

            if testScene {
                sourcePopup.selectItem(withTag: -1)
            } else if file != nil {
                sourcePopup.selectItem(withTag: -3)
            } else if let current, let index = cameras.firstIndex(where: { $0.id == current }) {
                sourcePopup.selectItem(at: index)
            }
        }
    }

    @objc private func sourceChanged() {
        guard !syncing, let item = sourcePopup.selectedItem else { return }
        switch item.tag {
        case -1: onSource?(.testScene)
        case -2: onSource?(.openFile)
        case -3: break
        default: if let id = item.representedObject as? String { onSource?(.camera(id: id)) }
        }
    }

    @objc private func sizeChanged() {
        guard !syncing else { return }
        let index = sizePopup.indexOfSelectedItem
        guard ControlBar.outputSizes.indices.contains(index) else { return }
        onOutputSize?(ControlBar.outputSizes[index])
    }

    @objc private func viewChanged() {
        guard !syncing else { return }
        onRectilinear?(viewPopup.indexOfSelectedItem == 1)
    }

    @objc private func rawChanged() {
        guard !syncing else { return }
        onRaw?(rawBox.state == .on)
    }

    @objc private func layoutChanged() {
        guard !syncing else { return }
        onLayout?(swapBox.state == .on, mirrorFrontBox.state == .on, mirrorRearBox.state == .on)
    }

    @objc private func calibratePressed() { onCalibrate?() }
    @objc private func resetPressed() { onReset?() }

    // MARK: - Sync

    private func syncSize() {
        sync {
            if let index = ControlBar.outputSizes.firstIndex(of: outputSize) {
                sizePopup.selectItem(at: index)
            } else {
                // A size from the command line that is not in the list.
                let title = "\(outputSize.x)×\(outputSize.y)"
                if sizePopup.item(withTitle: title) == nil { sizePopup.addItem(withTitle: title) }
                sizePopup.selectItem(withTitle: title)
            }
        }
    }

    private func syncStatus() {
        if let message {
            statusLabel.stringValue = message
            statusLabel.textColor = NSColor(calibratedRed: 1, green: 0.75, blue: 0.3, alpha: 1)
        } else {
            statusLabel.stringValue = status
            statusLabel.textColor = NSColor(calibratedRed: 0.3, green: 1, blue: 0.45, alpha: 1)
        }
    }
}
