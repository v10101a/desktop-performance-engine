import AppKit

/// A swarm of pointers chasing the viewer's own pointer.
///
/// Every particle is a Mac arrow cursor — any size, from a speck to bigger than the real
/// one — steering toward wherever the mouse actually is and turning to face the way it
/// is going. The real cursor is the only thing on screen the viewer still controls, and
/// this is the piece noticing it.
///
/// The target is `NSEvent.mouseLocation`, so it follows the pointer whether the VIEWER
/// is moving it or the show is (`cursorPath` drives it elsewhere in the piece) — it
/// chases the pointer, not the person.
final class CursorSwarmView: NSView {
    private struct Pointer {
        var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
        var size = 0.0
        var maxSpeed = 0.0
        var accel = 0.0
        var angle = 0.0                 // last heading, kept for when it is standing still
    }

    private var swarm: [Pointer] = []
    private var layers: [CALayer] = []
    private var rng: SplitMix64
    private var timer: Timer?
    private var started = CACurrentMediaTime()
    private var stepped = 0
    /// Where the real pointer was last seen, in this view's coordinates.
    private var target = CGPoint(x: 0, y: 0)

    private static let dt = 1.0 / 60.0

    /// The arrow, drawn ONCE at this size and scaled DOWN by each layer. Cursors here go
    /// up to ~90pt and a scaled-up 24pt system cursor image is mush at that size; drawn
    /// large and shrunk, every one of them is crisp.
    private static let master: CGFloat = 256

