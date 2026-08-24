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
        let args: [Double]
        func arg(_ i: Int, _ fallback: Double) -> Double {
            i < args.count ? args[i] : fallback
        }
    }

    /// Every `name(args)` call in source order. Nested calls (`.diff(osc(30))`) come
    /// out flat, which is exactly what the builder wants: the op, then its argument
    /// source.
    static func parse(_ source: String) -> [Op] {
        let pattern = try? NSRegularExpression(pattern: "([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(([^()]*)\\)")
        let ns = source as NSString
        let matches = pattern?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? []
        return matches.map { m in
            let name = ns.substring(with: m.range(at: 1))
            let args = ns.substring(with: m.range(at: 2))
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return Op(name: name, args: args)
        }
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
        guard let first = ops.first(where: { sourceNames.contains($0.name) }) else { return root }
        var current: CALayer = baseLayer(for: first, size: size, tint: tint, beat: beat)
        root.addSublayer(current)

        var index = (ops.firstIndex { $0.name == first.name } ?? 0) + 1
        var pendingBlend: String?
        while index < ops.count {
            let op = ops[index]
            index += 1
            if blendNames.contains(op.name) { pendingBlend = op.name; continue }
            if sourceNames.contains(op.name) {
                // The second input of a blend — composite it over what we have.
                let other = baseLayer(for: op, size: size, tint: tint, beat: beat)
                other.compositingFilter = blendFilter(pendingBlend ?? "blend")
                other.opacity = (pendingBlend ?? "").hasPrefix("modulate") ? 0.45 : 0.85
                root.addSublayer(other)
                pendingBlend = nil
                continue
            }
            apply(op, to: current, root: root, size: size, beat: beat)
            // `wrap` re-parents `current` into the replicator; adding a layer to a new
            // superlayer already removes it from the old one, so it must NOT be
            // removed again afterwards or the replicator ends up empty.
            if let wrapped = wrap(op, around: current, size: size) {
                root.addSublayer(wrapped)
                current = wrapped
            }
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

    /// Ops that change the layer in place.
    private static func apply(_ op: Op, to layer: CALayer, root: CALayer,
                              size: NSSize, beat: Double) {
        switch op.name {
        case "rotate":
            let angle = op.arg(0, 0), speed = op.arg(1, 0)
            layer.transform = CATransform3DRotate(layer.transform, CGFloat(angle), 0, 0, 1)
            if abs(speed) > 0.0001 {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = speed > 0 ? 2 * Double.pi : -2 * Double.pi
                spin.duration = max(0.5, beat * 8 / max(0.05, abs(speed) * 4))
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
        case "colorama", "color", "hue":
            if let f = CIFilter(name: "CIHueAdjust") {
                let amount = op.arg(0, 0.3)
                f.setValue(amount * 3.0, forKey: "inputAngle")
                layer.filters = (layer.filters ?? []) + [f]
                let cycle = CABasicAnimation(keyPath: "filters.hueAdjust.inputAngle")
                cycle.fromValue = 0
                cycle.toValue = 2 * Double.pi
                cycle.duration = max(1.0, beat * 16)
                cycle.repeatCount = .infinity
                layer.add(cycle, forKey: "hue")
            }
        case "luma", "brightness", "contrast", "saturate", "posterize":
            if let f = CIFilter(name: "CIColorPosterize") {
                f.setValue(max(2.0, op.arg(0, 4) * 6), forKey: "inputLevels")
                layer.filters = (layer.filters ?? []) + [f]
            }
        case "scrollX", "scrollY":
            let d = max(0.4, beat * 4 / max(0.05, abs(op.arg(0, 0.1)) * 10))
            let a = CABasicAnimation(keyPath: op.name == "scrollX" ? "position.x" : "position.y")
            a.byValue = (op.arg(0, 0.1) > 0 ? 1 : -1) * (op.name == "scrollX" ? size.width : size.height)
            a.duration = d
            a.repeatCount = .infinity
            layer.add(a, forKey: op.name)
        default:
            break
        }
    }

    /// Ops that need to wrap the layer in a replicator (repetition, kaleidoscope).
    private static func wrap(_ op: Op, around layer: CALayer, size: NSSize) -> CALayer? {
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
        case "repeat", "repeatX", "repeatY":
            let nx = max(1, min(12, Int(op.arg(0, 3))))
            let r = replicator(nx)
            let dx = op.name == "repeatY" ? 0 : size.width / CGFloat(nx)
            let dy = op.name == "repeatX" ? 0 : size.height / CGFloat(nx)
            layer.transform = CATransform3DScale(layer.transform, 1 / CGFloat(nx), 1 / CGFloat(nx), 1)
            r.instanceTransform = CATransform3DMakeTranslation(dx, dy, 0)
            return r
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
