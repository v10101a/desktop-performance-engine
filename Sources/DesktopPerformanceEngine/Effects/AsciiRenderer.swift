import AppKit
import ImageIO

/// ASCII-art renderer: turns literal ASCII text OR an image into monospaced ASCII,
/// auto-fit to the window. Image→ASCII conversion runs off the main thread (like the
/// image kind) and is cached, so respawns never re-convert or stall the pump.

let dpeAsciiRamp = " .:-=+*#%@"   // dark → light

/// Cached conversion result (NSCache values must be classes).
final class AsciiArt {
    let lines: [String]
    let colors: [[NSColor]]?      // per-cell color when colorized, else nil (monochrome)
    let cols: Int
    let rows: Int
    init(lines: [String], colors: [[NSColor]]?, cols: Int, rows: Int) {
        self.lines = lines; self.colors = colors; self.cols = cols; self.rows = rows
    }
}

private let dpeAsciiCache = NSCache<NSString, AsciiArt>()
private let dpeAsciiQueue = DispatchQueue(label: "com.computerart.dpe.ascii", qos: .userInitiated)

// MARK: - Conversion

func asciiArtFromText(_ text: String) -> AsciiArt {
    let lines = text.components(separatedBy: "\n")
    let cols = lines.map { $0.count }.max() ?? 1
    return AsciiArt(lines: lines, colors: nil, cols: max(cols, 1), rows: max(lines.count, 1))
}

/// Sample an image down to a `cols`-wide character grid (monospace cells are ~2× taller
/// than wide, so rows are scaled by ~0.55), mapping luminance to the `ramp`.
func asciiArtFromImage(path: String, cols: Int, invert: Bool, colorized: Bool, ramp: String) -> AsciiArt? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let cols = max(4, min(cols, 240))
    let rows = max(1, Int((Double(cols) * Double(cg.height) / Double(cg.width) * 0.55).rounded()))
    let bpr = cols * 4
    var buf = [UInt8](repeating: 0, count: rows * bpr)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: cols, height: rows, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cols, height: rows))

    let chars = Array(ramp.isEmpty ? dpeAsciiRamp : ramp)
    var lines: [String] = []
    var colors: [[NSColor]] = []
    for r in 0..<rows {
        let sr = rows - 1 - r              // CGContext is bottom-up; emit top row first
        var line = ""; var rowColors: [NSColor] = []
        for c in 0..<cols {
            let i = sr * bpr + c * 4
            let rr = buf[i], gg = buf[i + 1], bb = buf[i + 2]
            let lum = (0.299 * Double(rr) + 0.587 * Double(gg) + 0.114 * Double(bb)) / 255.0
            var idx = Int(lum * Double(chars.count - 1))
            if invert { idx = chars.count - 1 - idx }
            line.append(chars[min(max(idx, 0), chars.count - 1)])
            if colorized {
                rowColors.append(NSColor(srgbRed: CGFloat(rr) / 255, green: CGFloat(gg) / 255,
                                         blue: CGFloat(bb) / 255, alpha: 1))
            }
        }
        lines.append(line)
        if colorized { colors.append(rowColors) }
    }
    return AsciiArt(lines: lines, colors: colorized ? colors : nil, cols: cols, rows: rows)
}

// MARK: - Rendering

func makeAsciiTextView(frame: NSRect) -> NSTextView {
    let tv = NSTextView(frame: frame)
    tv.isEditable = false
    tv.isSelectable = false
    tv.drawsBackground = false
    tv.textContainerInset = .zero
    tv.textContainer?.lineFragmentPadding = 0
    tv.autoresizingMask = [.width, .height]
    return tv
}

/// Build a tight monospaced attributed string sized so the whole grid fills the view.
func renderAscii(_ art: AsciiArt, into tv: NSTextView, fg: NSColor) {
    let avail = NSSize(width: max(tv.bounds.width - 6, 8), height: max(tv.bounds.height - 6, 8))
    // monospace advance ≈ 0.60·pt; force line height == pt so cells are tight.
    let fs = max(4, min(avail.width / (CGFloat(art.cols) * 0.60), avail.height / CGFloat(art.rows)))
    let font = NSFont.monospacedSystemFont(ofSize: fs, weight: .regular)
    let para = NSMutableParagraphStyle()
    para.minimumLineHeight = fs; para.maximumLineHeight = fs; para.lineSpacing = 0

    let out = NSMutableAttributedString()
    for (r, line) in art.lines.enumerated() {
        if r > 0 {
            out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para]))
        }
        if let colors = art.colors, r < colors.count {
            for (c, ch) in line.enumerated() {
                let col = c < colors[r].count ? colors[r][c] : fg
                out.append(NSAttributedString(string: String(ch),
                    attributes: [.font: font, .paragraphStyle: para, .foregroundColor: col]))
            }
        } else {
            out.append(NSAttributedString(string: line,
                attributes: [.font: font, .paragraphStyle: para, .foregroundColor: fg]))
        }
    }
    tv.textStorage?.setAttributedString(out)
}

/// Convert an image to ASCII off the main thread (cached), then render on main.
func loadAsciiImageAsync(path: String, cols: Int, invert: Bool, colorized: Bool,
                         ramp: String, fg: NSColor, into tv: NSTextView) {
    let key = "\(path)|\(cols)|\(invert)|\(colorized)|\(ramp)" as NSString
    if let art = dpeAsciiCache.object(forKey: key) { renderAscii(art, into: tv, fg: fg); return }
    dpeAsciiQueue.async { [weak tv] in
        guard let art = asciiArtFromImage(path: path, cols: cols, invert: invert,
                                          colorized: colorized, ramp: ramp) else { return }
        dpeAsciiCache.setObject(art, forKey: key)
        DispatchQueue.main.async { if let tv = tv { renderAscii(art, into: tv, fg: fg) } }
    }
}

/// Resolve a resource path (absolute, cwd-relative, or found under an `assets/` folder
/// beside the app/executable) — same strategy as the audio resolver.
func resolveResourcePath(_ name: String) -> String {
    let fm = FileManager.default
    if name.hasPrefix("/") { return name }
    var bases = [URL(fileURLWithPath: fm.currentDirectoryPath)]
    if let res = Bundle.main.resourceURL { bases.append(res) }
    var walk = Bundle.main.bundleURL
    for _ in 0..<7 { bases.append(walk); walk = walk.deletingLastPathComponent() }
    let basename = (name as NSString).lastPathComponent
    for base in bases {
        for cand in [base.appendingPathComponent(name),
                     base.appendingPathComponent("assets").appendingPathComponent(basename)] {
            if fm.fileExists(atPath: cand.path) { return cand.path }
        }
    }
    return name
}
