import AppKit

/// A swarm of pointers: chasing the viewer's own pointer, or schooling like fish.
///
/// Every particle is a Mac arrow cursor — any size, from a speck to bigger than the real
/// one — steering toward wherever the mouse actually is and turning to face the way it
/// is going. The real cursor is the only thing on screen the viewer still controls, and
/// this is the piece noticing it.
///
/// The target is `NSEvent.mouseLocation`, so it follows the pointer whether the VIEWER
/// is moving it or the show is (`cursorPath` drives it elsewhere in the piece) — it
/// chases the pointer, not the person.
///
/// `.school` is the other reading of the same particles, and the one cue 28 uses: they
/// are laid out on a spiral and then flock — Reynolds' three rules over a vortex — so
/// the pointer the viewer owns is no longer the thing they want. Nothing about the
/// pointer is read in that mode at all.
final class CursorSwarmView: NSView {
    /// How the swarm moves. `.chase` is the pointer-hunting swarm of cues 24–25.
    enum Mode: String {
        case chase, school
        init(_ name: String?) { self = Mode(rawValue: name ?? "") ?? .chase }
    }

    private struct Pointer {
        var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
        var size = 0.0
        var maxSpeed = 0.0
        var accel = 0.0
        var angle = 0.0                 // last heading, kept for when it is standing still
        var bornAt = 0.0                // seconds after the window opens that it arrives
    }

    private let mode: Mode
    /// School only: which scene this is. See `Pattern`.
    private let pattern: Pattern
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

    /// Seconds over which the swarm arrives, one pointer at a time. 0 is what it did
    /// before: the whole population on the frame the window opens, which lands as a
    /// wall and gives the section it arrives in a hard edge.
    private let ramp: Double

