import Foundation
import CoreGraphics

/// A grid over one screen recording, per cell, **how many windows cover it**.
///
/// A plain covered/bare flag is enough to fill the screen once, but not to keep
/// filling it: retiring an old window has to be proved safe first, and that needs
/// to know whether anything else is underneath. Depth counts make both questions
/// exact — `bare` for "is the screen full", `wouldExpose` for "can this one go".
///
/// Window rectangles are snapped to this same lattice (see Planner), so every cell
/// is wholly inside or wholly outside each window and testing cell centres cannot
/// miss a hairline seam.
final class ScreenCoverage {
    let frame: CGRect
    let cellSize: Double
    private let cols: Int
    private let rows: Int
    private var depth: [Int]
    /// Number of cells no window covers.
    private(set) var bare: Int

    init(frame: CGRect, cellSize: Double) {
        self.frame = frame
        self.cellSize = cellSize
        cols = max(1, Int(ceil(frame.width / cellSize)))
        rows = max(1, Int(ceil(frame.height / cellSize)))
        depth = Array(repeating: 0, count: cols * rows)
        bare = cols * rows
    }

    var total: Int { cols * rows }
    var fraction: Double { total == 0 ? 1 : Double(total - bare) / Double(total) }
    var isFull: Bool { bare == 0 }

    private func centre(_ i: Int) -> CGPoint {
        CGPoint(x: frame.minX + (Double(i % cols) + 0.5) * cellSize,
                y: frame.minY + (Double(i / cols) + 0.5) * cellSize)
    }

    /// Runs `body` over every cell whose centre lies inside `rect`.
    private func forEachCell(in rect: CGRect, _ body: (Int) -> Void) {
        guard !rect.intersection(frame).isNull else { return }
        let c0 = max(0, Int(floor((rect.minX - frame.minX) / cellSize - 0.5)))
        let c1 = min(cols - 1, Int(ceil((rect.maxX - frame.minX) / cellSize)))
        let r0 = max(0, Int(floor((rect.minY - frame.minY) / cellSize - 0.5)))
        let r1 = min(rows - 1, Int(ceil((rect.maxY - frame.minY) / cellSize)))
        guard c0 <= c1, r0 <= r1 else { return }
        for row in r0...r1 {
            for col in c0...c1 {
                let i = row * cols + col
                if rect.contains(centre(i)) { body(i) }
            }
        }
    }

    func add(_ rect: CGRect) {
        forEachCell(in: rect) { i in
            if depth[i] == 0 { bare -= 1 }
            depth[i] += 1
        }
    }

    func remove(_ rect: CGRect) {
        forEachCell(in: rect) { i in
            guard depth[i] > 0 else { return }
            depth[i] -= 1
            if depth[i] == 0 { bare += 1 }
        }
    }

    /// True if removing this window would leave bare screen behind.
    func wouldExpose(_ rect: CGRect) -> Bool {
        var exposes = false
        forEachCell(in: rect) { i in if depth[i] <= 1 { exposes = true } }
        return exposes
    }

    /// Centre of a random cell no window covers.
    func randomBareCentre() -> CGPoint? {
        guard bare > 0 else { return nil }
        for _ in 0..<24 {                                    // cheap rejection sampling
            let i = Int.random(in: 0..<depth.count)
            if depth[i] == 0 { return centre(i) }
        }
        var nth = Int.random(in: 0..<bare)                   // exact fallback when nearly full
        for i in depth.indices where depth[i] == 0 {
            if nth == 0 { return centre(i) }
            nth -= 1
        }
        return nil
    }

    /// Centre of a random cell among the thinnest-covered ones. Aiming here while the
    /// wall churns keeps new photos spread over the screen instead of piling up.
    func randomShallowCentre() -> CGPoint? {
        guard let min = depth.min() else { return nil }
        var pick: Int? = nil
        var seen = 0
        for i in depth.indices where depth[i] == min {       // reservoir sample
            seen += 1
            if Int.random(in: 0..<seen) == 0 { pick = i }
        }
        return pick.map(centre)
    }

    func reset() {
        for i in depth.indices { depth[i] = 0 }
        bare = total
    }
}