    init(size: NSSize, seed: Int, count: Int) {
        rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 3 : seed)))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let art = CursorSwarmView.arrowImage(side: CursorSwarmView.master)
        target = CGPoint(x: size.width / 2, y: size.height / 2)

        for _ in 0..<max(1, count) {
            var p = Pointer()
            p.x = rand(0, Double(size.width))
            p.y = rand(0, Double(size.height))
            // Any size. The spread is deliberately wide rather than a tight band: a
            // swarm of near-identical arrows reads as a texture, and the big ones
            // arriving late behind the small ones is the whole picture.
            p.size = rand(11, 92)
            // Small ones are quick and twitchy, big ones are heavy and late. Tying both
            // to size is what turns a cloud of dots into a thing with weight.
            let u = (p.size - 11) / 81
            p.maxSpeed = rand(520, 900) * (1.0 - 0.45 * u)
            p.accel = rand(900, 1700) * (1.0 - 0.5 * u)
            p.vx = rand(-120, 120)
            p.vy = rand(-120, 120)
            swarm.append(p)

            let l = CALayer()
            l.contents = art
            // The tip, not the middle: a cursor pivots about its point, and rotating one
            // about its centre makes it swing like a compass needle instead of turning.
            l.anchorPoint = CursorSwarmView.tipAnchor
            l.bounds = CGRect(x: 0, y: 0, width: p.size, height: p.size)
            l.contentsGravity = .resizeAspect
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(l)
            layers.append(l)
        }

        let t = Timer(timeInterval: CursorSwarmView.dt, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil }
    }

    /// Scenery. It reads the pointer's position; it must never take its clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rand(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(rng.next() % 1_000_000) / 1_000_000.0
    }

    // MARK: - Chase

    private func tick() {
        // Where the real pointer is, in this view's space. Read here rather than in
        // `step` so a catch-up of several steps chases one position instead of pretending
        // the mouse teleported between them.
        if let win = window {
            let inWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
            target = convert(inWindow, from: nil)
        }
        let want = Int((CACurrentMediaTime() - started) / CursorSwarmView.dt)
        var budget = min(max(0, want - stepped), 8)
        while budget > 0 { step(); stepped += 1; budget -= 1 }
        draw()
    }

    private func step() {
        let dt = CursorSwarmView.dt
        for i in swarm.indices {
            let dx = Double(target.x) - swarm[i].x
            let dy = Double(target.y) - swarm[i].y
            let d = max(1, (dx * dx + dy * dy).squareRoot())
            // Steer toward the desired velocity rather than snapping to it, so they
            // arc in and overshoot instead of converging on a point and stopping dead.
            let desiredX = dx / d * swarm[i].maxSpeed
            let desiredY = dy / d * swarm[i].maxSpeed
            let ax = (desiredX - swarm[i].vx)
            let ay = (desiredY - swarm[i].vy)
            let am = max(1, (ax * ax + ay * ay).squareRoot())
            let k = min(1.0, swarm[i].accel * dt / am)
            swarm[i].vx += ax * k
            swarm[i].vy += ay * k
            swarm[i].x += swarm[i].vx * dt
            swarm[i].y += swarm[i].vy * dt
            // Face the way it is going, and HOLD that heading when it is barely moving:
            // atan2 on a near-zero velocity is noise, and a stalled cursor spinning on
            // the spot is the tell that this is a particle system.
            let speed = (swarm[i].vx * swarm[i].vx + swarm[i].vy * swarm[i].vy).squareRoot()
            if speed > 12 { swarm[i].angle = atan2(swarm[i].vy, swarm[i].vx) }
        }
    }

    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, p) in swarm.enumerated() {
            let l = layers[i]
            l.position = CGPoint(x: p.x, y: p.y)
            l.setAffineTransform(
                CGAffineTransform(rotationAngle: CGFloat(p.angle - CursorSwarmView.artAngle)))
        }
        CATransaction.commit()
    }

    // MARK: - The arrow

    /// The Mac pointer: the canonical outline, black body with a white keyline so it
    /// reads on any background.
    ///
    /// Drawn in the shape's OWN orientation — tip up and to the left, like the real one
    /// — rather than straightened to point up. A straightened arrow is easier to rotate
    /// and stops looking like a cursor, which is the entire idea here.
    ///
    /// Coordinates are the standard pointer polygon in a y-DOWN unit box with the tip at
    /// the origin, shifted into the box so the keyline has room; NSBezierPath is y-up,
    /// hence the flip.
    private static let poly: [(Double, Double)] = [
        (0.00, 0.00),   // the tip
        (0.00, 0.72), (0.20, 0.55), (0.33, 0.85),
        (0.46, 0.79), (0.33, 0.51), (0.55, 0.51),
    ]
    private static let inset = (x: 0.22, y: 0.07)

    /// Which way the drawn arrow points, as an angle. It is the bisector of the two
    /// edges meeting at the tip, which for this outline is up and to the left — NOT
    /// straight up, and not a number worth guessing. `draw` subtracts it to turn a
    /// heading into a rotation.
    static let artAngle: Double = {
        let tip = (x: poly[0].0, y: -poly[0].1)
        let a = (x: poly[1].0 - tip.x, y: -poly[1].1 - tip.y)
        let b = (x: poly[6].0 - tip.x, y: -poly[6].1 - tip.y)
        let na = (a.x * a.x + a.y * a.y).squareRoot(), nb = (b.x * b.x + b.y * b.y).squareRoot()
        // Away from the average of the two edges is the way the point faces.
        return atan2(-(a.y / na + b.y / nb), -(a.x / na + b.x / nb))
    }()

    /// The tip's position in the square, as CALayer anchor coordinates (y up). A cursor
    /// pivots about its point.
    static var tipAnchor: CGPoint {
        CGPoint(x: inset.x + poly[0].0, y: 1.0 - (inset.y + poly[0].1))
    }

    static func arrowImage(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let path = NSBezierPath()
        for (i, p) in poly.enumerated() {
            let q = NSPoint(x: (inset.x + p.0) * side, y: (1.0 - (inset.y + p.1)) * side)
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close()
        NSColor.white.setStroke()
        path.lineWidth = max(1.5, side * 0.045)
        path.lineJoinStyle = .round
        path.stroke()
        NSColor.black.setFill()
        path.fill()
        image.unlockFocus()
        return image
    }

    /// Test seams.
    var countForTesting: Int { swarm.count }
    var sizesForTesting: [Double] { swarm.map(\.size) }
    var headingsForTesting: [Double] { swarm.map(\.angle) }
    var spreadForTesting: Int {
        guard swarm.count > 1 else { return 0 }
        let xs = swarm.map(\.x)
        return Int((xs.max()! - xs.min()!).rounded())
    }
}
