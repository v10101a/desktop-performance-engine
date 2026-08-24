import AppKit

/// Owns every window the show spawns, keyed by author-supplied id so later events
/// can close them and panic/restore can wipe them all at once.
/// Some members below are module-internal rather than private: the sprite, trail,
/// typing and motion subsystems live in `WindowManager+*.swift`, and a Swift extension
/// in another file cannot see `private`. Everything not touched by those four files
/// stays private. See the header of any of them for why the split is organisational.
final class WindowManager {
    var windows: [String: NSWindow] = [:]

    /// Set from the loaded timeline so beat-based durations resolve to seconds.
    /// Also published to `dpeShowBPM` so generative content (the livecode visuals)
    /// can key its Core Animation periods to the beat.
    var bpm: Double = 120 { didSet { dpeShowBPM = bpm } }

    var count: Int {
        windows.count
            + sprites.values.reduce(0) { $0 + $1.pool.count }
            + trails.values.reduce(0) { $0 + $1.stamps.count + $1.pool.count }
    }

    /// Test hook: current on-screen origin of a spawned window.
    func frameOrigin(id: String) -> NSPoint? { windows[id]?.frame.origin }

    struct Jiggle {
        let base: NSPoint
        let start: Double
        let duration: Double
        let amplitude: Double
        let frequency: Double
    }
    var jiggles: [String: Jiggle] = [:]

    struct Move {
        let baseFrame: NSRect
        let targetFrame: NSRect
        let start: Double
        let duration: Double
        let easing: (Double) -> Double
    }
    var moves: [String: Move] = [:]

    /// A text editor writing itself out. `shown` is cached so the (relatively costly)
    /// text relayout only happens when the visible character count actually changes,
    /// not on every one of the pump's ~72 ticks a second.
    struct Typer {
        let view: TextEditorView
        let text: [Character]
        let start: Double
        let charsPerSecond: Double
        let endTime: Double?
        var shown: Int
        var caretOn: Bool
    }
    var typers: [String: Typer] = [:]

    /// Windows the viewer is allowed to close but that come back anyway. The
    /// generation counter makes a pending respawn a no-op once the show has stopped,
    /// so nothing can pop up on a restored desktop.
    private var respawns: [String: OpenWindowParams] = [:]
    private var respawnGeneration = 0

    /// Reused fullscreen flash overlays, keyed by screen index.
    private var flashOverlays: [Int: FlashWindow] = [:]

    /// Body colors cycled across micro-window pools when the event doesn't specify any.
    static let defaultPoolColors = ["#020AF5", "#F2F4FE", "#68BDF8", "#669DF6", "#C1C7D6", "#6C86E2"]

    /// A running window-zoetrope: pooled micro-windows repainted as animation frames.
    final class Sprite {
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
    var sprites: [String: Sprite] = [:]

    /// A running cursor trail (stamp breadcrumbs or follow comet).
    final class Trail {
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
    var trails: [String: Trail] = [:]

    /// Pools built BEFORE the clock starts (see `prewarm`). Creating dozens of
    /// NSPanels inside a pump tick stalls the main thread ~100ms and everything
    /// after that event fires late — so begin* consumes a prepared pool instead.
    private var preparedPools: [String: [MicroWindow]] = [:]

    private func buildPool(count: Int, size: NSSize, chrome: String?,
                           colors: [String], shadow: Bool) -> [MicroWindow] {
        (0..<count).map { i in
            let win = MicroWindow(size: size,
                                  bodyColor: NSColor(hex: colors[i % colors.count]) ?? .magenta,
                                  shadow: shadow)
            win.alphaValue = 0
            win.orderFrontRegardless()
            return win
        }
    }

    /// Take a prepared pool if one matches, else build on the spot (logged: that
    /// path means a mid-show stall and the timeline should be prewarmed).
    /// Size compares with tolerance — AppKit rounds window frames to backing pixels.
    func takePool(id: String, count: Int, size: NSSize, chrome: String?,
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
        respawns[p.id] = (p.respawn == true) ? p : nil
        // Reuse the existing window if this id is being re-opened — swapping the
        // content view + frame avoids the expensive NSWindow create/destroy that
        // otherwise dominates a dense strobe. (Re-opening the same id is also how a
        // livecode window goes from "written" to "running".)
        //
        // Only reusable while the native/drawn decision is unchanged: that decision is
        // baked into the styleMask at creation, so a window first opened too small for a
        // real title bar cannot grow one by being re-opened larger. When it flips, fall
        // through and build a fresh window.
        if let existing = windows[p.id] as? EffectWindow,
           existing.isNativeChrome == usesNativeChrome(p.content.chrome, size: frame.size) {
            existing.applyContent(p.content, frame: frame)
            arm(existing, p, size: frame.size)
            existing.present(animate: "none")
            return
        }
        close(id: p.id)
        let win = EffectWindow(contentRect: frame, content: p.content)
        arm(win, p, size: frame.size)
        windows[p.id] = win
        win.present(animate: p.animate?.kind ?? "fadeIn")
    }

    /// Hand a window to the viewer if the event asked for it: draggable, and closable
    /// by its fake traffic lights. A `respawn` window comes straight back.
    private func arm(_ win: EffectWindow, _ p: OpenWindowParams, size: NSSize) {
        guard p.interactive == true else {
            win.onUserClose = nil
            return
        }
        win.makeInteractive(size: size)
        win.onUserClose = { [weak self] in
            guard let self = self else { return }
            let again = self.respawns[p.id]
            let generation = self.respawnGeneration
            self.close(id: p.id)
            guard let again = again else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.respawnGeneration == generation else { return }
                self.openWindow(again)
            }
        }
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
                                                         buttons: p.buttons ?? ["OK"],
                                                         icon: p.dialogIcon, size: frame.size)
            existing.present(animate: "none")
            return
        }
        close(id: p.id)
        let win = FakeDialogWindow(contentRect: frame,
                                   title: p.title,
                                   message: p.body,
                                   buttons: p.buttons ?? ["OK"],
                                   icon: p.dialogIcon)
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

    func update(now: Double) {
        updateSprites(now: now)
        updateTrails(now: now)
        updateTypers(now: now)
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
        typers[id] = nil
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
        typers.removeAll()
        respawns.removeAll()
        respawnGeneration &+= 1     // cancels any respawn still in flight
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

    func screen(_ index: Int?) -> NSScreen { ScreenGeometry.screen(index) }

    func rect(from frame: [Double], on screen: NSScreen,
                      fallbackSize: NSSize? = nil) -> NSRect {
        ScreenGeometry.rect(from: frame, on: screen, fallbackSize: fallbackSize)
    }
}
