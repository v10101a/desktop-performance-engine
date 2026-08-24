import AppKit

/// A pattern is a pure function of step → the set of grid slots that should be
/// occupied right now. The engine diffs consecutive frames and turns the
/// difference into file creations and deletions, so every pattern gets its
/// appear/disappear choreography for free.
protocol SwarmPattern: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func reset(grid: Grid, seed: UInt64)
    func cells(step: Int) -> Set<Cell>
}

/// Stateful patterns step forward incrementally; this keeps them in sync when the
/// engine skips a tick, without letting a big jump stall the main thread.
func stepsToAdvance(from lastStep: Int, to step: Int) -> Int {
    lastStep < 0 ? 1 : max(0, min(step - lastStep, 4))
}

enum PatternLibrary {
    static func all() -> [SwarmPattern] {
        [SpiralPattern(), WavePattern(), RainPattern(), RipplePattern(),
         LifePattern(), MarqueePattern(), ConstellationPattern()]
    }

    static func make(id: String) -> SwarmPattern? {
        all().first { $0.id == id }
    }
}

// MARK: - Spiral

/// A head tracing an Archimedean spiral out from the centre, dragging a tail.
final class SpiralPattern: SwarmPattern {
    let id = "spiral", displayName = "Spiral"
    private var grid = Grid.forMainScreen()
    private var trail: [Cell] = []
    private var theta = 0.0
    private var phaseOffset = 0.0
    private var lastStep = -1
    private let tailLength = 46
    private let growth = 0.42        // radius gained per radian, in grid rows

    func reset(grid: Grid, seed: UInt64) {
        self.grid = grid
        trail = []
        theta = 0
        lastStep = -1
    }

    func cells(step: Int) -> Set<Cell> {
        // Advance incrementally so the tail survives; rebuild if the caller jumps.
        if step <= lastStep { trail = []; theta = 0; phaseOffset = 0; lastStep = -1 }
        for _ in 0..<stepsToAdvance(from: lastStep, to: step) { advance() }
        lastStep = step
        return Set(trail)
    }

    private func advance() {
        let r = growth * theta
        // Sweep by constant arc length rather than constant angle, so the head
        // covers about one slot per tick whether it is near the centre or the rim.
        theta += 0.6 / max(r, 0.6)

        let cx = Double(grid.cols - 1) / 2, cy = Double(grid.rows - 1) / 2
        // The icon grid is far wider than it is tall; stretch x to match.
        let aspect = Double(grid.cols) / Double(max(grid.rows, 1))
        let angle = theta + phaseOffset
        let cell = Cell(col: Int((cx + r * cos(angle) * aspect).rounded()),
                        row: Int((cy + r * sin(angle)).rounded()))
        // Repeats are appended too: the tail is a window over the last N *ticks*,
        // so slots keep ageing out even while the head crawls near the centre.
        if grid.contains(cell) { trail.append(cell) }
        // Once the head runs off the rim it restarts at the centre, rotated a little
        // so the next pass traces new slots instead of freezing the same shape.
        if r > Double(grid.rows) * 0.55 { theta = 0; phaseOffset += 1.1 }
        if trail.count > tailLength { trail.removeFirst(trail.count - tailLength) }
    }
}

// MARK: - Wave

/// Two travelling sinusoids, one per column, crossing each other.
final class WavePattern: SwarmPattern {
    let id = "wave", displayName = "Wave"
    private var grid = Grid.forMainScreen()

    func reset(grid: Grid, seed: UInt64) { self.grid = grid }

    func cells(step: Int) -> Set<Cell> {
        let mid = Double(grid.rows - 1) / 2
        let amp = mid * 0.95
        let phase = Double(step) * 0.32
        // One full period across the screen for the fundamental — any faster and
        // the two waves read as noise at this resolution.
        let k = 2 * Double.pi / Double(max(grid.cols, 1))
        var out = Set<Cell>()
        for col in 0..<grid.cols {
            let x = Double(col) * k
            let fundamental = mid + amp * sin(x + phase)
            let harmonic = mid + amp * 0.55 * sin(2 * x - phase * 0.8)
            for y in [fundamental, harmonic] {
                let cell = Cell(col: col, row: Int(y.rounded()))
                if grid.contains(cell) { out.insert(cell) }
            }
        }
        return out
    }
}

// MARK: - Rain

