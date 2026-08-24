import AppKit
import ImageIO
import UniformTypeIdentifiers

// Ported from the standalone GlitchWallpaper app (Sources/GlitchWallpaper/main.swift,
// lines 1-258) — the pixel engine only. Its CLI parsing, Application Support
// bookkeeping and wallpaper plumbing are dropped: DPE's WallpaperController already
// owns the snapshot/restore, and the show authors settings per event.
//
// UNCHANGED from upstream below this line, apart from the imports above.

// MARK: - Errors

struct GlitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Deterministic RNG (so `seed` reproduces a glitch exactly)

// DPE already ships SplitMix64 (Effects/DesktopIconController.swift) with the identical
// algorithm and constants, so this uses that one rather than shadowing it. Upstream's
// copy conformed to RandomNumberGenerator and carried these three helpers; they're added
// back here so the ported pixel code below is unmodified.
extension SplitMix64: RandomNumberGenerator {}

extension SplitMix64 {
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func double(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func chance(_ probability: Double) -> Bool { double(0...1) < probability }
}

// MARK: - Bitmap

/// An RGBA8 (alpha ignored) pixel buffer we can scribble on directly.
final class Bitmap {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: UnsafeMutablePointer<UInt8>

    /// The buffer is left uninitialized — every consumer (a full-frame
    /// `CGContext.draw`, or the displacement pass) writes every byte before
    /// anything reads it, so zeroing 30+ MB up front is pure waste.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.pixels = .allocate(capacity: bytesPerRow * height)
    }

    deinit { pixels.deallocate() }

    private static let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    func makeContext() -> CGContext? {
        CGContext(
            data: pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: Bitmap.bitmapInfo)
    }

    /// Rasterizes `image` into a fresh bitmap, scaled so the long edge is at
    /// most `maxEdge` (a 6K wallpaper is 60 MB per buffer; two of those is
    /// plenty).
    static func render(_ image: CGImage, maxEdge: Int) throws -> Bitmap {
        var width = image.width
        var height = image.height
        let longEdge = max(width, height)
        if longEdge > maxEdge {
            let scale = Double(maxEdge) / Double(longEdge)
            width = max(Int((Double(width) * scale).rounded()), 1)
            height = max(Int((Double(height) * scale).rounded()), 1)
        }

        let bitmap = Bitmap(width: width, height: height)
        guard let context = bitmap.makeContext() else {
            throw GlitchError("could not create a \(width)x\(height) bitmap context")
        }
        // Interpolation only costs anything when we're actually resampling.
        context.interpolationQuality = (width == image.width) ? .none : .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap
    }

    func makeImage() throws -> CGImage {
        guard let image = makeContext()?.makeImage() else {
            throw GlitchError("could not render the glitched bitmap")
        }
        return image
    }
}

// MARK: - The glitch

struct GlitchSettings {
    var intensity: Double   // 0...1, scales every effect below
    var seed: UInt64
}

