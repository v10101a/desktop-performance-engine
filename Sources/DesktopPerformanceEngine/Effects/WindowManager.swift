import AppKit

/// Owns every window the show spawns, keyed by author-supplied id so later events
/// can close them and panic/restore can wipe them all at once.
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    /// Set from the loaded timeline so beat-based durations resolve to seconds.
    var bpm: Double = 120

    var count: Int { windows.count }

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

    /// Called every pump tick to advance active moves and jiggles.
    func update(now: Double) {
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
        guard let win = windows[id] else { return }
        win.orderOut(nil)
        windows[id] = nil
    }

    func closeAll() {
        jiggles.removeAll()
        moves.removeAll()
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
