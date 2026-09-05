import AppKit
import CoreImage
import CoreVideo

/// segcam, as a window in the show.
///
/// The imported engine (`SegmentEngine` and the three segmenters) with a source in front
/// of it and segcam's overlay behind it: the picture, and every segment stroked as a box
/// and labelled with its id. What is deliberately absent is everything you could touch —
/// no HUD, no sensitivity slider, no keys, no device cycling, no mode switching. A cue
/// says what it wants when the window opens and the window does that until it closes.
///
/// **Drawn, not layered.** The obvious build is a `CALayer` with the frame as its
/// `contents`, but this view is flipped (`NormRect` is top-left origin, and the imported
/// `FrameMap.fit` is written against that), and a flipped view's backing layer flips its
/// sublayers' geometry with it — which turns the picture upside down and puts the boxes
/// somewhere else again. One `draw(_:)` doing both keeps the picture and the boxes in the
/// same coordinate system by construction.
final class SegCamView: NSView {
    private let engine = SegmentEngine()
    private var source: SegCamSource?
    private let ciContext = CIContext()

    private var picture: NSImage?
    private var segments: [Segment] = []
    private var aspect: CGFloat = 16.0 / 9.0
    private var status: String?

    private let mirrored: Bool
    private let showLabels: Bool
    private let stroke: NSColor

    /// segcam's own green. `fg` overrides it for a cue that wants the piece's palette.
    private static let defaultStroke = NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 1)

    init(size: NSSize, content: ContentSpec) {
        let isFile = content.path != nil
        // A camera is a mirror — you are looking at yourself — and a clip is not.
        mirrored = content.mirror ?? !isFile
        showLabels = content.labels ?? true
        stroke = content.fg.flatMap { NSColor(hex: $0) } ?? SegCamView.defaultStroke
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        var settings = SegmentSettings()
        switch content.mode {
        case "threshold":
            engine.mode = .threshold
            // `intensity` is one knob per segmenter, always 0…1 and always "more".
            settings.thresholdLevel = Int((1 - min(1, max(0, content.intensity ?? 0.33))) * 255)
            settings.invertThreshold = content.invert ?? false
        case "motion":
            engine.mode = .motion
            settings.motionSensitivityFraction = content.intensity ?? 0.6
        default:
            engine.mode = .face
        }
        engine.settings = settings
        engine.wantsImage = false          // the crops are for segcam's swarm; nothing here wants them

        engine.onResult = { [weak self] result in
            guard let self else { return }
            self.segments = result.segments
            self.aspect = result.aspect
            self.needsDisplay = true
        }

        if let path = content.path {
            let url = URL(fileURLWithPath: resolveResourcePath(path))
            let file = SegCamFile(url: url, hz: content.hz ?? 30)
            source = file
        } else {
            source = SegCamCamera(deviceHint: content.text)
        }
        status = "waiting for frames…"
        source?.onStatus = { [weak self] message in
            self?.status = message
            self?.needsDisplay = true
        }
        source?.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.engine.ingest(buffer)          // capture queue, as the engine expects
            self.publish(buffer)
        }
        source?.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { source?.stop() }

    /// Top-left origin, so `NormRect` and `FrameMap.fit` land where they say they do.
    override var isFlipped: Bool { true }

    /// Scenery, like every other live surface here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { source?.stop() }
    }

    /// Capture queue → main. The conversion happens off main (it is the expensive part)
    /// and only the finished image crosses over.
    private func publish(_ buffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let size = NSSize(width: cg.width, height: cg.height)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.picture = NSImage(cgImage: cg, size: size)
            if self.status != nil { self.status = nil }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let picture else {
            if let status { drawCentred(status) }
            return
        }

        let content = FrameMap.contentRect(in: bounds, aspect: aspect)
        if mirrored {
            NSGraphicsContext.saveGraphicsState()
            let flip = NSAffineTransform()
            flip.translateX(by: content.midX * 2, yBy: 0)
            flip.scaleX(by: -1, yBy: 1)
            flip.concat()
            picture.draw(in: content)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            picture.draw(in: content)
        }

        stroke.setStroke()
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        for segment in segments {
            let rect = FrameMap.fit(segment.rect, into: bounds, aspect: aspect, mirrored: mirrored)
            guard rect.width > 1, rect.height > 1 else { continue }
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()

            guard showLabels else { continue }
            let string = NSAttributedString(string: segment.label, attributes: labelAttributes)
            let size = string.size()
            var chip = NSRect(x: rect.minX - 1, y: rect.minY - size.height - 3,
                              width: size.width + 8, height: size.height + 2)
            if chip.minY < 0 { chip.origin.y = rect.minY + 1 }      // the box is at the top edge
            stroke.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 2, yRadius: 2).fill()
            string.draw(at: NSPoint(x: chip.minX + 4, y: chip.minY + 1))
            stroke.setStroke()
        }
    }

    private func drawCentred(_ message: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: message, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: stroke,
            .paragraphStyle: paragraph,
        ])
        let size = string.boundingRect(with: NSSize(width: bounds.width - 40,
                                                    height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin])
        string.draw(with: NSRect(x: 20, y: bounds.midY - size.height / 2,
                                 width: bounds.width - 40, height: size.height),
                    options: [.usesLineFragmentOrigin])
    }

    // MARK: - Test seams

    var segmentCountForTesting: Int { segments.count }
    var hasPictureForTesting: Bool { picture != nil }
    var statusForTesting: String? { status }
}
