import AppKit

// Split out of WindowManager.swift, which had grown to 753 lines covering seven
// unrelated subsystems. Extensions can't hold stored properties, so the state these
// operate on still lives in the core type — this is an organisational split, not a
// decoupling. Genuinely extracting these into their own executors is the right end
// state, but it should wait until the animation paths have test coverage; there is
// none today, and they are the hardest thing here to verify by eye.

extension WindowManager {
    // MARK: - Jiggle / Move (pump-synced timed effects; mutually exclusive per window)

    func beginJiggle(_ p: JiggleParams, at now: Double, bpm: Double) {
        guard let win = windows[p.id] else {
            NSLog("[DPE] jiggle: no window \"\(p.id)\"")
            return
        }
        moves[p.id] = nil
        let duration = p.durationSeconds ?? ((p.durationBeats ?? 1) * 60.0 / bpm)
        jiggles[p.id] = Jiggle(base: win.frame.origin,
                               start: now,
                               duration: max(0.05, duration),
                               amplitude: p.amplitude ?? 14,
                               frequency: p.frequency ?? 10)
    }

    func beginMove(_ p: MoveWindowParams, at now: Double, bpm: Double) {
        guard let win = windows[p.id] else {
            NSLog("[DPE] moveWindow: no window \"\(p.id)\"")
            return
        }
        let scr = win.screen ?? screen(nil)
        let target = rect(from: p.frame, on: scr, fallbackSize: win.frame.size)
        let duration = p.durationSeconds ?? ((p.durationBeats ?? 0) * 60.0 / bpm)
        jiggles[p.id] = nil
        if duration <= 0.0001 {
            moves[p.id] = nil
            win.setFrame(target, display: false)
            return
        }
        moves[p.id] = Move(baseFrame: win.frame, targetFrame: target,
                           start: now, duration: duration, easing: easingCurve(p.easing))
    }
}
