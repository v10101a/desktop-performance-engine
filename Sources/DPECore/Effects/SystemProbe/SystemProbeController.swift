import AppKit
import SwiftUI

/// The `system_probe` disclosure report, typing itself out in a window, driven by the
/// show clock.
///
/// - The reveal is beat-paced: `linesPerBeat` drives `Probe.revealOne()` from the pump.
/// - The window wears real macOS chrome but is a non-activating panel that refuses key
///   and ignores the mouse; it closes on `closeWindow` by `id`.
///
/// **Permissions.** The `geolocation` section asks Location Services for a fix — the only
/// TCC prompt this event triggers; refused, those lines read `<unavailable>` and the
/// report runs on. Nothing here reads Contacts: the `identity` section reads the local
/// account (`getpwuid`/`NSFullUserName`), and the ex-`contacts` panel is now a hardware
/// readout (`hardwareDeepSection`).
///
/// **Reversibility.** One window; nothing on disk, nothing in system state.
///
/// Like the other executors, every method here is called on the main thread by the
/// display pump — see `EventContext.execute`.
final class SystemProbeController {
    private struct Report {
        let id: String
        let probe: Probe
        let window: NSWindow
        var cadence: Cadence
        /// Show-time position of the last live-stats resample.
        var lastSample: Double
        var endTime: Double?
        var finished = false
    }

    /// One report per id, not one report. Cue 4 splits the probe into a window per
    /// section and scatters them, so several are up and typing at once; before that this
    /// was a single optional and opening a second window tore the first one down.
    private var reports: [String: Report] = [:]

    var bpm: Double = 120

    /// A stalled tick shouldn't dump the rest of the report on screen at once.
    private static let maxRevealsPerTick = 40

    // MARK: - Lifecycle

    func begin(_ p: SystemProbeParams, at now: Double, bpm: Double) {
        // Same id, already up, and a `focus`: don't rebuild the window — clear the text
        // and read the named sections back out, highlighted. The pacing can change too.
        if var r = reports[p.id], let focus = p.focus {
            MainActor.assumeIsolated { r.probe.rerun(focus: focus) }
            if let rate = p.linesPerBeat { r.cadence.ratePerBeat = rate }
            r.finished = false
            let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
            r.endTime = duration.map { now + $0 }
            reports[p.id] = r
            return
        }
        // Only this id is replaced. Another report under another id is another window
        // and stays where it is.
        teardown(id: p.id)

        // The surface every report prints on. Static and shared — see `Phosphor.use` —
        // so this is the LAST one to open deciding the look for all of them; in the show
        // they are opened together with the same colours, which is what that is for.
        if let ground = p.hex.flatMap({ NSColor(hex: $0) }),
           let ink = p.fg.flatMap({ NSColor(hex: $0) }) {
            Phosphor.use(background: ground, text: ink)
        } else {
            Phosphor.useTerminalBasic()
        }

        // Probe is @MainActor because it drives SwiftUI; the pump already guarantees
        // main, which is what assumeIsolated asserts.
        let probe = MainActor.assumeIsolated { Probe() }
        let frame = self.frame(for: p)

        let window = SystemProbeController.makeReportWindow(
            frame: frame, title: p.title ?? SystemProbeController.defaultTitle)
        window.contentView = NSHostingView(
            rootView: TerminalView().environmentObject(probe))
        window.orderFront(nil)

        // A live close button: clicking the report's traffic light dismisses that report.
        // (makeReportWindow defaults to click-through so it stays testable in isolation;
        // the live show hands the window to the viewer here, where the id exists.)
        if let base = window as? BaseEffectWindow {
            base.ignoresMouseEvents = false
            base.onUserClose = { [weak self] in self?.teardown(id: p.id) }
        }

        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        reports[p.id] = Report(id: p.id, probe: probe, window: window,
                        cadence: Cadence(ratePerBeat: p.linesPerBeat ?? 24,
                                         burstCap: SystemProbeController.maxRevealsPerTick,
                                         start: now),
                        lastSample: now,
                        endTime: duration.map { now + $0 })

        // Kicks the off-main gathering; nothing is revealed until the clock says so.
        MainActor.assumeIsolated { probe.start(focus: p.focus) }
    }

    func stop(id: String) { teardown(id: id) }

    func closeAll() {
        for id in reports.keys { teardown(id: id) }
        // Back to Terminal's own profile: a colour a show set must not outlive it into
        // the still renderer or the next run.
        Phosphor.useTerminalBasic()
    }

    private func teardown(id: String) {
        guard let r = reports.removeValue(forKey: id) else { return }
        r.window.orderOut(nil)
        r.window.close()
    }

    // MARK: - Tick

    func update(now: Double) {
        for id in reports.keys { update(id: id, now: now) }
    }

    private func update(id: String, now: Double) {
        guard var r = reports[id] else { return }

        // Cadence absorbs the seek/stall guard as well as the rate.
        let budgetOrZero = r.cadence.step(now: now, bpm: bpm)

        if let end = r.endTime, now >= end {
            teardown(id: id)
            return
        }

        // Live stats block, once a second of show time.
        if now - r.lastSample >= 1.0 {
            r.lastSample = now
            MainActor.assumeIsolated { r.probe.resample() }
        }

        if !r.finished {
            var budget = budgetOrZero
            while budget > 0 {
                budget -= 1
                let more = MainActor.assumeIsolated { r.probe.revealOne() }
                if !more { r.finished = true; break }
            }
        }
        reports[id] = r
    }

    /// The command the report is the output of — what its title bar says.
    static let defaultTitle = "./scan_identity"

    /// The report's window, split out so the ownership invariant is testable without
    /// constructing a `Probe` — which would fire the Contacts and Location prompts.
    /// Built on `BaseEffectWindow` (real chrome, key refused — a titled plain NSWindow
    /// would take focus on a click). Two defaults deliberately overridden: `.normal`
    /// level, below the effect windows that play over it, and a black body.
    static func makeReportWindow(frame: NSRect, title: String = defaultTitle) -> NSWindow {
        let window = BaseEffectWindow(contentRect: frame, native: true)
        window.title = title
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        // Scenery, like every other effect window: the show owns the keyboard and a
        // stray click must not disturb the report — the traffic lights included.
        window.ignoresMouseEvents = true
        return window
    }

    // MARK: - Geometry

    /// Defaults to the standalone app's 1060×800, centred.
    private func frame(for p: SystemProbeParams) -> NSRect {
        ScreenGeometry.rectOrCentred(p.frame, size: NSSize(width: 1060, height: 800),
                                     on: ScreenGeometry.screen(p.screen))
    }
}
