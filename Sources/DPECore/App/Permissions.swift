import AppKit
import AVFoundation
import CoreLocation
import CoreServices

/// Every permission prompt the loaded show will need, raised BEFORE the music starts.
///
/// Left to themselves these land mid-song — a system dialog over the 3·2·1 countdown,
/// which is the one moment that can't wait. So after the viewer says yes at the gate,
/// each prompt is raised here, one at a time, and the show starts once the last has been
/// answered.
///
/// Only what the timeline actually uses is asked for. A show with no probe never mentions
/// Location Services. Refusals are fine: every consumer degrades on its own.
///
/// **Two of them have no request API.** Files and Folders and Automation are only ever
/// raised by *doing the thing* — macOS decides to prompt when the read or the Apple event
/// happens. So those steps do the thing here, early and for nothing: a directory listing
/// that is thrown away, an Apple event that asks Finder for no data. Slightly grubby, and
/// the only way to move those dialogs off the middle of the show.
enum Permissions {
    /// One thing the gate will ask macOS for.
    ///
    /// Separated from the asking so a test can pin what a timeline requires without
    /// firing a single dialog — which is most of the reason the list is worth having.
    enum Request: Equatable, CustomStringConvertible {
        case camera
        case location
        case folder(URL)
        case finderAutomation

        var description: String {
            switch self {
            case .camera:           return "camera"
            case .location:         return "location"
            case .folder(let url):  return "~/\(url.lastPathComponent)"
            case .finderAutomation: return "Finder automation"
            }
        }
    }

    /// What the gate will raise, in the order it will raise it.
    static func plan(for events: [ResolvedEvent]) -> [Request] {
        var camera = false, location = false, automation = false
        var folders: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        for ev in events {
            switch ev.action {
            case .photoBooth:
                camera = true
            case .systemProbe:
                location = true
                folders += censusFolderNames.map { home.appendingPathComponent($0) }
            case .photoWall(let p):
                folders += PhotoWallConfig(p).roots
            case .fileSwarm:
                // Reads the Desktop to sweep its own files, and asks Finder where the
                // icons are.
                folders.append(home.appendingPathComponent("Desktop"))
                automation = true
            case .rearrangeIcons:
                automation = true
            case .openWindow(let p) where p.content.map?.here == true:
                location = true
            default:
                break
            }
        }

        var plan: [Request] = []
        if camera { plan.append(.camera) }
        if location { plan.append(.location) }
        plan += gatedRoots(among: folders).map(Request.folder)
        if automation { plan.append(.finderAutomation) }
        return plan
    }

    /// How long the gate will hold for the location prompt specifically. Long enough to
    /// read it and press a button, short enough that an ignored prompt costs a pause and
    /// not a performance.
    static let locationGrace: Double = 12

