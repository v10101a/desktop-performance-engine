import AppKit
import SwiftUI

/// The `system_probe` disclosure report, typing itself out in a window — the standalone
/// systemprobe app, driven by the show clock.
///
/// **What changed in the port.**
///
/// - **The reveal is beat-paced.** The standalone app ran a 0.012 s `Timer`; here
///   `linesPerBeat` drives `Probe.revealOne()` from the pump, using the same fractional
///   credit accumulator as the photo wall, so the report types in tempo.
/// - **The window doesn't take focus and can't be closed by hand.** The standalone app
///   put up a titled, key window; here it is chrome-consistent with the rest of the show
///   and closes on `closeWindow` by `id`.
///
/// **Permissions.** The report's `identity` section reads the Contacts "me" card and
/// asks Location Services for a fix — that is the *point* of the piece ("everything this
/// machine knows about you"), but it means two TCC prompts the rest of the show doesn't
/// trigger. Both degrade: refused, those lines read `<unavailable>` and the report runs
/// on. `assets`-only shows never construct a `Probe` at all, so nothing is asked for.
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

    private var report: Report?

    var bpm: Double = 120

    /// A stalled tick shouldn't dump the rest of the report on screen at once.
    private static let maxRevealsPerTick = 40

    // MARK: - Lifecycle

    func begin(_ p: SystemProbeParams, at now: Double, bpm: Double) {
        // Same id, already up, and a `focus`: don't rebuild the window — clear the text
        // and read the named sections back out, highlighted. The pacing can change too.
        if var r = report, r.id == p.id, let focus = p.focus {
            MainActor.assumeIsolated { r.probe.rerun(focus: focus) }
            if let rate = p.linesPerBeat { r.cadence.ratePerBeat = rate }
            r.finished = false
            let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
            r.endTime = duration.map { now + $0 }
            report = r
            return
        }
        if report != nil { teardown() }

        // Probe is @MainActor because it drives SwiftUI; the pump already guarantees
        // main, which is what assumeIsolated asserts.
        let probe = MainActor.assumeIsolated { Probe() }
        let frame = self.frame(for: p)

        let window = SystemProbeController.makeReportWindow(frame: frame)
        window.contentView = NSHostingView(
            rootView: TerminalView().environmentObject(probe))
        window.orderFront(nil)

        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        report = Report(id: p.id, probe: probe, window: window,
                        cadence: Cadence(ratePerBeat: p.linesPerBeat ?? 24,
                                         burstCap: SystemProbeController.maxRevealsPerTick,
                                         start: now),
                        lastSample: now,
                        endTime: duration.map { now + $0 })

        // Kicks the off-main gathering; nothing is revealed until the clock says so.
        MainActor.assumeIsolated { probe.start(focus: p.focus) }
    }

    func stop(id: String) {
        guard report?.id == id else { return }
        teardown()
    }

    func closeAll() { teardown() }

    private func teardown() {
        guard let r = report else { return }
        r.window.orderOut(nil)
        r.window.close()
        report = nil
    }

    // MARK: - Tick

    func update(now: Double) {
        guard var r = report else { return }

        // Cadence absorbs the seek/stall guard as well as the rate.
        let budgetOrZero = r.cadence.step(now: now, bpm: bpm)

        if let end = r.endTime, now >= end {
            teardown()
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
        report = r
    }

    /// The report's window, split out so the ownership invariant is testable without
    /// constructing a `Probe` — which would fire the Contacts and Location prompts.
    static func makeReportWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // See TorusWindow: this controller holds the window and closes it on teardown,
        // and AppKit's default would over-release it. EffectWindow and PhotoWindow both
        // set this for the same reason.
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        // Scenery, like every other effect window: the show owns the keyboard and a
        // stray click must not disturb the report.
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
