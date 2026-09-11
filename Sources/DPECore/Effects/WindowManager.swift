import AppKit

/// Owns every window the show spawns, keyed by author-supplied id so later events
/// can close them and panic/restore can wipe them all at once.
/// Some members below are module-internal rather than private: the sprite, trail,
/// typing and motion subsystems live in `WindowManager+*.swift`, and a Swift extension
/// in another file cannot see `private`. Everything not touched by those four files
/// stays private. See the header of any of them for why the split is organisational.
final class WindowManager {
    var windows: [String: NSWindow] = [:]

    /// Timeline position each live window opened at, for the inspect badges.
    /// Same keys as `windows`.
    private var openedAt: [String: Double] = [:]
    /// One counter per id, bumped by every open and close. A dissolve's completion
    /// carries the value it started with and does nothing if it no longer matches —
    /// otherwise a window re-opened mid-fade would be ordered out by the old fade.
    private var fadeToken: [String: Int] = [:]

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

    /// Every window this manager has open, **back to front**, as (screen frame, label).
    ///
    /// Read by `AsciiLogView`'s window map, which draws these as box art instead of
    /// capturing the screen — the engine opened them, so it already knows where they are,
    /// and capturing would need Screen Recording that the cut is not allowed to ask for.
    ///
    /// Ordered back to front by `NSWindow.orderedIndex` (0 is frontmost), because the map
    /// draws later boxes over earlier ones and the overlaps only read correctly in the
    /// order the window server composites in.
    ///
    /// It walks THIS DICTIONARY, not `NSApp.orderedWindows`. The obvious version asked
    /// AppKit for the ordered list and intersected it with ours, and it came back empty
    /// every time — measured, `provider gave 0 rects` with three windows plainly on
    /// screen. `orderedWindows` does not list these: they are borderless, non-activating
    /// panels ordered in with `orderFrontRegardless`, and the app's window list is not
    /// where they live. The manager's own dictionary is the authority on what the show
    /// has open; `orderedIndex` is only used to sort it.
    ///
    /// The label is the window's ID — `w3`, `d1`, `sl7`. Not a shortcut: these wear DRAWN
    /// chrome, so `NSWindow.title` is empty on all of them, and the id is what the machine
    /// calls the thing. A window map captioned with the show's own internal handles is the
    /// machine looking at itself, which is the act.
    func asciiSnapshot(excluding asking: NSWindow? = nil) -> [(NSRect, String)] {
        // Openness is THIS DICTIONARY, not `isVisible`. `close(id:)` nils the entry, so a
        // tracked window is by definition one the show has open — and `isVisible` came
        // back false for every one of them with three plainly on screen (measured:
        // "3 tracked, 0 visible"). These are borderless panels ordered in with
        // `orderFrontRegardless`, and AppKit's idea of visible does not cover them.
        //
        // `alphaValue` is the one real filter: windows mid-fade on their way out are
        // still tracked for a moment after they stop being anything to look at.
        windows
            .filter { $0.value.alphaValue > 0.01 && $0.value !== asking }
            .sorted { $0.value.orderedIndex > $1.value.orderedIndex }   // back → front
            .map { ($0.value.frame, $0.key) }
    }

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

    /// A window writing itself out. `shown` is cached so the (relatively costly) text
    /// relayout only happens when the visible character count actually changes, not on
    /// every one of the pump's ~72 ticks a second.
    struct Typer {
        let sink: TypedTextSink
        let text: [Character]
        /// The character counts the copy pauses at, in order: every character when it
        /// types by the character, the end of each line when it types by the line. The
        /// credits' own scheme — see `CreditsController.advanceTyping`.
        let stops: [Int]
        let byLine: Bool
        let start: Double
        /// Stops per second: characters or whole lines, per `byLine`.
        let unitsPerSecond: Double
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
                let win = EffectWindow(contentRect: rect(from: p.frame, on: screen(p.screen),
                                                         anchor: p.anchor),
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
        cancelFade(p.id)
        let frame = rect(from: p.frame, on: scr, anchor: p.anchor)
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
            existing.level = WindowManager.level(p.level)
            existing.applyContent(p.content, frame: frame)
            arm(existing, p, size: frame.size)
            existing.present(animate: "none")
            if inspecting { applyBadge(to: existing, id: p.id) }   // contentView was swapped
            return
        }
        close(id: p.id)
        let win = EffectWindow(contentRect: frame, content: p.content)
        win.level = WindowManager.level(p.level)
        arm(win, p, size: frame.size)
        windows[p.id] = win
        win.present(animate: p.animate?.kind ?? "fadeIn")
        if inspecting { applyBadge(to: win, id: p.id) }
    }

