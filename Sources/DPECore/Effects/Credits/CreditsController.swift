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
        /// The credits terminal types itself out; these drive it from `update(now:)`.
        let roll: NSTextField?
        let text: [Character]
        /// Wall-clock, not show time — see `startTyping`.
        let start: Double
        let charsPerSecond: Double
        var shown: Int = -1
        var caretOn: Bool = true
        /// True once the last character has landed — the point the card will take a
        /// click to dismiss.
        var finished: Bool { shown >= text.count }
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

    func begin(_ p: CreditsParams, at now: Double, bpm: Double) {
        teardown()
        let screen = ScreenGeometry.screen(p.screen)
        let sf = screen.frame
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

        // 2. the photo, centred, in a white frame. Sized off the screen so it stays
        //    the biggest thing on the card.
        let photoW = min(W * 0.30, 440)
        let photoH = photoW * 0.75
        // Taller foot than the still preview's: the caption and the save button stack in it.
        let margin: CGFloat = 16, foot: CGFloat = (p.allowSave ?? true) ? 100 : 64
        let cardSize = NSSize(width: photoW + margin * 2, height: photoH + margin + foot)
        // Bottom-right, deliberately lapping over the credits terminal's corner: the
        // photo is the thing the viewer keeps, so it sits in front of the copy rather
        // than beside it. Clamped to the screen so a small display can't push it off.
        let cardFrame = NSRect(x: min(sf.maxX - cardSize.width - W * 0.04,
                                      sf.maxX - cardSize.width),
                               y: max(sf.minY + H * 0.08, sf.minY),
                               width: cardSize.width, height: cardSize.height)
        let card = BaseEffectWindow(contentRect: cardFrame)
        // The one interactive thing on the card: the save button. Everything else on it
        // is scenery, and the window still never becomes key.
        card.ignoresMouseEvents = false
        card.hasShadow = true
        card.contentView = CreditsController.makePhotoCard(
            size: cardSize, photo: PhotoBoothStore.shared.image, photoRect: NSRect(x: margin, y: foot, width: photoW, height: photoH),
            caption: p.caption ?? CreditsController.defaultCaption(), filter: p.filter ?? "instant",
            showsSave: p.allowSave ?? true, saveTarget: self, saveAction: #selector(savePressed))
        card.present(animate: "springIn")
        wins.append(card)

        // 3. the machine, in the probe's terminal
        if p.showInfo ?? true {
            let infoW = min(W * 0.34, 520), infoH: CGFloat = 250
            let info = EffectWindow(
                contentRect: NSRect(x: sf.minX + W * 0.06, y: sf.minY + H * 0.10, width: infoW, height: infoH),
                content: ContentSpec(kind: "code", text: CreditsController.machineSummary(),
                                     chrome: "terminal", title: "system_probe — summary"))
            info.present(animate: "fadeIn")
            wins.append(info)
        }

        // 4. the credits — a terminal, centred, half the screen, typing itself out.
        //    Interior blank lines are kept (they are the stanza breaks in the copy);
        //    only leading and trailing blanks are trimmed.
        var lines = p.lines ?? []
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let body = lines.joined(separator: "\n")

        let rollFrame = NSRect(x: sf.minX + W * 0.25, y: sf.minY + H * 0.25,
                               width: W * 0.5, height: H * 0.5)
        let roll = EffectWindow(contentRect: rollFrame,
                                content: ContentSpec(kind: "code", text: "",
                                                     chrome: "terminal",
                                                     title: p.title ?? "credits"))
        // It sits UNDER the photo card, which is ordered front after it.
        roll.present(animate: "fadeIn")
        wins.append(roll)
        // The dialog's "bye" button used to be the one affordance that ended the show.
        // The terminal has no buttons, so the window itself takes the click — but only
        // once the copy has finished typing, so a stray click can't cut the card short.
        // (Stop and the panic hotkey end it regardless, as before.)
        roll.ignoresMouseEvents = false
        roll.onUserClose = { [weak self] in self?.byePressed() }
        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        roll.contentView?.addGestureRecognizer(click)

        // Front-to-back: photo over terminal.
        card.order(.above, relativeTo: roll.windowNumber)

        outroEnabled = p.outro ?? true
        outroDelay = p.outroDelay ?? 2
        outroScreen = screen
        outro.glitchSeconds = p.glitchSeconds ?? 0.5
        outro.bootSeconds = p.bootSeconds ?? 5

        credits = Credits(id: p.id, windows: wins, hold: p.hold ?? true,
                          roll: CreditsController.firstTextField(in: roll.contentView),
                          text: Array(body), start: CACurrentMediaTime(),
                          charsPerSecond: max(0.5, p.charsPerSecond ?? 7))
        startTyping()
    }

    @objc private func byePressed() { onDismiss?() }

    /// Write the photo out, at the viewer's explicit request.
    ///
    /// This is the ONLY thing in the piece that puts the photo on disk, and it happens
    /// only because someone pressed the button. The show still writes nothing on its own
    /// and still discards the image on stop — what changes is that the viewer now has a
    /// way to keep it other than screenshotting the card.
    ///
    /// An `NSSavePanel` would be the obvious choice and is the wrong one here: the end
    /// card's windows sit at `.screenSaver` level, so the panel opens *behind* them with
    /// no way to reach it. This writes straight to `~/Pictures` and reports back on the
    /// button instead.
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
    private static func cornerColor(of image: NSImage) -> NSColor? {
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

    /// A click anywhere on the credits terminal ends the show — but only after the copy
    /// has finished. Before that the click lands on scenery and does nothing.
    @objc private func cardClicked() {
        guard credits?.finished == true else { return }
        onDismiss?()
    }

    /// The `code` content view is built by `applyContent`, which owns the terminal
    /// styling; the label it makes is fished back out here rather than rebuilt, so the
    /// typed text keeps exactly the chrome every other terminal in the piece wears.
    static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let tf = firstTextField(in: sub) { return tf }
        }
        return nil
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

    /// The credits run on their own wall-clock timer rather than the show clock.
    ///
    /// The card is authored at the last beat of the track, so `PerformanceEngine.step`
    /// reaches its end-of-piece branch on the very next tick: with `hold` set it calls
    /// `pause()` and returns, and `pause()` stops the pump. Nothing calls `update(now:)`
    /// again. Typing off show time therefore froze the copy a character or two in and
    /// left it there for the whole hold — the card's entire reason to exist is that the
    /// viewer gets to read it.
    ///
    /// A timer of its own is immune to all of that: the copy finishes whether the
    /// transport is playing, paused, holding at the end, or scrubbed.
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

    /// Characters by elapsed time, caret blinking at 2 Hz, redraw only when one of them
    /// changes. The caret is dropped once the copy is done — the card is finished, and
    /// that is also the point it starts accepting a click.
    private func advanceTyping() {
        guard var c = credits, let label = c.roll else { typeTimer?.invalidate(); return }
        let elapsed = CACurrentMediaTime() - c.start
        let want = min(c.text.count, max(0, Int(elapsed * c.charsPerSecond)))
        let done = want >= c.text.count
        let caret = !done && Int(elapsed * 2) % 2 == 0
        guard want != c.shown || caret != c.caretOn else { return }
        c.shown = want
        c.caretOn = caret
        credits = c
        label.stringValue = String(c.text[0..<want]) + (caret ? "\u{2588}" : "")
        if done {
            typeTimer?.invalidate()
            typeTimer = nil
            beginOutro()
        }
    }

    // MARK: - Pieces

    static func defaultCaption() -> String { "I survived DJ_Dave GiveIt2Me" }

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
        cap.font = NSFont(name: "Noteworthy-Light", size: 15) ?? .systemFont(ofSize: 14, weight: .regular)
        cap.textColor = NSColor(white: 0.25, alpha: 1)
        cap.alignment = .center
        cap.frame = NSRect(x: 8, y: hasButton ? 54 : 18, width: size.width - 16, height: 28)
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

    /// So `savePressed` can find the button again and report back on it.
    static let savePhotoButtonID = NSUserInterfaceItemIdentifier("dpe.credits.savePhoto")

    /// The flattering pass: a warm instant-film look with a soft vignette, or one of
    /// the others by name. `none` is the photo as taken.
    static func filtered(_ image: NSImage, filter: String) -> NSImage {
        guard filter != "none", let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return image }
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

    /// Warm the filter pipeline at load if the show has an end card.
    func prewarm(for events: [ResolvedEvent]) {
        guard events.contains(where: { if case .credits = $0.action { return true }; return false }) else { return }
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
