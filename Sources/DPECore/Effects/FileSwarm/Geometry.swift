import AppKit

/// A slot in the desktop icon grid. (0,0) is the top-left slot.
struct Cell: Hashable, Comparable {
    let col: Int
    let row: Int

    static func < (a: Cell, b: Cell) -> Bool {
        a.row == b.row ? a.col < b.col : a.row < b.row
    }
}

/// Maps grid slots to Finder desktop coordinates.
///
/// Finder's `desktop position` uses a top-left origin with y growing downward —
/// the opposite of AppKit's screen coordinates — so the grid is defined directly
/// in Finder space and never flipped.
struct Grid {
    let cols: Int
    let rows: Int
    let origin: CGPoint
    let cell: CGSize

    var count: Int { cols * rows }

    func point(_ c: Cell) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(c.col) * cell.width,
                y: origin.y + CGFloat(c.row) * cell.height)
    }

    func contains(_ c: Cell) -> Bool {
        c.col >= 0 && c.col < cols && c.row >= 0 && c.row < rows
    }

    /// Grid sized to the main screen, insetting the menu bar and the Dock so the
    /// icons we place always land somewhere the user can actually see them.
    static func forMainScreen(cellSize: CGSize = CGSize(width: 82, height: 94)) -> Grid {
        let size = (NSScreen.main ?? NSScreen.screens.first)?.frame.size
            ?? CGSize(width: 1440, height: 900)
        let inset = NSEdgeInsets(top: 56, left: 60, bottom: 110, right: 60)
        let usableW = max(size.width - inset.left - inset.right, cellSize.width)
        let usableH = max(size.height - inset.top - inset.bottom, cellSize.height)
        return Grid(cols: max(1, Int(usableW / cellSize.width)),
                    rows: max(1, Int(usableH / cellSize.height)),
                    origin: CGPoint(x: inset.left, y: inset.top),
                    cell: cellSize)
    }
}

// DPE already ships SplitMix64 (Effects/DesktopIconController.swift) with the identical
// algorithm and constants, so FileSwarm's copy is gone and these are the two helpers its
// patterns used. Upstream's init also mapped seed 0 to the golden-ratio constant; that
// guard now lives in FileSwarmController, so every seeded call site here is unchanged.
extension SplitMix64 {
    mutating func unit() -> Double { nextUnit() }

    mutating func int(_ range: Range<Int>) -> Int {
        guard range.count > 0 else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(range.count))
    }
}