    /// What macOS currently thinks about one of these, WITHOUT asking it. Every call
    /// here is a status read: none of them can raise a window, so `--check-permissions`
    /// is safe to run in front of an audience five minutes before a show.
    ///
    /// The folder and automation entries have no non-prompting status API — asking IS
    /// the check — so they are reported as unknown rather than tested.
    static func status(of request: Request) -> String {
        switch request {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: return "not determined — WILL show a window"
            case .authorized:    return "already granted — no window"
            case .denied:        return "already denied — no window (System Settings ▸ Privacy)"
            case .restricted:    return "restricted — no window"
            @unknown default:    return "unknown"
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .notDetermined: return "not determined — WILL show a window"
            case .authorizedAlways, .authorized: return "already granted — no window"
            case .denied:        return "already denied — no window (System Settings ▸ Privacy)"
            case .restricted:    return "restricted — no window"
            @unknown default:    return "unknown"
            }
        case .folder(let root):
            return "asked by reading ~/\(root.lastPathComponent) — a window only the first time"
        case .finderAutomation:
            return "asked by talking to Finder — a window only the first time"
        }
    }

    static func preflight(for events: [ResolvedEvent], done: @escaping () -> Void) {
        let requests = plan(for: events)
        NSLog("[DPE] preflight: \(requests.count) prompt(s) — "
            + requests.map(\.description).joined(separator: ", "))
        run(requests.map(step(for:)), then: done)
    }

    // MARK: - The steps

    private static func step(for request: Request) -> (@escaping () -> Void) -> Void {
        switch request {
        case .camera:
            return { next in
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    NSLog("[DPE] preflight: camera \(ok ? "granted" : "refused")")
                    DispatchQueue.main.async(execute: next)
                }
            }

        case .location:
            return { next in
                // Waited on like the others, but on a LEASH. Every prompt is meant to be
                // accepted or denied before the machine starts restarting, and location
                // is a prompt like any other — but it is also the one that can sit
                // unanswered (`warm` gives it 45 seconds), and a gate that waits that
                // long is a gate that has failed in front of an audience. So: whichever
                // comes first, the answer or `locationGrace`, and then on.
                //
                // Nothing needs a fix immediately even if it is still hanging: the probe
                // is ~60 s in and prints `<no fix>` without one, and the map is ~103 s in
                // and falls back to Los Angeles. A fix that arrives during the first
                // minute is used by both.
                var moved = false
                let once = {
                    guard !moved else { return }
                    moved = true
                    next()
                }
                LocationStore.shared.warm {
                    NSLog("[DPE] preflight: location settled")
                    DispatchQueue.main.async(execute: once)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + locationGrace) {
                    if !moved { NSLog("[DPE] preflight: location still unanswered — going on") }
                    once()
                }
            }

        case .folder(let root):
            return { next in
                // Off the main thread: the read blocks until the viewer answers, and on
                // main that freezes the gate behind its own dialog. The listing itself is
                // thrown away — it exists only to make macOS ask now rather than at 60 s.
                DispatchQueue.global(qos: .userInitiated).async {
                    let granted = (try? FileManager.default.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: nil)) != nil
                    NSLog("[DPE] preflight: ~/\(root.lastPathComponent) "
                        + "\(granted ? "granted" : "refused")")
                    DispatchQueue.main.async(execute: next)
                }
            }

        case .finderAutomation:
            return { next in
                DispatchQueue.global(qos: .userInitiated).async {
                    let granted = finderAutomationGranted()
                    NSLog("[DPE] preflight: Finder automation \(granted ? "granted" : "refused")")
                    DispatchQueue.main.async(execute: next)
                }
            }
        }
    }

    /// The subset of `folders` that macOS actually gates.
    ///
    /// Only `~/Desktop`, `~/Documents` and `~/Downloads` sit behind a Files and Folders
    /// prompt; `~/Pictures`, `~/Movies` and `~/Music` do not, so warming those would be a
    /// read that buys nothing. Matched by full path rather than folder name, or an
    /// authored `dirs: ["~/archive/Desktop"]` would be mistaken for the real one.
    static func gatedRoots(among folders: [URL]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gated = ["Desktop", "Documents", "Downloads"]
            .map { home.appendingPathComponent($0).standardizedFileURL.path }
        var seen = Set<String>()
        return folders.filter { url in
            let path = url.standardizedFileURL.path
            guard gated.contains(path) else { return false }
            return seen.insert(path).inserted
        }
    }

    /// Raise the Automation → Finder prompt without actually driving Finder.
    ///
    /// The show sends its Finder scripts through the `osascript` subprocess rather than
    /// in-process, but TCC records Automation against the *responsible* process, which is
    /// this app either way — so a grant taken here is the one `osascript` later runs
    /// under. `askUserIfNeeded: true` makes this block on the dialog, hence the caller's
    /// background queue.
    private static func finderAutomationGranted() -> Bool {
        var target = AEAddressDesc()
        let bundleID = "com.apple.finder"
        let created = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, true) == noErr
    }

    /// Run the steps in order, but never let one of them hold the show forever: an
    /// unanswered (or unseen) prompt must not leave the show never starting with
    /// nothing on screen to say why. Every step gets a timeout — the folder and
    /// Automation prompts block a background thread until answered.
    private static func run(_ steps: [(@escaping () -> Void) -> Void], then done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        var moved = false
        let next = {
            guard !moved else { return }
            moved = true
            run(Array(steps.dropFirst()), then: done)
        }
        first(next)
        DispatchQueue.main.asyncAfter(deadline: .now() + stepTimeout) {
            if !moved { NSLog("[DPE] preflight: a permission step timed out — carrying on") }
            next()
        }
    }

    /// Long enough to read a prompt and decide; short enough that an unanswered one
    /// doesn't look like the show is broken. Only the prompts that block reach this —
    /// location is fired and left to settle on its own.
    private static let stepTimeout: Double = 20
}