/// Droplets falling down columns, each with a short trail.
final class RainPattern: SwarmPattern {
    let id = "rain", displayName = "Rain"
    private struct Drop { let col: Int; var head: Double; let speed: Double; let tail: Int }

    private var grid = Grid.forMainScreen()
    private var drops: [Drop] = []
    private var rng = SplitMix64(seed: 1)
    private var lastStep = -1

    func reset(grid: Grid, seed: UInt64) {
        self.grid = grid
        drops = []
        rng = SplitMix64(seed: seed)
        lastStep = -1
    }

    func cells(step: Int) -> Set<Cell> {
        if step <= lastStep { drops = []; lastStep = -1 }
        for _ in 0..<stepsToAdvance(from: lastStep, to: step) { advance() }
        lastStep = step

        var out = Set<Cell>()
        for drop in drops {
            let head = Int(drop.head.rounded())
            for t in 0...drop.tail {
                let cell = Cell(col: drop.col, row: head - t)
                if grid.contains(cell) { out.insert(cell) }
            }
        }
        return out
    }

    private func advance() {
        for i in drops.indices { drops[i].head += drops[i].speed }
        drops.removeAll { $0.head - Double($0.tail) > Double(grid.rows) }
        // Keep roughly half the columns raining at any moment.
        while drops.count < max(4, grid.cols / 2) {
            drops.append(Drop(col: rng.int(0..<grid.cols),
                              head: -rng.unit() * Double(grid.rows),
                              speed: 0.7 + rng.unit() * 0.9,
                              tail: 3 + rng.int(0..<5)))
        }
    }
}

// MARK: - Ripple

/// Expanding rings dropped at random points, overlapping like rain on water.
final class RipplePattern: SwarmPattern {
    let id = "ripple", displayName = "Ripple"
    private struct Ring { let center: Cell; let born: Int }

    private var grid = Grid.forMainScreen()
    private var rings: [Ring] = []
    private var rng = SplitMix64(seed: 1)
    private var lastSpawn = -99

    func reset(grid: Grid, seed: UInt64) {
        self.grid = grid
        rings = []
        rng = SplitMix64(seed: seed)
        lastSpawn = -99
    }

