import AppKit
import AVFoundation

/// Act 0 — the pre-show. 

// MARK: - Script

enum IntroCardStyle {
    /// Centered type on black — the house style.
    case plain
    /// The VHS anti-piracy screen: blue field, white box, giant condensed FBI,
    /// seal, justified block of text. Drawn by `VHSWarningView`.
    case vhs
    /// The same VHS treatment shrunk to a small window that pops up on the desktop
    /// instead of taking the whole screen. Title and buttons only.
    case popup
    /// A macOS restart: black, the logo, a progress bar — and at the end the ground
    /// turns DJ Dave blue and the logo becomes the face. Drawn by `RestartCardView`.
    case restart
    /// A plain macOS alert on the desktop: system chrome, icon, title, body, two real
    /// buttons. Built from `makeDialogContentView`, the same one the show's fake
    /// dialogs use, so it is indistinguishable from the ones that follow it.
    case macAlert
}

struct IntroCard {
    let kicker: String
    let title: String
    let body: String
    let accent: String          // hex
    /// Seconds before auto-advancing. `nil` = wait for the viewer to choose.
    let dwell: Double?
    var style: IntroCardStyle = .plain
    /// The huge word filling the left column of a `.vhs` card. Short — it gets
    /// squeezed to fit a tall narrow box, so 1-3 characters.
    var glyph: String = "FBI"
}

enum IntroGate {
    static let script: [IntroCard] = [
        // The machine appears to restart before the piece begins. It ends on the
        // signature blue with the face where the logo was — the first thing the viewer
        // sees is the show having already taken the computer over.
        IntroCard(
            kicker: "",
            title: "",
            body: "",
            accent: djBlue,
            dwell: 7.0,
            style: .restart),
        // The warning and the question, together, in real macOS chrome. The
        // photosensitivity notice is the part that actually matters here; it is not a
        // joke, and it stays in front of the viewer until they answer.
        IntroCard(
            kicker: "malware",
            title: "DO YOU WANT THE MALWARE?",
            body: """
                  This presentation contains strobing light, rapid flashing and sudden \
                  full-screen color for approximately three minutes.

                  Federal law provides mild civil and criminal penalties for the \
                  unauthorized reproduction, distribution or exhibition of this software.
                  """,
            accent: "#0078D7",
            dwell: nil,
            style: .macAlert,
            glyph: "?")
    ]

    /// The signature blue: rgb(2, 10, 245). The desktop wallpaper and the restart card
    /// both take it, so the ground under the whole piece is one colour. It matches
    /// `PALETTE[1]` in the generator — the blue the horse and the strobe are built from.
    ///
    /// It is not exactly the blue inside `pixelface.jpg` (a near-pure #001FFD), so the
    /// face is keyed to transparency before it is drawn — see `maskingField` — rather
    /// than relying on the two matching.
    static let djBlue = "#020AF5"
    static let faceAsset = "assets/pixelface.jpg"
    static let buttonSound = "assets/bubble_sound.wav"

    static let backdrop = "#050508"

    /// On-screen size of a `.popup` card's window.
    static let popupSize = NSSize(width: 620, height: 300)
    /// On-screen size of the `.macAlert` card's window. Taller than a stock alert
    /// because the warning body is four lines of real text, not a one-liner.
    static let alertSize = NSSize(width: 620, height: 250)
}


final class VHSWarningView: NSView {
    private let card: IntroCard
    private var buttons: [NSButton] = []

    /// The project's BSOD blue, standing in for the VHS screen's royal blue — the
    /// gate should read as the same piece as everything that follows it.
    private static let field = NSColor(hex: "#0078D7") ?? .blue

