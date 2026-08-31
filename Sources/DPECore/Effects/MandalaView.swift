import AppKit

/// A mandala of spinning beach balls.
///
/// Concentric rings of the macOS wait cursor, evenly spaced around the screen's centre,
/// each ring turning at its own rate and in the opposite direction to its neighbours —
/// so the whole thing counter-rotates against itself the way a mandala does. Every ball
/// also spins on its own axis, because that is what a beach ball is for.
///
/// The cue asks for "the mouse spinner", and there was no spinner to fire: nothing in
/// the app sets the pointer. This is the other reading of it — not one spinner on the
/// cursor, but the machine hung everywhere at once.
///
/// Built like `CursorSwarmView`: art drawn once at high resolution and scaled DOWN by
/// each layer, one CALayer per ball, a fixed timestep accumulated against wall time.
final class MandalaView: NSView {
    private struct Ball {
        var radius = 0.0        // distance from the centre
        var phase = 0.0         // where it sits on its ring
        var ringSpeed = 0.0     // radians/sec the ring turns, signed
        var size = 0.0
        /// Which of the cursor's 15 frames this ball starts on. Staggered on purpose --
        /// see the note in `init`.
        var framePhase = 0
        /// The frame currently ON the layer, so `draw` only writes when it changes.
        var shownFrame = -1
    }

    private var balls: [Ball] = []
    private var layers: [CALayer] = []
    private var timer: Timer?
    private var started = CACurrentMediaTime()
    private var stepped = 0
    private var elapsed = 0.0
    /// CGImage, not NSImage. Assigning an NSImage to `layer.contents` makes Core
    /// Animation derive a CGImage from it on EVERY assignment; with 84 layers restepped
    /// each frame that alone took the main thread from 60 Hz to 8, and the display pump
    /// is coalesced, so what it actually looked like was the whole show slowing down.
    private var frames: [CGImage] = []
    private var frameCount = 1

    private static let dt = 1.0 / 60.0
    /// Drawn once at this size and only ever scaled down — the biggest ball here is
    /// ~110pt and an upscaled small bitmap of a pinwheel is mush.
    private static let master: CGFloat = 256
    /// Segments in the wheel — also the divisor in the flicker sum above.
    static let segments = 12

