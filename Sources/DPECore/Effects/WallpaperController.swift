import AppKit

/// Swaps the desktop wallpaper during the show and restores the original per-screen
/// image afterward. `NSWorkspace.setDesktopImageURL` needs no special permission.
final class WallpaperController {
    /// Off by default. Only true when the timeline sets `meta.allowWallpaper = true`,
    /// acknowledging the swap may not fully restore (see Meta.allowWallpaper).
    var enabled = false

    /// Resolves relative `path` params against the timeline file's directory.
    var baseDir: URL?

    private var original: [(screen: NSScreen, url: URL)] = []
    private var generatedColors: [String: URL] = [:]

    var hasSnapshot: Bool { !original.isEmpty }

    // MARK: - Snapshot / restore

    func snapshot() {
        original = NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return (screen, url)
        }
        NSLog("[DPE] wallpaper snapshot: \(original.count) screen(s)")
    }

    func restore() {
        guard hasSnapshot else { return }
        for (screen, url) in original {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        NSLog("[DPE] wallpaper restored (\(original.count) screen(s))")
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
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                NSLog("[DPE] wallpaper set error: \(error)")
            }
        }
    }

    // MARK: - deskWallpaper (ported from the BlackWallpaper tools)

    /// One running desk-wallpaper effect. Only one at a time — all three modes drive
    /// the same single piece of global state, so a second event replaces the first.
    private struct Desk {
        let id: String
        let mode: String
        let hz: Double
        let intensity: Double
        let seed: UInt64
        let startTime: Double
        var endTime: Double?
        /// Timeline position of the last applied frame, for rate limiting.
        var lastApply: Double = -1
        var frame = 0
        var busy = false
    }

    private var desk: Desk?

    /// Snapshot happened at play(); `enabled` is the meta.allowWallpaper gate. Both are
    /// already wired — this reuses them rather than opening a second path to the same
    /// global state.
    func beginDesk(_ p: DeskWallpaperParams, at now: Double, bpm: Double) {
        guard enabled else {
            NSLog("[DPE] deskWallpaper skipped — disabled for reversibility "
                + "(set meta.allowWallpaper=true to enable)")
            return
        }
        if !hasSnapshot { snapshot() }
        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        desk = Desk(id: p.id, mode: p.mode ?? "strobe",
                    hz: max(0, p.hz ?? 8),
                    intensity: min(1, max(0, p.intensity ?? 0.6)),
                    seed: UInt64(p.seed ?? 1),
                    startTime: now,
                    endTime: duration.map { now + $0 })
        NSLog("[DPE] deskWallpaper begin: mode=\(p.mode ?? "strobe") hz=\(p.hz ?? 8)")
    }

    func stopDesk(id: String) {
        guard desk?.id == id else { return }
        desk = nil
        restore()
    }

    /// Idempotent teardown for panic/seek. Puts the original wallpaper back and removes
    /// every frame this run wrote.
    func closeDesk() {
        guard desk != nil else { return }
        desk = nil
        restore()
        WallpaperImage.cleanUp()
    }

    /// Called each tick from the engine.
    ///
    /// `setDesktopImageURL` blocks for roughly 58 ms per call per screen, which is why
    /// the standalone strobe measured a ~17 Hz ceiling. That is far too slow to sit on
    /// the pump's thread every frame, so applies are rate-limited to `hz` and the
    /// recursive mode (which needs an async screenshot) never has more than one capture
    /// in flight.
    func updateDesk(now: Double) {
        guard var d = desk else { return }

        if let end = d.endTime, now >= end {
            desk = nil
            restore()
            WallpaperImage.cleanUp()
            return
        }

        let interval = d.hz > 0 ? 1.0 / d.hz : 0
        guard d.lastApply < 0 || now - d.lastApply >= interval else { return }
        d.lastApply = now
        d.frame += 1

        switch d.mode {
        case "strobe":
            // Alternate solid black and solid white on every screen.
            if let url = try? WallpaperImage.solid(gray: d.frame % 2 == 0 ? 0 : 1) {
                apply(url, to: NSScreen.screens)
            }
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
    private func applyGlitch(_ d: inout Desk) {
        guard !d.busy, let source = original.first?.url else { return }
        d.busy = true
        let settings = GlitchSettings(intensity: d.intensity, seed: d.seed &+ UInt64(d.frame))
        let sequence = d.frame
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { DispatchQueue.main.async { self?.desk?.busy = false } }
            guard let image = try? WallpaperImage.load(at: source),
                  let bitmap = try? Bitmap.render(image, maxEdge: 2048),
                  let glitched = try? glitch(bitmap, settings: settings),
                  let out = try? glitched.makeImage(),
                  let url = try? WallpaperImage.uniqueURL(prefix: "glitch", sequence: sequence),
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
        Task.detached(priority: .userInitiated) { [weak self] in
            var written: [(CGDirectDisplayID, URL)] = []
            for id in ids {
                guard let image = try? await WallpaperImage.captureDisplay(id),
                      let url = try? WallpaperImage.uniqueURL(prefix: "recursive-\(id)",
                                                             sequence: sequence),
                      (try? WallpaperImage.write(image, to: url)) != nil
                else { continue }
                written.append((id, url))
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

    private func apply(_ url: URL, to screens: [NSScreen]) {
        for screen in screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen,
                                                       options: WallpaperImage.fillOptions)
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
