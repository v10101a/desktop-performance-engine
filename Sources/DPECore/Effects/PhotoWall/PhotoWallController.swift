import AppKit

/// Fills every screen with randomly sized, randomly placed photo windows, then keeps
/// laying new photos over the wall, driven by the show clock. No timers: `update(now:)`
/// runs on the display pump and placement is paced by a *beat credit* accumulator, so
/// the wall fills in tempo.
///
/// **Reversibility.** The wall is a pile of windows and nothing else: no cursor warp,
/// no icon moves, no wallpaper. `closeAll()` takes the desktop back exactly, which is
/// what the panic hotkey calls.
///
/// Like the other executors, every method here is called on the main thread by the
/// display pump — see `EventContext.execute`.
final class PhotoWallController {
    /// One running wall. Only one exists at a time — two walls would fight over the
    /// same coverage grids — so a second `photoWall` event replaces the first.
    private struct Wall {
        let id: String
        let cfg: PhotoWallConfig
        var cadence: Cadence
        var endTime: Double?
        var churning = false
        var placed = 0
    }

    private var wall: Wall?
    private var screens: [ScreenCoverage] = []
    private var windows: [PhotoWindow] = []

    /// The scan is shared across walls and survives teardown — it is a read-only index
    /// of the disk, and re-walking a home folder on every replay would stall the show.
    private let index = PhotoIndex()
    private var scanning = false
    private var scanRoots: [URL] = []

    private let loadQueue = DispatchQueue(label: "dpe.photowall.load", qos: .userInitiated,
                                          attributes: .concurrent)
    private let loadSlots = DispatchSemaphore(value: 6)   // cap in-flight decodes

    /// Bounds the catch-up burst after a long stall (a seek, a stop-the-world decode).
    /// Without it, a two-second gap would try to place 40+ windows in one tick.
    private static let maxPlacementsPerTick = 12

    var bpm: Double = 120

    // MARK: - Prewarm

    /// Walk the disk now, while nothing is playing.
    ///
    /// This is not an optimisation. A cold scan of four home folders takes seconds,
    /// and a `photoWall` event fires on a beat — without a warm index the wall would
    /// come up empty and fill in late, off the music. Mirrors `WindowManager.prewarm`.
    func prewarm(for events: [ResolvedEvent]) {
        let roots: [URL]? = events.lazy.compactMap { ev -> [URL]? in
            if case .photoWall(let p) = ev.action { return PhotoWallConfig(p).roots }
            return nil
        }.first
        guard let roots else { return }
        guard !scanning || roots.map(\.path) != scanRoots.map(\.path) else { return }
        scanning = true
        scanRoots = roots
        // `cfg` here only supplies the selection filters; the first photoWall event's
        // settings stand in for any later one, which is right in practice (one wall).
        let cfg = events.lazy.compactMap { ev -> PhotoWallConfig? in
            if case .photoWall(let p) = ev.action { return PhotoWallConfig(p) }
            return nil
        }.first ?? PhotoWallConfig(PhotoWallParams(id: "prewarm"))
        index.scan(roots: roots, cfg: cfg) { _, _ in }
    }

    // MARK: - Lifecycle

    func begin(_ p: PhotoWallParams, at now: Double, bpm: Double) {
        let cfg = PhotoWallConfig(p)
        // A second wall replaces the first rather than compounding onto it.
        if wall != nil { teardown() }

        // The scan normally happened at load; start it here too so a wall still works
        // when an event was added after prewarm (editor insert, hand-edited JSON).
        if index.count == 0 && !scanning {
            scanning = true
            scanRoots = cfg.roots
            index.scan(roots: cfg.roots, cfg: cfg) { _, _ in }
        }

        rebuildCoverage(cell: cfg.cell)
        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        wall = Wall(id: p.id, cfg: cfg,
                    cadence: Cadence(ratePerBeat: cfg.fillPerBeat,
                                     burstCap: PhotoWallController.maxPlacementsPerTick,
                                     start: now),
                    endTime: duration.map { now + $0 })
    }

    /// Stop placing and take the wall down. Matches `closeWindow` by id, the same way
    /// an open-ended `sprite` or `cursorTrail` is ended.
    func stop(id: String) {
        guard wall?.id == id else { return }
        teardown()
    }

    /// Every window closed, every grid cleared. Idempotent.
    func closeAll() {
        teardown()
    }

    private func teardown() {
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        screens.removeAll()
        wall = nil
    }

    // MARK: - Tick

