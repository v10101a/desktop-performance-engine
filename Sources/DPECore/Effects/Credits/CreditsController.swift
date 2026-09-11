import AppKit
import CoreImage
import QuartzCore

/// The end card. A black ground, and on it: the photo the booth took, in a white
/// frame with a flattering filter; the machine reading its own vitals out in the probe's
/// terminal style; and the credits, typing themselves out in a terminal of their own.
///
/// It HOLDS. When the track runs out the engine asks `isHolding` and, if so, pauses
/// instead of restoring — so the card stays up as long as the viewer wants to look at
/// it (or screenshot it). The credits alert's button, the Stop button and the panic
/// hotkey all end it.
///
/// **Reversibility.** Windows only, with one deliberate exception: the card's *save
/// photo* button writes a PNG to `~/Pictures`, and only when the viewer presses it. The
/// photo itself still lives in `PhotoBoothStore`, in memory, and is still discarded when
/// the show stops — the show never writes it on its own.
final class CreditsController {
    private struct Credits {
        let id: String
        let windows: [NSWindow]
        let hold: Bool
        /// The credits terminal types itself out; these drive it from `startTyping`.
        let roll: NSTextField?
        let text: [Character]
        /// The character counts the typing pauses at, in order: every character when it
        /// types by the character, the end of each line when it types by the line.
        let stops: [Int]
        let byLine: Bool
        /// Wall-clock, not show time — see `startTyping`.
        let start: Double
        /// Stops per second.
        let rate: Double
        var shown: Int = -1
        var caretOn: Bool = true
        /// True once the last character has landed — the point the card will take a
        /// click to dismiss.
        var finished: Bool { shown >= text.count }
        /// Back-to-front with the frame the layout gave each window, for compositing
        /// the card into a still. (The frame is kept separately because AppKit keeps a
        /// titled window at least partly on a screen, so off-screen the window's own
        /// `frame` is not where the layout put it.)
        var placed: [(window: NSWindow, frame: NSRect)] = []
    }

    private var credits: Credits?
    /// Drives the credits typing independently of the show clock (see `startTyping`).
    private var typeTimer: Timer?
    private var outroTimer: Timer?
    private let outro = OutroController()
    private var outroEnabled = true
    private var outroDelay: Double = 2
    private var outroScreen: NSScreen?
    /// The tile layer, kept so the outro can stop it mid-drift.
    private var driftLayer: CALayer?

    /// Set by the engine: what ends the process once the outro has run.
    var onQuit: (() -> Void)?
    var bpm: Double = 120

    /// Set by the engine: what the "bye" button does.
    var onDismiss: (() -> Void)?

    /// The engine checks this at the end of the track.
    var isHolding: Bool { credits?.hold ?? false }

    // MARK: - Lifecycle

