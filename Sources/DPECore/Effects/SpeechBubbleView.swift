import AppKit

/// Clippy's balloon: the Office Assistant speech bubble, typed into.
///
/// Pale yellow, a hairline black outline, generous corners and a spike pointing at
/// whoever is talking. The torus is the one thing in the piece that addresses the viewer
/// directly and asks them for something, so it gets the surface every computer used to
/// use to interrupt you — the same register as "It looks like you're writing a letter",
/// which is exactly the tone the torus is going for.
///
/// A `TypedTextSink` like `TextEditorView`, and for the same reason it keeps its copy in
/// a CATextLayer: the typewriter rewrites the string ~30 times a second, and an
/// NSTextField would re-run cell layout on the main thread on every keystroke.
final class SpeechBubbleView: NSView, TypedTextSink {

    /// Which edge the spike comes off, and therefore where the speaker is. `bottom` is
    /// the canonical Office Assistant arrangement — the balloon above the character —
    /// and `left`/`right` are for a speaker beside the copy, which is where the torus
    /// sits.
    enum Tail: String {
        case left, right, bottom, none

        /// Index of the edge it sits on, in the perimeter walk below.
        /// 0 bottom, 1 right, 2 top, 3 left.
        var edge: Int? {
            switch self {
            case .bottom: return 0
            case .right:  return 1
            case .left:   return 3
            case .none:   return nil
            }
        }
    }

    /// The assistant balloon's yellow. Not the Windows tooltip's `#FFFFE1`, which is so
    /// nearly white that on a projector it reads as a plain box: this is the warmer
    /// `#FFFFCC` the Office 97 assistant actually spoke in.
    static let ground = NSColor(srgbRed: 1.0, green: 1.0, blue: 0.8, alpha: 1.0)
    static let ink = NSColor.black

    static let cornerRadius: CGFloat = 12
    static let tailLength: CGFloat = 22
    static let tailBase: CGFloat = 26
    /// Inset from the balloon body to the copy.
    static let padding: CGFloat = 18

    private let shape = CAShapeLayer()
    private let textLayer = CATextLayer()
    private let font: NSFont

    init(size: NSSize, tail: Tail, fontSize: CGFloat) {
        self.font = SpeechBubbleView.balloonFont(ofSize: fontSize)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true

        shape.path = SpeechBubbleView.balloonPath(in: size, tail: tail)
        shape.fillColor = SpeechBubbleView.ground.cgColor
        shape.strokeColor = SpeechBubbleView.ink.cgColor
        shape.lineWidth = 1
        layer?.addSublayer(shape)

        textLayer.frame = SpeechBubbleView.textBox(in: size, tail: tail)
        textLayer.isWrapped = true
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// MS Sans Serif is not on a Mac and Tahoma only arrives with Office, so the face is
    /// whichever of the assistant's own lineage is actually installed, falling back to
    /// Geneva — the system font of the era this balloon is quoting — before the modern
    /// system face.
    static func balloonFont(ofSize size: CGFloat) -> NSFont {
        for name in ["Tahoma", "Verdana", "Geneva"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Geometry

    /// The balloon body, with the spike's length taken off the edge it comes from so the
    /// whole thing still fits the authored frame.
    static func bodyRect(in size: NSSize, tail: Tail) -> CGRect {
        switch tail {
        case .none:
            return CGRect(origin: .zero, size: size)
        case .left:
            return CGRect(x: tailLength, y: 0,
                          width: size.width - tailLength, height: size.height)
        case .right:
            return CGRect(x: 0, y: 0,
                          width: size.width - tailLength, height: size.height)
        case .bottom:
            // y is up: a spike off the bottom lifts the body by its length.
            return CGRect(x: 0, y: tailLength,
                          width: size.width, height: size.height - tailLength)
        }
    }

    /// Where the copy sets, inside the body.
    static func textBox(in size: NSSize, tail: Tail) -> CGRect {
        bodyRect(in: size, tail: tail).insetBy(dx: padding, dy: padding)
    }

    /// How tall `text` sets in that box, with the same line spacing `showTyped` uses.
    /// Bigger than the box means the copy runs off the bottom of its own balloon — which
    /// is silent, so `TimelineTests` measures it.
    static func textHeight(_ text: String, in size: NSSize, tail: Tail,
                           fontSize: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fontSize * 0.28
        let box = textBox(in: size, tail: tail)
        return text.boundingRect(
            with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: balloonFont(ofSize: fontSize),
                         .paragraphStyle: para]).height
    }

    /// The outline: one continuous path, body and spike together.
    ///
    /// It has to be one path rather than a rounded rect with a triangle laid over it —
    /// two shapes would each carry their own stroke, and the body's stroke would draw a
    /// line straight across the base of the spike.
    ///
    /// The perimeter is walked counterclockwise as four edges (bottom, right, top, left),
    /// each corner turned with a tangent arc. The tailed edge gets three extra points
    /// inserted mid-run. Doing it as one walk is what keeps all four directions honest:
    /// there is no per-side special case to get wrong.
    static func balloonPath(in size: NSSize, tail: Tail,
                            radius: CGFloat = cornerRadius) -> CGPath {
        let body = bodyRect(in: size, tail: tail)
        let r = min(radius, min(body.width, body.height) / 2)
        // Counterclockwise from the bottom-left.
        let corners = [CGPoint(x: body.minX, y: body.minY),
                       CGPoint(x: body.maxX, y: body.minY),
                       CGPoint(x: body.maxX, y: body.maxY),
                       CGPoint(x: body.minX, y: body.maxY)]

        let path = CGMutablePath()
        // Start just past the bottom-left corner, on the bottom edge.
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))

        for i in 0..<4 {
            let from = corners[i], to = corners[(i + 1) % 4]
            if tail.edge == i {
                let len = hypot(to.x - from.x, to.y - from.y)
                let d = CGPoint(x: (to.x - from.x) / len, y: (to.y - from.y) / len)
                // Outward is to the right of travel on a counterclockwise walk.
                let n = CGPoint(x: d.y, y: -d.x)
                // Halfway along the edge, clamped so the spike cannot eat a corner arc.
                let half = tailBase / 2
                let centre = max(r + half, min(len - r - half, len / 2))
                let c = CGPoint(x: from.x + d.x * centre, y: from.y + d.y * centre)
                path.addLine(to: CGPoint(x: c.x - d.x * half, y: c.y - d.y * half))
                path.addLine(to: CGPoint(x: c.x + n.x * tailLength, y: c.y + n.y * tailLength))
                path.addLine(to: CGPoint(x: c.x + d.x * half, y: c.y + d.y * half))
            }
            // Turn the corner at `to`, heading for the corner after it.
            path.addArc(tangent1End: to, tangent2End: corners[(i + 2) % 4], radius: r)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - TypedTextSink

    /// CATextLayer anchors its string at the TOP of its frame, so the copy grows
    /// downward as it is typed — the same behaviour as the document surface.
    func showTyped(_ visible: String, caret: Bool) {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = font.pointSize * 0.28
        let s = NSMutableAttributedString(string: visible, attributes: [
            .font: font, .foregroundColor: SpeechBubbleView.ink, .paragraphStyle: para])
        if caret {
            s.append(NSAttributedString(string: "▌", attributes: [
                .font: font, .foregroundColor: SpeechBubbleView.ink, .paragraphStyle: para]))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)     // no implicit fade on every keystroke
        textLayer.string = s
        CATransaction.commit()
    }
}
