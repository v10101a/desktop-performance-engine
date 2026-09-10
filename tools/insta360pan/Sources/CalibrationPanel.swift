import AppKit

/// A floating panel of every number in the lens model, each on a slider with a field you
/// can type into. Meant to be used with the raw view: drag the circle onto the edge of the
/// real fisheye, put the axis through its centre, then switch back and tune the seams.
final class CalibrationPanel: NSPanel {
    var onChange: ((Calibration) -> Void)?

    /// Set from outside to keep the sliders in step; does not fire `onChange`.
    var calibration: Calibration {
        didSet { if !editing { syncAll() } }
    }

    private final class Row {
        let title: String
        let keyPath: WritableKeyPath<Calibration, Double>
        let range: ClosedRange<Double>
        let format: String
        let logarithmic: Bool
        let slider = NSSlider()
        let field = NSTextField()

        init(_ title: String, _ keyPath: WritableKeyPath<Calibration, Double>, _ range: ClosedRange<Double>,
             format: String, logarithmic: Bool = false) {
            self.title = title
            self.keyPath = keyPath
            self.range = range
            self.format = format
            self.logarithmic = logarithmic
        }

        func sliderPosition(for value: Double) -> Double {
            logarithmic ? log10(max(range.lowerBound, value)) : value
        }

        func value(forSliderPosition p: Double) -> Double {
            logarithmic ? pow(10, p) : p
        }
    }

    private let projectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rows: [Row] = []
    private var editing = false

    init(calibration: Calibration) {
        self.calibration = calibration
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        title = "Lens Calibration"
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        setFrameAutosaveName("Insta360PanCalibration")

        rows = [
            Row("Field of view °", \.fovDegrees, 120...240, format: "%.1f"),
            Row("Circle centre X px", \.circleCenterX, 0...1920, format: "%.0f"),
            Row("Circle centre Y px", \.circleCenterY, -540...1080, format: "%.0f"),
            Row("Circle radius X px", \.circleRadiusX, 200...2400, format: "%.0f"),
            Row("Circle radius Y px", \.circleRadiusY, 200...2400, format: "%.0f"),
            Row("Front pitch °", \.frontPitch, -15...15, format: "%.2f"),
            Row("Front roll °", \.frontRoll, -15...15, format: "%.2f"),
            Row("Rear yaw °", \.rearYaw, -15...15, format: "%.2f"),
            Row("Rear pitch °", \.rearPitch, -15...15, format: "%.2f"),
            Row("Rear roll °", \.rearRoll, -15...15, format: "%.2f"),
            Row("Seam blend °", \.blendDegrees, 0...40, format: "%.1f"),
            Row("Stitch distance m", \.stitchDistanceMetres, 0.2...50, format: "%.2f", logarithmic: true),
            Row("Lens baseline m", \.baselineMetres, 0...0.12, format: "%.3f"),
        ]

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        projectionPopup.addItems(withTitles: Calibration.Projection.allCases.map(\.title))
        projectionPopup.controlSize = .small
        projectionPopup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        projectionPopup.target = self
        projectionPopup.action = #selector(projectionChanged)
        grid.addRow(with: [label("Projection"), projectionPopup, NSView()])

        for (index, row) in rows.enumerated() {
            row.slider.controlSize = .small
            row.slider.isContinuous = true
            row.slider.minValue = row.sliderPosition(for: row.range.lowerBound)
            row.slider.maxValue = row.sliderPosition(for: row.range.upperBound)
            row.slider.tag = index
            row.slider.target = self
            row.slider.action = #selector(sliderMoved(_:))
            row.slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            row.field.controlSize = .small
            row.field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            row.field.alignment = .right
            row.field.tag = index
            row.field.target = self
            row.field.action = #selector(fieldEdited(_:))
            row.field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            grid.addRow(with: [label(row.title), row.slider, row.field])
            if index == 4 || index == 9 { grid.addRow(with: [NSView(), NSView(), NSView()]).height = 6 }
        }

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetPressed))
        reset.controlSize = .small
        reset.bezelStyle = .rounded
        let path = NSTextField(labelWithString: "Saved as it changes to " + Calibration.defaultFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        path.font = NSFont.systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1
        let hint = NSTextField(wrappingLabelWithString:
            "Turn on Raw (X) to see the frame as it arrives: put the magenta ring on the edge of the fisheye and the green axis through its centre. " +
            "Then switch back and set the field of view and blend until the seams join; stitch distance aligns things at that distance.")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 400

        let stack = NSStackView(views: [grid, reset, path, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        contentView = content
        syncAll()
        setContentSize(stack.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        return l
    }

    private func syncAll() {
        projectionPopup.selectItem(at: Int(calibration.projection.index))
        for row in rows {
            let value = calibration[keyPath: row.keyPath]
            row.slider.doubleValue = row.sliderPosition(for: value)
            row.field.stringValue = String(format: row.format, value)
        }
    }

    private func change(_ body: (inout Calibration) -> Void) {
        editing = true
        body(&calibration)
        editing = false
        syncAll()
        onChange?(calibration)
    }

    @objc private func projectionChanged() {
        let all = Calibration.Projection.allCases
        guard all.indices.contains(projectionPopup.indexOfSelectedItem) else { return }
        change { $0.projection = all[projectionPopup.indexOfSelectedItem] }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        change { $0[keyPath: row.keyPath] = row.value(forSliderPosition: sender.doubleValue) }
    }

    @objc private func fieldEdited(_ sender: NSTextField) {
        guard rows.indices.contains(sender.tag), let value = Double(sender.stringValue.replacingOccurrences(of: ",", with: ".")) else {
            syncAll()
            return
        }
        let row = rows[sender.tag]
        change { $0[keyPath: row.keyPath] = value }
    }

    @objc private func resetPressed() {
        change { $0 = Calibration() }
    }
}