    /// - Parameter screenFrame: build the card in this rect instead of on the screen —
    ///   the still renderer's seam, so it can lay the real windows out off-screen.
    func begin(_ p: CreditsParams, at now: Double, bpm: Double, screenFrame: NSRect? = nil) {
        teardown()
        let screen = ScreenGeometry.screen(p.screen)
        let sf = screenFrame ?? screen.frame
        let W = sf.width, H = sf.height
        var wins: [NSWindow] = []

        // 1. the ground
        let back = BaseEffectWindow(contentRect: sf)
        back.ignoresMouseEvents = true
        back.hasShadow = false
        let ground = NSView(frame: NSRect(origin: .zero, size: sf.size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = (NSColor(hex: p.backdrop ?? "#000000") ?? .black).cgColor
        if let tile = p.tile {
            driftLayer = CreditsController.addDriftingTile(tile, to: ground,
                                                           secondsPerTile: p.tileDriftSeconds ?? 4,
                                                           padding: p.tilePadding ?? 1.0,
                                                           scale: p.tileScale ?? 0.05)
        }
        back.contentView = ground
        back.present(animate: "fadeIn")
        wins.append(back)

        // The copy. Interior blank lines are kept (they are the stanza breaks); only
        // leading and trailing blanks are trimmed.
        var lines = p.lines ?? []
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let body = lines.joined(separator: "\n")
        let rollFont = CreditsController.rollFont(for: lines, size: p.fontSize ?? 11, in: sf)

        // Sizes first, then the layout places them as a group — see `layout`.
        let photoW = min(W * 0.32, 480)
        let photoH = photoW * 0.75
        // Taller foot than the still preview's: the caption and the save button stack in it.
        let margin: CGFloat = 16, foot: CGFloat = (p.allowSave ?? true) ? 108 : 70
        let cardSize = NSSize(width: photoW + margin * 2, height: photoH + margin + foot)
        let tilt = CGFloat(p.photoTilt ?? -4)
        let rollSize = CreditsController.rollSize(for: lines, font: rollFont, in: sf)
        let showInfo = p.showInfo ?? true
        let infoSize = NSSize(width: min(W * 0.30, 440), height: 262)
        let lay = CreditsController.layout(in: sf, photo: CreditsController.tiltedBounds(cardSize, degrees: tilt),
                                           roll: rollSize, info: infoSize, showInfo: showInfo)

        // 2. the machine, in the probe's terminal — under the credits, flush right with them
        var info: EffectWindow?
        if showInfo {
            let w = EffectWindow(contentRect: lay.info,
                                 content: ContentSpec(kind: "code", text: CreditsController.machineSummary(),
                                                      chrome: "terminal", title: "system_probe — summary"))
            // A size up from Terminal's 11: it sits next to the credits' big type and
            // would otherwise read as fine print.
            CreditsController.firstTextField(in: w.contentView)?.font =
                .monospacedSystemFont(ofSize: 13, weight: .regular)
            w.present(animate: "fadeIn")
            wins.append(w)
            info = w
        }

        // 3. the credits — a terminal sized to its copy, typing itself out.
        let roll = EffectWindow(contentRect: lay.roll,
                                content: ContentSpec(kind: "code", text: "",
                                                     chrome: "terminal",
                                                     title: p.title ?? "credits"))
        let label = CreditsController.firstTextField(in: roll.contentView)
        label?.font = rollFont
        // The copy starts clear of the strip the photo laps over, so no line loses its
        // first letters under the print.
        if let label {
            let indent = CreditsController.photoOverlap + 12
            label.frame = NSRect(x: label.frame.minX + indent, y: label.frame.minY,
                                 width: label.frame.width - indent, height: label.frame.height)
        }
        roll.present(animate: "fadeIn")
        wins.append(roll)
        // The window itself takes the click that ends the show — but only once the copy
        // has finished typing, so a stray click can't cut the card short. (Stop and the
        // panic hotkey end it regardless.)
        roll.ignoresMouseEvents = false
        roll.onUserClose = { [weak self] in self?.byePressed() }
        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        roll.contentView?.addGestureRecognizer(click)

        // 4. the photo, in a white frame, pinned on at a slight tilt and lapping over the
        //    credits' edge: it is the thing the viewer keeps, so it sits in front.
        //    The window is the tilted card's bounding box, clear, with the card turned
        //    inside it — a window can't rotate, a view can.
        let card = BaseEffectWindow(contentRect: lay.photo)
        // The one interactive thing on the card: the save button. Everything else on it
        // is scenery, and the window still never becomes key.
        card.ignoresMouseEvents = false
        card.hasShadow = true
        let holder = NSView(frame: NSRect(origin: .zero, size: lay.photo.size))
        holder.wantsLayer = true
        let photoCard = CreditsController.makePhotoCard(
            size: cardSize, photo: PhotoBoothStore.shared.image,
            photoRect: NSRect(x: margin, y: foot, width: photoW, height: photoH),
            caption: p.caption ?? CreditsController.defaultCaption(), filter: p.filter ?? "instant",
            showsSave: p.allowSave ?? true, saveTarget: self, saveAction: #selector(savePressed))
        photoCard.frame.origin = NSPoint(x: (lay.photo.width - cardSize.width) / 2,
                                         y: (lay.photo.height - cardSize.height) / 2)
        photoCard.frameCenterRotation = tilt
        holder.addSubview(photoCard)
        card.contentView = holder
        card.present(animate: "springIn")
        // A clear window's shadow follows its opaque pixels; ask for it once they exist.
        card.invalidateShadow()
        wins.append(card)

        // Front-to-back: photo over terminal.
        card.order(.above, relativeTo: roll.windowNumber)

        outroEnabled = p.outro ?? true
        outroDelay = p.outroDelay ?? 2
        outroScreen = screen
        outro.glitchSeconds = p.glitchSeconds ?? 0.5
        outro.bootSeconds = p.bootSeconds ?? 5

        let byLine = p.linesPerSecond != nil
        let text = Array(body)
        var stops: [Int] = []
        if byLine {
            var n = 0
            for (i, line) in lines.enumerated() {
                n += line.count + (i > 0 ? 1 : 0)      // the newline before every line but the first
                stops.append(n)
            }
        } else {
            stops = text.isEmpty ? [] : Array(1...text.count)
        }
        credits = Credits(id: p.id, windows: wins, hold: p.hold ?? true,
                          roll: label, text: text, stops: stops, byLine: byLine,
                          start: CACurrentMediaTime(),
                          rate: max(0.1, byLine ? (p.linesPerSecond ?? 2) : (p.charsPerSecond ?? 7)),
                          placed: [(back, sf)] + (info.map { [($0, lay.info)] } ?? [])
                                  + [(roll, lay.roll), (card, lay.photo)])
        startTyping()
    }

    // MARK: - Layout

    struct Layout {
        let photo: NSRect
        let roll: NSRect
        let info: NSRect
    }

    /// How far the photo's box laps over the credits terminal's left edge.
    static let photoOverlap: CGFloat = 30

    /// A collage, centred as a group rather than spread to the corners: the photo on the
    /// left, the credits beside it with the machine's summary tucked under them, flush
    /// right. Every rect is kept on the screen by shifting, never by shrinking.
    static func layout(in sf: NSRect, photo: NSSize, roll: NSSize, info: NSSize,
                       showInfo: Bool) -> Layout {
        let overlap = photoOverlap
        let gap: CGFloat = 18
        let groupW = photo.width - overlap + roll.width
        let left = sf.midX - groupW / 2
        let colH = showInfo ? roll.height + gap + info.height : roll.height
        let colTop = sf.midY + colH / 2
        let rollRect = NSRect(x: left + photo.width - overlap, y: colTop - roll.height,
                              width: roll.width, height: roll.height)
        let infoRect = NSRect(x: rollRect.maxX - info.width, y: rollRect.minY - gap - info.height,
                              width: info.width, height: info.height)
        // The photo rides a touch above the column's middle, the way a pinned print does.
        let photoRect = NSRect(x: left, y: sf.midY - photo.height / 2 + sf.height * 0.02,
                               width: photo.width, height: photo.height)
        func onScreen(_ r: NSRect) -> NSRect {
            let inset = sf.insetBy(dx: 12, dy: 12)
            var out = r
            out.origin.x = min(max(r.minX, inset.minX), max(inset.minX, inset.maxX - r.width))
            out.origin.y = min(max(r.minY, inset.minY), max(inset.minY, inset.maxY - r.height))
            return out
        }
        return Layout(photo: onScreen(photoRect), roll: onScreen(rollRect), info: onScreen(infoRect))
    }

    /// The widest the credits terminal is allowed to get, as a fraction of the screen:
    /// past this the collage stops being a group and becomes a wall of type.
    static let rollWidthFraction: CGFloat = 0.46

    /// What the terminal WOULD take across to hold `lines` at `font` — the longest line
    /// plus a little air, plus Terminal's insets and the strip the photo laps over.
    static func naturalRollWidth(for lines: [String], font: NSFont) -> CGFloat {
        let charW = ("M" as NSString).size(withAttributes: [.font: font]).width
        let longest = CGFloat(lines.map(\.count).max() ?? 0)
        return charW * (longest + 6) + TerminalStyle.inset * 2 + photoOverlap + 12
    }

    /// The credits face, shrunk until the longest line fits the width the terminal is
    /// allowed to take. `rollSize` clamps the width, so at the authored size a long line
    /// does not widen the window — it WRAPS, and a credit that breaks in the middle of a
    /// name reads as a bug. The song's own credit block runs to 44 characters.
    static func rollFont(for lines: [String], size: Double, in sf: NSRect) -> NSFont {
        var pt = CGFloat(size)
        func font(_ pt: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: pt, weight: .regular) }
        while pt > 11, naturalRollWidth(for: lines, font: font(pt)) > sf.width * rollWidthFraction {
            pt -= 0.5
        }
        return font(pt)
    }

    /// The credits terminal, sized to its copy: the longest line plus a little air across,
    /// the line count plus a spare line down (the caret sits on its own line while the
    /// copy types by the line), plus Terminal's insets and a title bar.
    static func rollSize(for lines: [String], font: NSFont, in sf: NSRect) -> NSSize {
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let w = naturalRollWidth(for: lines, font: font)
        let h = lineH * CGFloat(lines.count + 2) + TerminalStyle.inset * 2 + 28
        return NSSize(width: min(sf.width * rollWidthFraction, max(sf.width * 0.28, w)),
                      height: min(sf.height * 0.62, max(sf.height * 0.22, h)))
    }

    /// The bounding box of `size` turned by `degrees` — what the tilted card's window has
    /// to be for none of its corners to be clipped.
    static func tiltedBounds(_ size: NSSize, degrees: CGFloat) -> NSSize {
        let a = abs(degrees) * .pi / 180
        return NSSize(width: (size.width * cos(a) + size.height * sin(a)).rounded(.up),
                      height: (size.width * sin(a) + size.height * cos(a)).rounded(.up))
    }

    @objc private func byePressed() { onDismiss?() }

    /// The ONLY thing in the piece that puts the photo on disk, and only because the
    /// viewer pressed the button. Writes straight to `~/Pictures` rather than via
    /// `NSSavePanel`, which would open *behind* the card's `.screenSaver`-level windows.
    @objc private func savePressed() {
        guard let image = PhotoBoothStore.shared.image else {
            reportSave("no photo to save"); return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let when = PhotoBoothStore.shared.takenAt ?? Date()
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        let url = dir.appendingPathComponent("GiveIt2Me-\(f.string(from: when)).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            reportSave("couldn't encode"); return
        }
        do {
            try png.write(to: url)
            NSLog("[DPE] credits: photo saved to \(url.path)")
            reportSave("saved to Pictures")
        } catch {
            NSLog("[DPE] credits: photo save failed — \(error.localizedDescription)")
            reportSave("couldn't save")
        }
    }

    /// The button is the only status surface the card has, so it becomes the receipt.
    private func reportSave(_ text: String) {
        guard let card = credits?.windows.first(where: {
            $0.contentView?.subviews.contains { $0.identifier == CreditsController.savePhotoButtonID } ?? false
        }), let button = card.contentView?.subviews.first(where: {
            $0.identifier == CreditsController.savePhotoButtonID
        }) as? NSButton else { return }
        button.title = text
        button.isEnabled = false
    }

    /// The copy has landed. After a beat to read the last line, the machine stops
    /// responding — see `OutroController`.
    private func beginOutro() {
        guard outroEnabled, let screen = outroScreen else { return }
        let delay = outroDelay
        let t = Timer(timeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.freeze()
            self.outro.onFinished = { [weak self] in self?.onQuit?() }
            self.outro.begin(on: screen)
        }
        RunLoop.main.add(t, forMode: .common)
        outroTimer = t
    }

    /// Make the card look hung, the moment the machine claims it is.
    ///
    /// Three things at once, because any one of them alone reads as a style choice rather
    /// than a stall: the drift stops dead, every window on the card goes grey and flat,
    /// and the pointer becomes the spinner. The alert itself is raised afterwards and is
    /// deliberately NOT frozen — it is the one part of the screen still responding.
    private func freeze() {
        // Stop the drift where it stands. Pausing the layer's time rather than removing
        // the animation keeps the tiles wherever the eye last saw them; removing it would
        // snap them back to the animation's start.
        if let layer = driftLayer {
            layer.speed = 0
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
        }
        for window in credits?.windows ?? [] {
            guard let content = window.contentView, let layer = content.layer else { continue }
            // Desaturate the whole window. `filters` is a real macOS-only CALayer feature,
            // so this is the actual "colour drains out" look rather than a grey wash.
            if let mono = CIFilter(name: "CIColorControls") {
                mono.setValue(0.0, forKey: kCIInputSaturationKey)
                mono.setValue(-0.08, forKey: kCIInputBrightnessKey)
                layer.filters = [mono]
            }
            // And a translucent grey over the top, so it still reads as frozen on a
            // display where layer filters are unavailable.
            let veil = CALayer()
            veil.frame = content.bounds
            veil.backgroundColor = (NSColor(hex: "#C1C7D6") ?? .lightGray)
                .withAlphaComponent(0.42).cgColor
            veil.zPosition = 10_000
            veil.name = CreditsController.veilLayerName
            layer.addSublayer(veil)
        }
    }

    static let veilLayerName = "dpe.credits.frozenVeil"

    /// Tiled wallpaper behind the end card, drifting diagonally.
    ///
    /// The layer is inset by one tile on every side and translated by exactly one tile
    /// per cycle, so the pattern lands back on itself and the repeat is seamless — a
    /// drift of any other distance would visibly jump at the loop point.
    @discardableResult
    static func addDriftingTile(_ path: String, to view: NSView, secondsPerTile: Double,
                                padding: Double, scale: Double) -> CALayer? {
        let resolved = resolveResourcePath(path)
        guard let source = NSImage(contentsOfFile: resolved) else {
            NSLog("[DPE] credits: tile image not found at \(resolved) — plain backdrop")
            return nil
        }
        let image = padded(scaled(source, by: scale), by: padding)
        let tw = max(2, image.size.width), th = max(2, image.size.height)
        // Clip: the drifting layer is deliberately one tile larger than the view on every
        // side, and without this it paints that overhang outside its bounds. Invisible on
        // a fullscreen card (the excess is off-screen) but wrong everywhere else.
        view.layer?.masksToBounds = true
        let layer = CALayer()
        layer.frame = view.bounds.insetBy(dx: -tw, dy: -th)
        layer.backgroundColor = NSColor(patternImage: image).cgColor
        layer.zPosition = -1
        view.layer?.addSublayer(layer)

        let drift = CABasicAnimation(keyPath: "position")
        drift.fromValue = NSValue(point: NSPoint(x: layer.position.x, y: layer.position.y))
        drift.toValue = NSValue(point: NSPoint(x: layer.position.x + tw, y: layer.position.y + th))
        drift.duration = max(1, secondsPerTile)
        drift.repeatCount = .greatestFiniteMagnitude
        // Linear and non-removed: this runs for the whole hold, which has no end.
        drift.timingFunction = CAMediaTimingFunction(name: .linear)
        drift.isRemovedOnCompletion = false
        layer.add(drift, forKey: "drift")
        return layer
    }

    /// The artwork's own field colour, read from its top-left pixel. Read-only — nothing
    /// here writes to the bitmap, which is what makes it safe on a file-backed image.
    static func cornerColor(of image: NSImage) -> NSColor? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).colorAt(x: 0, y: 0)
    }

    /// Redraw the artwork at `scale`. At the show's 0.05 this turns a 432 px motif into a
    /// ~22 px one — a fine repeating texture rather than recognisable artwork, which is
    /// the point: it reads as pattern behind the copy, not as a picture competing with it.
    static func scaled(_ image: NSImage, by scale: Double) -> NSImage {
        guard scale > 0, scale != 1 else { return image }
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        return out
    }

    /// Space the motif out: the cell grows by `padding` (1.0 = 100%, i.e. a full
    /// image-width of gap between neighbours) with the artwork centred in it.
    ///
    /// The gap is filled with the artwork's own top-left pixel, so the spacing between
    /// motifs is indistinguishable from the field inside each one — the whole card reads
    /// as a single continuous white ground rather than tiles on a backing colour.
    static func padded(_ image: NSImage, by padding: Double) -> NSImage {
        let pad = max(0, padding)
        guard pad > 0 else { return image }
        let w = image.size.width, h = image.size.height
        let cell = NSSize(width: w * (1 + pad), height: h * (1 + pad))
        let fill = cornerColor(of: image) ?? .white
        let out = NSImage(size: cell)
        out.lockFocus()
        fill.setFill()
        NSRect(origin: .zero, size: cell).fill()
        image.draw(in: NSRect(x: (cell.width - w) / 2, y: (cell.height - h) / 2,
                              width: w, height: h))
        out.unlockFocus()
        return out
    }

    /// What the credits terminal currently shows, caret stripped. Test seam only.
    var typedTextForTesting: String? {
        credits?.roll?.stringValue.replacingOccurrences(of: "\u{2588}", with: "")
    }

    /// The same, caret included. Test seam only.
    var credits_rawTextForTesting: String? { credits?.roll?.stringValue }

    /// Land the whole copy at once, without the outro. Still-renderer seam only.
    func finishTypingForSnapshot() {
        typeTimer?.invalidate()
        typeTimer = nil
        guard var c = credits else { return }
        c.shown = c.text.count
        c.caretOn = false
        credits = c
        c.roll?.stringValue = String(c.text)
    }

    /// The card's windows, back to front, each with the frame the layout gave it.
    /// Still-renderer seam only.
    var windowsForSnapshot: [(window: NSWindow, frame: NSRect)] { credits?.placed ?? [] }

    /// A click anywhere on the credits terminal ends the show — but only after the copy
    /// has finished. Before that the click lands on scenery and does nothing.
    @objc private func cardClicked() {
        guard credits?.finished == true else { return }
        onDismiss?()
    }

    /// The label `applyContent` made for a `code` window, fished back out rather than
    /// rebuilt, so the typed text keeps the chrome every other terminal wears.
    static func firstTextField(in view: NSView?) -> NSTextField? {
        DPECore.firstTextField(in: view)
    }

    func stop(id: String) {
        guard credits?.id == id else { return }
        teardown()
    }

    func closeAll() { teardown() }

    private func teardown() {
        typeTimer?.invalidate()
        typeTimer = nil
        outroTimer?.invalidate()
        outroTimer = nil
        outro.closeAll()
        guard let c = credits else { return }
        for w in c.windows { w.orderOut(nil) }
        credits = nil
    }

    /// The engine's per-frame hook. The credits deliberately do NOT type from it — see
    /// `startTyping` — so there is nothing to do here.
    func update(now: Double) {}

    /// The credits run on their own wall-clock timer rather than the show clock: the
    /// card fires at the last beat, the engine's end-of-piece branch pauses the pump,
    /// and nothing calls `update(now:)` again during the hold. A timer of its own
    /// finishes the copy whether the transport is playing, paused, holding or scrubbed.
    private func startTyping() {
        typeTimer?.invalidate()
        guard credits?.roll != nil, credits?.text.isEmpty == false else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceTyping()
        }
        // .common so the copy keeps typing while a menu is open or a window is dragged.
        RunLoop.main.add(t, forMode: .common)
        typeTimer = t
        advanceTyping()
    }

