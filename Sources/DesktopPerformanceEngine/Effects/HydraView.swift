import AppKit
import CoreImage

/// A very small hydra.
///
/// It parses the subset of the livecoding language the show uses and **builds the
/// layer stack that code describes**, so the visual running in the window is what the
/// code printed over it actually says. Not an emulator — an honest reading of the
/// chain. A source (`osc` / `noise` / `voronoi` / `shape` / `gradient` / `solid`)
/// becomes a base layer; the chained ops (`kaleid`, `rotate`, `scale`, `repeat`,
/// `pixelate`, `colorama`, `thresh`, `invert`, `scroll*`, and `blend`/`diff`/`mult`
/// against a second source) wrap, transform or filter it.
///
/// Everything is Core Animation and Core Image on the render server, with periods
/// keyed to the show's BPM. Nothing here runs on the pump, so a stack of these keeps
/// playing — in tempo — while the timeline is busy elsewhere.
enum Hydra {

    // MARK: - Parsing

    struct Op {
        let name: String
        /// Paren nesting where the call was written. `diff(...)` sits at the depth of
        /// the chain it hangs off; the source inside its parens is one deeper. That is
        /// how the builder knows which ops belong to a blend's input and which have
        /// come back out to the main chain.
        let depth: Int
        let args: [Double]
        private let dynamicArgs: Set<Int>

        func arg(_ i: Int, _ fallback: Double) -> Double {
            i < args.count ? args[i] : fallback
        }

        /// True when the arg was written as a time function (`()=>time*0.4`) rather
        /// than a constant — the difference between "turn to this angle" and "keep
        /// turning at this rate", which is the whole character of a sketch.
        func isDynamic(_ i: Int) -> Bool { dynamicArgs.contains(i) }

