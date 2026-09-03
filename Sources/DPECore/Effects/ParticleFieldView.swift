import AppKit
import UniformTypeIdentifiers

/// Three more ways to throw the desktop around, next to `fileworks`' fireworks.
///
/// One view, two dials. `Mode` is what the particles DO and `Sprite` is what they ARE,
/// and every combination is legal — the point of the split is that the piece's three
/// bodies (the file icon, the pointer, the beach ball) can each be put through any of
/// the behaviours without a fourth view being written.
///
/// - `.vortex` — a drain. Everything circles inward, faster as it closes on the middle,
///   and is gone at the centre; the rim keeps feeding it. The desktop being swallowed.
/// - `.rain` — gravity. They fall in, bounce off the bottom of the screen, lose most of
///   it each time, and settle into a heap that keeps being rained on. The machine
///   shedding its contents.
/// - `.orbit` — the pointer as a gravitational body. Rings of particles turn around
///   wherever the mouse actually is, the far ones lagging, so the whole system swings
///   after the cursor when it moves and keeps spinning when it stops.
///
/// Built like `FileworksView` and `CursorSwarmView`, for the same reasons: art rendered
/// once and reused, one CALayer per particle, a fixed timestep accumulated against wall
/// time so a dropped frame does not change the physics.
final class ParticleFieldView: NSView {
    enum Mode: String {
        case vortex, rain, orbit
        init(_ name: String?) { self = Mode(rawValue: name ?? "") ?? .vortex }
    }

    /// What the particles are made of. All three are things the show already owns: the
    /// system's file icons, its pointer, and its beach ball.
    enum Sprite: String {
        case icons, cursors, beachballs
        init(_ name: String?) { self = Sprite(rawValue: name ?? "") ?? .icons }
    }

    private struct P {
        var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
        var size = 0.0
        var art = 0                 // index into `art`, or the phase for an animated one
        var angle = 0.0             // drawn rotation
        var spin = 0.0              // …and how fast it turns, radians/sec
        var radius = 0.0            // orbit only: how far out this one rides
        var omega = 0.0             // orbit/vortex: angular speed
        var theta = 0.0
        var rests = 0               // rain only: how many bounces it has left in it
    }

    private let mode: Mode
    private let sprite: Sprite
    private var parts: [P] = []
    private var layers: [CALayer] = []
    private var art: [CGImage] = []
    private var rng: SplitMix64
    private var timer: Timer?
    private var started = CACurrentMediaTime()
    private var stepped = 0
    /// Where the real pointer is, in this view's space — `.orbit` only.
    private var target = CGPoint.zero

    private static let dt = 1.0 / 60.0
    /// The beach ball's own cadence, the same 15-frames-at-30fps the mandala steps.
    private static let ballFPS = 30.0

