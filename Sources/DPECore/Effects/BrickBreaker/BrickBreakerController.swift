import AppKit

/// Brick breaker, played with the machine's own furniture.
///
/// Every brick is a real window — the same drawn chrome the rest of the piece opens, in
/// the show's palette — the ball is the system's beach ball, all fifteen frames of it,
/// and the paddle follows the viewer's actual pointer. Nothing here is a picture of a
/// game: the bricks are windows going off the screen one at a time, which is the same
/// sentence the rest of the show is written in.
///
/// **It plays itself if nobody plays it.** The ball launches on the frame the event
/// fires and never waits for a click, the paddle simply is wherever the mouse is, and a
/// ball that gets past the paddle is served again rather than ending anything. A cue
/// cannot stall waiting for a viewer who is not touching the machine.
///
/// **Its own 60 Hz timer, not the pump.** The pump is vsync-driven, coalesced and
/// throttled to ~72 Hz, and it is carrying the whole show; physics that inherits its
/// hitches reads as a ball that sticks. The simulation is stepped at a fixed dt against
/// wall time, like every other live view here.
final class BrickBreakerController {
    private struct Brick {
        let window: EffectWindow
        let rect: NSRect
        var alive = true
        var fading = false
    }

    private var id: String?
    private var bricks: [Brick] = []
    private var ballWindow: BaseEffectWindow?
    private var ballLayer: CALayer?
    private var ballFrames: [CGImage] = []
    private var paddleWindow: EffectWindow?

    private var area = NSRect.zero
    private var ball = CGPoint.zero
    private var vel = CGVector.zero
    private var ballSize: CGFloat = 44
    private var paddleSize = NSSize(width: 190, height: 26)
    private var paddleX: CGFloat = 0
    private var speed: Double = 520
    private var rng = SplitMix64(seed: 44)
    private var layout = (rows: 4, cols: 8, content: [ContentSpec]())

    private var timer: Timer?
    private var started = CACurrentMediaTime()
    private var stepped = 0
    /// Set when the last brick goes; the rack comes back a beat later so the game keeps
    /// going for as long as the cue holds it.
    private var reRackAt: Double?

    private static let dt = 1.0 / 60.0

    // MARK: - Lifecycle