        init(name: String, depth: Int, rawArgs: [String]) {
            self.name = name
            self.depth = depth
            var values: [Double] = []
            var dynamic: Set<Int> = []
            for (i, raw) in rawArgs.enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let constant = Double(trimmed) {
                    values.append(constant)
                } else if let rate = Hydra.timeRate(trimmed) {
                    values.append(rate)
                    dynamic.insert(i)
                } else {
                    values.append(0)      // keep positions: arg(1,…) must stay arg 1
                }
            }
            self.args = values
            self.dynamicArgs = dynamic
        }
    }

    /// `()=>time*0.4` → 0.4, `()=>-time * 0.5` → -0.5, `()=>time` → 1.
    ///
    /// Nothing here evaluates an expression per frame; the rate is pulled out and handed
    /// to Core Animation as a speed. That covers the way the show actually uses arrow
    /// functions — a value that advances steadily with time — and nothing more.
    static func timeRate(_ expr: String) -> Double? {
        // The arrow has to be THIS expression's, not one buried in a nested call:
        // `diff(osc(10).rotate(()=>time*0.4))` is not itself a time function, and
        // reading it as one would hand `diff` an argument it never had.
        let chars = Array(expr)
        var depth = 0
        var arrow: Int?
        for i in chars.indices {
            if chars[i] == "(" { depth += 1 }
            else if chars[i] == ")" { depth -= 1 }
            else if depth == 0, chars[i] == "=", i + 1 < chars.count, chars[i + 1] == ">" {
                arrow = i
                break
            }
        }
        guard let arrow = arrow else { return nil }
        let body = String(chars[(arrow + 2)...]).trimmingCharacters(in: .whitespaces)
        guard body.contains("time") else { return nil }
        let magnitude = body
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap(Double.init)
            .first ?? 1.0
        return body.hasPrefix("-") ? -magnitude : magnitude
    }

    /// Every `name(args)` call in source order, flattened depth-first: an op, then
    /// whatever was written inside its parentheses. That order is what the builder
    /// wants — `diff` arrives before the source it blends against.
    ///
    /// Hand-written rather than a regex because the interesting ops are exactly the
    /// ones a regex cannot see. `[^()]*` between parens cannot match `diff(osc(…))` or
    /// `rotate(()=>time*0.4)`, so both used to be dropped on the floor — silently, and
    /// they are usually the ops carrying all the motion.
    static func parse(_ source: String) -> [Op] {
        let chars = Array(source)
        var ops: [Op] = []
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" { depth = max(0, depth - 1); i += 1; continue }
            guard c.isLetter || c == "_" else { i += 1; continue }

            var end = i
            while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                end += 1
            }
            var paren = end
            while paren < chars.count, chars[paren] == " " || chars[paren] == "\n" || chars[paren] == "\t" {
                paren += 1
            }
            // A bare identifier (`o0`, `time`) is not a call — skip it.
            guard paren < chars.count, chars[paren] == "(" else { i = end; continue }

            ops.append(Op(name: String(chars[i..<end]), depth: depth,
                          rawArgs: topLevelArgs(chars, openParen: paren)))
            i = paren   // step onto the "(" so the loop descends into the args
        }
        return ops
    }

    /// The argument list of one call, split on its own commas. A comma inside a nested
    /// call belongs to that call, so depth is tracked rather than doing a plain split.
    private static func topLevelArgs(_ chars: [Character], openParen: Int) -> [String] {
        var args: [String] = []
        var current = ""
        var depth = 0
        var i = openParen
        while i < chars.count {
            let c = chars[i]
            if c == "(" {
                depth += 1
                if depth == 1 { i += 1; continue }       // this call's own paren
            } else if c == ")" {
                depth -= 1
                if depth == 0 { break }                  // and its closer: done
            } else if c == ",", depth == 1 {
                args.append(current)
                current = ""
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args.append(current) }
        return args
    }

    static let sourceNames: Set<String> = ["osc", "noise", "voronoi", "shape", "gradient", "solid", "src"]
    static let blendNames: Set<String> = ["blend", "diff", "mult", "add", "modulate",
                                          "modulateRotate", "modulateScale", "layer"]

    // MARK: - Generated textures

    private static var textureCache: [String: CGImage] = [:]

    private static func texture(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let hit = textureCache[key] { return hit }
        guard let img = make() else { return nil }
        textureCache[key] = img
        return img
    }

    private static func image(width: Int, height: Int,
                              _ fill: (_ x: Int, _ y: Int) -> (Double, Double, Double)) -> CGImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let i = (y * width + x) * 4
                px[i]     = UInt8(max(0, min(255, r * 255)))
                px[i + 1] = UInt8(max(0, min(255, g * 255)))
                px[i + 2] = UInt8(max(0, min(255, b * 255)))
                px[i + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// `osc(freq, sync, offset)` — sine bars. The image holds a whole number of
    /// periods across its width so scrolling it by half its width loops seamlessly.
    private static func oscTexture(freq: Double, offset: Double, tint: NSColor) -> CGImage? {
        let bands = max(3, min(90, Int((freq / 2).rounded()))) * 2      // even → seamless
        let w = 1024, h = 4
        let (tr, tg, tb) = (Double(tint.redComponent), Double(tint.greenComponent),
                            Double(tint.blueComponent))
        return texture("osc-\(bands)-\(Int(offset * 100))-\(tint.hexKey)") {
            image(width: w, height: h) { x, _ in
                let phase = Double(x) / Double(w) * Double(bands) * 2 * .pi
                let v = 0.5 + 0.5 * sin(phase)
                // `offset` phase-shifts the channels apart, the way hydra's does.
                let r = 0.5 + 0.5 * sin(phase + offset * 2.0)
                let g = 0.5 + 0.5 * sin(phase + offset * 4.0)
                // Lifted well above the tint's own luminance — these sit under a
                // scrim and behind type, and a faithful multiply comes out muddy.
                return (min(1, (v * 0.35 + r * 0.65) * (0.45 + tr)),
                        min(1, (v * 0.35 + g * 0.65) * (0.35 + tg)),
                        min(1, (v * 0.45 + 0.55) * (0.35 + tb)))
            }
        }
    }

    /// `noise(scale, speed)` — value noise, smoothstep-interpolated off a random grid.
    private static func noiseTexture(scale: Double, tint: NSColor) -> CGImage? {
        let cells = max(2, min(48, Int(scale.rounded())))
        let n = 256
        return texture("noise-\(cells)-\(tint.hexKey)") {
            var grid = [Double](repeating: 0, count: (cells + 1) * (cells + 1))
            var seed = UInt64(cells) &* 6364136223846793005 &+ 1
            for i in grid.indices {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                grid[i] = Double((seed >> 33) & 0xFFFF) / Double(0xFFFF)
            }
            func at(_ cx: Int, _ cy: Int) -> Double {
                grid[(cy % (cells + 1)) * (cells + 1) + (cx % (cells + 1))]
            }
            let (tr, tg, tb) = (Double(tint.redComponent), Double(tint.greenComponent),
                                Double(tint.blueComponent))
            return image(width: n, height: n) { x, y in
                let fx = Double(x) / Double(n) * Double(cells)
                let fy = Double(y) / Double(n) * Double(cells)
                let x0 = Int(fx), y0 = Int(fy)
                let tx = fx - Double(x0), ty = fy - Double(y0)
                let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
                let bot = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
                let v = top + (bot - top) * sy
                return (min(1, v * (0.4 + tr)), min(1, v * (0.4 + tg)), min(1, v * (0.4 + tb)))
            }
        }
    }

    /// `voronoi(scale, speed)` — brightness by distance to the nearest of N seeds.
    private static func voronoiTexture(scale: Double, tint: NSColor) -> CGImage? {
        let count = max(3, min(64, Int(scale.rounded())))
        let n = 192
        return texture("voronoi-\(count)-\(tint.hexKey)") {
            var seeds: [(Double, Double)] = []
            var s = UInt64(count) &* 2862933555777941757 &+ 3037000493
            for _ in 0..<count {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let a = Double((s >> 33) & 0xFFFF) / Double(0xFFFF)
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let b = Double((s >> 33) & 0xFFFF) / Double(0xFFFF)
                seeds.append((a, b))
            }
            let (tr, tg, tb) = (Double(tint.redComponent), Double(tint.greenComponent),
                                Double(tint.blueComponent))
            return image(width: n, height: n) { x, y in
                let px = Double(x) / Double(n), py = Double(y) / Double(n)
                var best = 4.0
                for (sx, sy) in seeds {
                    // wrap-around distance, so the cells tile
                    let dx = min(abs(px - sx), 1 - abs(px - sx))
                    let dy = min(abs(py - sy), 1 - abs(py - sy))
                    best = min(best, dx * dx + dy * dy)
                }
                let v = min(1.0, sqrt(best) * Double(count) * 0.55)
                return (min(1, v * (0.4 + tr)), min(1, v * (0.4 + tg)), min(1, v * (0.4 + tb)))
            }
        }
    }

    // MARK: - Building

    /// Build the visual described by `source`, sized to `size`, in `tint`.
    static func makeVisual(source: String, size: NSSize, tint: NSColor, beat: Double) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true

        let ops = parse(source)
        guard let firstIndex = ops.firstIndex(where: { sourceNames.contains($0.name) }) else {
            return root
        }
        var current: CALayer = baseLayer(for: ops[firstIndex], size: size, tint: tint, beat: beat)
        root.addSublayer(current)

        // A blend's input is a chain in its own right: in
        // `.diff(osc(10).rotate(()=>time*0.4).kaleid())` the rotate and the kaleid
        // belong to that inner osc, not to the main chain. Ops written inside the
        // blend's parens (deeper than the blend itself) are routed to `branch`; when
        // the nesting comes back out, so does the target.
        var branch: CALayer?
        var branchDepth = 0
        var blended: [CALayer] = []
        var pendingBlend: String?
        var index = firstIndex + 1
        while index < ops.count {
            let op = ops[index]
            index += 1
            if branch != nil, op.depth <= branchDepth { branch = nil }

            if blendNames.contains(op.name) {
                pendingBlend = op.name
                branchDepth = op.depth
                continue
            }
            if sourceNames.contains(op.name) {
                // The second input of a blend — composite it over what we have.
                let other = baseLayer(for: op, size: size, tint: tint, beat: beat)
                other.compositingFilter = blendFilter(pendingBlend ?? "blend")
                other.opacity = (pendingBlend ?? "").hasPrefix("modulate") ? 0.45 : 0.85
                root.addSublayer(other)
                branch = other
                blended.append(other)
                pendingBlend = nil
                continue
            }

            let target = branch ?? current
            apply(op, to: target, root: root, size: size, beat: beat)
            // `wrap` re-parents `target` into the replicator; adding a layer to a new
            // superlayer already removes it from the old one, so it must NOT be
            // removed again afterwards or the replicator ends up empty.
            if let wrapped = wrap(op, around: target, size: size, beat: beat) {
                // The wrapper inherits the composite role of the layer it swallowed,
                // or a kaleid inside a `.diff()` would stop being differenced.
                wrapped.compositingFilter = target.compositingFilter
                wrapped.opacity = target.opacity
                target.compositingFilter = nil
                target.opacity = 1
                root.addSublayer(wrapped)
                if branch != nil {
                    blended[blended.count - 1] = wrapped
                    branch = wrapped
                } else {
                    current = wrapped
                }
            }
        }
        // Sublayers draw in array order, so a blend has to END above the chain it is
        // blended against: `A.diff(B)` is the difference of B over A. The branch was
        // added the moment it was written, but the main chain keeps growing wrappers
        // after that — `.scrollY().repeat().scale()` each append a fresh one — and
        // every wrapper landed on top of the branch, burying it. Lifting the branches
        // last puts them back over the chain they belong to.
        for layer in blended {
            layer.removeFromSuperlayer()
            root.addSublayer(layer)
        }
        return root
    }

    private static func blendFilter(_ name: String) -> String {
        switch name {
        case "diff":  return "differenceBlendMode"
        case "mult":  return "multiplyBlendMode"
        case "add":   return "additiveBlendMode"
        default:      return "screenBlendMode"
        }
    }

    private static func baseLayer(for op: Op, size: NSSize, tint: NSColor, beat: Double) -> CALayer {
        let layer = CALayer()
        // Oversized so rotation and kaleidoscoping never expose a corner.
        let over = max(size.width, size.height) * 1.55
        layer.bounds = CGRect(x: 0, y: 0, width: over, height: over)
        layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        layer.contentsGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor

        switch op.name {
        case "osc":
            let freq = op.arg(0, 60), sync = op.arg(1, 0.1), offset = op.arg(2, 0)
            layer.contents = oscTexture(freq: freq, offset: offset, tint: tint)
            layer.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
            scroll(layer, by: 0.5, seconds: max(0.25, beat * 4 * (0.1 / max(0.005, abs(sync)))))
        case "noise":
            layer.contents = noiseTexture(scale: op.arg(0, 10), tint: tint)
            layer.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
            scroll(layer, by: 0.5, seconds: max(0.5, beat * 8 / max(0.05, abs(op.arg(1, 0.1)) * 10)))
        case "voronoi":
            layer.contents = voronoiTexture(scale: op.arg(0, 12), tint: tint)
            layer.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
            scroll(layer, by: 0.5, seconds: max(0.5, beat * 12 / max(0.05, abs(op.arg(1, 0.3)) * 6)))
        case "gradient":
            let g = CAGradientLayer()
            g.frame = layer.bounds
            g.colors = [tint.cgColor, NSColor.black.cgColor, tint.blended(withFraction: 0.6, of: .white)?.cgColor ?? tint.cgColor]
            g.startPoint = CGPoint(x: 0, y: 0)
            g.endPoint = CGPoint(x: 1, y: 1)
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [0.0, 0.3, 1.0]
            sweep.toValue = [0.0, 0.8, 1.0]
            sweep.duration = max(0.4, beat * 4 / max(0.1, op.arg(0, 0.3) * 3))
            sweep.autoreverses = true
            sweep.repeatCount = .infinity
            g.add(sweep, forKey: "sweep")
            layer.addSublayer(g)
        case "shape":
            let sides = max(3, min(64, Int(op.arg(0, 3))))
            let radius = min(0.95, max(0.05, op.arg(1, 0.3))) * over / 2
            let path = CGMutablePath()
            for i in 0..<sides {
                let a = Double(i) / Double(sides) * 2 * .pi - .pi / 2
                let p = CGPoint(x: over / 2 + CGFloat(cos(a)) * radius,
                                y: over / 2 + CGFloat(sin(a)) * radius)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
            let s = CAShapeLayer()
            s.frame = layer.bounds
            s.path = path
            s.fillColor = tint.cgColor
            layer.addSublayer(s)
        default:  // "solid" / "src" — a flat field to modulate
            layer.backgroundColor = tint.withAlphaComponent(0.55).cgColor
        }
        return layer
    }

    /// Seamless loop: the texture holds two copies, so sliding the sampling window by
    /// half its width and snapping back is invisible.
    private static func scroll(_ layer: CALayer, by amount: CGFloat, seconds: Double) {
        let a = CABasicAnimation(keyPath: "contentsRect.origin.x")
        a.fromValue = 0
        a.toValue = amount
        a.duration = seconds
        a.repeatCount = .infinity
        layer.add(a, forKey: "scroll")
    }

    /// How long one full cycle of a motion should take.
    ///
    /// The two kinds of argument mean genuinely different things and this is the one
    /// place that difference is decided. A `()=>time*k` is a literal claim about
    /// seconds — 0.4 radians a second, half a screen a second — so it is honoured as
    /// written. A bare number is not a rate at all in hydra, it is a static offset;
    /// reading it as one would leave most of the show's sketches sitting perfectly
    /// still, so a constant animates at a period keyed to the show's BPM instead.
    /// That liberty is deliberate, and it is why eight of the nine windows stay on the
    /// grid while the hand-written one says exactly what it means.
    private static func cycleSeconds(rate: Double, isDynamic: Bool,
                                     unitsPerCycle: Double, beatsPerCycle: Double,
                                     beat: Double) -> Double {
        let magnitude = max(0.0001, abs(rate))
        let seconds = isDynamic ? unitsPerCycle / magnitude : beat * beatsPerCycle / magnitude
        return min(600, max(0.2, seconds))
    }

    /// Ops that change the layer in place.
    private static func apply(_ op: Op, to layer: CALayer, root: CALayer,
                              size: NSSize, beat: Double) {
        switch op.name {
        case "rotate":
            // `rotate(0.2, 0.1)` is a fixed angle plus a spin; `rotate(()=>time*0.4)`
            // is nothing but spin. Reading the second form's rate as a static angle
            // would leave the layer sitting still at a slight tilt.
            //
            // The rate is also in radians per second, so 0.4 is a turn every 15.7s —
            // sedate, and nothing like the beat-locked period a bare constant gets.
            let angle = op.isDynamic(0) ? 0 : op.arg(0, 0)
            let speed = op.isDynamic(0) ? op.arg(0, 0) : op.arg(1, 0)
            layer.transform = CATransform3DRotate(layer.transform, CGFloat(angle), 0, 0, 1)
            if abs(speed) > 0.0001 {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = speed > 0 ? 2 * Double.pi : -2 * Double.pi
                spin.duration = cycleSeconds(rate: speed, isDynamic: op.isDynamic(0),
                                             unitsPerCycle: 2 * .pi, beatsPerCycle: 2,
                                             beat: beat)
                spin.repeatCount = .infinity
                layer.add(spin, forKey: "spin")
            }
        case "scale":
            let k = CGFloat(max(0.05, op.arg(0, 1.5)))
            layer.transform = CATransform3DScale(layer.transform, k, k, 1)
        case "pixelate":
            // Rasterize small, then magnify with nearest-neighbour: real chunky pixels.
            layer.shouldRasterize = true
            layer.rasterizationScale = CGFloat(max(0.01, min(1, 20 / max(4, op.arg(0, 20)) / 20)))
            layer.magnificationFilter = .nearest
        case "invert":
            layer.filters = (layer.filters ?? []) + [CIFilter(name: "CIColorInvert")].compactMap { $0 }
        case "thresh":
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(6.0 + op.arg(0, 0.5) * 8, forKey: "inputContrast")
                f.setValue(-0.1, forKey: "inputBrightness")
                layer.filters = (layer.filters ?? []) + [f]
            }
        case "color":
            // hydra's `.color(r,g,b)` scales the channels. Folding it into the hue
            // cycle below would throw away the actual palette the sketch asks for,
            // which is usually the point of writing it.
            if let f = CIFilter(name: "CIColorMatrix") {
                let r = CGFloat(op.arg(0, 1)), g = CGFloat(op.arg(1, 1)), b = CGFloat(op.arg(2, 1))
                f.setValue(CIVector(x: r, y: 0, z: 0, w: 0), forKey: "inputRVector")
                f.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector")
                f.setValue(CIVector(x: 0, y: 0, z: b, w: 0), forKey: "inputBVector")
                layer.filters = (layer.filters ?? []) + [f]
            }
        case "colorama", "hue":
            if let f = CIFilter(name: "CIHueAdjust") {
                let amount = op.arg(0, 0.3)
                // Core Animation resolves `filters.<name>.<key>` by the FILTER's name,
                // so an unnamed filter cannot be animated: the keyPath below silently
                // fails to bind and colorama sits on one static hue. Naming it is the
                // whole difference between a rainbow cycle and a tint.
                f.name = "hueAdjust"
                f.setValue(amount * 3.0, forKey: "inputAngle")
                layer.filters = (layer.filters ?? []) + [f]
                let cycle = CABasicAnimation(keyPath: "filters.hueAdjust.inputAngle")
                cycle.fromValue = 0
                cycle.toValue = 2 * Double.pi
                cycle.duration = max(1.0, beat * 16)
                cycle.repeatCount = .infinity
                layer.add(cycle, forKey: "hue")
            }
        case "luma":
            // hydra keys the dark end out — under the threshold goes transparent, and
            // what survives is scaled by how far over it got. Posterizing instead (the
            // old alias) kept every dark pixel and banded it, which is close to the
            // opposite. Four filters: luminance into alpha, a ramp across the
            // threshold, a clamp, then premultiply so the surviving colour dims the way
            // hydra's `vec4(c0.rgb*a, a)` does. A linear ramp where hydra smoothsteps.
            let threshold = op.arg(0, 0.5), tolerance = op.arg(1, 0.1)
            let low = threshold - tolerance
            let ramp = max(0.0001, 2 * tolerance)
            var stack: [CIFilter] = []
            if let luminance = CIFilter(name: "CIColorMatrix") {
                luminance.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                luminance.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                luminance.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                luminance.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                                   forKey: "inputAVector")
                stack.append(luminance)
            }
            if let step = CIFilter(name: "CIColorPolynomial") {
                step.setValue(CIVector(x: CGFloat(-low / ramp), y: CGFloat(1 / ramp), z: 0, w: 0),
                              forKey: "inputAlphaCoefficients")
                stack.append(step)
            }
            if let clamp = CIFilter(name: "CIColorClamp") { stack.append(clamp) }
            if let premultiplied = CIFilter(name: "CIPremultiply") { stack.append(premultiplied) }
            layer.filters = (layer.filters ?? []) + stack
        case "brightness", "contrast", "saturate", "posterize":
            if let f = CIFilter(name: "CIColorPosterize") {
                f.setValue(max(2.0, op.arg(0, 4) * 6), forKey: "inputLevels")
                layer.filters = (layer.filters ?? []) + [f]
            }
        default:
            break
        }
    }

    /// Ops that need to wrap the layer in a replicator (repetition, kaleidoscope).
    private static func wrap(_ op: Op, around layer: CALayer, size: NSSize,
                             beat: Double) -> CALayer? {
        func replicator(_ count: Int) -> CAReplicatorLayer {
            let r = CAReplicatorLayer()
            r.frame = CGRect(origin: .zero, size: size)
            r.masksToBounds = true
            r.instanceCount = count
            layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
            r.addSublayer(layer)
            return r
        }
        switch op.name {
        case "kaleid":
            // A kaleidoscope is wedges, not stacked copies: rotating an opaque
            // full-bleed layer just hides every instance under the last one. Mask the
            // source to one slice, then let the replicator sweep it round the circle.
            let n = max(2, min(24, Int(op.arg(0, 4))))
            let r = replicator(n)
            let slice = 2 * CGFloat.pi / CGFloat(n)
            let radius = max(size.width, size.height) * 1.6
            let c = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            let wedge = CGMutablePath()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: radius, startAngle: -slice / 2,
                         endAngle: slice / 2, clockwise: false)
            wedge.closeSubpath()
            let mask = CAShapeLayer()
            mask.frame = layer.bounds
            mask.path = wedge
            mask.fillColor = NSColor.white.cgColor
            layer.mask = mask
            r.instanceTransform = CATransform3DMakeRotation(slice, 0, 0, 1)
            return r
        case "scrollX", "scrollY":
            // Scrolling, not sliding. Animating `position` on a single layer walked the
            // sketch out of its own window and left black behind it — a patch whose
            // motion IS the scroll went blank a few seconds in. Three instances
            // stepping against the travel means whatever leaves one edge has already
            // arrived at the other, so the loop never shows a seam.
            let vertical = op.name == "scrollY"
            let step = vertical ? layer.bounds.height : layer.bounds.width
            let amount = op.arg(0, 0.1)
            guard step > 1, abs(amount) > 0.0001 else { return nil }
            let screens = Double(step) / Double(vertical ? size.height : size.width)
            let travel = (amount > 0 ? 1 : -1) * step
            let r = replicator(3)
            r.instanceTransform = CATransform3DMakeTranslation(vertical ? 0 : -travel,
                                                               vertical ? -travel : 0, 0)
            let a = CABasicAnimation(keyPath: vertical ? "position.y" : "position.x")
            a.byValue = travel
            a.duration = cycleSeconds(rate: amount, isDynamic: op.isDynamic(0),
                                      unitsPerCycle: screens, beatsPerCycle: 0.4 * screens,
                                      beat: beat)
            a.repeatCount = .infinity
            layer.add(a, forKey: op.name)
            return r
        case "repeat", "repeatX", "repeatY":
            // hydra tiles UV space: `repeat(4)` is a grid, every tile the whole frame.
            // A replicator steps in ONE direction, so asking a single one for both
            // axes marched the tiles diagonally across the window and left most of it
            // empty — four strips climbing to the corner instead of a wall of copies.
            // A row, then that row stacked, gives the grid the code asks for. Counts
            // default to hydra's own 3, so `repeat(4)` is 4 across and 3 down.
            let nx = op.name == "repeatY" ? 1 : max(1, min(12, Int(op.arg(0, 3))))
            let ny: Int
            switch op.name {
            case "repeatX": ny = 1
            case "repeatY": ny = max(1, min(12, Int(op.arg(0, 3))))
            default:        ny = max(1, min(12, Int(op.arg(1, 3))))
            }
            guard nx > 1 || ny > 1, layer.bounds.width > 1, layer.bounds.height > 1 else { return nil }
            let tile = CGSize(width: size.width / CGFloat(nx), height: size.height / CGFloat(ny))
            layer.transform = CATransform3DScale(layer.transform,
                                                 tile.width / layer.bounds.width,
                                                 tile.height / layer.bounds.height, 1)
            layer.position = CGPoint(x: tile.width / 2, y: tile.height / 2)
            let row = CAReplicatorLayer()
            row.frame = CGRect(origin: .zero, size: size)
            row.instanceCount = nx
            row.instanceTransform = CATransform3DMakeTranslation(tile.width, 0, 0)
            row.addSublayer(layer)
            let grid = CAReplicatorLayer()
            grid.frame = CGRect(origin: .zero, size: size)
            grid.masksToBounds = true
            grid.instanceCount = ny
            grid.instanceTransform = CATransform3DMakeTranslation(0, tile.height, 0)
            grid.addSublayer(row)
            return grid
        default:
            return nil
        }
    }
}

private extension NSColor {
    /// Stable cache key for the generated textures.
    var hexKey: String {
        guard let c = usingColorSpace(.sRGB) else { return "?" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255),
                      Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
