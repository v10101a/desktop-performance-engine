import AppKit

/// Draws patterns on the desktop out of real file icons — the standalone FileSwarm app,
/// driven by the show clock.
///
/// **Read this before authoring one.**
///
/// - **This event writes real files.** Every other effect in the show is windows and
///   pixels; this one creates and deletes tiny files in `~/Desktop`. They are prefixed
///   `swarm-`, carry an extended-attribute marker, and are removed by the pattern, by
///   `closeWindow`, by panic, by seek, and on quit — `SwarmFileStore.sweep()` also
///   catches orphans from a run that was killed. It only ever deletes files carrying its
///   own marker, so nothing of yours can be touched. Even so it is **gated behind
///   `meta.allowDesktopFiles`**, the same way wallpaper swaps are gated, because a show
///   that writes to disk should be an explicit choice.
///
/// - **It cannot be tightly beat-synced, and no amount of engineering fixes that.** The
///   standalone app measured Finder's desktop view: a *deletion* appears in ~85 ms
///   reliably, a *creation* takes 0.7-3 s and erratically does not appear at all before
///   it is deleted again. That is the window server's limit. Author this as "a pattern
///   running under a section", not as something that lands on a beat.
///
/// - **It needs two permissions**: Files and Folders ▸ Desktop (to write at all) and
///   Automation ▸ Finder (to place icons on a grid). Refused the second, the pattern
///   still runs — Finder just puts each icon wherever it likes, so it reads in time but
///   not in space.
///
/// Like the other executors, every method here is called on the main thread by the
/// display pump — see `EventContext.execute`.
final class FileSwarmController {
    private struct Run {
        let id: String
        let engine: SwarmEngine
        var cadence: Cadence
        var endTime: Double?
    }

    private var run: Run?

    /// Off by default. True only when the timeline sets `meta.allowDesktopFiles`.
    var enabled = false
    var bpm: Double = 120

    /// Finder cannot show creations faster than roughly one every 0.7 s, so a burst
    /// larger than this is wasted work that only makes the sweep longer.
    private static let maxTicksPerUpdate = 4

    // MARK: - Lifecycle

    func begin(_ p: FileSwarmParams, at now: Double, bpm: Double) {
        guard enabled else {
            NSLog("[DPE] fileSwarm skipped — writes real files to ~/Desktop "
                + "(set meta.allowDesktopFiles=true to enable)")
            return
        }
        if run != nil { teardown(reason: "replaced") }

        let store: SwarmFileStore
        do {
            store = try SwarmFileStore()
        } catch {
            NSLog("[DPE] fileSwarm: \(error) — event skipped")
            return
        }

        let engine = SwarmEngine(store: store)
        engine.settings.patternID = p.pattern ?? "spiral"
        if let v = p.maxLive { engine.settings.maxLive = max(1, v) }
        if let v = p.createsPerTick { engine.settings.createsPerTick = max(1, v) }
        if let v = p.minLifetime { engine.settings.minLifetime = max(0, v) }
        if let v = p.positionIcons { engine.settings.positionIcons = v }
        if let v = p.erase { engine.settings.erase = v }
        // Upstream's SplitMix64 init mapped a 0 seed to the golden-ratio constant; DPE's
        // shared one doesn't, so the guard is applied here instead of at nine call sites.
        if let v = p.seed { engine.settings.seed = v == 0 ? 0x9E37_79B9_7F4A_7C15 : UInt64(v) }
        // Marquee copy is a static on the pattern, not a settings field.
        if let v = p.text { MarqueePattern.message = v }
        engine.onLog = { NSLog("[DPE] fileSwarm: \($0)") }

        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        run = Run(id: p.id, engine: engine,
                  cadence: Cadence(ratePerBeat: p.ticksPerBeat ?? 2,
                                   burstCap: FileSwarmController.maxTicksPerUpdate,
                                   start: now),
                  endTime: duration.map { now + $0 })
        engine.start()
    }

    /// Matches `closeWindow` by id. Stops the pattern and removes every file it made.
    func stop(id: String) {
        guard run?.id == id else { return }
        teardown(reason: "closeWindow")
    }

    /// Idempotent teardown for panic, seek and quit. The sweep is the important part:
    /// it is what keeps "fully reversible" true for an effect that touches the disk.
    func closeAll() { teardown(reason: "restore") }

    private func teardown(reason: String) {
        guard let r = run else { return }
        r.engine.stop(reason: reason)
        run = nil
    }

    // MARK: - Tick

    func update(now: Double) {
        guard var r = run else { return }

        var budget = r.cadence.step(now: now, bpm: bpm)

        if let end = r.endTime, now >= end {
            teardown(reason: "duration elapsed")
            return
        }

        while budget > 0 {
            budget -= 1
            r.engine.tickOnce()
        }
        run = r
    }
}
