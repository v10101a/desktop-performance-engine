import AppKit

/// Owns every window the show spawns, keyed by author-supplied id so later events
/// can close them and panic/restore can wipe them all at once.
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    /// Timeline position each live window opened at, for the inspect badges.
    /// Same keys as `windows`.
    private var openedAt: [String: Double] = [:]

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

    /// A text editor writing itself out. `shown` is cached so the (relatively costly)
    /// text relayout only happens when the visible character count actually changes,
    /// not on every one of the pump's ~72 ticks a second.
    private struct Typer {
        let view: TextEditorView
        let text: [Character]
        let start: Double
        let charsPerSecond: Double
        let endTime: Double?
        var shown: Int
        var caretOn: Bool
    }
    private var typers: [String: Typer] = [:]

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
        // Every sketch that ever runs needs a live canvas, and a WKWebView carrying a
        // 205KB library is nowhere near cheap enough to build inside a tick. Count them
        // from the timeline and stand them all up now, with a couple spare for the
        // windows the viewer is allowed to close and respawn.
        var liveSketches = 0
        for ev in events {
            if case .openWindow(let p) = ev.action,
               p.content.kind == "livecode", p.content.running ?? true {
                liveSketches += 1
            }
        }
        HydraWeb.prewarm(count: liveSketches + 2)

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

    // MARK: - Authoring aids (pause inspection — never part of the piece)

    /// True while the inspect overlay is on, so windows opened later get badged too.
    private(set) var inspecting = false

    /// Halt — or release — every Core Animation timeline the show has running.
    ///
    /// Stopping the pump freezes everything the pump drives (moves, jiggles, sprites,
    /// typers), but the livecode visuals animate on the render server and would sail
    /// straight through a pause. A pause that only stopped the pump would leave the
    /// hydra stack spinning, which is not a still frame and not what you want to judge.
    func setAnimationsPaused(_ paused: Bool) {
        // Live hydra canvases are web views driving their own rAF loop in another
        // process; no CALayer speed reaches them. They have to be told.
        for canvas in liveHydraCanvases() { canvas.setPaused(paused) }

        var layers: [CALayer] = windows.values.compactMap { $0.contentView?.layer }
        layers += flashOverlays.values.compactMap { $0.contentView?.layer }
        for layer in layers {
            if paused {
                guard layer.speed != 0 else { continue }
                layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
            } else {
                guard layer.speed == 0 else { continue }
                let held = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - held
            }
        }
    }

    /// Stamp every live window with its timeline id and the moment it opened, so a
    /// stack of near-identical windows can be told apart and the right one edited.
    func setInspecting(_ on: Bool) {
        inspecting = on
        for (id, win) in windows {
            if on { applyBadge(to: win, id: id) } else { removeBadge(from: win) }
        }
    }

    /// Every live sketch currently on screen. They hang inside a livecode window's
    /// content view, so the window list is the way to reach them.
    private func liveHydraCanvases() -> [HydraCanvasView] {
        func canvases(in view: NSView) -> [HydraCanvasView] {
            if let canvas = view as? HydraCanvasView { return [canvas] }
            return view.subviews.flatMap(canvases)
        }
        return windows.values.compactMap { $0.contentView }.flatMap(canvases)
    }

    /// Frame counts of every live sketch, for `--test-pause`.
    func readHydraTicks(_ done: @escaping ([String]) -> Void) {
        let canvases = liveHydraCanvases()
        guard !canvases.isEmpty else { done([]); return }
        var out: [String] = []
        let group = DispatchGroup()
        for canvas in canvases {
            group.enter()
            canvas.readTicks { value in out.append(value); group.leave() }
        }
        group.notify(queue: .main) { done(out.sorted()) }
    }

    private static let badgeID = NSUserInterfaceItemIdentifier("dpe.inspect.badge")

    private func applyBadge(to win: NSWindow, id: String) {
        guard let content = win.contentView else { return }
        removeBadge(from: win)
        let label = NSTextField(labelWithString: openedAt[id].map {
            String(format: "%@ · %.2fs", id, $0)
        } ?? id)
        label.identifier = WindowManager.badgeID
        label.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.backgroundColor = .systemPink
        label.drawsBackground = true
        label.alignment = .center
        label.sizeToFit()
        let size = label.frame.size
        // Top-left, inside the window. Not flipped, so the top edge is max-y.
        label.frame = NSRect(x: 0, y: content.bounds.height - size.height,
                             width: size.width + 8, height: size.height)
        label.autoresizingMask = [.minYMargin, .maxXMargin]
        content.addSubview(label)
    }

    /// What the inspect overlay is actually showing right now, read back off the live
    /// view hierarchy (not from bookkeeping), plus whether each window's animations are
    /// really frozen. Used by `--test-pause` to prove the overlay and the freeze landed.
    var inspectSummary: [String] {
        windows.keys.sorted().map { id in
            let win = windows[id]
            let badge = (win?.contentView?.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier == WindowManager.badgeID }?.stringValue) ?? "—"
            let speed = win?.contentView?.layer?.speed ?? -1
            return "\(id): badge=\"\(badge)\" layerSpeed=\(speed)"
        }
    }

    private func removeBadge(from win: NSWindow) {
        win.contentView?.subviews
            .filter { $0.identifier == WindowManager.badgeID }
            .forEach { $0.removeFromSuperview() }
    }

    // MARK: - Executors

    func openWindow(_ p: OpenWindowParams, at now: Double) {
        let scr = screen(p.screen)
        openedAt[p.id] = now
        let frame = rect(from: p.frame, on: scr)
        jiggles[p.id] = nil
        moves[p.id] = nil
        respawns[p.id] = (p.respawn == true) ? p : nil
        // Reuse the existing window if this id is being re-opened — swapping the
        // content view + frame avoids the expensive NSWindow create/destroy that
        // otherwise dominates a dense strobe. (Re-opening the same id is also how a
        // livecode window goes from "written" to "running".)
        if let existing = windows[p.id] as? EffectWindow {
            existing.setFrame(frame, display: false)
            existing.contentView = makeEffectContentView(p.content, size: frame.size)
            arm(existing, p, size: frame.size)
            existing.present(animate: "none")
            if inspecting { applyBadge(to: existing, id: p.id) }   // contentView was swapped
            return
        }
        close(id: p.id)
        let win = EffectWindow(contentRect: frame, content: p.content)
        arm(win, p, size: frame.size)
        windows[p.id] = win
        win.present(animate: p.animate?.kind ?? "fadeIn")
        if inspecting { applyBadge(to: win, id: p.id) }
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
            // Keep the authored open time across the respawn — the badge should name
            // the timeline event this window came from, not when the viewer closed it.
            let authored = self.openedAt[p.id] ?? 0
            self.close(id: p.id)
            guard let again = again else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.respawnGeneration == generation else { return }
                self.openWindow(again, at: authored)
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

    /// The typewriter: reveal however many characters the tempo says we should be at
    /// by now, and blink the caret at 2 Hz.
    func beginTyping(_ p: TypeTextParams, at now: Double, bpm: Double) {
        let scr = screen(p.screen)
        let frame = rect(from: p.frame, on: scr)
        close(id: p.id)
        let view = TextEditorView(size: frame.size, title: p.title,
                                  fontSize: CGFloat(p.fontSize ?? 13))
        let win = HostedEffectWindow(contentRect: frame, view: view)
        // Draggable, but with no close zone armed: the letter can be shoved around
        // while it writes itself, and can't be dismissed by accident.
        if p.interactive == true { win.makeInteractive(size: frame.size) }
        windows[p.id] = win
        win.present(animate: "fadeIn")
        let cps = max(0.5, (p.charsPerBeat ?? 16) * bpm / 60.0)
        let trim = p.durationSeconds ?? p.durationBeats.map { $0 * 60.0 / bpm }
        typers[p.id] = Typer(view: view, text: Array(p.text), start: now,
                             charsPerSecond: cps, endTime: trim.map { now + $0 },
                             shown: -1, caretOn: true)
        view.render("", caret: true)
    }

    private func updateTypers(now: Double) {
        for (id, var t) in typers {
            guard windows[id] != nil else { typers[id] = nil; continue }
            if let end = t.endTime, now >= end { typers[id] = nil; continue }
            let want = min(t.text.count, max(0, Int((now - t.start) * t.charsPerSecond)))
            let caret = Int((now - t.start) * 2) % 2 == 0
            guard want != t.shown || caret != t.caretOn else { continue }
            t.shown = want
            t.caretOn = caret
            typers[id] = t
            t.view.render(String(t.text[0..<want]), caret: caret)
        }
    }

    /// Called every pump tick to advance active moves and jiggles.
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
        openedAt[id] = nil
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
        openedAt.removeAll()
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

    private func screen(_ index: Int?) -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        let i = index ?? 0
        return (i >= 0 && i < screens.count) ? screens[i] : (NSScreen.main ?? screens[0])
    }

    /// Interpret `[x, y, w, h]` as top-left origin relative to `screen`, converting
    /// to AppKit's bottom-left global coordinates.
    /// `[x, y, w, h]`, top-left origin relative to `screen`. NEGATIVE x/y anchor to the
    /// far edge (screen-size-independent): x < 0 measures from the right, y < 0 from the
    /// bottom — so `[40, -40, …]` is "40 pt from the left, 40 pt up from the bottom"
    /// (lower-left corner) regardless of resolution.
    private func rect(from frame: [Double], on screen: NSScreen, fallbackSize: NSSize? = nil) -> NSRect {
        let sf = screen.frame
        let x = frame.count > 0 ? frame[0] : 0
        let topY = frame.count > 1 ? frame[1] : 0
        let w = frame.count > 2 ? frame[2] : (fallbackSize?.width ?? 300)
        let h = frame.count > 3 ? frame[3] : (fallbackSize?.height ?? 200)
        let originX = x >= 0 ? sf.minX + x : sf.maxX + x - w
        let originY = topY >= 0 ? sf.maxY - topY - h    // from top
                                : sf.minY - topY         // from bottom (topY negative)
        return NSRect(x: originX, y: originY, width: w, height: h)
    }
}
