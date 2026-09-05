import AppKit

/// Swaps the desktop wallpaper during the show and restores the original per-screen
/// image afterward. `NSWorkspace.setDesktopImageURL` needs no special permission.
final class WallpaperController {
    /// Where a desktop change is drawn.
    enum Surface {
        /// A window at the desktop level (`DesktopLayer`). Looks like the wallpaper,
        /// costs a layer assignment, changes nothing about the machine.
        case layer
        /// The machine's real desktop picture, via `NSWorkspace.setDesktopImageURL`.
        /// Gated on `enabled`, and ~3 Hz whatever is asked for.
        case wallpaper

        init(_ name: String?) { self = name == "wallpaper" ? .wallpaper : .layer }
    }

    /// The photosensitivity cap on the desktop layer, in changes per second.
    ///
    /// This is a safety limit, not a performance one — the layer is measured at 119 Hz
    /// sustained on the show's own pump. The ~3 Hz wall in `setDesktopImageURL` used to
    /// enforce this by accident; on the layer nothing does, so it is enforced here.
    /// 12 Hz is the peak full-screen change rate the current cut already measures at, and
    /// it leaves clear air under the 15–20 Hz band that triggers photosensitive seizures
    /// (see CLAUDE.md). Raising it means re-measuring the whole show, not editing a
    /// number.
    static let layerMaxHz: Double = 12

    /// Off by default. Only true when the timeline sets `meta.allowWallpaper = true`,
    /// acknowledging the swap may not fully restore (see Meta.allowWallpaper).
    ///
    /// Gates the REAL wallpaper only — `wallpaper` events, and `deskWallpaper` with
    /// `surface: "wallpaper"`. The desktop layer needs no gate: it makes no persistent
    /// change to reverse.
    var enabled = false

    /// The desktop-level window every `surface: "layer"` change is drawn into. Opened on
    /// the first such change and closed on teardown; costs nothing while it is shut.
    private let layer = DesktopLayer()

    /// Resolves relative `path` params against the timeline file's directory.
    var baseDir: URL?

    private var original: [(screen: NSScreen, url: URL)] = []
    private var generatedColors: [String: URL] = [:]

    /// The WallpaperAgent's own store, copied before the first swap. Per-SPACE
    /// wallpapers live only there: `setDesktopImageURL` reaches the active Space of
    /// each screen, so a viewer with more desktops keeps the show's blue on every
    /// other one unless the whole store comes back too (see `restoreAllSpaces`).
    private var storeSnapshot: URL?
    private static let agentStore = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    var hasSnapshot: Bool { !original.isEmpty }

    /// The desktop picture as it was before the show touched it — what the glass torus
    /// reflects now that it no longer captures the screen.
    ///
    /// Prefers the snapshot, which is taken before the first swap. Without one the
    /// wallpaper has not been changed — either the swap is off, or no `deskWallpaper`
    /// has fired yet — so the live value is still the original.
    func desktopPictureURL(for screen: NSScreen?) -> URL? {
        if let screen, let match = original.first(where: { $0.screen == screen }) {
            return match.url
        }
        if let first = original.first?.url { return first }
        guard let screen = screen ?? NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    // MARK: - Snapshot / restore

    /// Just the per-screen picture URLs — what `glitch` tears and what the glass torus
    /// reflects. No agent-store copy, because nothing that reads this is going to undo a
    /// swap. Cheap enough that the layer path can take it on every run.
    func snapshotOriginals() {
        original = NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return (screen, url)
        }
    }

    func snapshot() {
        snapshotOriginals()
        storeSnapshot = nil
        if FileManager.default.fileExists(atPath: Self.agentStore.path) {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("dpe-wallpaper-store-\(ProcessInfo.processInfo.processIdentifier).plist")
            try? FileManager.default.removeItem(at: copy)
            if (try? FileManager.default.copyItem(at: Self.agentStore, to: copy)) != nil {
                storeSnapshot = copy
            }
        }
        NSLog("[DPE] wallpaper snapshot: \(original.count) screen(s)"
            + (storeSnapshot != nil ? " + the agent store (all Spaces)" : ""))
    }

