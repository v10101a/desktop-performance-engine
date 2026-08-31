import AppKit
import UniformTypeIdentifiers

/// Fireworks made of the desktop.
///
/// Shells rise from the bottom of the screen, hang, and burst into a radial spray — and
/// every spark is a **macOS desktop file icon with a filename under it**, the way one
/// sits on a real desktop. The machine throwing its own files into the air.
///
/// The icons are the system's own (`NSWorkspace.icon(for:)` on real UTTypes), not
/// drawings of them, so they are whatever this Mac actually draws for a PDF or a folder.
///
/// **One layer per spark, one cached image per card.** Each distinct icon+name pair is
/// rendered ONCE into an NSImage and reused across every spark that shows it; a spark is
/// then a CALayer whose `contents` is that image, so a frame costs a position write per
/// spark and no drawing at all. Rendering text per spark per frame at this count would
/// not hold 60fps.
final class FileworksView: NSView {
    private struct Spark {
        var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
        var life = 0.0, maxLife = 1.0
        var card = 0
        var angle = 0.0            // a fixed tilt, not a spin -- see draw()
        var shell = false          // still rising, has yet to burst
        var fuse = 0.0
        var alive = false
    }

    /// Plausible desktop clutter, plus the piece's own voice. These are the names the
    /// sparks carry, so they are read at a glance: long enough to be believable, short
    /// enough to fit under a 48pt icon.
    private static let names = [
        "Screenshot 2026-08-30.png", "give_it_2_me.mp4", "untitled folder",
        "IMG_4821.HEIC", "Resume FINAL v3.pdf", "taxes.numbers", "notes.txt",
        "DJ_Dave_master.wav", "Untitled 2", "backup.zip", "old stuff",
        "receipt_scan.pdf", "what i want.rtf", "currents.mov", "Photo Booth Library",
        "do not delete", "passwords.txt", "Recently Deleted", "everything.dmg",
        "so give it to me.aiff",
    ]

    private static let types: [UTType] = [
        .pdf, .jpeg, .png, .plainText, .folder, .application, .zip, .mp3,
        .quickTimeMovie, .rtf, .html, .json, .diskImage, .movie, .audio,
    ]

    private var cards: [NSImage] = []
    private var layers: [CALayer] = []
    private var sparks: [Spark] = []
    private var rng: SplitMix64
    private var timer: Timer?
    private var started = CACurrentMediaTime()
    private var stepped = 0
    private var bursts = 0
    private let launchesPerSecond: Double
    private let burst: Int

    /// A fixed timestep, accumulated against wall time. The simulation therefore depends
    /// on how much time has passed and not on how often the timer happened to fire, so
    /// the same run looks the same twice — the standard the rest of the show holds to.
    private static let dt = 1.0 / 60.0

    /// Points per second squared, and it is NOT earth's. This is a ~700pt-tall field: at
    /// a realistic-looking value the sparks fell off the bottom and died inside a
    /// second, so five bursts had gone off and only the newest was still on screen.
    /// What matters here is hang time, not realism.
    private static let gravity = 200.0

