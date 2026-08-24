import AppKit

// Split out of WindowManager.swift, which had grown to 753 lines covering seven
// unrelated subsystems. Extensions can't hold stored properties, so the state these
// operate on still lives in the core type — this is an organisational split, not a
// decoupling. Genuinely extracting these into their own executors is the right end
// state, but it should wait until the animation paths have test coverage; there is
// none today, and they are the hardest thing here to verify by eye.

extension WindowManager {
    // MARK: - Cursor trail

    func beginTrail(_ p: CursorTrailParams, at now: Double, bpm: Double) {
        close(id: p.id)
        let mode = p.mode ?? "stamp"
        let sizeArr = p.size ?? []
        let size = NSSize(width: sizeArr.count > 0 ? sizeArr[0] : 46,
                          height: sizeArr.count > 1 ? sizeArr[1] : 34)
        let duration = p.durationSeconds ?? p.durationBeats.map { $0 * 60.0 / bpm }
        let trail = Trail(mode: mode,
                          spacing: max(6, p.spacing ?? 28),
                          maxCount: p.count ?? (mode == "follow" ? 8 : 160),
                          size: size,
                          chrome: p.chrome ?? "mixed",
                          colors: p.colors ?? WindowManager.defaultPoolColors,
                          delay: max(0.02, p.delay ?? 0.07),
                          start: now,
                          duration: duration)
        if mode == "follow" {
            trail.pool = takePool(id: p.id, count: trail.maxCount, size: size,
                                  chrome: trail.chrome, colors: trail.colors, shadow: false)
        }
        trails[p.id] = trail
    }

    /// Whether the cursor moving `dist` px since the last breadcrumb should stamp
    /// (and how many), or be treated as a pen-up jump. Exposed for the self-test.
    static func stampCount(dist: Double, spacing: Double) -> Int {
        if dist >= spacing * 4 { return -1 }        // pen up: warp between strokes
        return Int(dist / spacing)
    }

    func updateTrails(now: Double) {
        guard !trails.isEmpty else { return }
        let cursor = NSEvent.mouseLocation   // bottom-left global; no permission needed
        for (_, tr) in trails {
            if let d = tr.duration, now - tr.start >= d, tr.active {
                tr.active = false
                // Follow tails vanish when done; stamps persist until closed.
                if tr.mode == "follow" { for w in tr.pool { w.alphaValue = 0 } }
            }
            guard tr.active else { continue }

            if tr.mode == "follow" {
                tr.samples.append((now, cursor))
                let horizon = now - tr.delay * Double(tr.pool.count + 1) - 0.5
                while tr.samples.count > 2, tr.samples[1].t < horizon {
                    tr.samples.removeFirst()
                }
                for (i, win) in tr.pool.enumerated() {
                    let target = now - tr.delay * Double(i + 1)
                    guard let p = WindowManager.sample(tr.samples, at: target) else { continue }
                    win.setFrameOrigin(NSPoint(x: p.x - tr.size.width / 2,
                                               y: p.y - tr.size.height / 2))
                    // Slight fade down the tail so it reads as a comet.
                    let a = 1.0 - 0.6 * Double(i) / Double(max(1, tr.pool.count - 1))
                    if abs(win.alphaValue - a) > 0.01 { win.alphaValue = a }
                }
            } else {
                guard let last = tr.lastStamp else {
                    tr.lastStamp = cursor
                    stamp(tr, at: cursor)
                    continue
                }
                let dist = hypot(cursor.x - last.x, cursor.y - last.y)
                let n = WindowManager.stampCount(dist: dist, spacing: tr.spacing)
                if n < 0 {
                    tr.lastStamp = cursor    // pen up: re-anchor, no stamps across the jump
                } else if n > 0 {
                    // Fast cursor: fill the whole segment so spacing stays even.
                    for k in 1...n {
                        let f = Double(k) * tr.spacing / dist
                        stamp(tr, at: CGPoint(x: last.x + (cursor.x - last.x) * f,
                                              y: last.y + (cursor.y - last.y) * f))
                    }
                    let f = Double(n) * tr.spacing / dist
                    tr.lastStamp = CGPoint(x: last.x + (cursor.x - last.x) * f,
                                           y: last.y + (cursor.y - last.y) * f)
                }
            }
        }
    }

    private func stamp(_ tr: Trail, at p: CGPoint) {
        guard tr.stamps.count < tr.maxCount else { return }
        let i = tr.stamps.count
        let win = MicroWindow(size: tr.size,
                              bodyColor: NSColor(hex: tr.colors[i % tr.colors.count]) ?? .magenta,
                              shadow: true)
        win.setFrameOrigin(NSPoint(x: p.x - tr.size.width / 2, y: p.y - tr.size.height / 2))
        win.orderFrontRegardless()
        tr.stamps.append(win)
    }

    /// Linear interpolation into the follow-mode sample buffer. Exposed for tests.
    static func sample(_ samples: [(t: Double, p: CGPoint)], at time: Double) -> CGPoint? {
        guard let first = samples.first else { return nil }
        if time <= first.t { return nil }   // window hasn't "entered" yet
        for i in 1..<samples.count where samples[i].t >= time {
            let a = samples[i - 1], b = samples[i]
            let f = (time - a.t) / max(1e-9, b.t - a.t)
            return CGPoint(x: a.p.x + (b.p.x - a.p.x) * f,
                           y: a.p.y + (b.p.y - a.p.y) * f)
        }
        return samples.last?.p
    }

    /// The typewriter: reveal however many characters the tempo says we should be at
    /// by now, and blink the caret at 2 Hz.
}