    init(card: IntroCard, size: NSSize,
         onStart: (() -> Void)? = nil, onExit: (() -> Void)? = nil) {
        self.card = card
        super.init(frame: NSRect(origin: .zero, size: size))
        // The choice card carries the two answers inside the blue panel; the dwell
        // cards carry nothing at all (they advance on their own).
        guard card.dwell == nil else { return }
        let yes = GateButton(title: "YES. INFECT ME.", fill: .white,
                             textColor: Self.field, size: 15, handler: { onStart?() })
        let no = GateButton(title: "no thank you", fill: nil,
                            textColor: NSColor(white: 1, alpha: 0.8), size: 13,
                            handler: { onExit?() })
        buttons = [yes, no]
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { false }

    /// Where everything sits. Shared by `draw` and `layout` so the buttons land in
    /// the same blue panel the text is measured against.
    private struct Geometry {
        let box, inner, bluePanel, textArea, buttonRow: NSRect
        let border, radius, innerRadius, panelW: CGFloat
    }

    private func geometry() -> Geometry {
        // A popup IS the box — it fills its little window. Full-screen cards float
        // the box at the reference's ~1.4:1 inside the blue field.
        let box: NSRect
        if card.style == .popup {
            box = bounds
        } else {
            let boxH = min(bounds.height * 0.74, bounds.width * 0.53)
            let boxW = boxH * 1.4
            box = NSRect(x: (bounds.width - boxW) / 2,
                         y: (bounds.height - boxH) / 2, width: boxW, height: boxH)
        }
        let border = box.width * 0.018
        let radius = box.width * 0.045
        let inner = box.insetBy(dx: border, dy: border)
        let panelW = inner.width * 0.30          // the white glyph column on the left
        let bluePanel = NSRect(x: inner.minX + panelW, y: inner.minY,
                               width: inner.width - panelW, height: inner.height)
        // Generous side margins — justified type set tight against the white border
        // was the thing that read as "out of frame".
        var textArea = bluePanel.insetBy(dx: bluePanel.width * 0.06, dy: inner.height * 0.07)
        var buttonRow = NSRect.zero
        if !buttons.isEmpty {
            let rowH = min(max(inner.height * 0.13, 34), 52)
            buttonRow = NSRect(x: textArea.minX, y: textArea.minY,
                               width: textArea.width, height: rowH)
            textArea = NSRect(x: textArea.minX, y: buttonRow.maxY + inner.height * 0.05,
                              width: textArea.width,
                              height: textArea.maxY - buttonRow.maxY - inner.height * 0.05)
        }
        return Geometry(box: box, inner: inner, bluePanel: bluePanel, textArea: textArea,
                        buttonRow: buttonRow, border: border, radius: radius,
                        innerRadius: radius - border * 0.5, panelW: panelW)
    }

    override func layout() {
        super.layout()
        guard buttons.count == 2 else { return }
        let row = geometry().buttonRow
        let yesW = min(row.width * 0.52, 260)
        let noW = min(row.width * 0.36, 180)
        buttons[0].frame = NSRect(x: row.minX, y: row.minY, width: yesW, height: row.height)
        buttons[1].frame = NSRect(x: row.minX + yesW + 16, y: row.minY,
                                  width: noW, height: row.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = geometry()
        // A popup has no field around it — it sits on the real desktop, so anything
        // outside the rounded white box stays transparent.
        if card.style != .popup {
            Self.field.setFill()
            bounds.fill()
        }

        NSColor.white.setFill()
        NSBezierPath(roundedRect: g.box, xRadius: g.radius, yRadius: g.radius).fill()

        // Blue text panel: fills the inner box, square on the left where it meets
        // the white column, rounded on the right where it meets the border.
        Self.field.setFill()
        Self.roundedPath(g.bluePanel, tl: 0, tr: g.innerRadius, br: g.innerRadius, bl: 0).fill()

        // A popup is too short for the glyph-over-seal stack, so the glyph takes the
        // whole column and the seal sits it out.
        let tall = g.inner.height >= 240
        let glyphH = g.inner.height * (tall ? 0.47 : 0.62)
        drawGlyph(in: NSRect(x: g.inner.minX + g.panelW * 0.11,
                             y: tall ? g.inner.maxY - g.inner.height * 0.07 - glyphH
                                     : g.inner.midY - glyphH / 2,
                             width: g.panelW * 0.78, height: glyphH))
        if tall {
            drawSeal(center: NSPoint(x: g.inner.minX + g.panelW * 0.5,
                                     y: g.inner.minY + g.inner.height * 0.20),
                     radius: g.inner.height * 0.155)
        }
        drawText(in: g.textArea)
    }

    /// The big word squeezed to fill its column: measured at a reference size, then
    /// scaled non-uniformly, so it lands tall-and-narrow whatever fonts exist.
    private func drawGlyph(in rect: NSRect) {
        let probe = NSAttributedString(string: card.glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 200, weight: .black),
            .foregroundColor: Self.field
        ])
        let measured = probe.size()
        guard measured.width > 0, measured.height > 0 else { return }

        // A word gets squeezed to fill the column (that tall-narrow "FBI" look); a
        // single character would just come out fat, so it scales uniformly.
        var sx = rect.width / measured.width
        var sy = rect.height / measured.height
        var origin = NSPoint(x: rect.minX, y: rect.minY)
        if card.glyph.count < 2 {
            sx = min(sx, sy); sy = sx
            origin.x += (rect.width - measured.width * sx) / 2
            origin.y += (rect.height - measured.height * sy) / 2
        }

        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: origin.x, yBy: origin.y)
        t.scaleX(by: sx, yBy: sy)
        t.concat()
        probe.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A seal: two rings with tick "lettering" between them, a star ring, and a
    /// shield. Suggests the real thing at a glance without reproducing it.
    private func drawSeal(center c: NSPoint, radius r: CGFloat) {
        Self.field.setStroke()
        Self.field.setFill()
        for scale in [1.0, 0.86, 0.60] as [CGFloat] {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r * scale, y: c.y - r * scale,
                                                   width: r * scale * 2, height: r * scale * 2))
            ring.lineWidth = max(1, r * 0.035)
            ring.stroke()
        }
        // Tick marks standing in for the ring of tiny type.
        let ticks = NSBezierPath()
        ticks.lineWidth = max(0.8, r * 0.045)
        for i in 0..<44 {
            let a = CGFloat(i) / 44 * 2 * .pi
            ticks.move(to: NSPoint(x: c.x + cos(a) * r * 0.90, y: c.y + sin(a) * r * 0.90))
            ticks.line(to: NSPoint(x: c.x + cos(a) * r * 0.965, y: c.y + sin(a) * r * 0.965))
        }
        ticks.stroke()
        // Stars around the inner ring.
        for i in 0..<13 {
            let a = CGFloat(i) / 13 * 2 * .pi - .pi / 2
            let p = NSPoint(x: c.x + cos(a) * r * 0.73, y: c.y + sin(a) * r * 0.73)
            NSBezierPath(ovalIn: NSRect(x: p.x - r * 0.035, y: p.y - r * 0.035,
                                        width: r * 0.07, height: r * 0.07)).fill()
        }
        // Shield + scales in the middle.
        let s = r * 0.42
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: c.x - s * 0.8, y: c.y + s))
        shield.line(to: NSPoint(x: c.x + s * 0.8, y: c.y + s))
        shield.line(to: NSPoint(x: c.x + s * 0.8, y: c.y - s * 0.2))
        shield.curve(to: NSPoint(x: c.x, y: c.y - s),
                     controlPoint1: NSPoint(x: c.x + s * 0.8, y: c.y - s * 0.7),
                     controlPoint2: NSPoint(x: c.x + s * 0.4, y: c.y - s))
        shield.curve(to: NSPoint(x: c.x - s * 0.8, y: c.y - s * 0.2),
                     controlPoint1: NSPoint(x: c.x - s * 0.4, y: c.y - s),
                     controlPoint2: NSPoint(x: c.x - s * 0.8, y: c.y - s * 0.7))
        shield.close()
        shield.lineWidth = max(1, r * 0.05)
        shield.stroke()
        let bars = NSBezierPath()
        bars.lineWidth = max(1, r * 0.05)
        for dx in [-s * 0.34, 0, s * 0.34] as [CGFloat] {
            bars.move(to: NSPoint(x: c.x + dx, y: c.y - s * 0.35))
            bars.line(to: NSPoint(x: c.x + dx, y: c.y + s * 0.6))
        }
        bars.stroke()
    }

    /// Both blocks SHRINK TO FIT rather than clip. The copy is meant to be rewritten
    /// freely, and on a real screen a long title or an extra sentence would otherwise
    /// walk straight off the card.
    private func drawText(in rect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadow.shadowOffset = NSSize(width: 1.5, height: -1.5)
        shadow.shadowBlurRadius = 1

        func measure(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
            s.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                           options: [.usesLineFragmentOrigin]).height
        }

        let titlePara = NSMutableParagraphStyle()
        titlePara.alignment = .center
        func title(at size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: card.title, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: titlePara,
                .shadow: shadow
            ])
        }
        // A title that wraps eats the body's room, so shrink until it fits one line.
        let bodyless = card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var titleSize = rect.height * (bodyless ? 0.30 : 0.125)
        while titleSize > 12, title(at: titleSize).size().width > rect.width {
            titleSize -= 0.5
        }
        let fittedTitle = title(at: titleSize)
        let titleH = measure(fittedTitle, width: rect.width)
        // With no body the title is the whole message — center it in the panel.
        let titleY = bodyless ? rect.midY - titleH / 2 : rect.maxY - titleH
        fittedTitle.draw(in: NSRect(x: rect.minX, y: titleY,
                                    width: rect.width, height: titleH))
        guard !bodyless else { return }

        // Justified, tightly leaded — the look of the original block of legalese.
        let column = NSRect(x: rect.minX, y: rect.minY, width: rect.width,
                            height: rect.maxY - titleH - rect.height * 0.07 - rect.minY)
        guard column.height > 0 else { return }
        func body(at size: CGFloat) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.alignment = .justified
            para.lineSpacing = size * 0.20
            para.paragraphSpacing = size * 0.85
            return NSAttributedString(string: card.body, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
                .shadow: shadow
            ])
        }
        var size = rect.height * 0.058
        while size > 7, measure(body(at: size), width: column.width) > column.height {
            size -= 0.5
        }
        let fitted = body(at: size)
        let h = measure(fitted, width: column.width)
        fitted.draw(in: NSRect(x: column.minX, y: column.maxY - h,      // top-aligned
                               width: column.width, height: h))
    }

    /// Rounded rect with per-corner radii (the blue panel is square where it butts
    /// against the white column, rounded where it meets the border).
    private static func roundedPath(_ r: NSRect, tl: CGFloat, tr: CGFloat,
                                    br: CGFloat, bl: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + tl, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX - tr, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - tr, y: r.maxY - tr), radius: tr,
                    startAngle: 90, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: r.maxX, y: r.minY + br))
        p.appendArc(withCenter: NSPoint(x: r.maxX - br, y: r.minY + br), radius: br,
                    startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: r.minX + bl, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.minX + bl, y: r.minY + bl), radius: bl,
                    startAngle: -90, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: r.minX, y: r.maxY - tl))
        p.appendArc(withCenter: NSPoint(x: r.minX + tl, y: r.maxY - tl), radius: tl,
                    startAngle: 180, endAngle: 90, clockwise: true)
        p.close()
        return p
    }
}