    func update(now: Double) {
        guard var w = wall else { return }

        // Cadence carries the fractional remainder and absorbs seeks and stalls.
        var budget = w.cadence.step(now: now, bpm: bpm)

        if let end = w.endTime, now >= end {
            // Duration only bounds the *placing*. The wall stays up until a
            // `closeWindow` with this id, so the screen never flashes bare mid-show.
            wall = w
            return
        }

        // Screens can be plugged in or resolution-changed mid-show.
        if screens.count != NSScreen.screens.count { rebuildCoverage(cell: w.cfg.cell) }

        while budget > 0 {
            budget -= 1
            if let cov = pickBare() {
                place(on: cov, &w)
                continue
            }
            // Full. Drop to the churn rate — a hail of windows is right for filling an
            // empty screen and wrong as a permanent state, in feel and in cost.
            guard w.cfg.keepFilling else { wall = w; return }
            if !w.churning {
                // Credit earned at the fill rate must not spend at the churn rate.
                w.churning = true
                w.cadence.ratePerBeat = w.cfg.churnPerBeat
                w.cadence.resetCredit()
                break
            }
            if let cov = pickByArea() { place(on: cov, &w) }
        }
        wall = w
    }

    // MARK: - Placement

    private func rebuildCoverage(cell: Double) {
        screens = NSScreen.screens.map { ScreenCoverage(frame: $0.frame, cellSize: cell) }
        for w in windows { for s in screens { s.add(w.placedRect) } }
    }

    /// Weight the choice by how much of each screen is still bare, so a second display
    /// can't be left half-empty while the first churns.
    private func pickBare() -> ScreenCoverage? {
        let covs = screens.filter { !$0.isFull }
        let totalBare = covs.reduce(0) { $0 + $1.bare }
        guard totalBare > 0 else { return nil }
        var n = Int.random(in: 0..<totalBare)
        for c in covs {
            if n < c.bare { return c }
            n -= c.bare
        }
        return covs.last
    }

    private func pickByArea() -> ScreenCoverage? {
        let totalCells = screens.reduce(0) { $0 + $1.total }
        guard totalCells > 0 else { return nil }
        var n = Int.random(in: 0..<totalCells)
        for c in screens {
            if n < c.total { return c }
            n -= c.total
        }
        return screens.last
    }

    private func place(on cov: ScreenCoverage, _ w: inout Wall) {
        let rect = Planner.next(on: cov, cfg: w.cfg).rect
        for s in screens { s.add(rect) }        // a window may span two displays
        spawn(rect, cfg: w.cfg)
        w.placed += 1
        retireBuried(cfg: w.cfg)
    }

    /// Closes windows that newer photos have completely buried — they cost memory and
    /// contribute nothing visible, and because a window is only retired once every cell
    /// it covers is held by something else, the wall never flashes desktop while it
    /// churns.
    ///
    /// Only down to `liveWindows`, though: retiring every buried window collapses the
    /// wall into the handful of big photos that happen to cover the screen, which is
    /// not a collage.
    private func retireBuried(cfg: PhotoWallConfig) {
        for _ in 0..<3 {
            guard windows.count > cfg.liveWindows,
                  let i = Planner.evictionCandidate(windows.map(\.placedRect), screens: screens)
            else { break }
            let w = windows.remove(at: i)
            for s in screens { s.remove(w.placedRect) }
            w.orderOut(nil)
            w.close()
        }
        while windows.count > cfg.maxWindows {                  // safety net
            let w = windows.removeFirst()
            for s in screens { s.remove(w.placedRect) }
            w.orderOut(nil); w.close()
        }
    }

    private func spawn(_ rect: CGRect, cfg: PhotoWallConfig) {
        guard let url = index.next() else { return }
        let win = PhotoWindow(frame: rect, shadows: cfg.shadows, level: cfg.level)
        win.alphaValue = cfg.fade > 0 ? 0 : 1
        // Never `makeKeyAndOrderFront` — the control window keeps focus (see PhotoWindow).
        win.orderFront(nil)
        windows.append(win)

        let scale = win.screen?.backingScaleFactor ?? 2
        let maxPixel = min(max(rect.width, rect.height) * scale, cfg.imageCap)
        let fade = cfg.fade
        loadQueue.async { [weak self, weak win] in
            self?.loadSlots.wait()
            defer { self?.loadSlots.signal() }
            var image = ImageLoader.thumbnail(url, maxPixel: maxPixel)
            var tries = 0
            while image == nil, tries < 6 {                    // skip past unreadable files
                tries += 1
                guard let alt = self?.nextURLSafely() else { break }
                image = ImageLoader.thumbnail(alt, maxPixel: maxPixel)
            }
            guard let image else { return }
            DispatchQueue.main.async {
                guard let win, win.isVisible || win.alphaValue == 0 else { return }
                win.show(image)
                if fade > 0 {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = fade
                        win.animator().alphaValue = 1
                    }
                } else {
                    win.alphaValue = 1
                }
            }
        }
    }

    private func nextURLSafely() -> URL? { index.next() }

}