    init(size: NSSize, seed: Int, count: Int, mode: Mode, sprite: Sprite) {
        self.mode = mode
        self.sprite = sprite
        rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 11 : seed)))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        art = ParticleFieldView.art(for: sprite)
        target = CGPoint(x: size.width / 2, y: size.height / 2)

        for i in 0..<max(1, count) {
            var p = P()
            p.size = rand(sprite == .icons ? 26 : 18, sprite == .icons ? 64 : 54)
            p.art = art.isEmpty ? 0 : Int(rng.next() % UInt64(art.count))
            p.spin = rand(-1.2, 1.2)
            seedParticle(&p, index: i, initial: true)
            parts.append(p)

            let l = CALayer()
            l.contents = art.isEmpty ? nil : art[p.art % max(1, art.count)]
            l.bounds = CGRect(x: 0, y: 0, width: p.size, height: p.size)
            l.contentsGravity = .resizeAspect
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(l)
            layers.append(l)
        }

        let t = Timer(timeInterval: ParticleFieldView.dt, repeats: true) { [weak self] _ in
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

    /// Scenery: it never takes a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rand(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(rng.next() % 1_000_000) / 1_000_000.0
    }

    // MARK: - Placing one

    /// Put a particle where its mode wants it. `initial` scatters the first generation
    /// through the whole field instead of stacking it all on the spawn line — otherwise
    /// every mode opens with one dense clump and thins out from there.
    private func seedParticle(_ p: inout P, index: Int, initial: Bool) {
        let w = Double(bounds.width), h = Double(bounds.height)
        switch mode {
        case .vortex:
            // On the rim, or anywhere in the disc for the first generation.
            let rMax = max(w, h) * 0.62
            p.radius = initial ? rand(rMax * 0.15, rMax) : rand(rMax * 0.85, rMax)
            p.theta = rand(0, 2 * .pi)
            // Angular speed rises as it closes in — a drain turns faster at the middle,
            // and a constant one reads as a carousel.
            p.omega = rand(0.9, 1.5)
            p.x = w / 2 + cos(p.theta) * p.radius
            p.y = h / 2 + sin(p.theta) * p.radius
        case .rain:
            p.x = rand(0, w)
            p.y = initial ? rand(0, h * 1.6) : h + rand(20, h * 0.5)
            p.vx = rand(-24, 24)
            p.vy = rand(-40, 0)
            p.rests = Int(rand(2, 5))
        case .orbit:
            p.radius = initial ? rand(30, min(w, h) * 0.45) : rand(30, min(w, h) * 0.45)
            p.theta = rand(0, 2 * .pi)
            // Inner rings turn faster: the field reads as one body with depth rather
            // than as a ring of identical dots.
            p.omega = rand(0.5, 1.4) * (1.6 - p.radius / max(1, min(w, h) * 0.45)) *
                      (Double(index % 2) == 0 ? 1 : -1)
            p.x = target.x + cos(p.theta) * p.radius
            p.y = target.y + sin(p.theta) * p.radius
        }
    }

    // MARK: - Running

    private func tick() {
        if mode == .orbit, let win = window {
            let inWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
            target = convert(inWindow, from: nil)
        }
        let want = Int((CACurrentMediaTime() - started) / ParticleFieldView.dt)
        var budget = min(max(0, want - stepped), 8)
        while budget > 0 { step(); stepped += 1; budget -= 1 }
        draw()
    }

    private func step() {
        let dt = ParticleFieldView.dt
        let w = Double(bounds.width), h = Double(bounds.height)
        guard w > 0, h > 0 else { return }
        for i in parts.indices {
            switch mode {
            case .vortex:
                // Polar integration, not a force: a drain is a shape, and steering
                // particles into one with an attractor takes tuning to look like this
                // and still occasionally throws one across the screen.
                parts[i].radius -= (60 + 240 * (1 - parts[i].radius / (max(w, h) * 0.62))) * dt
                parts[i].theta += parts[i].omega * (1 + 90 / max(20, parts[i].radius)) * dt
                if parts[i].radius < 10 {
                    seedParticle(&parts[i], index: i, initial: false)
                }
                parts[i].x = w / 2 + cos(parts[i].theta) * parts[i].radius
                parts[i].y = h / 2 + sin(parts[i].theta) * parts[i].radius
                // Everything leans into the turn, and shrinks as it goes down the hole.
                parts[i].angle = parts[i].theta + .pi / 2
            case .rain:
                parts[i].vy -= 900 * dt                      // AppKit's y is up
                parts[i].x += parts[i].vx * dt
                parts[i].y += parts[i].vy * dt
                let floor = parts[i].size * 0.35
                if parts[i].y < floor {
                    parts[i].y = floor
                    if parts[i].rests > 0 && abs(parts[i].vy) > 60 {
                        parts[i].vy = -parts[i].vy * 0.42    // most of it is gone
                        parts[i].vx *= 0.7
                        parts[i].rests -= 1
                    } else {
                        // Landed. It lies there a moment and then it is raining again
                        // somewhere else — a heap that only grows would fill the screen
                        // and stop being weather.
                        parts[i].vy = 0
                        parts[i].vx *= 0.85
                        if abs(parts[i].vx) < 4 { seedParticle(&parts[i], index: i, initial: false) }
                    }
                }
                if parts[i].x < -60 || parts[i].x > w + 60 {
                    seedParticle(&parts[i], index: i, initial: false)
                }
                parts[i].angle += parts[i].spin * dt
            case .orbit:
                parts[i].theta += parts[i].omega * dt
                // The ring's centre CHASES the pointer rather than being pinned to it,
                // and the far ones chase more slowly, so a flick of the mouse drags the
                // system out of round and it settles back over the next second.
                let lag = 3.0 + 6.0 * (parts[i].radius / max(1, min(w, h) * 0.45))
                let cx = Double(target.x) + cos(parts[i].theta) * parts[i].radius
                let cy = Double(target.y) + sin(parts[i].theta) * parts[i].radius
                parts[i].x += (cx - parts[i].x) * min(1, lag * dt)
                parts[i].y += (cy - parts[i].y) * min(1, lag * dt)
                parts[i].angle = parts[i].theta + .pi / 2
            }
        }
    }

    private func draw() {
        let tick = Int((CACurrentMediaTime() - started) * ParticleFieldView.ballFPS)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, p) in parts.enumerated() {
            let l = layers[i]
            // The beach ball is fifteen frames, not one picture: stepping it is what
            // makes it the system's spinner rather than a sticker of it.
            if sprite == .beachballs && art.count > 1 {
                l.contents = art[(tick + p.art) % art.count]
            }
            let scale = mode == .vortex
                ? max(0.25, min(1, p.radius / (max(bounds.width, bounds.height) * 0.35)))
                : 1
            l.bounds = CGRect(x: 0, y: 0, width: p.size * scale, height: p.size * scale)
            l.position = CGPoint(x: p.x, y: p.y)
            l.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(p.angle)))
        }
        CATransaction.commit()
    }

    // MARK: - The art

    private static func art(for sprite: Sprite) -> [CGImage] {
        switch sprite {
        case .beachballs:
            return MandalaView.beachballFrames(side: 128)
        case .cursors:
            return [CursorSwarmView.arrowImage(side: 256)].compactMap(cgImage)
        case .icons:
            // The system's own icons for real types — whatever THIS Mac draws for a PDF
            // or a folder, same as the fireworks.
            let types: [UTType] = [.pdf, .jpeg, .png, .plainText, .folder, .application,
                                   .zip, .mp3, .quickTimeMovie, .diskImage]
            return types.compactMap { cgImage(NSWorkspace.shared.icon(for: $0)) }
        }
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Test seams

    var countForTesting: Int { parts.count }
    var positionsForTesting: [(Double, Double)] { parts.map { ($0.x, $0.y) } }
    func stepForTesting(_ n: Int) { for _ in 0..<n { step() } }
}