// MARK: - Card rendering

/// Flat, stylized button. A real system bezel would read as genuine UI; this is a
/// stage set. Carries its own action closure so a card can be built without a target.
final class GateButton: NSButton {
    private let handler: () -> Void

    init(title: String, fill: NSColor?, textColor: NSColor, size: CGFloat, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = (fill ?? .clear).cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = fill == nil ? 1 : 0
        layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: textColor,
            .kern: 1.5
        ])
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func fire() { handler() }
}

/// Build one full-screen card. Manual frames (no autolayout) so the same builder
/// renders identically live and off-screen in `StillRenderer.renderGate`.
/// `onStart`/`onExit` are nil when rendering a still — the buttons draw but do nothing.
func makeIntroCardView(_ card: IntroCard, size: NSSize,
                       onStart: (() -> Void)? = nil,
                       onExit: (() -> Void)? = nil) -> NSView {
    if card.style == .vhs || card.style == .popup {
        return VHSWarningView(card: card, size: size, onStart: onStart, onExit: onExit)
    }
    if card.style == .restart {
        // The bar fills over most of the card, leaving a beat on a full bar before it
        // advances.
        return RestartCardView(size: size, duration: (card.dwell ?? 7) * 0.82)
    }
    if card.style == .macAlert {
        return GateAlertView(card, size: size, onStart: onStart, onExit: onExit)
    }

    let accent = NSColor(hex: card.accent) ?? .white
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = (NSColor(hex: IntroGate.backdrop) ?? .black).cgColor

    // The old warning-screen frame: a thin rule boxing in the whole message.
    let inset = min(size.width, size.height) * 0.055
    let frameView = NSView(frame: root.bounds.insetBy(dx: inset, dy: inset))
    frameView.wantsLayer = true
    frameView.layer?.borderWidth = 2
    frameView.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
    root.addSubview(frameView)

    let colW = min(760, size.width - inset * 4)
    let colX = (size.width - colW) / 2

    func label(_ string: String, font: NSFont, color: NSColor, kern: CGFloat, leading: CGFloat) -> NSTextField {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = leading
        let field = NSTextField(labelWithAttributedString: NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: para
        ]))
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = colW
        field.frame.size = field.sizeThatFits(NSSize(width: colW, height: .greatestFiniteMagnitude))
        field.frame.size.width = colW
        return field
    }

    let kicker = label(card.kicker, font: .monospacedSystemFont(ofSize: 12, weight: .bold),
                       color: accent, kern: 3.5, leading: 0)
    let title = label(card.title, font: .systemFont(ofSize: size.width < 900 ? 40 : 54, weight: .black),
                      color: .white, kern: -0.5, leading: 2)
    let body = label(card.body, font: .monospacedSystemFont(ofSize: 15, weight: .regular),
                     color: NSColor(white: 0.78, alpha: 1), kern: 0, leading: 6)

    var blocks: [NSView] = [kicker, title, body]
    let gaps: [CGFloat] = [18, 30]      // kicker→title, title→body
    var trailingGap: CGFloat = 0

    if card.dwell == nil {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: colW, height: 46))
        let yes = GateButton(title: "YES. INFECT ME.", fill: accent, textColor: .white, size: 15,
                             handler: { onStart?() })
        yes.frame = NSRect(x: 0, y: 0, width: 260, height: 46)
        let no = GateButton(title: "no thank you", fill: nil,
                            textColor: NSColor(white: 0.65, alpha: 1), size: 13,
                            handler: { onExit?() })
        no.frame = NSRect(x: 280, y: 0, width: 180, height: 46)
        let rowW = no.frame.maxX
        row.frame.size.width = rowW
        row.frame.origin.x = (size.width - rowW) / 2 - colX   // centered inside the column
        row.addSubview(yes)
        row.addSubview(no)
        blocks.append(row)
        trailingGap = 42
    }

    let totalH = blocks.reduce(0) { $0 + $1.frame.height } + gaps.reduce(0, +) + trailingGap
    var y = (size.height + totalH) / 2
    for (i, block) in blocks.enumerated() {
        y -= block.frame.height
        block.frame.origin.x += colX
        block.frame.origin.y = y
        root.addSubview(block)
        y -= (i < gaps.count ? gaps[i] : trailingGap)
    }
    return root
}