    init(size: NSSize, seed: Int, rings: Int, intensity: Double) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 5 : seed)))
        func rand(_ lo: Double, _ hi: Double) -> Double {
            lo + (hi - lo) * Double(rng.next() % 1_000_000) / 1_000_000.0
        }
        frames = MandalaView.beachballFrames(side: MandalaView.master)
        frameCount = max(1, frames.count)
        let short = Double(min(size.width, size.height))
        let ringCount = max(2, rings)

        for r in 0..<ringCount {
            let u = Double(r) / Double(ringCount - 1)          // 0 at the centre, 1 outside
            // Counts rise with the radius so the SPACING stays even — a fixed count per
            // ring leaves the outer rings sparse and the inner ones jammed, which reads
            // as a mistake rather than as a pattern.
            let count = Int((6 + u * 22) * max(0.3, intensity))
            let radius = short * (0.07 + 0.40 * u)
            let ballSize = short * (0.085 - 0.045 * u)
            // Alternating direction is what makes it a mandala rather than a wheel.
            let dir: Double = r % 2 == 0 ? 1 : -1
            let ringSpeed = dir * (0.22 + rand(0, 0.16)) * (1.4 - u)
            for k in 0..<count {
                var b = Ball()
                b.radius = radius
                b.phase = Double(k) / Double(count) * .pi * 2
                b.ringSpeed = ringSpeed
                b.size = ballSize
                // Every ball starts on a DIFFERENT frame of the cursor's animation.
                // This is a photosensitivity measure, not a decorative one: the real
                // cursor steps 15 frames at 30 fps, and eighty of them stepping in
                // unison would be a synchronised full-screen change at 30 Hz, straight
                // through the 15-20 Hz band CLAUDE.md keeps the piece out of. Staggered,
                // the screen changes somewhere constantly and nowhere all at once.
                b.framePhase = Int(rand(0, Double(max(1, frameCount))))
                balls.append(b)

                let l = CALayer()
                l.contents = frames.isEmpty ? nil : frames[b.framePhase % frames.count]
                b.shownFrame = b.framePhase % max(1, frameCount)
                l.bounds = CGRect(x: 0, y: 0, width: b.size,
                                  height: b.size * CGFloat(MandalaView.ballAspect))
                l.contentsGravity = .resizeAspect
                l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                layer?.addSublayer(l)
                layers.append(l)
            }
        }

        let t = Timer(timeInterval: MandalaView.dt, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        draw()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func tick() {
        let want = Int((CACurrentMediaTime() - started) / MandalaView.dt)
        var budget = min(max(0, want - stepped), 8)
        while budget > 0 {
            elapsed += MandalaView.dt
            stepped += 1
            budget -= 1
        }
        draw()
    }

    private func draw() {
        let cx = Double(bounds.midX), cy = Double(bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The cursor's own cadence, out of its own info.plist: 15 frames, 0.033 s each.
        // The spin is the ANIMATION, not a rotation of a still -- turning the real art
        // as well would spin it twice.
        let tick = Int(elapsed / MandalaView.frameDelay)
        for i in balls.indices {
            let b = balls[i]
            let a = b.phase + b.ringSpeed * elapsed
            layers[i].position = CGPoint(x: cx + cos(a) * b.radius, y: cy + sin(a) * b.radius)
            guard !frames.isEmpty else { continue }
            // Only when it actually changes. The cursor steps at 30 fps and this draws at
            // 60, so half of these writes were redundant even before the cost of each.
            let want = (tick + b.framePhase) % frames.count
            if want != b.shownFrame {
                layers[i].contents = frames[want]
                balls[i].shownFrame = want
            }
        }
        CATransaction.commit()
    }

    // MARK: - The beach ball

    /// Where macOS keeps its own cursors. `busybutclickable` is the beach ball: a
    /// vector PDF of 15 frames stacked vertically, 28x40 each, with the frame delay in
    /// the folder's info.plist.
    static let systemCursorPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks"
        + "/HIServices.framework/Versions/A/Resources/cursors/busybutclickable/cursor.pdf"
    static let frameDelay = 0.033
    static let frameTotal = 15

    /// The ball's box within one frame, as fractions of it (x from the left, y from the
    /// BOTTOM, PDF-style).
    ///
    /// `busybutclickable` is the arrow AND the spinner -- the cursor macOS shows when an
    /// app is busy but still answering. Only the lower part of it is the beach ball, and
    /// the arrow has to go: cue 25 is already a swarm of arrows, and two cues of the same
    /// shape in a row would read as one long cue.
    /// Measured off the art: the ball is a circle of radius ~9.5 in the 28x40 frame,
    /// centred at (14, 14) up from the bottom. In fractions that is a square box.
    static let ballCrop = (x: 0.16, y: 0.1125, w: 0.68, h: 0.475)

    /// The ball's aspect once cropped, which is what the layers are sized to.
    static var ballAspect: Double {
        (ballCrop.h * 40.0) / (ballCrop.w * 28.0)
    }

    /// The REAL beach ball, sliced out of the system's own cursor file.
    ///
    /// It is a PDF and `vectoronly` in its plist, so redrawing it at `side` gives a
    /// clean edge at any size the mandala asks for -- which is the whole reason to go to
    /// the file rather than screenshotting a cursor.
    ///
    /// Falls back to the drawn pinwheel below if the file is not there. That path is a
    /// system implementation detail: it has moved before across macOS versions, and a
    /// mandala of nothing is a worse failure than a mandala of an approximation.
    static func beachballFrames(side: CGFloat) -> [CGImage] {
        guard let strip = NSImage(contentsOfFile: systemCursorPath), strip.size.height > 0 else {
            NSLog("[DPE] mandala: system beach ball not at \(systemCursorPath) - drawing one")
            return [beachballImage(side: side)].compactMap(cgImage(of:))
        }
        let fw = strip.size.width
        let fh = strip.size.height / CGFloat(frameTotal)
        let out = NSSize(width: side, height: side * CGFloat(ballAspect))
        var frames: [CGImage] = []
        for i in 0..<frameTotal {
            let image = NSImage(size: out)
            image.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            // Clipped to the ball's own circle. The arrow's tail hangs INTO the ball's
            // bounding box -- they overlap in the art -- so no rectangular crop can
            // separate them, and a straight box leaves a white sliver above every ball.
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: out)).addClip()
            // Frame 0 is at the TOP of the strip and PDF coordinates run bottom-up, so
            // the frames are read back to front; the crop then takes the ball out of the
            // lower part of the frame and leaves the arrow behind.
            let band = CGFloat(frameTotal - 1 - i) * fh
            let src = NSRect(x: CGFloat(ballCrop.x) * fw,
                             y: band + CGFloat(ballCrop.y) * fh,
                             width: CGFloat(ballCrop.w) * fw,
                             height: CGFloat(ballCrop.h) * fh)
            strip.draw(in: NSRect(origin: .zero, size: out), from: src,
                       operation: .sourceOver, fraction: 1)
            image.unlockFocus()
            if let cg = cgImage(of: image) { frames.append(cg) }
        }
        return frames
    }

    private static func cgImage(of image: NSImage) -> CGImage? {
        var box = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &box, context: nil, hints: nil)
    }

    /// The fallback: a pinwheel of segments running through the spectrum, with
    /// a hole in the middle. Drawn rather than taken from `NSCursor`, for the same
    /// reason as the arrow — the system's is a small bitmap and these go up to ~110pt.
    static func beachballImage(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let c = NSPoint(x: side / 2, y: side / 2)
        let outer = side * 0.46, inner = side * 0.15
        let segments = MandalaView.segments
        for i in 0..<segments {
            let a0 = Double(i) / Double(segments) * 360.0
            let a1 = Double(i + 1) / Double(segments) * 360.0
            let wedge = NSBezierPath()
            wedge.appendArc(withCenter: c, radius: outer,
                            startAngle: CGFloat(a0), endAngle: CGFloat(a1))
            wedge.appendArc(withCenter: c, radius: inner,
                            startAngle: CGFloat(a1), endAngle: CGFloat(a0), clockwise: true)
            wedge.close()
            // Round the spectrum once across the segments; the real cursor fades toward
            // grey as it goes, which is what reads as "spinning" when it steps.
            let hue = CGFloat(i) / CGFloat(segments)
            NSColor(calibratedHue: hue, saturation: 0.85, brightness: 0.98, alpha: 1).setFill()
            wedge.fill()
        }
        // The keyline and the hole, so it reads on any background.
        let rim = NSBezierPath(ovalIn: NSRect(x: c.x - outer, y: c.y - outer,
                                              width: outer * 2, height: outer * 2))
        NSColor(white: 0.15, alpha: 0.9).setStroke()
        rim.lineWidth = max(1, side * 0.02)
        rim.stroke()
        let hole = NSBezierPath(ovalIn: NSRect(x: c.x - inner, y: c.y - inner,
                                               width: inner * 2, height: inner * 2))
        NSColor(white: 0.97, alpha: 1).setFill()
        hole.fill()
        NSColor(white: 0.15, alpha: 0.9).setStroke()
        hole.lineWidth = max(1, side * 0.015)
        hole.stroke()
        image.unlockFocus()
        return image
    }

    /// The largest share of balls sitting on the SAME animation frame.
    ///
    /// This is the photosensitivity number now that the art is the system's own: each
    /// ball steps at the cursor's real 30 fps, which is what every Mac shows anyway, but
    /// eighty of them stepping together would be one synchronised full-screen change at
    /// that rate -- straight through the 15-20 Hz band the piece stays out of. Staggered
    /// phases keep it low, and the tests pin it.
    var phaseSyncForTesting: Double {
        guard !balls.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for b in balls { counts[b.framePhase, default: 0] += 1 }
        return Double(counts.values.max() ?? 0) / Double(balls.count)
    }
    var frameCountForTesting: Int { frames.count }

    /// Test seams.
    var countForTesting: Int { balls.count }
    var radiiForTesting: [Double] { balls.map(\.radius) }
    /// Every ring turns the opposite way to its neighbour; this is the set of signed
    /// speeds, one per distinct radius.
    var ringSpeedsForTesting: [Double] {
        var seen: [Double: Double] = [:]
        for b in balls where seen[b.radius] == nil { seen[b.radius] = b.ringSpeed }
        return seen.sorted { $0.key < $1.key }.map(\.value)
    }
    var positionsForTesting: [CGPoint] { layers.map(\.position) }
}
