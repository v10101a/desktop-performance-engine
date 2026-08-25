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
                LocationStore.shared.warm {
                    NSLog("[DPE] preflight: location settled")
                    next()
                }
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

    private static func run(_ steps: [(@escaping () -> Void) -> Void], then done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first { run(Array(steps.dropFirst()), then: done) }
    }
}