// MARK: - Controller

/// Borderless full-screen window that CAN take key events — unlike the effect panels,
/// which deliberately never steal focus. The pre-show is the one moment we want the
/// keyboard and the click.
private final class IntroWindow: NSWindow {
    var onClick: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class IntroGateController {
    private let onStart: () -> Void
    private let onExit: () -> Void
    private var window: IntroWindow?
    private var keyMonitor: Any?
    private var index = 0
    private var dwellToken = 0

    init(onStart: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onStart = onStart
        self.onExit = onExit
    }

    func present() {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).frame
        let win = IntroWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.backgroundColor = NSColor(hex: IntroGate.backdrop) ?? .black
        win.hasShadow = false
        win.alphaValue = 0
        win.onClick = { [weak self] in self?.advance() }
        window = win

        show(cardAt: 0, fade: false)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.7
            win.animator().alphaValue = 1
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window != nil else { return event }
            switch event.keyCode {
            case 53:                                   // esc — leave, at any point
                self.dismiss(then: self.onExit)
                return nil
            case 36:                                   // return — the default action
                if IntroGate.script[self.index].dwell == nil {
                    self.dismiss(then: self.onStart)
                } else {
                    self.advance()
                }
                return nil
            case 49:                                   // space — advance the dwell cards only
                if IntroGate.script[self.index].dwell != nil { self.advance() }
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Card flow

    private func show(cardAt i: Int, fade: Bool = true) {
        guard let win = window, i < IntroGate.script.count else { return }
        index = i
        let card = IntroGate.script[i]

        let screen = (NSScreen.main ?? NSScreen.screens[0]).frame
        // `.popup` and `.macAlert` stop being takeovers: the window shrinks to a panel
        // on the desktop and everything else comes back into view.
        let windowed = card.style == .popup || card.style == .macAlert
        let target: NSRect
        if windowed {
            let s = card.style == .macAlert ? IntroGate.alertSize : IntroGate.popupSize
            target = NSRect(x: screen.midX - s.width / 2, y: screen.midY - s.height / 2,
                            width: s.width, height: s.height)
        } else {
            target = screen
        }
        let reframe = {
            guard win.frame != target else { return }
            win.setFrame(target, display: false)
            win.backgroundColor = windowed ? .clear : (NSColor(hex: IntroGate.backdrop) ?? .black)
            win.isOpaque = !windowed
            win.hasShadow = windowed
        }

        let install = {
            let view = makeIntroCardView(card, size: win.frame.size,
                                         onStart: { [weak self] in self?.dismiss(then: self?.onStart) },
                                         onExit: { [weak self] in self?.dismiss(then: self?.onExit) })
            if fade {
                view.alphaValue = 0
                win.contentView = view
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    view.animator().alphaValue = 1
                }
            } else {
                win.contentView = view
            }
        }
        // The outgoing card fades out before the next one is built. The restart card
        // ends on a full blue screen, and cutting straight from that to a small alert
        // on the desktop is a jump-cut; this lets the blue go down first. The window is
        // resized only after the fade, or the shrink happens behind the fading view.
        if fade, let outgoing = win.contentView, outgoing.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.55
                outgoing.animator().alphaValue = 0
            }, completionHandler: {
                reframe()
                install()
            })
        } else {
            reframe()
            install()
        }

        if ProcessInfo.processInfo.environment["DPE_GATE_AUTOYES"] == "1",
           card.style == .macAlert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak win] in
                NSLog("[DPE] gate: DPE_GATE_AUTOYES pressing yes")
                ((win?.contentView) as? GateAlertView)?.pressYesForTesting()
            }
        }

        dwellToken &+= 1
        guard let dwell = card.dwell else { return }
        let token = dwellToken
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell) { [weak self] in
            guard let self = self, self.dwellToken == token else { return }
            self.advance()
        }
    }

    /// Click / space / timer: step to the next card. Stops at the choice card — that
    /// one only moves on a deliberate answer.
    private func advance() {
        guard index + 1 < IntroGate.script.count else { return }
        show(cardAt: index + 1)
    }

    private func dismiss(then action: (() -> Void)?) {
        guard let win = window else { return }
        dwellToken &+= 1
        window = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            win.animator().alphaValue = 0
        }, completionHandler: {
            win.orderOut(nil)
            action?()
        })
    }
}

