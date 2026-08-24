import AppKit

// Split out of WindowManager.swift, which had grown to 753 lines covering seven
// unrelated subsystems. Extensions can't hold stored properties, so the state these
// operate on still lives in the core type — this is an organisational split, not a
// decoupling. Genuinely extracting these into their own executors is the right end
// state, but it should wait until the animation paths have test coverage; there is
// none today, and they are the hardest thing here to verify by eye.

extension WindowManager {
    // MARK: - Sprite (window zoetrope)

    func beginSprite(_ p: SpriteParams, at now: Double, bpm: Double) {
        close(id: p.id)
        let cellW = p.cell ?? 30
        let cellH = cellW * (p.cellAspect ?? 0.72)
        let gap = p.gap ?? 4
        let frameOffsets = WindowManager.spriteFrameOffsets(p.frames,
                                                           strideX: cellW + gap,
                                                           strideY: cellH + gap)
        let maxLit = frameOffsets.map(\.count).max() ?? 0
        guard maxLit > 0 else {
            NSLog("[DPE] sprite \"\(p.id)\": no lit cells")
            return
        }
        let pool = takePool(id: p.id, count: maxLit,
                            size: NSSize(width: cellW, height: cellH),
                            chrome: p.chrome ?? "mixed",
                            colors: p.colors ?? WindowManager.defaultPoolColors,
                            shadow: false)
        let scr = screen(p.screen)
        let duration = p.durationSeconds ?? p.durationBeats.map { $0 * 60.0 / bpm }
        let vel = p.velocity ?? [0, 0]
        var target: CGPoint?
        if let t = p.target, t.count >= 2 { target = CGPoint(x: t[0], y: t[1]) }
        let travel = p.travelSeconds ?? ((p.travelBeats ?? 4) * 60.0 / bpm)
        var exit: CGPoint?
        if let e = p.exit, e.count >= 2 { exit = CGPoint(x: e[0], y: e[1]) }
        let exitDur = p.exitSeconds ?? ((p.exitBeats ?? 4) * 60.0 / bpm)
        sprites[p.id] = Sprite(frameOffsets: frameOffsets, pool: pool, cellHeight: cellH,
                               screenFrame: scr.frame,
                               origin: CGPoint(x: p.origin.count > 0 ? p.origin[0] : 0,
                                               y: p.origin.count > 1 ? p.origin[1] : 0),
                               velocity: CGVector(dx: vel.count > 0 ? vel[0] : 0,
                                                  dy: vel.count > 1 ? vel[1] : 0),
                               target: target,
                               travelDuration: max(0.01, travel),
                               travelEasing: easingCurve(p.travelEasing ?? "easeOut"),
                               exit: exit,
                               exitDuration: max(0.01, exitDur),
                               exitEasing: easingCurve(p.exitEasing ?? "easeIn"),
                               start: now,
                               frameDuration: max(0.02, (p.beatsPerFrame ?? 0.5) * 60.0 / bpm),
                               duration: duration)
    }

    /// Parse character frames into lit-cell offsets in points. Any char except
    /// "." or space is lit. Exposed for the headless self-test.
    static func spriteFrameOffsets(_ frames: [[String]], strideX: Double, strideY: Double) -> [[CGPoint]] {
        frames.map { rows in
            var offsets: [CGPoint] = []
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." && ch != " " {
                    offsets.append(CGPoint(x: Double(c) * strideX, y: Double(r) * strideY))
                }
            }
            return offsets
        }
    }

    /// Assign pool windows to a frame's cell offsets, nearest-previous-position
    /// first so windows glide between frames instead of teleporting. Deterministic.
    /// Exposed for the headless self-test.
    static func assignCells(targets: [CGPoint], previous: [CGPoint?]) -> [CGPoint?] {
        var result = [CGPoint?](repeating: nil, count: previous.count)
        var used = [Bool](repeating: false, count: previous.count)
        for target in targets {
            var best = -1
            var bestD = Double.greatestFiniteMagnitude
            for i in 0..<previous.count where !used[i] {
                // Windows already on screen are strongly preferred over hidden ones.
                let d = previous[i].map { hypot($0.x - target.x, $0.y - target.y) } ?? 1e9
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0 { used[best] = true; result[best] = target }
        }
        return result
    }

    func updateSprites(now: Double) {
        for (id, s) in sprites {
            let t = now - s.start
            if let d = s.duration, t >= d { close(id: id); continue }
            let frameIdx = Int(t / s.frameDuration) % s.frameOffsets.count
            let needFrame = frameIdx != s.lastFrame
            // Translation is throttled to ~30 fps — smooth to the eye, and half the
            // window-server traffic of moving the whole pool at full pump rate.
            let needTranslate = s.isMoving(at: t) && (now - s.lastApply) >= 1.0 / 30.0
            guard needFrame || needTranslate else { continue }
            if needFrame {
                s.assigned = WindowManager.assignCells(targets: s.frameOffsets[frameIdx],
                                                       previous: s.assigned)
                s.lastFrame = frameIdx
            }
            s.lastApply = now
            let sf = s.screenFrame
            let o = s.originAt(t)
            let ox = o.x
            let oy = o.y
            for (i, win) in s.pool.enumerated() {
                guard let cell = s.assigned[i] else {
                    if win.alphaValue != 0 { win.alphaValue = 0 }
                    continue
                }
                // Top-left authored space → AppKit bottom-left global.
                win.setFrameOrigin(NSPoint(x: sf.minX + ox + cell.x,
                                           y: sf.maxY - (oy + cell.y) - s.cellHeight))
                if win.alphaValue != 1 { win.alphaValue = 1 }
            }
        }
    }
}
