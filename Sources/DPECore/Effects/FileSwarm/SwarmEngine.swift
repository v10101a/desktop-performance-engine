import AppKit

struct SwarmSettings {
    var patternID = "spiral"
    var ticksPerSecond = 1.0
    var maxLive = 80
    var createsPerTick = 80
    var positionIcons = true
    var reregisterSlots = false
    /// Seconds an icon is guaranteed to stay before the pattern may remove it.
    ///
    /// Finder draws a *removed* icon within ~85 ms but takes 0.7–3 s to draw a
    /// *newly created* one, and there is no way to hurry it (touching the folder,
    /// `update desktop`, hidden flags, renames and activating Finder were all
    /// measured and none of them help). Without a floor on how long a slot lives,
    /// a fast pattern creates and deletes files that Finder never gets around to
    /// drawing, and the desktop just stays empty.
    var minLifetime = 2.5
    /// Draw by *removing* icons instead of adding them: the grid is filled and the
    /// pattern is cut out of it. Since Finder renders a deletion in ~85 ms and an
    /// addition in ~1 s, the moving edge of the shape is crisp and it is the
    /// healing-behind that lags — the opposite, and better-looking, trade.
    var erase = false
    var seed: UInt64 = 1

    static let maxTicksPerSecond = 30.0
}

struct SwarmStats {
    var step = 0
    var live = 0
    var created = 0
    var deleted = 0
    var refused = 0
    var lastOps = 0
    var patternName = ""
    var note: String?
}

/// **Changed in the port.** The standalone app ran the loop on a `Timer` at
/// `ticksPerSecond`. Here `beginTicking()` only arms the engine and
/// `FileSwarmController` calls `tickOnce()` from the show clock at a per-beat rate, so
/// the pattern advances in tempo and freezes when the transport stops. Everything else
/// — the diff, the store, the registrar, the patterns — is unchanged.
///
/// Note the rate that matters is not this one: Finder shows a *deletion* in ~85 ms but
/// takes 0.7-3 s to show a *creation*, erratically. See the standalone app's README;
/// that ceiling is the window server's and cannot be hurried.
///
/// The loop: each tick asks the pattern which slots should be occupied, diffs that
/// against the files currently on the desktop, and turns the difference into
/// creations and deletions. Nothing here knows what a pattern *is*.
final class SwarmEngine {
    private(set) var isRunning = false
    private(set) var stats = SwarmStats()
    private(set) var grid = Grid.forMainScreen()

    var settings = SwarmSettings()
    var onUpdate: ((SwarmStats) -> Void)?
    var onLog: ((String) -> Void)?

    private let store: SwarmFileStore
    private let registrar = SlotRegistrar()
    private let prepQueue = DispatchQueue(label: "com.computerart.fileswarm.prepare")
    private var pattern: SwarmPattern = SpiralPattern()
    private var live: [Cell: URL] = [:]
    private var born: [Cell: CFAbsoluteTime] = [:]
    private var step = 0
    private var generation = 0

    init(store: SwarmFileStore) {
        self.store = store
    }

    var desktopPath: String { store.desktop.path }

    // MARK: - Transport

    func start() {
        guard !isRunning else { return }
        grid = Grid.forMainScreen()
        pattern = PatternLibrary.make(id: settings.patternID) ?? SpiralPattern()
        pattern.reset(grid: grid, seed: settings.seed)
        step = 0
        stats = SwarmStats(patternName: pattern.displayName)
        if settings.erase {
            // The canvas is the whole grid, so the ceiling has to clear it.
            settings.maxLive = max(settings.maxLive, grid.count)
            settings.createsPerTick = settings.maxLive
            // Here removals *are* the animation, so holding a slot before releasing
            // it would blunt the exact edge this mode exists to sharpen.
            settings.minLifetime = min(settings.minLifetime, 0.4)
        }
        isRunning = true
        generation += 1
        log("▶︎ \(pattern.displayName) — \(grid.cols)×\(grid.rows) grid on \(store.desktop.path)")

        guard settings.positionIcons else { beginTicking(); return }

        // Registration talks to Finder and can take a second, so it runs off the main
        // thread; the pattern starts the moment it finishes.
        let generation = self.generation
        let grid = self.grid
        let force = settings.reregisterSlots
        log("Preparing \(grid.count) desktop slots…")
        prepQueue.async { [weak self] in
            guard let self else { return }
            let result = self.registrar.prepare(grid: grid, store: self.store, force: force)
            DispatchQueue.main.async {
                guard self.isRunning, self.generation == generation else { return }
                self.settings.reregisterSlots = false
                if !result.authorized {
                    self.log("Finder automation not granted — icons will land wherever Finder likes. \(result.error ?? "")")
                } else if result.skipped {
                    self.log(String(format: "Slots already registered (verified in %.1fs)", result.seconds))
                } else {
                    self.log(String(format: "Registered %d slots in %.1fs — that cost is not paid again.",
                                    result.registered, result.seconds))
                }
                if let warning = DesktopArrangement.warning() { self.log("Heads up: \(warning)") }
                self.beginTicking()
            }
        }
    }