    func start(_ p: BrickBreakerParams) {
        closeAll()
        id = p.id
        let screen = ScreenGeometry.screen(p.screen)
        area = ScreenGeometry.rectOrCentred(p.frame, size: NSSize(width: 1440, height: 900),
                                            on: screen)
        rng = SplitMix64(seed: UInt64(bitPattern: Int64(p.seed ?? 44)))
        let (sx, _) = ScreenGeometry.scale(for: screen)
        ballSize = CGFloat((p.ball ?? 44) * sx)
        paddleSize = NSSize(width: CGFloat((p.paddle?.first ?? 190) * sx),
                            height: CGFloat((p.paddle?.last ?? 26) * sx))
        speed = (p.speed ?? 520) * sx
        layout.rows = max(1, p.rows ?? 4)
        layout.cols = max(1, p.cols ?? 8)

        rack()
        buildPaddle()
        buildBall()
        serve()

        let t = Timer(timeInterval: BrickBreakerController.dt, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        started = CACurrentMediaTime()
        stepped = 0
    }

    func stop(id which: String) {
        guard which == id else { return }
        closeAll()
    }

    /// Idempotent, and it has to be: stop, seek, quit and the panic key all land here.
    func closeAll() {
        timer?.invalidate()
        timer = nil
        for b in bricks { b.window.orderOut(nil); b.window.close() }
        bricks.removeAll()
        ballWindow?.orderOut(nil)
        ballWindow = nil
        ballLayer = nil
        paddleWindow?.orderOut(nil)
        paddleWindow = nil
        reRackAt = nil
        id = nil
    }

    func update(now: Double) {}      // the game keeps its own clock — see the type note

    // MARK: - Building the table

    /// The wall of bricks. Windows, with the drawn chrome and the palette the rest of
    /// the piece uses, so the wall reads as the machine's own clutter racked up rather
    /// than as game furniture that wandered in.
    /// ALL THIRTY-TWO ON ONE FRAME, on purpose. Racking them up one at a time over the
    /// bar before was tried (2026-09-12) and measured far WORSE — the second before the
    /// cue fell from over 60 Hz to 3 — because what a window's first appearance costs is
    /// paid per run-loop commit, not per window: thirty-two in one pass is one commit,
    /// thirty-two across a bar is thirty-two. Born together they cost one 38 Hz second.
    private func rack() {
        for b in bricks { b.window.orderOut(nil); b.window.close() }
        bricks.removeAll()
        let palette = ["#020AF5", "#68BDF8", "#F2F4FE", "#0078D7", "#0B0E16"]
        let titles = ["look://again", "haunt.sh", "recovered.jpg", "Untitled", "brick.app"]
        let inset = area.width * 0.04
        let top = area.maxY - area.height * 0.10
        let gridW = area.width - inset * 2
        let cellW = gridW / CGFloat(layout.cols)
        let cellH = (area.height * 0.34) / CGFloat(layout.rows)
        let pad = min(cellW, cellH) * 0.10

        for r in 0..<layout.rows {
            for c in 0..<layout.cols {
                let rect = NSRect(x: area.minX + inset + CGFloat(c) * cellW + pad / 2,
                                  y: top - CGFloat(r + 1) * cellH + pad / 2,
                                  width: cellW - pad, height: cellH - pad)
                let spec = ContentSpec(kind: "color",
                                       hex: palette[(r * layout.cols + c) % palette.count],
                                       chrome: "mixed",
                                       title: titles[(r + c) % titles.count])
                let win = EffectWindow(contentRect: rect, content: spec)
                win.present(animate: "none")
                bricks.append(Brick(window: win, rect: rect))
            }
        }
    }

    private func buildPaddle() {
        let rect = NSRect(x: area.midX - paddleSize.width / 2,
                          y: area.minY + area.height * 0.06,
                          width: paddleSize.width, height: paddleSize.height)
        let spec = ContentSpec(kind: "color", hex: "#F2F4FE", chrome: "none")
        let win = EffectWindow(contentRect: rect, content: spec)
        win.present(animate: "none")
        paddleWindow = win
        paddleX = rect.midX
    }

    private func buildBall() {
        ballFrames = MandalaView.beachballFrames(side: 128)
        let rect = NSRect(x: area.midX - ballSize / 2, y: area.midY,
                          width: ballSize, height: ballSize)
        let win = BaseEffectWindow(contentRect: rect)
        win.ignoresMouseEvents = true
        win.hasShadow = false
        let host = NSView(frame: NSRect(origin: .zero, size: rect.size))
        host.wantsLayer = true
        let l = CALayer()
        l.frame = host.bounds
        l.contents = ballFrames.first
        l.contentsGravity = .resizeAspect
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        host.layer?.addSublayer(l)
        win.contentView = host
        win.orderFrontRegardless()
        ballWindow = win
        ballLayer = l
    }

    /// Put the ball back in the middle and send it off. Always downward and always at
    /// an angle — a ball served straight down bounces up and down the same column until
    /// the paddle happens to be under it, which looks broken rather than hard.
    private func serve() {
        ball = CGPoint(x: area.midX, y: area.midY - area.height * 0.05)
        let lean = Double(rng.next() % 1000) / 1000.0 * 0.7 + 0.35   // 0.35…1.05 rad
        let dir: Double = (rng.next() % 2 == 0) ? 1 : -1
        vel = CGVector(dx: cos(lean) * speed * dir, dy: -sin(lean) * speed)
    }

    // MARK: - Playing

    private func tick() {
        // The paddle IS the pointer: no click, no focus, no window to hit. Whoever is at
        // the machine is already playing whether they meant to be or not.
        paddleX = NSEvent.mouseLocation.x
        let want = Int((CACurrentMediaTime() - started) / BrickBreakerController.dt)
        var budget = min(max(0, want - stepped), 8)
        while budget > 0 { step(); stepped += 1; budget -= 1 }
        draw()
    }

    private func step() {
        let dt = BrickBreakerController.dt
        if let due = reRackAt {
            if CACurrentMediaTime() >= due { reRackAt = nil; rack(); serve() }
            return
        }

        ball.x += vel.dx * dt
        ball.y += vel.dy * dt
        let r = ballSize / 2

        // Walls. The top and the sides are the play area's edges; the bottom is not a
        // wall, it is where a missed ball goes.
        if ball.x - r < area.minX { ball.x = area.minX + r; vel.dx = abs(vel.dx) }
        if ball.x + r > area.maxX { ball.x = area.maxX - r; vel.dx = -abs(vel.dx) }
        if ball.y + r > area.maxY { ball.y = area.maxY - r; vel.dy = -abs(vel.dy) }

        // The paddle. Where it hits decides the angle out — the edges throw it wide —
        // so a player has some say in it rather than watching a mirror bounce.
        let paddleRect = currentPaddleRect()
        if vel.dy < 0, ball.y - r < paddleRect.maxY, ball.y > paddleRect.minY,
           ball.x > paddleRect.minX - r, ball.x < paddleRect.maxX + r {
            ball.y = paddleRect.maxY + r
            let offset = (ball.x - paddleRect.midX) / max(1, paddleRect.width / 2)
            let angle = Double(max(-1, min(1, offset))) * 1.0            // ±57°
            vel = CGVector(dx: sin(angle) * speed, dy: cos(angle) * speed)
        }

        // Missed. Served again, immediately: this is scenery with a pulse, not a game
        // that can be lost while the track keeps playing.
        if ball.y + r < area.minY { serve() }

        // Bricks. The axis it bounces on is whichever overlap is shallower, which is the
        // cheap way to get a corner hit to behave.
        for i in bricks.indices where bricks[i].alive {
            let b = bricks[i].rect
            guard ball.x + r > b.minX, ball.x - r < b.maxX,
                  ball.y + r > b.minY, ball.y - r < b.maxY else { continue }
            let overlapX = min(ball.x + r - b.minX, b.maxX - (ball.x - r))
            let overlapY = min(ball.y + r - b.minY, b.maxY - (ball.y - r))
            if overlapX < overlapY {
                vel.dx = ball.x < b.midX ? -abs(vel.dx) : abs(vel.dx)
            } else {
                vel.dy = ball.y < b.midY ? -abs(vel.dy) : abs(vel.dy)
            }
            bricks[i].alive = false
            fade(bricks[i].window)
            break                                    // one brick per step, never a chain
        }

        if !bricks.contains(where: \.alive) && reRackAt == nil {
            reRackAt = CACurrentMediaTime() + 0.9
        }
    }

    /// A hit brick dissolves rather than vanishing — the same quarter-second the wipe
    /// uses. A window that blinks out on the frame it is hit reads as a dropped frame.
    private func fade(_ win: NSWindow) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            win.animator().alphaValue = 0
        }, completionHandler: { win.orderOut(nil) })
    }

    private func currentPaddleRect() -> NSRect {
        let x = max(area.minX, min(paddleX - paddleSize.width / 2,
                                   area.maxX - paddleSize.width))
        return NSRect(x: x, y: area.minY + area.height * 0.06,
                      width: paddleSize.width, height: paddleSize.height)
    }

    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let ballWindow {
            ballWindow.setFrameOrigin(NSPoint(x: ball.x - ballSize / 2, y: ball.y - ballSize / 2))
            // The ball SPINS: it is the system's spinner, and a still one is a sticker.
            if ballFrames.count > 1, let l = ballLayer {
                let f = Int((CACurrentMediaTime() - started) * 30) % ballFrames.count
                l.contents = ballFrames[f]
            }
        }
        paddleWindow?.setFrameOrigin(currentPaddleRect().origin)
        CATransaction.commit()
    }

    // MARK: - Test seams

    var isPlaying: Bool { timer != nil }
    var bricksAlive: Int { bricks.filter(\.alive).count }
    var ballPosition: CGPoint { ball }
    var ballSpeed: Double { (vel.dx * vel.dx + vel.dy * vel.dy).squareRoot() }
    func stepForTesting(_ n: Int) { for _ in 0..<n { step() } }
    func setPaddleForTesting(x: CGFloat) { paddleX = x }
    func startForTesting(_ p: BrickBreakerParams) {
        start(p)
        timer?.invalidate()      // stepped by hand, so the test is not a race
        timer = nil
    }
}