    func cells(step: Int) -> Set<Cell> {
        if step - lastSpawn >= 5 {
            rings.append(Ring(center: Cell(col: rng.int(0..<grid.cols), row: rng.int(0..<grid.rows)),
                              born: step))
            lastSpawn = step
        }
        let maxR = Double(grid.cols + grid.rows)
        rings.removeAll { Double(step - $0.born) * 0.75 > maxR }

        var out = Set<Cell>()
        for ring in rings {
            let r = Double(step - ring.born) * 0.75
            guard r > 0.3 else { out.insert(ring.center); continue }
            for row in 0..<grid.rows {
                for col in 0..<grid.cols {
                    // Squash y so a "circle" on the wide, short icon grid still reads round.
                    let dx = Double(col - ring.center.col)
                    let dy = Double(row - ring.center.row) * 1.9
                    if abs((dx * dx + dy * dy).squareRoot() - r) < 0.55 {
                        out.insert(Cell(col: col, row: row))
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Life

/// Conway's Game of Life on a wrapped grid, reseeded when it stalls.
final class LifePattern: SwarmPattern {
    let id = "life", displayName = "Game of Life"
    private var grid = Grid.forMainScreen()
    private var alive = Set<Cell>()
    private var rng = SplitMix64(seed: 1)
    private var history: [Int] = []
    private var lastStep = -1
    private var seed: UInt64 = 1

    func reset(grid: Grid, seed: UInt64) {
        self.grid = grid
        self.seed = seed
        rng = SplitMix64(seed: seed)
        lastStep = -1
        history = []
        seedBoard()
    }

    private func seedBoard() {
        alive = []
        for row in 0..<grid.rows {
            for col in 0..<grid.cols where rng.unit() < 0.32 {
                alive.insert(Cell(col: col, row: row))
            }
        }
    }

    func cells(step: Int) -> Set<Cell> {
        if step <= lastStep { rng = SplitMix64(seed: seed); seedBoard(); history = []; lastStep = -1 }
        for _ in 0..<stepsToAdvance(from: lastStep, to: step) { evolve() }
        lastStep = step

        // A dead or frozen board is boring — restart it.
        history.append(alive.count)
        if history.count > 14 { history.removeFirst() }
        if alive.isEmpty || (history.count == 14 && Set(history).count <= 2) {
            seedBoard()
            history = []
        }
        return alive
    }

    private func evolve() {
        var counts: [Cell: Int] = [:]
        for cell in alive {
            for dr in -1...1 {
                for dc in -1...1 where !(dr == 0 && dc == 0) {
                    let n = Cell(col: (cell.col + dc + grid.cols) % grid.cols,
                                 row: (cell.row + dr + grid.rows) % grid.rows)
                    counts[n, default: 0] += 1
                }
            }
        }
        var next = Set<Cell>()
        for (cell, n) in counts where n == 3 || (n == 2 && alive.contains(cell)) {
            next.insert(cell)
        }
        alive = next
    }
}

// MARK: - Marquee

/// Scrolling text, rendered by Core Graphics straight into the icon grid — one
/// glyph pixel per file. Any message works; no hand-built bitmap font.
final class MarqueePattern: SwarmPattern {
    let id = "marquee", displayName = "Marquee"
    static var message = "FILE SWARM  ·  "

    private var grid = Grid.forMainScreen()
    private var bitmap: [[Bool]] = []   // [column][row]
    private var renderedFor = ""

    func reset(grid: Grid, seed: UInt64) {
        self.grid = grid
        render()
    }

    func cells(step: Int) -> Set<Cell> {
        if renderedFor != Self.message + "\(grid.rows)" { render() }
        guard !bitmap.isEmpty else { return [] }
        var out = Set<Cell>()
        for col in 0..<grid.cols {
            let src = ((col + step) % bitmap.count + bitmap.count) % bitmap.count
            for row in 0..<min(grid.rows, bitmap[src].count) where bitmap[src][row] {
                out.insert(Cell(col: col, row: row))
            }
        }
        return out
    }

    private func render() {
        renderedFor = Self.message + "\(grid.rows)"
        bitmap = []
        let rows = grid.rows
        guard rows > 1 else { return }

        let font = NSFont.systemFont(ofSize: 64, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: Self.message, attributes: attrs)
        let natural = string.size()
        guard natural.height > 0, natural.width > 0 else { return }

        // Scale the rendering so the text's full line height maps onto the grid's
        // rows, then threshold the antialiased coverage into on/off slots.
        let scale = Double(rows) / Double(natural.height)
        let width = max(1, Int((natural.width * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: rows,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: rows))
        ctx.scaleBy(x: scale, y: scale)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(at: .zero)
        NSGraphicsContext.current = previous

        guard let data = ctx.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * rows)
        // Core Graphics rows run bottom-up; grid rows run top-down.
        bitmap = (0..<width).map { x in
            (0..<rows).map { row in pixels[(rows - 1 - row) * width + x] > 96 }
        }
        // A gap of blank columns so the message reads as a loop, not a wall.
        bitmap.append(contentsOf: Array(repeating: Array(repeating: false, count: rows),
                                        count: max(2, grid.cols / 2)))
    }
}

// MARK: - Constellation

/// Random walkers leaving short trails — the loosest, most organic pattern.
final class ConstellationPattern: SwarmPattern {
    let id = "constellation", displayName = "Constellation"
    private var grid = Grid.forMainScreen()
    private var walkers: [Cell] = []
    private var trails: [[Cell]] = []
    private var rng = SplitMix64(seed: 1)
    private var lastStep = -1
    private let tail = 7

    func reset(grid: Grid, seed: UInt64) {
        self.grid = grid
        rng = SplitMix64(seed: seed)
        lastStep = -1
        walkers = (0..<6).map { _ in Cell(col: rng.int(0..<grid.cols), row: rng.int(0..<grid.rows)) }
        trails = walkers.map { [$0] }
    }

    func cells(step: Int) -> Set<Cell> {
        if step <= lastStep { reset(grid: grid, seed: 1) }
        for _ in 0..<stepsToAdvance(from: lastStep, to: step) { advance() }
        lastStep = step
        return Set(trails.flatMap { $0 })
    }

    private func advance() {
        for i in walkers.indices {
            var next = walkers[i]
            for _ in 0..<6 {   // resample rather than stick to a wall
                let dc = rng.int(0..<3) - 1
                let dr = rng.int(0..<3) - 1
                let candidate = Cell(col: walkers[i].col + dc, row: walkers[i].row + dr)
                if grid.contains(candidate) { next = candidate; break }
            }
            walkers[i] = next
            trails[i].append(next)
            if trails[i].count > tail { trails[i].removeFirst(trails[i].count - tail) }
        }
    }
}
