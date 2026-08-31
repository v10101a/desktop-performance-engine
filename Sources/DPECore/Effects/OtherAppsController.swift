import AppKit

/// Clears the stage. The show paints the desktop itself — the wallpaper goes blue on
/// the first beat — and on a machine with a dozen windows open nobody sees it. So on
/// cue every other app is hidden, and on stop, panic or seek exactly those apps come
/// back.
///
/// Hide, not minimise and not a new Space. `NSRunningApplication.hide()` needs no
/// permission, takes a whole app in one call, and `unhide()` puts every window back
/// where it was — same Space, same stacking, same size, no animation per window.
/// Minimising would go through the Accessibility API (a permission prompt, then a
/// genie animation per window on the way back, and it forgets windows that were
/// already minimised); switching Spaces has no public API at all, and would leave the
/// show's own windows behind on the old one.
///
/// Only apps that were VISIBLE when the event fired are recorded, so an app the viewer
/// had hidden themselves stays hidden afterwards. Finder counts — its windows cover the
/// desktop like anyone else's — and hiding it leaves the desktop icons in place.
///
/// Like the other executors, every method here is called on the main thread by the
/// engine.
final class OtherAppsController {
    private var id = ""
    /// The apps this run hid, in the order they were hidden. Empty while nothing is.
    private var hidden: [NSRunningApplication] = []

    /// Each `hide()` is a synchronous round trip to that app — about 3–4 ms apiece,
    /// measured — on the pump's thread. Three visible apps cost ~12 ms; the event sits
    /// on beat 0, ahead of everything, so nothing else in the tick is waiting on it.
    func begin(_ p: HideOtherAppsParams) {
        // A second event replaces the first: whatever the first hid stays hidden and
        // is still restored — the list accumulates, it never resets on a re-fire.
        id = p.id ?? "otherApps"
        let started = CFAbsoluteTimeGetCurrent()
        let me = ProcessInfo.processInfo.processIdentifier
        let keep = Set(p.except ?? [])
        var names: [String] = []
        var acknowledged = 0
        for app in NSWorkspace.shared.runningApplications {
            // Only apps with a Dock tile have windows to hide; the rest are agents.
            guard app.activationPolicy == .regular,
                  !app.isHidden, !app.isTerminated,
                  app.processIdentifier != me,
                  !keep.contains(app.bundleIdentifier ?? ""),
                  !hidden.contains(where: { $0.processIdentifier == app.processIdentifier })
            else { continue }
            // Recorded whether or not the call claims success — see `closeAll`.
            if app.hide() { acknowledged += 1 }
            hidden.append(app)
            names.append(app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)")
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        NSLog(String(format: "[DPE] hideOtherApps: hid %d app(s) (%d acknowledged) in %.1f ms — %@",
                     names.count, acknowledged, ms, names.joined(separator: ", ")))
    }

    /// `closeWindow` with this event's id brings the apps back mid-show.
    func stop(id: String) {
        guard id == self.id else { return }
        closeAll()
    }

    func update(now: Double) {}

    /// Idempotent. Unhiding an app that is already visible is a no-op, so an app the
    /// viewer brought back by hand during the show is left alone; one that has since
    /// quit is skipped. `unhide()` does not activate, so focus stays where it is.
    ///
    /// The Bool from `hide()`/`unhide()` is NOT what decides anything here. On macOS
    /// 26.4 both return `false` while doing exactly what was asked (measured: Finder
    /// hid and came back, both calls reporting failure), so an app is recorded because
    /// we *asked* to hide it, and every recorded app is asked back — a no-op for one
    /// that was never hidden. Trusting the return value hid apps and then forgot them,
    /// which is the one thing this engine must never do.
    func closeAll() {
        guard !hidden.isEmpty else { return }
        let apps = hidden
        hidden.removeAll()
        var acknowledged = 0
        var asked = 0
        for app in apps where !app.isTerminated {
            if app.unhide() { acknowledged += 1 }
            asked += 1
        }
        NSLog("[DPE] hideOtherApps: unhid \(asked) app(s) (\(acknowledged) acknowledged)")
    }
}
