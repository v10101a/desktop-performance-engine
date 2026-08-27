import AppKit
import AVFoundation
import Contacts

/// The permission prompts, all of them, BEFORE the music starts.
///
/// Four things in the show ask macOS for something the first time they run: the system
/// probe (Contacts, Location Services), the photo booth (Camera), the glass torus
/// (Screen Recording). Left to themselves those prompts land mid-song — a system
/// dialog over the 3·2·1 countdown, which is the one moment that can't wait. So after
/// the viewer says yes at the gate, each prompt the loaded show will need is raised
/// here, one at a time, and the show starts once the last has been answered.
///
/// Only what the timeline actually uses is asked for. A show with no probe never
/// mentions Contacts. Refusals are fine: every consumer degrades on its own.
enum Permissions {
    static func preflight(for events: [ResolvedEvent], done: @escaping () -> Void) {
        var camera = false, location = false, contacts = false, screen = false
        for ev in events {
            switch ev.action {
            case .photoBooth: camera = true
            case .systemProbe: location = true; contacts = true
            case .glassTorus: screen = true
            case .openWindow(let p) where p.content.map?.here == true: location = true
            default: break
            }
        }

        var steps: [(@escaping () -> Void) -> Void] = []
        if camera {
            steps.append { next in
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    NSLog("[DPE] preflight: camera \(ok ? "granted" : "refused")")
                    DispatchQueue.main.async(execute: next)
                }
            }
        }
        if contacts {
            steps.append { next in
                CNContactStore().requestAccess(for: .contacts) { ok, _ in
                    NSLog("[DPE] preflight: contacts \(ok ? "granted" : "refused")")
                    DispatchQueue.main.async(execute: next)
                }
            }
        }
        if location {
            steps.append { next in
                // Asked for, but NOT waited on. This is the one prompt that can sit
                // unanswered — `warm` gives it 45 seconds — and while it does, the show
                // has not started and nothing on screen says why. Hitting "yes" and
                // getting silence is the worst thing the gate can do.
                //
                // Nothing needs a fix for a long time: the probe is ~60 s in and says
                // `<no fix>` without one, and the map is ~103 s in and falls back to Los
                // Angeles. A fix that arrives during the first minute is used by both.
                LocationStore.shared.warm { NSLog("[DPE] preflight: location settled") }
                next()
            }
        }
        if screen {
            steps.append { next in
                // Returns immediately; the prompt (once) sends the viewer to System
                // Settings, and the torus reflects a studio until they come back.
                if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                next()
            }
        }
        run(steps, then: done)
    }

    /// Run the steps in order, but never let one of them hold the show forever.
    ///
    /// The camera and contacts prompts had NO timeout: if the viewer never answers one —
    /// or never sees it, which is the same thing from here — the show simply never
    /// starts, with nothing on screen to say why. Location already had a 45 s escape;
    /// this gives every step one.
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