/// The warning and the question in real macOS chrome, built from
/// `makeDialogContentView` so it matches the show's fake dialogs; its inert buttons are
/// found by title and given the gate's actions.
///
/// **The view owns the action objects.** `NSControl.target` is a WEAK reference: an
/// action object held anywhere less durable is deallocated, `target` quietly becomes
/// nil, and the button does nothing at all when clicked.
final class GateAlertView: NSView {
    private var actions: [GateButtonAction] = []

    init(_ card: IntroCard, size: NSSize, onStart: (() -> Void)?, onExit: (() -> Void)?) {
        super.init(frame: NSRect(origin: .zero, size: size))
        let yes = "YES. INFECT ME."
        let no = "no thank you"
        let content = makeDialogContentView(title: card.title, message: card.body,
                                            buttons: [no, yes], icon: .caution, size: size)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)

        for button in content.subviews.compactMap({ $0 as? NSButton }) {
            let isYes = button.title == yes
            // Either answer makes the sound; only then does the gate act on it. The
            // sound is short and the dismissal fades over 0.45 s, so they overlap rather
            // than the click being swallowed.
            let action = GateButtonAction {
                NSLog("[DPE] gate: answered \(isYes ? "YES" : "no")")
                GateSound.play()
                if isYes { onStart?() } else { onExit?() }
            }
            actions.append(action)                 // strong, for as long as the card lives
            button.target = action
            button.action = #selector(GateButtonAction.fire)
        }
    }

    /// Press "yes" as if the viewer had. `DPE_GATE_AUTOYES=1` uses this to drive the
    /// gate from a script — the dev loop's `--no-gate` skips the gate entirely, which is
    /// no use when the thing being checked is what the gate's answer sets in motion.
    func pressYesForTesting() {
        (subviews.first?.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == "YES. INFECT ME." }?.target as? GateButtonAction)?.fire()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Target for a gate alert button. `makeDialogContentView` builds plain `NSButton`s