    init(size: NSSize, seed: Int, hz: Double, intensity: Double) {
        rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 7 : seed)))
        launchesPerSecond = max(0.2, min(8, hz))
        burst = max(6, min(60, Int(28 * max(0.2, intensity))))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        // No background: the window is a transparent overlay on whatever the show has
        // already put on screen.
        layer?.backgroundColor = NSColor.clear.cgColor

        for i in 0..<40 {
            cards.append(FileworksView.card(type: FileworksView.types[i % FileworksView.types.count],
                                            name: FileworksView.names[i % FileworksView.names.count]))
        }
        let pool = 320
        sparks = Array(repeating: Spark(), count: pool)
        for _ in 0..<pool {
            let l = CALayer()
            l.isHidden = true
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(l)
            layers.append(l)
        }

        let t = Timer(timeInterval: FileworksView.dt, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }

    /// Stop the moment the view leaves the screen — `closeWindow` drops the window, and
    /// a timer still stepping a detached particle system is a leak per run.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil }
    }

    /// Scenery, like every other effect view: the window owns the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Simulation

    private func rand(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(rng.next() % 1_000_000) / 1_000_000.0
    }

    private func spawn(_ s: Spark) {
        guard let i = sparks.firstIndex(where: { !$0.alive }) else { return }
        sparks[i] = s
    }

    private func tick() {
        let want = Int((CACurrentMediaTime() - started) / FileworksView.dt)
        // Catch up, but never in an unbounded burst: a stalled run loop must not spend
        // a second of CPU replaying the simulation.
        var budget = min(max(0, want - stepped), 8)
        while budget > 0 {
            step()
            stepped += 1
            budget -= 1
        }
        draw()
    }

    private func step() {
        let w = Double(bounds.width), h = Double(bounds.height)
        guard w > 1, h > 1 else { return }
        let dt = FileworksView.dt

        // Launches, as a probability per step rather than a countdown, so the rhythm is
        // uneven the way fireworks are.
        if rand(0, 1) < launchesPerSecond * dt {
            var shell = Spark()
            shell.x = rand(w * 0.15, w * 0.85)
            shell.y = -30
            shell.vx = rand(-40, 40)
            // Solved, not guessed: pick the height it should burst at and derive the
            // launch speed and the fuse from it. Guessing a speed put every burst a
            // third of the way up with an empty sky above it.
            let apex = rand(h * 0.55, h * 0.80)
            shell.vy = (2 * FileworksView.gravity * apex).squareRoot()
            shell.fuse = shell.vy / FileworksView.gravity
            shell.shell = true
            shell.alive = true
            shell.maxLife = 3.0
            shell.card = Int(rng.next() % UInt64(cards.count))
            shell.angle = rand(-0.22, 0.22)
            spawn(shell)
        }

        for i in sparks.indices where sparks[i].alive {
            sparks[i].vy -= FileworksView.gravity * dt
            // Per STEP, and there are 60 of those a second: 0.985 looks gentle written
            // down and is 0.4x per second, which stopped every spark about 100px from
            // the shell and made each burst a clump. 0.997 is ~0.83x per second.
            let drag = sparks[i].shell ? 1.0 : 0.997
            sparks[i].vx *= drag
            sparks[i].vy *= drag
            sparks[i].x += sparks[i].vx * dt
            sparks[i].y += sparks[i].vy * dt
            sparks[i].life += dt

            if sparks[i].shell && sparks[i].life >= sparks[i].fuse {
                burstOpen(at: i)
                continue
            }
            if sparks[i].life >= sparks[i].maxLife || sparks[i].y < -80 {
                sparks[i].alive = false
            }
        }
    }

    /// The shell becomes the burst: it dies and throws `burst` sparks radially from
    /// where it got to.
    private func burstOpen(at i: Int) {
        let cx = sparks[i].x, cy = sparks[i].y
        sparks[i].alive = false
        bursts += 1
        // Sized so a burst stays a legible RING inside the field. At 460 the sparks
        // travelled 1585pt across an 1100pt view and every burst overlapped every other
        // one, which reads as a blizzard rather than as fireworks.
        let speed = rand(160, 285)
        for k in 0..<burst {
            var p = Spark()
            // Evenly spaced around the circle with a little jitter, so it reads as a
            // shell and not as a cloud.
            let a = Double(k) / Double(burst) * .pi * 2 + rand(-0.12, 0.12)
            let v = speed * rand(0.55, 1.0)
            p.x = cx; p.y = cy
            p.vx = cos(a) * v
            p.vy = sin(a) * v
            p.maxLife = rand(1.9, 2.9)
            p.card = Int(rng.next() % UInt64(cards.count))
            p.angle = rand(-0.35, 0.35)
            p.alive = true
            spawn(p)
        }
    }

    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, s) in sparks.enumerated() {
            let l = layers[i]
            guard s.alive else { l.isHidden = true; continue }
            let card = cards[s.card]
            if l.contents == nil || l.bounds.width != card.size.width {
                l.contents = card
                l.bounds = CGRect(origin: .zero, size: card.size)
            }
            l.isHidden = false
            l.position = CGPoint(x: s.x, y: s.y)
            // Shells stay solid; sparks fade over the back half of their life, so a
            // burst thins out instead of vanishing.
            let u = s.life / s.maxLife
            l.opacity = s.shell ? 1 : Float(max(0, min(1, (1 - u) * 1.8)))
            // A small FIXED tilt per spark, so the field does not read as a texture of
            // identical icons. Derived from position it looked clever and was not: x+y
            // reaches a couple of thousand, so at any useful scale the cards spun past
            // a full turn and every label came out upside down.
            l.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(s.angle)))
        }
        CATransaction.commit()
    }

    // MARK: - The card

    /// One desktop icon, rendered once: the system's icon for `type`, with `name` under
    /// it in the Finder's own arrangement — white, centred, shadowed so it stays legible
    /// over whatever the show has on screen behind it.
    static func card(type: UTType, name: String) -> NSImage {
        let iconSide: CGFloat = 48
        let size = NSSize(width: 116, height: 74)
        let image = NSImage(size: size)
        image.lockFocus()
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: iconSide, height: iconSide)
        icon.draw(in: NSRect(x: (size.width - iconSide) / 2, y: size.height - iconSide,
                             width: iconSide, height: iconSide))

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
            .paragraphStyle: para,
        ]
        (name as NSString).draw(in: NSRect(x: 2, y: 2, width: size.width - 4, height: 22),
                                withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    /// Test seam: how many sparks are in flight.
    var liveSparksForTesting: Int { sparks.filter(\.alive).count }
    /// Test seam: how far the field actually spreads, in points. A burst that reads as a
    /// clump rather than a firework is a number, not a matter of taste.
    var stepsForTesting: Int { stepped }
    var burstsForTesting: Int { bursts }
    var spreadForTesting: (w: Int, h: Int) {
        let live = sparks.filter(\.alive)
        guard live.count > 1 else { return (0, 0) }
        let xs = live.map(\.x), ys = live.map(\.y)
        return (Int((xs.max()! - xs.min()!).rounded()), Int((ys.max()! - ys.min()!).rounded()))
    }
    var cardCountForTesting: Int { cards.count }
}