    /// Stops by elapsed time — characters, or whole lines — caret blinking at 2 Hz,
    /// redraw only when one of them changes. The caret is dropped once the copy is
    /// done, which is also the point the card starts accepting a click.
    private func advanceTyping() {
        guard var c = credits, let label = c.roll else { typeTimer?.invalidate(); return }
        let elapsed = CACurrentMediaTime() - c.start
        let units = max(0, Int(elapsed * c.rate))
        let want = units == 0 ? 0 : c.stops[min(units, c.stops.count) - 1]
        let done = units >= c.stops.count
        let caret = !done && Int(elapsed * 2) % 2 == 0
        guard want != c.shown || caret != c.caretOn else { return }
        c.shown = want
        c.caretOn = caret
        credits = c
        var shown = String(c.text[0..<want])
        if caret { shown += (c.byLine && want > 0 ? "\n" : "") + "\u{2588}" }
        label.stringValue = shown
        if done {
            typeTimer?.invalidate()
            typeTimer = nil
            beginOutro()
        }
    }

    // MARK: - Pieces

    static func defaultCaption() -> String { "I SURVIVED THE GIVE IT 2 ME MALWARE EXPERIENCE!" }

    /// A white card with the photo and a caption under it — the frame a photo gets
    /// when somebody wants to keep it.
    static func makePhotoCard(size: NSSize, photo: NSImage?, photoRect: NSRect,
                              caption: String, filter: String,
                              showsSave: Bool = false,
                              saveTarget: AnyObject? = nil, saveAction: Selector? = nil) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.985, alpha: 1).cgColor
        root.layer?.cornerRadius = 4

        let iv = NSImageView(frame: photoRect)
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        iv.imageScaling = .scaleProportionallyUpOrDown
        if let photo {
            iv.image = filtered(photo, filter: filter)
            iv.imageScaling = .scaleAxesIndependently
        } else {
            let none = NSTextField(labelWithString: "no photo —\nthe camera said no")
            none.font = .systemFont(ofSize: 15, weight: .medium)
            none.textColor = NSColor(white: 1, alpha: 0.6)
            none.alignment = .center
            none.maximumNumberOfLines = 2
            none.frame = NSRect(x: 0, y: photoRect.height / 2 - 20, width: photoRect.width, height: 40)
            iv.addSubview(none)
        }
        root.addSubview(iv)

        let hasButton = showsSave
        let cap = NSTextField(labelWithString: caption)
        let capW = size.width - 16
        cap.font = fittedCaptionFont(caption, in: capW)
        cap.textColor = NSColor(white: 0.12, alpha: 1)
        cap.alignment = .center
        cap.maximumNumberOfLines = 2
        cap.cell?.truncatesLastVisibleLine = true
        cap.frame = NSRect(x: 8, y: hasButton ? 56 : 18, width: capW, height: 36)
        root.addSubview(cap)

        if hasButton {
            // Target/action are optional: the still renderer draws the same button as
            // inert scenery, the way every other fake dialog button in the piece is.
            let save = NSButton(title: "save photo…", target: saveTarget, action: saveAction)
            save.bezelStyle = .rounded
            save.controlSize = .regular
            // Font set explicitly and the height taken from `sizeToFit`, matching
            // `makeDialogContentView`. Forcing a height here clips the title away.
            save.font = .systemFont(ofSize: NSFont.systemFontSize)
            // Explicit attributed title with an explicit colour: the card is a plain
            // light view with no window behind it in the still renderer, and the cell's
            // default title colour resolves to nothing there.
            save.attributedTitle = NSAttributedString(
                string: "save photo…",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                             .foregroundColor: NSColor(white: 0.15, alpha: 1)])
            save.sizeToFit()
            let w = max(save.frame.width + 24, 130)
            save.frame = NSRect(x: (size.width - w) / 2, y: 14, width: w, height: save.frame.height)
            save.identifier = savePhotoButtonID
            root.addSubview(save)
        }
        return root
    }

    /// The caption, set on ONE LINE and shrunk until it fits the card. Truncating it to
    /// "I SURVIVED THE GIVE IT 2 ME MALWA…" would be worse than setting it small, and the
    /// caption is the one line on the end card the viewer is meant to read off the photo.
    ///
    /// Fitted to the box less `captionSideMargin`: a text field is a little wider than
    /// the type inside it, and measured flush the last character comes out clipped
    /// against the card's edge. Under the floor it wraps to a second line instead.
    static func fittedCaptionFont(_ caption: String, in width: CGFloat) -> NSFont {
        var pt: CGFloat = 21
        while pt > 12, caption.size(withAttributes: [.font: captionFont(size: pt)]).width
                > width - captionSideMargin {
            pt -= 0.5
        }
        return captionFont(size: pt)
    }

    /// Air kept either side of the caption, on top of the field's own inset.
    static let captionSideMargin: CGFloat = 16

    /// The caption's face: Apple Garamond when installed (it never shipped with the
    /// system), then Hoefler Text, then Georgia. Never a handwriting face.
    static func captionFont(size: CGFloat) -> NSFont {
        for name in ["AppleGaramond", "AppleGaramondLight", "HoeflerText-Regular", "Georgia"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: .regular)
    }

    /// So `savePressed` can find the button again and report back on it.
    static let savePhotoButtonID = NSUserInterfaceItemIdentifier("dpe.credits.savePhoto")

    /// The photo's treatment, by name. `dither` is the booth print — a coarse ordered
    /// dither and nothing else (`DitherLook`); `instant`, `chrome` and `fade` are Core
    /// Image's film looks, each under a soft vignette; `none` is the photo as taken.
    static func filtered(_ image: NSImage, filter: String) -> NSImage {
        switch filter {
        case "none": return image
        case "dither": return DitherLook.apply(to: image) ?? image
        default: break
        }
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return image }
        let name: String
        switch filter {
        case "chrome": name = "CIPhotoEffectChrome"
        case "fade":   name = "CIPhotoEffectFade"
        default:       name = "CIPhotoEffectInstant"
        }
        var out = ci
        if let f = CIFilter(name: name) {
            f.setValue(out, forKey: kCIInputImageKey)
            out = f.outputImage ?? out
        }
        if let v = CIFilter(name: "CIVignette") {
            v.setValue(out, forKey: kCIInputImageKey)
            v.setValue(0.8, forKey: kCIInputIntensityKey)
            v.setValue(1.6, forKey: kCIInputRadiusKey)
            out = v.outputImage ?? out
        }
        guard let cg = ciContext.createCGImage(out, from: ci.extent) else { return image }
        return NSImage(cgImage: cg, size: image.size)
    }

    /// Built once. Standing a Core Image context up costs a few hundred milliseconds
    /// on first use, which is why `prewarm` touches it before the clock runs.
    private static let ciContext = CIContext()

    /// Warm the filter pipeline at load if the show has an end card on a Core Image look.
    /// `dither` and `none` never touch Core Image, so there is nothing to warm for them.
    func prewarm(for events: [ResolvedEvent]) {
        guard events.contains(where: {
            if case .credits(let p) = $0.action { return !["dither", "none"].contains(p.filter ?? "instant") }
            return false
        }) else { return }
        DispatchQueue.global(qos: .utility).async { _ = CreditsController.ciContext }
    }

    /// The machine, in a few lines, the way the probe would put it.
    static func machineSummary() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rows: [(String, String)] = [
            ("computer name", Host.current().localizedName ?? "<unavailable>"),
            ("user", NSFullUserName()),
            ("model", sysctlString("hw.model") ?? "<unavailable>"),
            ("chip", sysctlString("machdep.cpu.brand_string") ?? "<unavailable>"),
            ("memory", String(format: "%.0f GB", memGB)),
            ("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            ("ip", LocationStore.localIPv4() ?? "<unavailable>"),
            ("location", LocationStore.shared.placeName ?? "<no fix>"),
        ]
        if let b = bootDate() { rows.append(("time since boot", duration(Date().timeIntervalSince(b)))) }
        rows.append(("photo taken", PhotoBoothStore.shared.takenAt.map { f.string(from: $0) } ?? "no"))
        rows.append(("survived", "yes"))
        let body = rows.map { pad("  " + $0.0, 20) + $0.1 }.joined(separator: "\n")
        return "$ system_probe --summary\n" + body + "\n$ █"
    }
}