/// with no target, and a closure cannot be one.
final class GateButtonAction: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

// MARK: - Restart card

/// The machine restarting: black, the logo, a progress bar — and then it doesn't come
/// back the way it went down. At the end of the bar the ground turns DJ Dave blue and
/// the logo becomes the face.
///
/// Deliberately NOT `BootView`, which the fake reboot and the outro both use: this one
/// carries the colour turn and the image swap, and folding those into the shared view
/// would put a one-off intro behaviour in the middle of two other acts. The geometry is
/// matched to it so the two read as the same screen.
final class RestartCardView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private let glyph = NSTextField(labelWithString: "\u{F8FF}")
    private let face = NSImageView()
    private let trackWidth: CGFloat
    private var timer: Timer?
    private let start = CACurrentMediaTime()
    /// How long the bar takes to reach the hang point.
    private let duration: Double
    private var turned = false

    /// Where the bar catches. It does not stop there — it stalls, the ground turns blue
    /// and the face arrives, and then it carries on and fills. The stumble is the tell:
    /// something interrupted the restart and the restart kept going anyway.
    static let hangFraction: CGFloat = 0.6
    /// The bar's life, split three ways: rise to the catch, sit there, finish.
    static let risePortion = 0.42
    static let pausePortion = 0.16

    /// The logo's height, as a fraction of the screen. The FACE inherits the same
    /// number — the swap only reads as the logo *becoming* the face if the two are one
    /// size, so they must not drift apart.
    static let logoHeight: CGFloat = 0.1275

    init(size: NSSize, duration: Double) {
        self.duration = max(1, duration)
        trackWidth = min(size.width * 0.20, 330)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        glyph.font = .systemFont(ofSize: size.height * RestartCardView.logoHeight, weight: .medium)
        glyph.textColor = .white
        glyph.alignment = .center
        glyph.sizeToFit()
        glyph.frame = NSRect(x: (size.width - glyph.frame.width) / 2, y: size.height * 0.50,
                             width: glyph.frame.width, height: glyph.frame.height)
        addSubview(glyph)

        // The face sits exactly where the logo was, at the same optical size, and fades
        // in over it — so the swap reads as the logo *becoming* the face rather than as
        // one thing leaving and another arriving.
        let faceH = size.height * RestartCardView.logoHeight
        if let image = NSImage(contentsOfFile: resolveResourcePath(IntroGate.faceAsset))
            .map(RestartCardView.maskingField) {
            face.image = image
            let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
            face.frame = NSRect(x: (size.width - faceH * ratio) / 2,
                                y: glyph.frame.midY - faceH / 2,
                                width: faceH * ratio, height: faceH)
        }
        face.imageScaling = .scaleProportionallyUpOrDown
        face.alphaValue = 0
        addSubview(face)

        let trackH: CGFloat = 6
        track.frame = CGRect(x: (size.width - trackWidth) / 2, y: size.height * 0.415,
                             width: trackWidth, height: trackH)
        track.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
        track.cornerRadius = trackH / 2
        track.masksToBounds = true
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: trackH)
        fill.backgroundColor = NSColor.white.cgColor
        fill.cornerRadius = trackH / 2
        track.addSublayer(fill)
        layer?.addSublayer(track)

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }

    /// Render one frame without a clock, for the still renderer, which has no run loop
    /// to drive the timer. `t` is 0…1 across the bar's life.
    func renderStatic(t: Double, turned: Bool) {
        setProgress(t)
        if turned { turn() }
    }

    /// The moment worth putting in a still: caught at the stall, already blue.
    static let stillMoment = risePortion + pausePortion / 2

    /// Knock the artwork's own background out, so only the face draws and it sits on
    /// whatever colour the card's ground happens to be.
    ///
    /// **Works on a private copy of the bitmap, never the source's own representation.**
    /// `NSBitmapImageRep.setColor` writes through to the backing store, and an `NSImage`
    /// loaded from a path can be backed by the mapped file — doing this in place once
    /// edited a committed asset on disk. `GateTests` pins that the file is untouched.
    static func maskingField(_ image: NSImage) -> NSImage {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return image
        }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let made: CGImage? = buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: info) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else {
                return nil
            }
            // The field colour, read from the top-left pixel.
            let fr = Int(p[0]), fg = Int(p[1]), fb = Int(p[2])
            // Wide tolerance: the source is a JPEG, so its flat blue is not one value.
            let tol = 56
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                if abs(Int(p[i]) - fr) < tol,
                   abs(Int(p[i + 1]) - fg) < tol,
                   abs(Int(p[i + 2]) - fb) < tol {
                    // Premultiplied: a transparent pixel is all four bytes zero.
                    p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
                }
            }
            return ctx.makeImage()
        }
        guard let masked = made else { return image }
        return NSImage(cgImage: masked, size: image.size)
    }

    private func tick() {
        let t = min(1.0, (CACurrentMediaTime() - start) / duration)
        setProgress(t)
        // The turn happens the moment the bar catches, not when it finishes.
        if t >= RestartCardView.risePortion { turn() }
        if t >= 1.0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Draw the bar at `t`, where `t` is 0…1 across the bar's whole life.
    ///
    /// Three segments: ease up to the catch, sit at it, then ease the rest of the way.
    /// The catch is expressed in the value that gets DRAWN, not in the input — easing a
    /// raw 0.6 gives about 0.81, which would put the stall four-fifths along rather than
    /// the three-fifths it is meant to read as.
    private func setProgress(_ t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame.size.width = trackWidth * RestartCardView.barFraction(at: t)
        CATransaction.commit()
    }

    /// How full the bar is at `t` (0…1 across its life). Pure, so the shape can be
    /// asserted — a still can only ever catch one frame of it, and the whole point is
    /// what happens across three.
    static func barFraction(at t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        func ease(_ x: Double) -> CGFloat { CGFloat(1 - pow(1 - min(1, max(0, x)), 1.8)) }
        if t < risePortion {
            return hangFraction * ease(t / risePortion)
        }
        if t < risePortion + pausePortion {
            return hangFraction
        }
        let rest = (t - risePortion - pausePortion) / max(0.001, 1 - risePortion - pausePortion)
        return min(1, hangFraction + (1 - hangFraction) * ease(rest))
    }

    /// Black to blue, logo to face — a deliberate one-frame cut. `CATransaction`
    /// actions are disabled because a layer's `backgroundColor` otherwise animates
    /// implicitly, a quarter-second cross-dissolve with no explicit animation anywhere.
    private func turn() {
        guard !turned else { return }
        turned = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (NSColor(hex: IntroGate.djBlue) ?? .systemBlue).cgColor
        glyph.alphaValue = 0
        face.alphaValue = 1
        CATransaction.commit()
    }
}

// MARK: - Gate sound

/// The click the gate's buttons make. One preloaded player, reused — building an
/// `AVAudioPlayer` at press time costs enough to land after the window has already
/// started fading out.
enum GateSound {
    private static var player: AVAudioPlayer? = {
        let path = resolveResourcePath(IntroGate.buttonSound)
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[DPE] gate: button sound not found at \(path)")
            return nil
        }
        let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        p?.prepareToPlay()
        return p
    }()

    static func play() {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }
}
