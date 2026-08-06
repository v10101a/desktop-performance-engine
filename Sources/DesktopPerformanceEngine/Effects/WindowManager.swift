import AppKit

/// Owns every window the show spawns, keyed by author-supplied id so later events
/// can close them and panic/restore can wipe them all at once.
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    /// Set from the loaded timeline so beat-based durations resolve to seconds.
    var bpm: Double = 120

    var count: Int {
        windows.count
            + sprites.values.reduce(0) { $0 + $1.pool.count }
            + trails.values.reduce(0) { $0 + $1.stamps.count + $1.pool.count }
    }

    /// Test hook: current on-screen origin of a spawned window.
    func frameOrigin(id: String) -> NSPoint? { windows[id]?.frame.origin }

    private struct Jiggle {
        let base: NSPoint
        let start: Double
        let duration: Double
        let amplitude: Double
        let frequency: Double
    }
    private var jiggles: [String: Jiggle] = [:]

    private struct Move {
        let baseFrame: NSRect
        let targetFrame: NSRect
        let start: Double
        let duration: Double
        let easing: (Double) -> Double
    }
    private var moves: [String: Move] = [:]

    /// Reused fullscreen flash overlays, keyed by screen index.
    private var flashOverlays: [Int: FlashWindow] = [:]

    /// Body colors cycled across micro-window pools when the event doesn't specify any.
    static let defaultPoolColors = ["#020AF5", "#F2F4FE", "#68BDF8", "#669DF6", "#C1C7D6", "#6C86E2"]

    /// A running window-zoetrope: pooled micro-windows repainted as animation frames.
    private final class Sprite {
        let frameOffsets: [[CGPoint]]     // per frame: lit-cell offsets in points (top-left space, +y down)
        let pool: [MicroWindow]
        let cellHeight: Double
        let screenFrame: NSRect
        let origin: CGPoint               // authored top-left origin, screen-relative
        let velocity: CGVector            // points/sec, +y down
        let target: CGPoint?              // arrival mode: run to here, then hold
        let travelDuration: Double
        let travelEasing: (Double) -> Double
        let exit: CGPoint?                // run out of frame in the final exitDuration
        let exitDuration: Double
        let exitEasing: (Double) -> Double
        let start: Double
        let frameDuration: Double
        let duration: Double?             // nil = until closeWindow(id)
        var lastFrame = -1
        var lastApply = -1.0
        var assigned: [CGPoint?]          // per pool window: its current cell offset

        init(frameOffsets: [[CGPoint]], pool: [MicroWindow], cellHeight: Double,
             screenFrame: NSRect, origin: CGPoint, velocity: CGVector,
             target: CGPoint?, travelDuration: Double, travelEasing: @escaping (Double) -> Double,
             exit: CGPoint?, exitDuration: Double, exitEasing: @escaping (Double) -> Double,
             start: Double, frameDuration: Double, duration: Double?) {
            self.frameOffsets = frameOffsets
            self.pool = pool
            self.cellHeight = cellHeight
            self.screenFrame = screenFrame
            self.origin = origin
            self.velocity = velocity
            self.target = target
            self.travelDuration = travelDuration
            self.travelEasing = travelEasing
            self.exit = exit
            self.exitDuration = exitDuration
            self.exitEasing = exitEasing
            self.start = start
            self.frameDuration = frameDuration
            self.duration = duration
            self.assigned = Array(repeating: nil, count: pool.count)
        }

        private var exitStart: Double? {
            guard exit != nil, let d = duration else { return nil }
            return d - exitDuration
        }

        /// Where the sprite's top-left sits at time `t` (top-left authored space):
        /// run in (origin→target), hold, then run out (target→exit).
        func originAt(_ t: Double) -> CGPoint {
            guard let target = target else {
                return CGPoint(x: origin.x + velocity.dx * t, y: origin.y + velocity.dy * t)
            }
            if let es = exitStart, let exit = exit, t >= es {
                let u = exitDuration > 0 ? min(1.0, (t - es) / exitDuration) : 1.0
                let e = exitEasing(u)
                return CGPoint(x: target.x + (exit.x - target.x) * e,
                               y: target.y + (exit.y - target.y) * e)
            }
            let u = travelDuration > 0 ? min(1.0, t / travelDuration) : 1.0
            let e = travelEasing(u)
            return CGPoint(x: origin.x + (target.x - origin.x) * e,
                           y: origin.y + (target.y - origin.y) * e)
        }

        /// Whether the sprite is translating at time `t` (the hold stands still).
        func isMoving(at t: Double) -> Bool {
            if target != nil {
                if t < travelDuration { return true }
                if let es = exitStart { return t >= es }
                return false
            }
            return velocity.dx != 0 || velocity.dy != 0
        }
    }
    private var sprites: [String: Sprite] = [:]

    /// A running cursor trail (stamp breadcrumbs or follow comet).
    private final class Trail {
        let mode: String                  // "stamp" | "follow"
        let spacing: Double
        let maxCount: Int
        let size: NSSize
        let chrome: String?
        let colors: [String]
        let delay: Double
        let start: Double
        let duration: Double?             // sampling window; stamp windows persist after
        var active = true
        var lastStamp: CGPoint?           // bottom-left global (NSEvent space)
        var stamps: [MicroWindow] = []
        var pool: [MicroWindow] = []      // follow mode, fixed size
        var samples: [(t: Double, p: CGPoint)] = []

        init(mode: String, spacing: Double, maxCount: Int, size: NSSize,
             chrome: String?, colors: [String], delay: Double,
             start: Double, duration: Double?) {
            self.mode = mode
            self.spacing = spacing
            self.maxCount = maxCount
            self.size = size
            self.chrome = chrome
            self.colors = colors
            self.delay = delay
            self.start = start
            self.duration = duration
        }
    }
    private var trails: [String: Trail] = [:]

    /// Pools built BEFORE the clock starts (see `prewarm`). Creating dozens of
    /// NSPanels inside a pump tick stalls the main thread ~100ms and everything
    /// after that event fires late — so begin* consumes a prepared pool instead.
    private var preparedPools: [String: [MicroWindow]] = [:]

    private func buildPool(count: Int, size: NSSize, chrome: String?,
                           colors: [String], shadow: Bool) -> [MicroWindow] {
        (0..<count).map { i in
            let win = MicroWindow(size: size,
                                  bodyColor: NSColor(hex: colors[i % colors.count]) ?? .magenta,
                                  chrome: resolvedChromeKind(chrome, index: i),
                                  title: nil, shadow: shadow)
            win.alphaValue = 0
            win.orderFrontRegardless()
            return win
        }
    }

    /// Take a prepared pool if one matches, else build on the spot (logged: that
    /// path means a mid-show stall and the timeline should be prewarmed).
    /// Size compares with tolerance — AppKit rounds window frames to backing pixels.
    private func takePool(id: String, count: Int, size: NSSize, chrome: String?,
                          colors: [String], shadow: Bool) -> [MicroWindow] {
        if let pool = preparedPools[id], pool.count == count,
           pool.first.map({ abs($0.frame.width - size.width) < 1
                            && abs($0.frame.height - size.height) < 1 }) ?? true {
            preparedPools.removeValue(forKey: id)
            return pool
        }
        NSLog("[DPE] pool \"\(id)\": building \(count) windows mid-show (not prewarmed)")
        return buildPool(count: count, size: size, chrome: chrome, colors: colors, shadow: shadow)
    }

    /// Scan the timeline and build every window the show will need up front,
    /// while the clock isn't running yet: sprite/follow-trail pools, effect and
    /// dialog window shells (reused by id at open), and flash overlays. Creating
    /// any of these inside a pump tick makes every later event fire late.
    func prewarm(for events: [ResolvedEvent]) {
        for ev in events {
            switch ev.action {
            case .openWindow(let p):
                guard windows[p.id] == nil else { continue }
                let win = EffectWindow(contentRect: rect(from: p.frame, on: screen(p.screen)),
                                       content: p.content)
                windows[p.id] = win   // not ordered front; open() presents it
            case .fakeDialog(let p):
                guard windows[p.id] == nil else { continue }
                let frame = p.frame.flatMap { $0.count == 4 ? rect(from: $0, on: screen(p.screen)) : nil }
                    ?? NSRect(x: 0, y: 0, width: 440, height: 180)
                windows[p.id] = FakeDialogWindow(contentRect: frame, title: p.title,
                                                 message: p.body, buttons: p.buttons ?? ["OK"])
            case .screenFlash(let p):
                let idx = p.screen ?? 0
                if flashOverlays[idx] == nil {
                    flashOverlays[idx] = FlashWindow(frame: screen(p.screen).frame)
                }
            case .sprite(let p):
                let cellW = p.cell ?? 30
                let cellH = cellW * (p.cellAspect ?? 0.72)
                let gap = p.gap ?? 4
                let offsets = WindowManager.spriteFrameOffsets(p.frames, strideX: cellW + gap,
                                                               strideY: cellH + gap)
                let maxLit = offsets.map(\.count).max() ?? 0
                guard maxLit > 0, preparedPools[p.id] == nil else { continue }
                preparedPools[p.id] = buildPool(count: maxLit,
                                                size: NSSize(width: cellW, height: cellH),
                                                chrome: p.chrome ?? "mixed",
                                                colors: p.colors ?? WindowManager.defaultPoolColors,
                                                shadow: false)
            case .cursorTrail(let p):
                guard (p.mode ?? "stamp") == "follow", preparedPools[p.id] == nil else { continue }
                let sizeArr = p.size ?? []
                preparedPools[p.id] = buildPool(count: p.count ?? 8,
                                                size: NSSize(width: sizeArr.count > 0 ? sizeArr[0] : 46,
                                                             height: sizeArr.count > 1 ? sizeArr[1] : 34),
                                                chrome: p.chrome ?? "mixed",
                                                colors: p.colors ?? WindowManager.defaultPoolColors,
                                                shadow: false)
            default:
                break
            }
        }
    }

    // MARK: - Executors

    func openWindow(_ p: OpenWindowParams) {
        let scr = screen(p.screen)
        let frame = rect(from: p.frame, on: scr)
        jiggles[p.id] = nil
        moves[p.id] = nil
        // Reuse the existing window if this id is being re-opened — swapping the
        // content view + frame avoids the expensive NSWindow create/destroy that
        // otherwise dominates a dense strobe.
        if let existing = windows[p.id] as? EffectWindow {
            existing.setFrame(frame, display: false)
            existing.contentView = makeEffectContentView(p.content, size: frame.size)
            existing.present(animate: "none")
            return
        }
        close(id: p.id)
        let win = EffectWindow(contentRect: frame, content: p.content)
        windows[p.id] = win
        win.present(animate: p.animate?.kind ?? "fadeIn")
    }

    func openDialog(_ p: FakeDialogParams) {
        let scr = screen(p.screen)
        let frame: NSRect
        if let f = p.frame, f.count == 4 {
            frame = rect(from: f, on: scr)
        } else {
            let size = NSSize(width: 440, height: 180)
            let sf = scr.frame
            frame = NSRect(x: sf.midX - size.width / 2,
                           y: sf.midY - size.height / 2,
                           width: size.width, height: size.height)
        }
        jiggles[p.id] = nil
        moves[p.id] = nil
        if let existing = windows[p.id] as? FakeDialogWindow {
            existing.setFrame(frame, display: false)
            existing.contentView = makeDialogContentView(title: p.title, message: p.body,
                                                         buttons: p.buttons ?? ["OK"], size: frame.size)
            existing.present(animate: "none")
            return
        }
        close(id: p.id)
        let win = FakeDialogWindow(contentRect: frame,
                                   title: p.title,
                                   message: p.body,
                                   buttons: p.buttons ?? ["OK"])
        windows[p.id] = win
        win.present(animate: "springIn")
    }

    func screenFlash(_ p: ScreenFlashParams) {
        let idx = p.screen ?? 0
        let scr = screen(p.screen)
        let duration: Double
        if let s = p.durationSeconds {
            duration = s
        } else if let b = p.durationBeats {
            duration = b * 60.0 / bpm
        } else {
            duration = 0.2
        }
        let color = NSColor(hex: p.color ?? "#FFFFFF") ?? .white
        let overlay = flashOverlays[idx] ?? {
            let f = FlashWindow(frame: scr.frame)
            flashOverlays[idx] = f
            return f
        }()
        overlay.flash(color: color, duration: duration)
    }

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

    private func updateSprites(now: Double) {
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

    private func updateTrails(now: Double) {
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
                              chrome: resolvedChromeKind(tr.chrome, index: i),
                              title: nil, shadow: true)
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

    /// Called every pump tick to advance active moves and jiggles.
    func update(now: Double) {
        updateSprites(now: now)
        updateTrails(now: now)
        guard !jiggles.isEmpty || !moves.isEmpty else { return }

        for (id, m) in moves {
            guard let win = windows[id] else { moves[id] = nil; continue }
            let t = (now - m.start) / m.duration
            if t >= 1.0 {
                win.setFrame(m.targetFrame, display: false)
                moves[id] = nil
                continue
            }
            let e = m.easing(t)
            win.setFrame(NSRect(x: lerp(m.baseFrame.minX, m.targetFrame.minX, e),
                                y: lerp(m.baseFrame.minY, m.targetFrame.minY, e),
                                width: lerp(m.baseFrame.width, m.targetFrame.width, e),
                                height: lerp(m.baseFrame.height, m.targetFrame.height, e)),
                        display: false)
        }

        for (id, j) in jiggles {
            guard let win = windows[id] else { jiggles[id] = nil; continue }
            let t = (now - j.start) / j.duration
            if t >= 1.0 {
                win.setFrameOrigin(j.base)   // settle back to base
                jiggles[id] = nil
                continue
            }
            let decay = 1.0 - t
            let phase = 2 * Double.pi * j.frequency * (now - j.start)
            let dx = j.amplitude * decay * sin(phase)
            let dy = j.amplitude * decay * sin(phase + Double.pi / 2)
            win.setFrameOrigin(NSPoint(x: j.base.x + dx, y: j.base.y + dy))
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    func close(id: String) {
        jiggles[id] = nil
        moves[id] = nil
        if let s = sprites.removeValue(forKey: id) {
            for w in s.pool { w.orderOut(nil) }
        }
        if let t = trails.removeValue(forKey: id) {
            for w in t.stamps { w.orderOut(nil) }
            for w in t.pool { w.orderOut(nil) }
        }
        guard let win = windows[id] else { return }
        win.orderOut(nil)
        windows[id] = nil
    }

    func closeAll() {
        jiggles.removeAll()
        moves.removeAll()
        for (_, s) in sprites { for w in s.pool { w.orderOut(nil) } }
        sprites.removeAll()
        for (_, t) in trails {
            for w in t.stamps { w.orderOut(nil) }
            for w in t.pool { w.orderOut(nil) }
        }
        trails.removeAll()
        for (_, pool) in preparedPools { for w in pool { w.orderOut(nil) } }
        preparedPools.removeAll()
        for (_, win) in windows { win.orderOut(nil) }
        windows.removeAll()
        for (_, overlay) in flashOverlays { overlay.orderOut(nil) }
        flashOverlays.removeAll()
    }

    // MARK: - Geometry

    private func screen(_ index: Int?) -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        let i = index ?? 0
        return (i >= 0 && i < screens.count) ? screens[i] : (NSScreen.main ?? screens[0])
    }

    /// Interpret `[x, y, w, h]` as top-left origin relative to `screen`, converting
    /// to AppKit's bottom-left global coordinates.
    private func rect(from frame: [Double], on screen: NSScreen, fallbackSize: NSSize? = nil) -> NSRect {
        let sf = screen.frame
        let x = frame.count > 0 ? frame[0] : 0
        let topY = frame.count > 1 ? frame[1] : 0
        let w = frame.count > 2 ? frame[2] : (fallbackSize?.width ?? 300)
        let h = frame.count > 3 ? frame[3] : (fallbackSize?.height ?? 200)
        return NSRect(x: sf.minX + x,
                      y: sf.maxY - topY - h,
                      width: w, height: h)
    }
}
