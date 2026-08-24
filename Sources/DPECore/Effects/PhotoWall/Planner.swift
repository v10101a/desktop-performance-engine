import Foundation
import CoreGraphics

/// Pure placement math: given a screen's coverage state, choose the next window
/// rectangle. Kept free of AppKit so it can be simulated headlessly — the upstream
/// photowall app carries the harness (`tools/simulate.sh`) that verifies termination,
/// exact coverage and no-exposure retirement over 60 fills and 4,000 churn steps.
enum Planner {
    /// Returns the rectangle plus whether it was aimed at a still-bare cell —
    /// gap-aimed placements are guaranteed to cover new ground, which the simulator asserts.
    static func next(on cov: ScreenCoverage, cfg: PhotoWallConfig) -> (rect: CGRect, aimedAtGap: Bool) {
        let f = cov.frame
        // Early on, place purely at random; as the screen fills, aim at what's left.
        // `randomBareCentre` returns a cell centre and the rect below always contains
        // it, so every placement covers at least one new cell — which is what makes
        // the fill terminate instead of chasing slivers forever.
        let wantGap = Double.random(in: 0..<1) < max(0.3, cov.fraction)
        let gap = wantGap ? cov.randomBareCentre() : nil
        // Once the screen is full and the wall is just churning, aim mostly at the
        // thinnest-covered spots so photos keep spreading rather than stacking up.
        let thin = (gap == nil && cov.isFull && Double.random(in: 0..<1) < 0.6)
            ? cov.randomShallowCentre() : nil
        let anchor: CGPoint = gap ?? thin
            ?? CGPoint(x: .random(in: f.minX...f.maxX), y: .random(in: f.minY...f.maxY))

        let w = (f.width * Double.random(in: cfg.minFrac...cfg.maxFrac)).rounded()
        let h = (f.height * Double.random(in: cfg.minFrac...cfg.maxFrac)).rounded()

        // The anchor sits at a random spot inside the window, so position varies
        // independently of size. Windows may hang a little off the screen edge.
        var x = anchor.x - Double.random(in: 0.03...0.97) * w
        var y = anchor.y - Double.random(in: 0.03...0.97) * h
        x = clampKeeping(anchor.x, coord: x, size: w, lo: f.minX - w * 0.3, hi: f.maxX - w * 0.7, cell: cfg.cell)
        y = clampKeeping(anchor.y, coord: y, size: h, lo: f.minY - h * 0.3, hi: f.maxY - h * 0.7, cell: cfg.cell)

        // Snap to the coverage lattice. This is what makes "the screen is full" exact
        // rather than sampled: every cell ends up wholly inside or wholly outside each
        // window, so testing cell centres can't miss a hairline seam between two windows.
        let c = cfg.cell
        var sx = f.minX + (((x - f.minX) / c).rounded(.down)) * c
        var sy = f.minY + (((y - f.minY) / c).rounded(.down)) * c
        var sw = max(c * 2, (w / c).rounded() * c)
        var sh = max(c * 2, (h / c).rounded() * c)
        // Keep the anchor cell inside after snapping.
        if sx + sw <= anchor.x { sw = ((anchor.x - sx) / c).rounded(.up) * c + c }
        if sy + sh <= anchor.y { sh = ((anchor.y - sy) / c).rounded(.up) * c + c }
        if sx >= anchor.x { sx = (((anchor.x - f.minX) / c).rounded(.down)) * c + f.minX }
        if sy >= anchor.y { sy = (((anchor.y - f.minY) / c).rounded(.down)) * c + f.minY }
        return (CGRect(x: sx, y: sy, width: sw, height: sh), gap != nil)
    }

    /// Clamp a window origin into `lo...hi` without letting it stop containing `anchor`.
    private static func clampKeeping(_ anchor: Double, coord: Double, size: Double,
                                     lo: Double, hi: Double, cell: Double) -> Double {
        let mustLo = anchor - size + cell     // still contains the anchor cell centre
        let mustHi = anchor - cell
        let l = max(lo, mustLo), h = min(hi, mustHi)
        guard l <= h else { return anchor - size / 2 }
        return min(max(coord, l), h)
    }

    /// Index of the oldest window that can be retired without exposing bare screen.
    /// Only the front of the queue is scanned — if the oldest few are all still
    /// load-bearing, it is cheaper to keep them a moment longer than to search on.
    static func evictionCandidate(_ rects: [CGRect], screens: [ScreenCoverage],
                                  scanLimit: Int = 48) -> Int? {
        for (i, r) in rects.prefix(scanLimit).enumerated() {
            if !screens.contains(where: { $0.wouldExpose(r) }) { return i }
        }
        return nil
    }
}