    /// The window levels a timeline can ask for. `.normal` is the show: everything
    /// stacks in the order it opened. `.floating` sits above all of that — including
    /// the `screenFlash` overlays, which are themselves normal windows — so a layer
    /// marked floating stays visible through everything opened after it. `front` is the
    /// shielding level, above even the menu bar.
    static func level(_ name: String?) -> NSWindow.Level {
        switch name {
        case "floating": return .floating
        case "front":    return NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Under everything the show opens, still over the desktop picture. For a layer
        // that is meant to be covered — cue 21's swarm, which the torus, the ring and the
        // video slot all land on top of.
        case "below":    return NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        default:         return .normal
        }
    }

    /// Snap a window out of a dissolve: bump the token so the fade's completion is a
    /// no-op, and put the alpha back with a zero-length animation, which replaces the
    /// one still running rather than being overwritten by it.
    private func cancelFade(_ id: String) {
        fadeToken[id] = (fadeToken[id] ?? 0) &+ 1
        guard let win = windows[id], win.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            win.animator().alphaValue = 1
        }
    }

    /// Hand a window to the viewer if the event asked for it: draggable, and closable
    /// by its fake traffic lights. A `respawn` window comes straight back.
    private func arm(_ win: EffectWindow, _ p: OpenWindowParams, size: NSSize) {
        let interactive = p.interactive == true
        // A window with a real title bar gets a live close button even when it is
        // otherwise scenery — clicking the traffic light closes it. A bare (`chrome:
        // "none"`) window has no close button, so it stays click-through unless the event
        // asked for `interactive`.
        guard interactive || win.isNativeChrome else {
            win.onUserClose = nil
            return
        }
        if interactive {
            win.makeInteractive(size: size)         // drag + mouse (native drags by its bar)
        } else {
            win.ignoresMouseEvents = false          // enough to reach the native close button
        }
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
        // Any button dismisses the dialog — OK, Cancel, or whatever the cue named.
        let dismiss: (String) -> Void = { [weak self] _ in self?.close(id: p.id) }
        if let existing = windows[p.id] as? FakeDialogWindow {
            existing.setFrame(frame, display: false)
            existing.contentView = makeDialogContentView(title: p.title, message: p.body,
                                                         buttons: p.buttons ?? ["OK"],
                                                         icon: p.dialogIcon, size: frame.size,
                                                         onButton: dismiss)
            existing.present(animate: "none")
            return
        }
        close(id: p.id)
        let win = FakeDialogWindow(contentRect: frame,
                                   title: p.title,
                                   message: p.body,
                                   buttons: p.buttons ?? ["OK"],
                                   icon: p.dialogIcon,
                                   onButton: dismiss)
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

    /// `fadeSeconds` dissolves the window instead of cutting it. The window keeps its
    /// place in `windows` for the length of the fade, so `closeAll` — stop, quit, the
    /// panic key — still sweeps it instantly: a dissolve in flight can never be the
    /// thing that leaves something on the viewer's screen.
    func close(id: String, fadeSeconds: Double = 0) {
        jiggles[id] = nil
        moves[id] = nil
        typers[id] = nil
        openedAt[id] = nil
        let token = (fadeToken[id] ?? 0) &+ 1     // orphans any fade already running
        fadeToken[id] = token
        if let s = sprites.removeValue(forKey: id) {
            for w in s.pool { w.orderOut(nil) }
        }
        if let t = trails.removeValue(forKey: id) {
            for w in t.stamps { w.orderOut(nil) }
            for w in t.pool { w.orderOut(nil) }
        }
        guard let win = windows[id] else { return }
        guard fadeSeconds > 0 else {
            win.orderOut(nil)
            windows[id] = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeSeconds
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak win] in
            guard let self = self, let win = win, self.fadeToken[id] == token else { return }
            win.orderOut(nil)
            win.alphaValue = 1                   // a reused id gets a clean window back
            if self.windows[id] === win { self.windows[id] = nil }
        })
    }

    func closeAll() {
        fadeToken.removeAll()       // every dissolve in flight is now orphaned
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

    func screen(_ index: Int?) -> NSScreen { ScreenGeometry.screen(index) }

    func rect(from frame: [Double], on screen: NSScreen, anchor: String? = nil,
                      fallbackSize: NSSize? = nil) -> NSRect {
        ScreenGeometry.rect(from: frame, on: screen, anchor: anchor, fallbackSize: fallbackSize)
    }
}