    init(size: NSSize, seed: Int, count: Int, mode: Mode = .chase,
         pattern: Pattern = .spiral, rampSeconds: Double = 0) {
        self.mode = mode
        self.pattern = pattern
        self.ramp = max(0, rampSeconds)
        rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 3 : seed)))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let art = CursorSwarmView.arrowImage(side: CursorSwarmView.master)
        target = CGPoint(x: size.width / 2, y: size.height / 2)

        let n = max(1, count)
        // The shape they arrive on. It is a STARTING shape, not a path — the flocking
        // below is what keeps it — but it is half of what makes a scene: the same
        // weights over a different spawn is a different picture for the second or two
        // that matters when the cuts are this fast.
        let W = Double(size.width), H = Double(size.height)
        let cx = W / 2, cy = H / 2
        let arm = 0.42 * min(W, H)
        for i in 0..<n {
            var p = Pointer()
            p.x = rand(0, W)
            p.y = rand(0, H)
            if mode == .school {
                let f = Double(i) / Double(max(1, n - 1))
                switch pattern {
                case .spiral:
                    // An Archimedean arm from the centre out, walked at a constant
                    // angular step so they are evenly spaced ALONG it.
                    let theta = f * 2.5 * 2 * .pi
                    p.x = cx + cos(theta) * arm * f
                    p.y = cy + sin(theta) * arm * f
                    // Moving along the arm, not out of it: already turning on the frame
                    // it appears.
                    p.vx = -sin(theta) * 180
                    p.vy = cos(theta) * 180
                case .ring:
                    let theta = f * 2 * .pi
                    let r = arm * rand(0.78, 1.0)      // a band, not a wire
                    p.x = cx + cos(theta) * r
                    p.y = cy + sin(theta) * r
                    p.vx = -sin(theta) * 240
                    p.vy = cos(theta) * 240
                case .grid:
                    let cols = max(1, Int(Double(n).squareRoot().rounded()))
                    let rows = max(1, (n + cols - 1) / cols)
                    let gx = Double(i % cols) / Double(max(1, cols - 1))
                    let gy = Double(i / cols) / Double(max(1, rows - 1))
                    p.x = W * (0.15 + 0.7 * gx)
                    p.y = H * (0.15 + 0.7 * gy)
                    p.vx = 200; p.vy = 0                // marching, one heading
                case .burst:
                    // All at the centre, thrown out. A tiny radius rather than a point:
                    // coincident particles have no separation direction to push along.
                    let theta = rand(0, 2 * .pi)
                    p.x = cx + cos(theta) * rand(2, 40)
                    p.y = cy + sin(theta) * rand(2, 40)
                    p.vx = cos(theta) * rand(320, 620)
                    p.vy = sin(theta) * rand(320, 620)
                case .stream:
                    p.x = W * f
                    p.y = cy + rand(-H * 0.18, H * 0.18)
                    p.vx = 300; p.vy = rand(-40, 40)
                }
            }
            // Any size. The spread is deliberately wide rather than a tight band: a
            // swarm of near-identical arrows reads as a texture, and the big ones
            // arriving late behind the small ones is the whole picture.
            p.size = rand(11, 92)
            // Small ones are quick and twitchy, big ones are heavy and late. Tying both
            // to size is what turns a cloud of dots into a thing with weight.
            let u = (p.size - 11) / 81
            p.maxSpeed = rand(520, 900) * (1.0 - 0.45 * u)
            p.accel = rand(900, 1700) * (1.0 - 0.5 * u)
            if mode == .chase {
                p.vx = rand(-120, 120)
                p.vy = rand(-120, 120)
            } else {
                // A shoal is fish of a size. The wide 11–92 spread reads as depth when
                // they are all flying at one target and as noise when they are flocking,
                // so school mode keeps a narrow band — and cruises, rather than sprints.
                p.size = rand(15, 46)
                let v = (p.size - 15) / 31
                p.maxSpeed = rand(190, 290) * (1.0 - 0.25 * v)
                p.accel = rand(600, 1000) * (1.0 - 0.3 * v)
                p.angle = atan2(p.vy, p.vx)
            }
            // Spread arrivals evenly across the ramp. Evenly, not randomly: a random
            // schedule clumps, and what this is for is a section that fills rather than
            // one that starts.
            p.bornAt = n > 1 ? ramp * Double(i) / Double(n - 1) : 0
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
        if mode == .chase, let win = window {
            let inWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
            target = convert(inWindow, from: nil)
        }
        let want = Int((CACurrentMediaTime() - started) / CursorSwarmView.dt)
        var budget = min(max(0, want - stepped), 8)
        while budget > 0 {
            if mode == .school { stepSchool() } else { step() }
            stepped += 1
            budget -= 1
        }
        draw()
    }

    private func step() {
        let dt = CursorSwarmView.dt
        let age = CACurrentMediaTime() - started
        for i in swarm.indices where swarm[i].bornAt <= age {
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

    // MARK: - School

    /// Reynolds' three rules over a vortex. Separation, alignment and cohesion make the
    /// shoal; the vortex — a tangential drive around the centre with a little pull
    /// inward — is what keeps the whole body turning, so the spiral they were spawned on
    /// stays a spiral instead of relaxing into a blob drifting at one heading.
    ///
    /// Every rule is written Reynolds' way: work out the velocity this cursor WANTS,
    /// subtract the one it has, and the difference is a force. Mixing raw position
    /// differences with velocity differences is the usual way boids end up needing
    /// magic weights that only hold at one screen size.
    fileprivate struct School {
        var perception = 130.0     // how far a cursor looks for its neighbours
        var personal = 34.0        // closer than this and it peels away
        var separation = 1.9       // …weighted above the other two: fish don't touch
        var alignment = 1.0
        var cohesion = 0.85
        var vortex = 1.15
        var inward = 0.30          // holds the arm curved instead of flying out
        var margin = 80.0          // turn back this far from the edge
        var edge = 2.4
    }

    /// A named scene: where the cursors start AND how they then behave. The two are one
    /// choice, not two — a ring spawn under the spiral's weights just relaxes into the
    /// spiral, and a grid spawn only reads as a grid while alignment is holding it
    /// together. Cutting between these is cutting between pictures; cutting between
    /// seeds alone is the same picture shuffled.
    ///
    /// Every one of them ignores the viewer's pointer. That is `Mode.school`'s whole
    /// distinction from `.chase`, and it is what these are built on.
    enum Pattern: String, CaseIterable {
        /// The original: an Archimedean arm, vortex-driven, turning as a body.
        case spiral
        /// An annulus with the vortex up and cohesion down — a band that rotates and
        /// keeps its hole instead of filling it in.
        case ring
        /// A lattice held by alignment with the vortex almost off: a block that marches
        /// one way and comes apart at the edges.
        case grid
        /// Everything at the centre, thrown outward, separation high and cohesion low —
        /// an explosion that drifts back together.
        case burst
        /// A line across the screen, alignment high and vortex off: a current.
        case stream

        init(_ name: String?) { self = Pattern(rawValue: name ?? "") ?? .spiral }

        fileprivate var weights: School {
            var s = School()
            switch self {
            case .spiral: break
            case .ring:   s.vortex = 1.9;  s.cohesion = 0.30; s.inward = 0.10; s.separation = 2.2
            case .grid:   s.vortex = 0.10; s.alignment = 2.2; s.cohesion = 0.55; s.personal = 46
            case .burst:  s.vortex = 0.35; s.cohesion = 0.20; s.separation = 3.0; s.alignment = 0.5
            case .stream: s.vortex = 0.0;  s.alignment = 2.6; s.cohesion = 0.40; s.margin = 30
            }
            return s
        }
    }

    private func stepSchool() {
        let dt = CursorSwarmView.dt
        let w = Double(bounds.width), h = Double(bounds.height)
        let cx = w / 2, cy = h / 2
        let School = pattern.weights          // the scene's weights, not one global set
        let p2 = School.perception * School.perception
        let s2 = School.personal * School.personal

        let age = CACurrentMediaTime() - started
        for i in swarm.indices where swarm[i].bornAt <= age {
            let me = swarm[i]
            var cohX = 0.0, cohY = 0.0, aliX = 0.0, aliY = 0.0, sepX = 0.0, sepY = 0.0
            var seen = 0.0
            for j in swarm.indices where j != i {
                let dx = swarm[j].x - me.x, dy = swarm[j].y - me.y
                let d2 = dx * dx + dy * dy
                guard d2 < p2 else { continue }
                seen += 1
                cohX += swarm[j].x;  cohY += swarm[j].y
                aliX += swarm[j].vx; aliY += swarm[j].vy
                if d2 < s2 {
                    // Push harder the closer it is — 1/d, not a flat shove.
                    let d = max(6, d2.squareRoot())
                    sepX -= dx / d / d
                    sepY -= dy / d / d
                }
            }

            var ax = 0.0, ay = 0.0
            func steer(_ vx: Double, _ vy: Double, _ weight: Double) {
                let m = (vx * vx + vy * vy).squareRoot()
                guard m > 0.0001 else { return }
                ax += (vx / m * me.maxSpeed - me.vx) * weight
                ay += (vy / m * me.maxSpeed - me.vy) * weight
            }
            if seen > 0 {
                steer(cohX / seen - me.x, cohY / seen - me.y, School.cohesion)
                steer(aliX / seen, aliY / seen, School.alignment)
                steer(sepX, sepY, School.separation)
            }
            // The vortex: tangent to the circle through this cursor, plus a fraction of
            // the inward radial. Anticlockwise, which is the way the spawn spiral winds.
            let rx = me.x - cx, ry = me.y - cy
            let rm = max(1, (rx * rx + ry * ry).squareRoot())
            steer(-ry / rm - School.inward * rx / rm,
                   rx / rm - School.inward * ry / rm, School.vortex)
            // Edges: a shoal in a tank. Turning back beats wrapping — a cursor that
            // teleports across the screen is the tell that these are particles.
            if me.x < School.margin { steer(1, 0, School.edge) }
            if me.x > w - School.margin { steer(-1, 0, School.edge) }
            if me.y < School.margin { steer(0, 1, School.edge) }
            if me.y > h - School.margin { steer(0, -1, School.edge) }

            let am = max(1, (ax * ax + ay * ay).squareRoot())
            let k = min(1.0, me.accel * dt / am)
            swarm[i].vx += ax * k
            swarm[i].vy += ay * k
            // Cruise: a school holds its speed, so this is a band, not a ceiling.
            let sp = max(0.001, (swarm[i].vx * swarm[i].vx + swarm[i].vy * swarm[i].vy).squareRoot())
            let want = min(max(sp, me.maxSpeed * 0.55), me.maxSpeed)
            swarm[i].vx *= want / sp
            swarm[i].vy *= want / sp
            swarm[i].x += swarm[i].vx * dt
            swarm[i].y += swarm[i].vy * dt
            if want > 12 { swarm[i].angle = atan2(swarm[i].vy, swarm[i].vx) }
        }
    }

    private func draw() {
        let age = CACurrentMediaTime() - started
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, p) in swarm.enumerated() {
            let l = layers[i]
            // Not yet arrived: hidden rather than parked off-screen, so a pointer that
            // has not been born cannot be seen sitting at its spawn point.
            if p.bornAt > age { l.opacity = 0; continue }
            if l.opacity != 1 { l.opacity = 1 }
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

    /// The master arrow, rendered once. Every layer scales this one image down, and every
    /// view asks for the same `master` side — so without the cache a section that CUTS
    /// between patterns re-renders a 256pt bezier on the main thread on every cut. Cue 12
    /// re-opens this view about thirty times in fifteen seconds.
    private static var artCache: [CGFloat: NSImage] = [:]

    static func arrowImage(side: CGFloat) -> NSImage {
        if let hit = artCache[side] { return hit }
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
        artCache[side] = image
        return image
    }

    /// Test seams.
    var countForTesting: Int { swarm.count }
    var arrivedForTesting: Int {
        let age = CACurrentMediaTime() - started
        return swarm.filter { $0.bornAt <= age }.count
    }
    var sizesForTesting: [Double] { swarm.map(\.size) }
    var headingsForTesting: [Double] { swarm.map(\.angle) }
    var positionsForTesting: [(Double, Double)] { swarm.map { ($0.x, $0.y) } }
    var speedsForTesting: [Double] { swarm.map { ($0.vx * $0.vx + $0.vy * $0.vy).squareRoot() } }
    func stepForTesting(_ n: Int) { for _ in 0..<n { if mode == .school { stepSchool() } else { step() } } }
    var spreadForTesting: Int {
        guard swarm.count > 1 else { return 0 }
        let xs = swarm.map(\.x)
        return Int((xs.max()! - xs.min()!).rounded())
    }
}
