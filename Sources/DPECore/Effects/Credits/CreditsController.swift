import AppKit
import CoreImage

/// The end card. A black ground, and on it: the photo the booth took, in a white
/// frame with a flattering filter; the machine reading its own vitals out in the probe's
/// terminal style; an "i survived" alert; and the credits.
///
/// It HOLDS. When the track runs out the engine asks `isHolding` and, if so, pauses
/// instead of restoring — so the card stays up as long as the viewer wants to look at
/// it (or screenshot it). The credits alert's button, the Stop button and the panic
/// hotkey all end it.
///
/// **Reversibility.** Windows only. The photo it shows lives in `PhotoBoothStore`, in
/// memory, and is discarded when the show stops.
final class CreditsController {
    private struct Credits {
        let id: String
        let windows: [NSWindow]
        let hold: Bool
    }

    private var credits: Credits?
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
        back.contentView = ground
        back.present(animate: "fadeIn")
        wins.append(back)

        // 2. the photo, centred, in a white frame. Sized off the screen so it stays
        //    the biggest thing on the card.
        let photoW = min(W * 0.30, 440)
        let photoH = photoW * 0.75
        let margin: CGFloat = 16, foot: CGFloat = 64
        let cardSize = NSSize(width: photoW + margin * 2, height: photoH + margin + foot)
        let cardFrame = NSRect(x: sf.minX + (W - cardSize.width) / 2,
                               y: sf.minY + (H - cardSize.height) / 2 + H * 0.02,
                               width: cardSize.width, height: cardSize.height)
        let card = BaseEffectWindow(contentRect: cardFrame)
        card.ignoresMouseEvents = true
        card.hasShadow = true
        card.contentView = CreditsController.makePhotoCard(
            size: cardSize, photo: PhotoBoothStore.shared.image, photoRect: NSRect(x: margin, y: foot, width: photoW, height: photoH),
            caption: p.caption ?? CreditsController.defaultCaption(), filter: p.filter ?? "instant")
        card.present(animate: "springIn")
        wins.append(card)

        // 3. "i survived" — an alert in the same voice as every other alert in the piece.
        let surv = FakeDialogWindow(
            contentRect: NSRect(x: sf.minX + W * 0.06, y: sf.maxY - H * 0.12 - 180, width: 440, height: 180),
            title: p.survivor ?? "i survived DJ_DAVE malware",
            message: p.survivorBody ?? "and all i got was this alert.",
            buttons: ["ok"], icon: .caution)
        surv.present(animate: "springIn")
        wins.append(surv)

        // 4. the machine, in the probe's terminal
        if p.showInfo ?? true {
            let infoW = min(W * 0.34, 520), infoH: CGFloat = 250
            let info = EffectWindow(
                contentRect: NSRect(x: sf.minX + W * 0.06, y: sf.minY + H * 0.10, width: infoW, height: infoH),
                content: ContentSpec(kind: "code", text: CreditsController.machineSummary(),
                                     chrome: "terminal", title: "system_probe — summary"))
            info.present(animate: "fadeIn")
            wins.append(info)
        }

        // 5. the credits, with the one button that ends the show
        let lines = (p.lines ?? []).filter { !$0.isEmpty }
        let creditsFrame = NSRect(x: sf.maxX - W * 0.06 - 460, y: sf.minY + H * 0.14, width: 460,
                                  height: max(200, CGFloat(56 + 18 * max(lines.count, 3)) + 60))
        let roll = FakeDialogWindow(contentRect: creditsFrame,
                                    title: p.title ?? "credits",
                                    message: lines.isEmpty ? "(pending)" : lines.joined(separator: "\n"),
                                    buttons: ["bye"], icon: .app)
        // The fake dialog's buttons are inert scenery; this one has to work.
        for b in roll.contentView?.subviews.compactMap({ $0 as? NSButton }) ?? [] {
            b.target = self
            b.action = #selector(byePressed)
        }
        roll.present(animate: "springIn")
        wins.append(roll)

        credits = Credits(id: p.id, windows: wins, hold: p.hold ?? true)
    }

    @objc private func byePressed() { onDismiss?() }

    func stop(id: String) {
        guard credits?.id == id else { return }
        teardown()
    }

    func closeAll() { teardown() }

    private func teardown() {
        guard let c = credits else { return }
        for w in c.windows { w.orderOut(nil) }
        credits = nil
    }

    func update(now: Double) {}

    // MARK: - Pieces

    static func defaultCaption() -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy · HH:mm"
        let when = PhotoBoothStore.shared.takenAt.map { f.string(from: $0) } ?? f.string(from: Date())
        return "the computer took this · \(when)"
    }

    /// A white card with the photo and a caption under it — the frame a photo gets
    /// when somebody wants to keep it.
    static func makePhotoCard(size: NSSize, photo: NSImage?, photoRect: NSRect,
                              caption: String, filter: String) -> NSView {
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

        let cap = NSTextField(labelWithString: caption)
        cap.font = NSFont(name: "Noteworthy-Light", size: 15) ?? .systemFont(ofSize: 14, weight: .regular)
        cap.textColor = NSColor(white: 0.25, alpha: 1)
        cap.alignment = .center
        cap.frame = NSRect(x: 8, y: 18, width: size.width - 16, height: 28)
        root.addSubview(cap)
        return root
    }

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