    /// Put the original wallpaper back, and make sure it is the *last* thing the
    /// window server hears about.
    ///
    /// This runs on `swapQueue` rather than on the calling thread, and that is load
    /// bearing. Every swap the show makes is issued from that queue; a restore issued
    /// from the main thread instead is a second, unordered writer, and the agent does
    /// not serialise the two. Measured: with the restore on main, a swap issued ~300 ms
    /// earlier still landed *after* it and the show left a lyric card on the desktop.
    /// One writer, in order, and the restore wins because it is genuinely last.
    ///
    /// `sync`, because reversibility has to have finished by the time this returns —
    /// the caller may be `applicationWillTerminate`.
    func restore() {
        guard hasSnapshot else { return }
        let shots = original
        swapQueue.sync {
            for (screen, url) in shots {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        }
        NSLog("[DPE] wallpaper restored (\(shots.count) screen(s))")
    }

    /// Put the agent's whole store back and bounce WallpaperAgent, so every OTHER
    /// Space gets its picture back too — `restore()` only reaches the active one.
    /// FINAL teardown only (stop/panic/quit): a bounce mid-show or on seek would
    /// flicker the desktop for nothing. Skipped when the store never changed.
    /// `sync` on `swapQueue` for the same single-writer/must-finish reasons as
    /// `restore()`.
    func restoreAllSpaces() {
        guard let snap = storeSnapshot else { return }
        if let a = try? Data(contentsOf: snap), let b = try? Data(contentsOf: Self.agentStore),
           a == b {
            NSLog("[DPE] wallpaper store unchanged — no agent bounce needed")
            return
        }
        swapQueue.sync {
            try? FileManager.default.removeItem(at: Self.agentStore)
            try? FileManager.default.copyItem(at: snap, to: Self.agentStore)
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["WallpaperAgent"]
            try? kill.run()
        }
        NSLog("[DPE] wallpaper store restored for every Space (WallpaperAgent bounced)")
    }

    // MARK: - Apply

    func set(_ p: WallpaperParams) {
        guard enabled else {
            NSLog("[DPE] wallpaper event skipped — disabled for reversibility (set meta.allowWallpaper=true to enable)")
            return
        }
        guard let url = resolve(p) else {
            NSLog("[DPE] wallpaper: could not resolve image (path=\(p.path ?? "nil") color=\(p.color ?? "nil"))")
            return
        }
        let screens: [NSScreen]
        if let i = p.screen, i >= 0, i < NSScreen.screens.count {
            screens = [NSScreen.screens[i]]
        } else {
            screens = NSScreen.screens
        }
        NSLog("[DPE] wallpaper set → \(url.path) exists=\(FileManager.default.fileExists(atPath: url.path)) on \(screens.count) screen(s)")
        // Same single-writer rule as `apply`/`restore` — see `restore()`.
        swapQueue.async {
            for screen in screens {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                } catch {
                    NSLog("[DPE] wallpaper set error: \(error)")
                }
            }
        }
    }

    // MARK: - deskWallpaper (ported from the BlackWallpaper tools)

    /// One running desk-wallpaper effect. Only one at a time — all three modes drive
    /// the same single piece of global state, so a second event replaces the first.
    private struct Desk {
        let id: String
        let mode: String
        /// Layer or real wallpaper. Fixed for the run — a single effect does not move
        /// between surfaces halfway through.
        let surface: Surface
        let hz: Double
        let intensity: Double
        let seed: UInt64
        /// `solid` only: the colour to paint the desktop.
        let hex: String
        /// `slides` only: resolved file URLs, cycled one per tick.
        let slides: [URL]
        /// `slides` only, optional: when each slide lands, in seconds from `startTime`.
        /// Non-empty means the run is a schedule, not a rate — see `updateDesk`.
        let slideTimes: [Double]
        /// Index of the last scheduled slide applied; −1 before the first.
        var slide = -1
        /// How many frames this run actually put on the desktop. Diagnostics: the claim
        /// that the layer lands every word of a scheduled run is only worth making if
        /// something counts them.
        var shown = 0
        let startTime: Double
        var endTime: Double?
        /// Timeline position of the last applied frame, for rate limiting.
        var lastApply: Double = -1
        var frame = 0
        var busy = false
    }

    private var desk: Desk?

