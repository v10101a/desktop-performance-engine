import AppKit

/// The photo card's low-fi treatment: the picture reduced to a coarse grid and put
/// through an ordered (Bayer) dither to a handful of tones per channel — the texture of
/// a cheap booth print — and nothing else on it. No vignette, no grain, no colour cast:
/// the earlier "instant film" pass layered all three and read as dirt on the photo
/// rather than as a print of it.
///
/// Pure CPU, one pass over a few hundred thousand bytes; no Core Image context to warm.
enum DitherLook {
    /// Cells across. The card shows the photo at up to 480 pt, so this puts a dither cell
    /// at a little over a point — visible as texture at arm's length, not as blocks.
    static let gridWidth = 400
    /// Tones per channel after quantising. Six keeps a face reading as a photograph with
    /// the dither carrying the in-between tones; two is the memory dump.
    static let levels = 6
    /// A hair of contrast so the pattern has edges to sit against. 1.0 is as taken.
    static let contrast = 1.12
    /// The classic 4×4 Bayer matrix, as thresholds in (0, 1).
    static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        .map { $0.map { ($0 + 0.5) / 16 } }

    /// The look applied; nil when the picture cannot be read as a bitmap.
    static func apply(to image: NSImage) -> NSImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let src = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              src.width > 0, src.height > 0 else { return nil }
        let gw = min(gridWidth, src.width)
        let gh = max(1, Int((Double(src.height) * Double(gw) / Double(src.width)).rounded()))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        // 1. Down to the grid. Ordinary resampling here: the reduction is what makes the
        //    cells, and it should average the source, not pick from it.
        guard let grid = CGContext(data: nil, width: gw, height: gh, bitsPerComponent: 8,
                                   bytesPerRow: gw * 4, space: space, bitmapInfo: info) else { return nil }
        grid.interpolationQuality = .medium
        grid.draw(src, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        guard let data = grid.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: gw * gh * 4)

        // 2. Contrast, then the dither: each channel is nudged by its cell's threshold
        //    and floored onto the level grid, so a tone between two levels lands on the
        //    upper one in exactly the share of cells its position between them says.
        let steps = Double(levels - 1)
        for y in 0..<gh {
            let row = bayer[y & 3]
            for x in 0..<gw {
                let i = (y * gw + x) * 4
                let t = row[x & 3]
                for c in 0..<3 {
                    let v = (Double(px[i + c]) / 255 - 0.5) * contrast + 0.5
                    let q = max(0, min(steps, (v * steps + t).rounded(.down)))
                    px[i + c] = UInt8((q / steps * 255).rounded())
                }
            }
        }
        guard let small = grid.makeImage() else { return nil }

        // 3. Back up to (at least) the picture's own pixel size with no interpolation, so
        //    the cells are square blocks when the card draws it, not a blur of them —
        //    the image view resamples smoothly and would otherwise soften the pattern away.
        let factor = max(1, Int((Double(src.width) / Double(gw)).rounded(.up)))
        let ow = gw * factor, oh = gh * factor
        guard let up = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8,
                                 bytesPerRow: ow * 4, space: space, bitmapInfo: info) else { return nil }
        up.interpolationQuality = .none
        up.draw(small, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        guard let out = up.makeImage() else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }
}
