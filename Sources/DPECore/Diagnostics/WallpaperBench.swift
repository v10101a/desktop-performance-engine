import AppKit
import QuartzCore

/// `--bench-wallpaper`: what the desktop actually costs to change, both ways.
///
/// The claim under test is the one in `WallpaperController.updateDesk` — that
/// `setDesktopImageURL` is a ~3 Hz wall and that a window at the desktop level is not.
/// This measures both on the machine in front of you rather than trusting either number.
///
/// The desktop-layer rounds are harmless: they open a window and close it. The real-API
/// round genuinely changes your wallpaper, so it is **opt-in** (`--include-real`) and
/// brackets itself with the same snapshot/restore the show uses.
enum WallpaperBench {

    static func run(includeReal: Bool, depth: DesktopLayer.Depth,
                    then done: @escaping () -> Void) {
        let layer = DesktopLayer()
        layer.open(depth: depth)

        // Give AppKit a beat to actually place the window before asking where it landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            probeOrdering(layer)
            benchLayerCalls(layer)
            benchSustained(layer) {
                layer.close()
                guard includeReal else {
                    NSLog("[DPE] bench wallpaper: real-API round skipped "
                        + "(pass --include-real to measure it — it changes your wallpaper)")
                    done()
                    return
                }
                benchRealAPI()
                done()
            }
        }
    }

    // MARK: - Where did the window land?

    /// The only question that matters for whether this is usable: is the layer above the
    /// wallpaper and below the desktop icons?
    ///
    /// Answered from the window server's own on-screen list rather than by eye, and
    /// without Screen Recording — `kCGWindowLayer` and the owner name come back to any
    /// process. The list is front-to-back, so the entries printed *after* ours are the
    /// ones it covers and the entries before it are the ones covering it. Finder's
    /// desktop-icon window must be among the latter.
    private static func probeOrdering(_ layer: DesktopLayer) {
        guard let screen = NSScreen.main, let window = layer.window(for: screen) else {
            NSLog("[DPE] bench wallpaper: no layer window to probe")
            return
        }
        let mine = window.windowNumber
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let all = CGWindowListCopyWindowInfo(.optionOnScreenOnly,
                                                   kCGNullWindowID) as? [[String: Any]]
        else {
            NSLog("[DPE] bench wallpaper: the window list is unavailable")
            return
        }
        _ = list
        NSLog("[DPE] bench wallpaper: layer window #\(mine) at level \(window.level.rawValue) — "
            + "desktop=\(CGWindowLevelForKey(.desktopWindow)) "
            + "icons=\(CGWindowLevelForKey(.desktopIconWindow)) normal=\(CGWindowLevelForKey(.normalWindow))")

        // Everything at or below the icon level, which is the neighbourhood we care
        // about. Front-to-back, so lower in this list = further back.
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        var printed = 0
        for entry in all {
            guard let level = entry[kCGWindowLayer as String] as? Int, level <= iconLevel else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let number = entry[kCGWindowNumber as String] as? Int ?? -1
            let name = entry[kCGWindowName as String] as? String ?? ""
            let marker = number == mine ? "  <<< THE LAYER" : ""
            NSLog("[DPE]   z layer=%6d  %-18s #%-6d %@%@",
                  level, (owner as NSString).utf8String!, number, name, marker)
            printed += 1
            if printed > 24 { break }
        }

        // The verdict, stated rather than left to be read off the dump.
        let ordered = all.compactMap { entry -> (Int, Int, String)? in
            guard let level = entry[kCGWindowLayer as String] as? Int,
                  let number = entry[kCGWindowNumber as String] as? Int else { return nil }
            return (level, number, entry[kCGWindowOwnerName as String] as? String ?? "?")
        }
        guard let mineIndex = ordered.firstIndex(where: { $0.1 == mine }) else {
            NSLog("[DPE] bench wallpaper: VERDICT — the layer is not in the on-screen list at all")
            return
        }
        // Finder's icon window is the one owned by Finder at the icon level.
        let iconIndex = ordered.firstIndex { $0.0 == iconLevel && $0.2 == "Finder" }
        switch iconIndex {
        case .some(let i) where i < mineIndex:
            NSLog("[DPE] bench wallpaper: VERDICT — layer is BELOW the desktop icons (icons stay on top). Correct.")
        case .some:
            NSLog("[DPE] bench wallpaper: VERDICT — layer is ABOVE the desktop icons (it buries them).")
        case .none:
            NSLog("[DPE] bench wallpaper: VERDICT — no Finder icon window on screen "
                + "(icons hidden, or this Mac shows none), so ordering vs. icons is untested here.")
        }
    }

    // MARK: - Round 1: what one desktop-layer update costs

    /// Per-call cost of putting a new image on the layer, measured on the main thread —
    /// the thread that matters, since this is what the pump would be paying.
    private static func benchLayerCalls(_ layer: DesktopLayer) {
        let frames = (0..<60).compactMap { solidImage(gray: CGFloat($0 % 2)) }
        guard frames.count == 60 else {
            NSLog("[DPE] bench wallpaper: could not build the test frames")
            return
        }
        var samples: [Double] = []
        samples.reserveCapacity(frames.count)
        for frame in frames {
            let t0 = CACurrentMediaTime()
            layer.show(frame)
            samples.append((CACurrentMediaTime() - t0) * 1000)
        }
        report("desktop layer  set contents (64×64)", samples)

        // A full-screen Retina frame, which is what `glitch` and `recursive` hand over.
        // The point of the comparison is that the layer does not care about size either —
        // but for the opposite reason to the real API: nothing is encoded or copied.
        let big = NSScreen.main.map {
            CGSize(width: $0.frame.width * $0.backingScaleFactor,
                   height: $0.frame.height * $0.backingScaleFactor)
        } ?? CGSize(width: 3024, height: 1964)
        let bigFrames = (0..<20).compactMap { solidImage(gray: CGFloat($0 % 2), size: big) }
        guard !bigFrames.isEmpty else { return }
        var bigSamples: [Double] = []
        for frame in bigFrames {
            let t0 = CACurrentMediaTime()
            layer.show(frame)
            bigSamples.append((CACurrentMediaTime() - t0) * 1000)
        }
        report(String(format: "desktop layer  set contents (%.0f×%.0f)", big.width, big.height),
               bigSamples)

        // `strobe` and `solid` never need a bitmap at all.
        var colorSamples: [Double] = []
        for i in 0..<60 {
            let g = CGFloat(i % 2)
            let t0 = CACurrentMediaTime()
            layer.show(color: CGColor(red: g, green: g, blue: g, alpha: 1))
            colorSamples.append((CACurrentMediaTime() - t0) * 1000)
        }
        report("desktop layer  set background colour", colorSamples)
    }

    // MARK: - Round 2: sustained rate on the show's own pump

    /// The number the effect actually cares about: driven from `DisplayPump` — the same
    /// vsync-coalesced pump the show runs on — how many desktop changes a second land,
    /// and does the main thread survive doing it?
    ///
    /// The probe timer is the health check borrowed from `--bench-views`: it wants 60 Hz,
    /// and a number well under that means whatever is being measured is eating main.
    ///
    /// The two frames are near-identical mid-greys, NOT black and white. This drives the
    /// whole screen at display rate for three seconds, and a full-screen black/white
    /// swing at 60–120 Hz is squarely in the band this project refuses to put on anyone's
    /// display (CLAUDE.md: keep full-screen change rates out of 15–20 Hz, and this is far
    /// past it). Two greys a few percent apart cost the compositor exactly the same — the
    /// contents pointer changes either way — and flash nothing.
    private static func benchSustained(_ layer: DesktopLayer, then next: @escaping () -> Void) {
        guard let black = solidImage(gray: 0.46), let white = solidImage(gray: 0.50) else {
            next(); return
        }
        let pump = DisplayPump()
        var updates = 0
        var ticks = 0
        let probe = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in ticks += 1 }
        RunLoop.main.add(probe, forMode: .common)
        let t0 = CACurrentMediaTime()
        pump.start {
            layer.show(updates % 2 == 0 ? black : white)
            updates += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            pump.stop()
            probe.invalidate()
            let secs = CACurrentMediaTime() - t0
            NSLog("%@", String(format:
                "[DPE] bench wallpaper: sustained %.1f Hz over %.1f s on the display pump "
                + "(main-thread probe %.1f of 60 Hz)",
                Double(updates) / secs, secs, Double(ticks) / secs))
            next()
        }
    }

    // MARK: - Round 3: the real API, opt-in

    /// `setDesktopImageURL`, timed. Twelve calls, because at the documented cost that is
    /// already four seconds of wallpaper thrash on someone's actual desktop.
    ///
    /// Each call needs a distinct URL — AppKit ignores a set to the path already in
    /// place, which is why the show writes `uniqueURL` frames — so this writes twelve
    /// tiny files and sweeps them.
    private static func benchRealAPI() {
        let controller = WallpaperController()
        controller.snapshot()
        guard controller.hasSnapshot else {
            NSLog("[DPE] bench wallpaper: no wallpaper snapshot — refusing to swap without one")
            return
        }
        defer {
            controller.restore()
            WallpaperImage.cleanUp()
        }
        guard let screen = NSScreen.main else { return }

        var urls: [URL] = []
        for i in 0..<12 {
            guard let image = solidImage(gray: CGFloat(i % 2)),
                  let url = try? WallpaperImage.uniqueURL(prefix: "bench", sequence: i),
                  (try? WallpaperImage.write(image, to: url)) != nil else { continue }
            urls.append(url)
        }
        guard urls.count == 12 else {
            NSLog("[DPE] bench wallpaper: could not write the bench frames")
            return
        }

        var samples: [Double] = []
        for url in urls {
            let t0 = CACurrentMediaTime()
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen,
                                                       options: WallpaperImage.fillOptions)
            samples.append((CACurrentMediaTime() - t0) * 1000)
        }
        report("setDesktopImageURL (64×64, one screen)", samples)
    }

    // MARK: - Helpers

    private static func solidImage(gray: CGFloat,
                                   size: CGSize = CGSize(width: 64, height: 64)) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// Median rather than mean, and the tail alongside it: one 300 ms outlier in a
    /// sub-millisecond sample would otherwise carry the average on its own.
    private static func report(_ label: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
        let median = pct(0.5)
        NSLog("%@", String(format:
            "[DPE] bench wallpaper: %-42s n=%2d  median %8.3f ms  (min %8.3f  p95 %8.3f  max %8.3f)  → %.0f Hz ceiling",
            (label as NSString).utf8String!, samples.count,
            median, sorted.first!, pct(0.95), sorted.last!,
            median > 0 ? 1000 / median : .infinity))
    }
}