    /// Diagnostics only — `desk` itself stays private. `DesktopLayerTests` reads these to
    /// assert what the gate and the hz cap actually did, rather than inferring it from a
    /// log line.
    var deskIsRunning: Bool { desk != nil }
    var deskHz: Double { desk?.hz ?? 0 }
    var deskFramesShown: Int { desk?.shown ?? 0 }

    /// Snapshot happened at play(); `enabled` is the meta.allowWallpaper gate. Both are
    /// already wired — this reuses them rather than opening a second path to the same
    /// global state.
    func beginDesk(_ p: DeskWallpaperParams, at now: Double, bpm: Double) {
        let surface = Surface(p.surface)
        // The gate is about persistence, so it only applies to the surface that
        // persists. A layer run leaves nothing behind to fail to restore.
        if surface == .wallpaper, !enabled {
            NSLog("[DPE] deskWallpaper skipped — surface=\"wallpaper\" is disabled for "
                + "reversibility (set meta.allowWallpaper=true, or drop the surface param "
                + "to draw on the desktop layer instead)")
            return
        }
        switch surface {
        case .wallpaper:
            if !hasSnapshot { snapshot() }
        case .layer:
            // `glitch` tears the ORIGINAL desktop picture, and the glass torus reflects
            // it, so both still need to know what it is — but the agent-store copy that
            // `snapshot()` also takes exists purely so the real swap can be undone on
            // every Space, and there is nothing to undo here.
            if original.isEmpty { snapshotOriginals() }
            layer.open()
            // Decode slides to the layer's own backing size and no further — carrying a
            // 3024-px card on a 1440-px display is pure memory.
            slides.maxPixel = NSScreen.screens.map {
                Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor)
            }.max() ?? 3024
        }
        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        // The real surface is capped by the window server at ~3 Hz; the layer is capped
        // here, for eyes rather than for throughput.
        let asked = max(0, p.hz ?? 8)
        let hz = surface == .layer ? min(asked, Self.layerMaxHz) : asked
        if hz < asked {
            NSLog("[DPE] deskWallpaper: hz \(asked) clamped to \(hz) — the desktop layer is "
                + "fast enough to reach the photosensitive band, so it is limited here")
        }
        desk = Desk(id: p.id, mode: p.mode ?? "strobe",
                    surface: surface,
                    hz: hz,
                    intensity: min(1, max(0, p.intensity ?? 0.6)),
                    seed: UInt64(p.seed ?? 1),
                    hex: p.hex ?? "#020AF5",
                    slides: (p.images ?? []).map {
                        URL(fileURLWithPath: resolveResourcePath($0))
                    },
                    slideTimes: p.at ?? [],
                    startTime: now,
                    endTime: duration.map { now + $0 })
        NSLog("[DPE] deskWallpaper begin: mode=\(p.mode ?? "strobe") hz=\(p.hz ?? 8)"
            + ((p.images?.isEmpty == false) ? " slides=\(p.images!.count)" : "")
            + ((p.at?.isEmpty == false) ? " timed" : ""))
    }

    func stopDesk(id: String) {
        guard let d = desk, d.id == id else { return }
        desk = nil
        tearDown(d)
    }

    /// Idempotent teardown for panic/seek. Takes the desktop back and removes every
    /// frame this run wrote.
    func closeDesk() {
        guard let d = desk else {
            // A layer left open by a run that has already ended (duration expiry closes
            // the effect but panic can still arrive after). Shutting a shut layer is free.
            layer.close()
            slides.removeAll()
            return
        }
        desk = nil
        tearDown(d)
        WallpaperImage.cleanUp()
    }

    /// Give the desktop back, by whichever route this run took it.
    ///
    /// The layer is the cheap case and the honest one: closing the window *is* the
    /// restore, it cannot half-fail, and it costs no `setDesktopImageURL` call. The real
    /// surface has to be written back from the snapshot, on the swap queue, as ever.
    private func tearDown(_ d: Desk) {
        switch d.surface {
        case .layer:
            layer.close()
            slides.removeAll()
        case .wallpaper:
            restore()
        }
    }

    /// Called each tick from the engine.
    ///
    /// Everything below about cost and back-pressure describes `surface: "wallpaper"`.
    /// On the default `surface: "layer"` none of it applies — a change is a
    /// `CALayer.contents` assignment (measured median 0.054 ms for a strobe frame,
    /// 11.7 ms for a full-screen one, 119 Hz sustained on this same pump), there is no
    /// in-flight swap to wait on, and `hz` is honoured up to `layerMaxHz`. The two paths
    /// share this method because they share the *timing*; only the last step differs.
    ///
    /// `setDesktopImageURL` is far slower than it looks. Measured on this machine
    /// (macOS 26, one built-in display) it blocks for **~270–330 ms per call**, and the
    /// cost barely moves with image size — a 64×64 solid PNG costs 268 ms and a
    /// 3024×1964 JPEG costs 327 ms, so it is the WallpaperAgent round-trip that is
    /// expensive, not the decode. That is a hard **~3 Hz ceiling** on how fast the
    /// desktop can change, whatever the timeline asks for.
    ///
    /// Two consequences, and this method handles both:
    ///
    /// 1. The call must never run on the pump's thread. Left synchronous it collapsed
    ///    the 72 Hz tick to **4 Hz** (median gap 339 ms), which stalls every other
    ///    effect in the show for as long as the wallpaper is moving. `apply` therefore
    ///    hands the swap to a serial background queue.
    /// 2. Asking for more than ~3 Hz has to *drop ticks*, not queue them, or the
    ///    backlog outlives the event and the desktop keeps changing after the section
    ///    has ended. A tick that arrives while a swap is still in flight returns
    ///    without advancing `frame` or `lastApply`, so no slide is skipped — the list
    ///    simply advances at whatever rate the window server can sustain.
    func updateDesk(now: Double) {
        guard var d = desk else { return }

        if let end = d.endTime, now >= end {
            desk = nil
            tearDown(d)
            WallpaperImage.cleanUp()
            return
        }

        // A SCHEDULED slide run is not rate-limited: each image lands on its own time
        // (the lyric on the desktop lands on the sung word, off the same cues as the
        // lyric cards) and nothing is written between two times. The list plays once
        // and the last image holds; `hz` does not apply. The same back-pressure as
        // below: while a swap is in flight the tick is dropped, and the next tick
        // applies whatever is due THEN — a word the window server could not fit is
        // skipped, not queued behind the one being sung.
        if d.mode == "slides", !d.slideTimes.isEmpty {
            guard !applying else { return }
            let elapsed = now - d.startTime
            let due = d.slideTimes.lastIndex { $0 <= elapsed } ?? -1
            // Keep the next few words decoded. The schedule is known in advance, so the
            // layer never has to decode a card in the tick that shows it.
            if d.surface == .layer, due != d.slide {
                slides.prewarm(Array(d.slides[max(0, due)...]))
            }
            if due != d.slide, due >= 0, due < d.slides.count {
                // `present` reports whether the frame actually landed. A slide still
                // decoding leaves `d.slide` alone so the next tick tries again — and if
                // the word after it has come due by then, that one goes up instead. A
                // word the machine could not fit is skipped, never queued behind the one
                // being sung.
                if present(d.slides[due], surface: d.surface) {
                    d.slide = due
                    d.shown += 1
                }
            }
            desk = d
            return
        }

        let interval = d.hz > 0 ? 1.0 / d.hz : 0
        guard d.lastApply < 0 || now - d.lastApply >= interval else { return }
        // The previous swap has not come back yet. Drop this tick whole — leaving
        // `lastApply`/`frame` alone means the next tick retries the same slide rather
        // than losing a word.
        guard !applying else { return }
        d.lastApply = now
        d.frame += 1

        switch d.mode {
        case "solid":
            // One shot: paint it once and stop. Re-applying a static colour every tick
            // would rewrite the desktop at `hz` for no visible change, and on the real
            // surface the window server charges for every one of those.
            if d.frame == 1 { present(hex: d.hex, surface: d.surface) }
        case "slides":
            // A word per tick, wrapping — the list is shorter than the run, so it plays
            // through more than once.
            guard !d.slides.isEmpty else {
                NSLog("[DPE] deskWallpaper: slides with no images")
                desk = nil
                return
            }
            let index = (d.frame - 1) % d.slides.count
            if d.surface == .layer {
                // Wrapping, so the lookahead wraps too.
                slides.prewarm((0...SlideStore.lookahead).map {
                    d.slides[(index + $0) % d.slides.count]
                })
            }
            if present(d.slides[index], surface: d.surface) {
                d.shown += 1
            } else if d.frame == 1 {
                // First tick only: a missing file is worth one line, not one per tick.
                NSLog("[DPE] deskWallpaper: slide not ready or missing at \(d.slides[index].path)")
            }
        case "strobe":
            // Alternate black and white on every screen. On the layer that is two floats;
            // on the real surface it is two cached 64×64 PNGs and a swap.
            present(gray: d.frame % 2 == 0 ? 0 : 1, surface: d.surface)
        case "glitch":
            applyGlitch(&d)
        case "recursive":
            applyRecursive(&d)
        default:
            NSLog("[DPE] deskWallpaper: unknown mode \(d.mode)")
            desk = nil
            return
        }
        desk = d
    }

    /// Displacement + channel split + block corruption over whatever the wallpaper was
    /// when the show started — read from the snapshot, not from the current wallpaper,
    /// or each pass would compound the last and dissolve to noise in a second.
    /// The snapshot, decoded and scaled once: every glitch frame reads the same source,
    /// and decoding a multi-megapixel wallpaper per frame was most of the frame's cost.
    /// 1280 px on the long edge — the tear is coarse by design, and this is a quarter
    /// of the pixels of 2048 through displace + corrupt + encode + the WallpaperAgent.
    private var glitchSource: (url: URL, bitmap: Bitmap)?
    private static let glitchMaxEdge = 1280

    private func applyGlitch(_ d: inout Desk) {
        guard !d.busy, let source = original.first?.url else { return }
        d.busy = true
        let settings = GlitchSettings(intensity: d.intensity, seed: d.seed &+ UInt64(d.frame))
        let sequence = d.frame
        let cached = glitchSource?.url == source ? glitchSource?.bitmap : nil
        let surface = d.surface
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { DispatchQueue.main.async { self?.desk?.busy = false } }
            let bitmap: Bitmap
            if let cached {
                bitmap = cached
            } else {
                guard let image = try? WallpaperImage.load(at: source),
                      let fresh = try? Bitmap.render(image, maxEdge: Self.glitchMaxEdge)
                else { return }
                bitmap = fresh
                DispatchQueue.main.async { self?.glitchSource = (source, fresh) }
            }
            guard let glitched = try? glitch(bitmap, settings: settings),
                  let out = try? glitched.makeImage()
            else { return }
            // The layer takes the frame as it stands. Only the real surface needs it on
            // disk, because macOS stores a path rather than the picture — so the JPEG
            // encode and the write are skipped entirely on the layer, along with the
            // sweep that would have had to remove the file afterwards.
            if surface == .layer {
                DispatchQueue.main.async { self?.layer.show(out) }
                return
            }
            guard let url = try? WallpaperImage.uniqueURL(prefix: "glitch", sequence: sequence),
                  (try? WallpaperImage.write(out, to: url)) != nil
            else { return }
            DispatchQueue.main.async { self?.apply(url, to: NSScreen.screens) }
        }
    }

    /// The desktop showing a screenshot of the desktop. Each pass captures what is on
    /// screen *now*, so the recursion deepens by one frame every time.
    private func applyRecursive(_ d: inout Desk) {
        guard !d.busy else { return }
        d.busy = true
        let sequence = d.frame
        // Only the display IDs cross into the task — NSScreen isn't Sendable, and the
        // screen is re-resolved on the main thread when the capture lands.
        let ids = NSScreen.screens.compactMap(WallpaperImage.displayID(of:))
        let surface = d.surface
        Task.detached(priority: .userInitiated) { [weak self] in
            var captured: [(CGDirectDisplayID, CGImage)] = []
            var written: [(CGDirectDisplayID, URL)] = []
            for id in ids {
                guard let image = try? await WallpaperImage.captureDisplay(id) else { continue }
                // The layer shows the capture directly — and note it is genuinely
                // recursive either way, since a desktop-level window is on screen and so
                // is in the shot.
                if surface == .layer { captured.append((id, image)); continue }
                guard let url = try? WallpaperImage.uniqueURL(prefix: "recursive-\(id)",
                                                             sequence: sequence),
                      (try? WallpaperImage.write(image, to: url)) != nil
                else { continue }
                written.append((id, url))
            }
            if surface == .layer {
                let shots = captured
                DispatchQueue.main.async {
                    guard let me = self else { return }
                    for (id, image) in shots {
                        guard let screen = NSScreen.screens.first(where: {
                            WallpaperImage.displayID(of: $0) == id
                        }) else { continue }
                        me.layer.show(image, on: screen)
                    }
                    me.desk?.busy = false
                }
                return
            }
            let done = written
            // Hop back the way the rest of DPE does. `MainActor.run` capturing the weak
            // `self` var trips a Swift 6 concurrency diagnostic; this doesn't, and it
            // matches every other executor here.
            DispatchQueue.main.async {
                guard let me = self else { return }
                for (id, url) in done {
                    guard let screen = NSScreen.screens.first(where: {
                        WallpaperImage.displayID(of: $0) == id
                    }) else { continue }
                    me.apply(url, to: [screen])
                }
                me.desk?.busy = false
            }
        }
    }

    // MARK: - Presenting a frame on whichever surface the run chose

    /// The slides the layer path has decoded, kept a few ahead of the one on screen.
    private let slides = SlideStore()

    /// A flat colour. `solid` and `strobe` want nothing else, and on the layer that means
    /// no bitmap, no file and no window server: two floats into a `CALayer`.
    private func present(hex: String, surface: Surface) {
        switch surface {
        case .layer:
            guard let color = NSColor(hex: hex)?.cgColor else {
                NSLog("[DPE] deskWallpaper: not a colour: \(hex)")
                return
            }
            layer.show(color: color)
        case .wallpaper:
            guard let url = try? WallpaperImage.solid(hex: hex) else { return }
            apply(url, to: NSScreen.screens)
        }
    }

    private func present(gray: CGFloat, surface: Surface) {
        switch surface {
        case .layer:
            layer.show(color: CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        case .wallpaper:
            guard let url = try? WallpaperImage.solid(gray: gray) else { return }
            apply(url, to: NSScreen.screens)
        }
    }

    /// A slide from disk. Returns whether the frame actually went up.
    ///
    /// `false` on the layer means the decode has not finished yet — the caller drops the
    /// tick and retries, which is the same back-pressure the real surface gets from
    /// `applying`, for the same reason: a frame that cannot be shown now must not be
    /// queued to show later, or the desktop keeps changing after the section has ended.
    @discardableResult
    private func present(_ url: URL, surface: Surface) -> Bool {
        switch surface {
        case .layer:
            guard let image = slides.image(at: url) else { return false }
            layer.show(image)
            return true
        case .wallpaper:
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            apply(url, to: NSScreen.screens)
            return true
        }
    }

    /// Every swap the running effect makes goes through here, off the main thread.
    ///
    /// Serial, so swaps still land in timeline order, and `applying` is the
    /// back-pressure signal `updateDesk` reads to decide whether to issue another one.
    /// Both flag writes happen on the main thread, so the tick never races them.
    private let swapQueue = DispatchQueue(label: "com.dpe.wallpaper.swap", qos: .userInitiated)
    private var applying = false

    private func apply(_ url: URL, to screens: [NSScreen]) {
        applying = true
        swapQueue.async { [weak self] in
            for screen in screens {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen,
                                                           options: WallpaperImage.fillOptions)
            }
            DispatchQueue.main.async { self?.applying = false }
        }
    }

    // MARK: - Image resolution

    private func resolve(_ p: WallpaperParams) -> URL? {
        if let path = p.path {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            if let base = baseDir { return base.appendingPathComponent(path) }
            return URL(fileURLWithPath: path)
        }
        if let color = p.color { return solidColorImage(hex: color) }
        return nil
    }

    /// Render (and cache) a solid-color image so `color` wallpapers work without an asset.
    private func solidColorImage(hex: String) -> URL? {
        if let cached = generatedColors[hex] { return cached }
        guard let color = NSColor(hex: hex) else { return nil }
        let size = NSSize(width: 1920, height: 1080)
        let image = NSImage(size: size)
        image.lockFocus()
        color.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpe_wall_\(hex.replacingOccurrences(of: "#", with: "")).png")
        do {
            try png.write(to: url)
            generatedColors[hex] = url
            return url
        } catch {
            NSLog("[DPE] wallpaper: failed to write color image: \(error)")
            return nil
        }
    }
}