    /// Every slot on the grid — the canvas that erase mode cuts the pattern out of.
    private var allCells: Set<Cell> {
        Set((0..<grid.rows).flatMap { row in (0..<grid.cols).map { Cell(col: $0, row: row) } })
    }

    /// Arms the engine and runs the first frame. The show clock supplies every tick
    /// after this one — see `tickOnce()`.
    private func beginTicking() {
        guard isRunning, !armed else { return }
        armed = true
        tick()
    }

    /// True once slot registration has finished and the pattern is running, so the
    /// controller knows when its clock-driven ticks will actually do anything.
    private(set) var armed = false

    /// One pattern step, called from the show clock. No-op until the engine is armed
    /// (registration talks to Finder and can take a second).
    func tickOnce() {
        guard isRunning, armed else { return }
        tick()
    }

    /// Stops and removes every file the run created. Idempotent — the panic hotkey,
    /// the Stop button, and app termination all land here.
    func stop(reason: String = "stopped") {
        armed = false
        let wasRunning = isRunning
        isRunning = false
        generation += 1          // a registration still in flight must not start ticking
        let removed = live.count
        for url in live.values { store.delete(url) }
        live = [:]
        born = [:]
        let swept = store.sweep()   // catches anything the live map lost track of
        stats.live = 0
        stats.deleted = store.deletedCount
        stats.refused = store.refusedCount
        if wasRunning || removed > 0 || swept > 0 {
            log("■ \(reason) — removed \(removed + swept) file\(removed + swept == 1 ? "" : "s")")
        }
        onUpdate?(stats)
    }

    /// Removes leftovers without having been running — used at launch and by the
    /// Clean Up button.
    @discardableResult
    func cleanUp() -> Int {
        let n = store.sweep()
        if n > 0 { log("Swept \(n) leftover swarm file\(n == 1 ? "" : "s")") }
        stats.deleted = store.deletedCount
        onUpdate?(stats)
        return n
    }

    // MARK: - Tick

    private func tick() {
        var desired = pattern.cells(step: step).filter { grid.contains($0) }
        if settings.erase { desired = allCells.subtracting(desired) }
        if desired.count > settings.maxLive {
            // Trim deterministically so the shape stays stable between frames
            // instead of flickering a different random subset each tick.
            desired = Set(desired.sorted().prefix(settings.maxLive))
        }

        // A slot the pattern has moved on from is only released once it has been on
        // screen long enough for Finder to have drawn it.
        let now = CFAbsoluteTimeGetCurrent()
        let gone = live.keys.filter {
            !desired.contains($0) && now - (born[$0] ?? 0) >= settings.minLifetime
        }
        let held = live.count - gone.count
        let fresh = desired.subtracting(live.keys)
            .sorted()
            .prefix(max(0, min(settings.createsPerTick, settings.maxLive - held)))

        var ops = 0
        for cell in gone {
            guard let url = live.removeValue(forKey: cell) else { continue }
            born[cell] = nil
            store.delete(url)
            ops += 1
        }

        // No scripting here by design: the slot's icon position is already
        // remembered by Finder, so creating the file is the whole animation.
        for cell in fresh {
            guard let url = store.create(for: cell, note: "step \(step)") else { continue }
            live[cell] = url
            born[cell] = now
            ops += 1
        }

        step += 1
        stats.step = step
        stats.live = live.count
        stats.created = store.createdCount
        stats.deleted = store.deletedCount
        stats.refused = store.refusedCount
        stats.lastOps = ops
        stats.note = store.lastError
        onUpdate?(stats)
    }

    private func log(_ message: String) {
        NSLog("[FileSwarm] \(message)")
        onLog?(message)
    }
}