/// Horizontal displacement + per-channel offset + scanlines, written src -> dst.
///
/// Every row gets an offset from three stacked sources: two sine waves (smooth
/// warp), a band-noise term (chunky tears), and a per-row chroma split that
/// pulls R and B apart. Rows can also *source* from a different y, which is
/// what reads as a torn scanline rather than a smooth wave.
///
/// Scanline darkening rides along in the same pass rather than getting its own
/// sweep over the buffer — at 8 MP the extra traversal costs more than the
/// arithmetic does.
func displace(_ src: Bitmap, into dst: Bitmap, settings: GlitchSettings) {
    let width = src.width
    let height = src.height
    var rng = SplitMix64(seed: settings.seed)
    let amount = settings.intensity

    // Two sine warps with unrelated periods so they don't visibly repeat.
    let waveAmplitude1 = Double(width) * 0.012 * amount
    let waveAmplitude2 = Double(width) * 0.004 * amount
    let wavePeriod1 = rng.double(60...220)
    let wavePeriod2 = rng.double(9...31)
    let phase = rng.double(0...(2 * .pi))

    var rowOffset = [Int](repeating: 0, count: height)
    var rowChroma = [Int](repeating: 0, count: height)
    var rowSource = [Int](repeating: 0, count: height)

    for y in 0..<height {
        let t = Double(y)
        let wave = sin(t / wavePeriod1 * 2 * .pi + phase) * waveAmplitude1
            + sin(t / wavePeriod2 * 2 * .pi) * waveAmplitude2
        rowOffset[y] = Int(wave.rounded())
        rowChroma[y] = Int((Double(width) * 0.0025 * amount).rounded())
        rowSource[y] = y
    }

    // Chunky bands: a minority of horizontal slices get yanked sideways, and a
    // few of those also pull their pixels from a different part of the image.
    // Tears are the loudest thing here, so they stay rare.
    let bandCount = Int(Double(height) * 0.018 * amount) + 1
    for _ in 0..<bandCount {
        let bandHeight = rng.int(2...max(3, Int(Double(height) * 0.025)))
        let top = rng.int(0...max(0, height - 1))
        let shift = Int(rng.double(-0.10...0.10) * Double(width) * amount)
        let tears = rng.chance(0.25)
        let tearFrom = rng.int(0...max(0, height - 1))
        let chroma = Int(rng.double(-0.015...0.015) * Double(width) * amount)

        for y in top..<min(top + bandHeight, height) {
            rowOffset[y] += shift
            rowChroma[y] += chroma
            if tears { rowSource[y] = (tearFrom + (y - top)) % height }
        }
    }

    // Fixed-point scanline factor, applied as (value * factor) >> 8.
    let scanlineFactor = UInt32(((1 - 0.12 * amount) * 256).rounded())

    // Only Sendable values may cross into the concurrent closure, so pull the
    // raw pointers and strides out of the Bitmap objects here.
    let sourcePixels = src.pixels
    let destinationPixels = dst.pixels
    let sourceStride = src.bytesPerRow
    let destinationStride = dst.bytesPerRow

    // Rows are independent and each chunk writes a disjoint slice of dst.
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let chunkHeight = max(16, (height + cores * 4 - 1) / (cores * 4))
    let chunks = (height + chunkHeight - 1) / chunkHeight

    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
        let firstRow = chunk * chunkHeight
        let lastRow = min(firstRow + chunkHeight, height)

        for y in firstRow..<lastRow {
            let source = sourcePixels + rowSource[y] * sourceStride
            let destination = destinationPixels + y * destinationStride
            let offset = rowOffset[y]
            let chroma = rowChroma[y]
            let factor: UInt32 = (y & 1 == 0) ? scanlineFactor : 256

            func startIndex(_ shift: Int) -> Int {
                let index = (-shift) % width
                return index < 0 ? index + width : index
            }
            // Offsets are constant per row, so the source index is just a
            // wrapping counter — no modulo in the inner loop.
            var red = startIndex(offset + chroma)
            var green = startIndex(offset)
            var blue = startIndex(offset - chroma)

            for x in 0..<width {
                destination[x * 4 + 0] = UInt8((UInt32(source[red * 4 + 0]) * factor) >> 8)
                destination[x * 4 + 1] = UInt8((UInt32(source[green * 4 + 1]) * factor) >> 8)
                destination[x * 4 + 2] = UInt8((UInt32(source[blue * 4 + 2]) * factor) >> 8)
                destination[x * 4 + 3] = 255
                red += 1; if red == width { red = 0 }
                green += 1; if green == width { green = 0 }
                blue += 1; if blue == width { blue = 0 }
            }
        }
    }
}

/// In-place block artifacts: small rectangles where a channel is pushed up or
/// down, or pixels are stamped in from somewhere else in the image.
///
/// These are weighted toward *partial* corruption — a halved or lifted channel
/// reads as a signal fault, where a hard 0/255 or an inversion reads as a
/// neon rectangle pasted on top.
func corruptBlocks(_ bitmap: Bitmap, settings: GlitchSettings) {
    let width = bitmap.width
    let height = bitmap.height
    var rng = SplitMix64(seed: settings.seed &+ 0xABCD)
    let count = Int(Double(18) * settings.intensity) + 1

    for _ in 0..<count {
        let blockWidth = rng.int(width / 60 ... max(width / 60 + 1, width / 8))
        let blockHeight = rng.int(2...max(3, height / 60))
        let left = rng.int(0...max(0, width - 1))
        let top = rng.int(0...max(0, height - 1))
        let mode = rng.int(0...2)
        let channel = rng.int(0...2)
        let sourceLeft = rng.int(0...max(0, width - 1))
        let sourceTop = rng.int(0...max(0, height - 1))

        for row in 0..<blockHeight {
            let y = top + row
            if y >= height { break }
            let line = bitmap.pixels + y * bitmap.bytesPerRow
            let sourceLine = bitmap.pixels + ((sourceTop + row) % height) * bitmap.bytesPerRow

            for column in 0..<blockWidth {
                let x = left + column
                if x >= width { break }
                let index = x * 4

                switch mode {
                case 0:  // channel pulled down, not zeroed
                    line[index + channel] = UInt8(UInt32(line[index + channel]) / 2)
                case 1:  // channel lifted halfway toward clipping
                    let value = UInt32(line[index + channel])
                    line[index + channel] = UInt8(value + (255 - value) / 2)
                default: // stamp pixels from elsewhere
                    let sourceIndex = ((sourceLeft + column) % width) * 4
                    line[index + 0] = sourceLine[sourceIndex + 0]
                    line[index + 1] = sourceLine[sourceIndex + 1]
                    line[index + 2] = sourceLine[sourceIndex + 2]
                }
            }
        }
    }
}

func glitch(_ source: Bitmap, settings: GlitchSettings) throws -> Bitmap {
    let output = Bitmap(width: source.width, height: source.height)
    displace(source, into: output, settings: settings)
    corruptBlocks(output, settings: settings)
    return output
}
