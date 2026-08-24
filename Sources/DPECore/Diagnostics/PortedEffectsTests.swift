import AppKit

/// The algorithms carried in from the standalone apps.
enum PhotoWallAlgorithmTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    static func run(_ t: TestHarness) {
        t.suite("PhotoWall") { t in
            let cfg = PhotoWallConfig(PhotoWallParams(id: "t"))

            // The fill terminates: a placement aimed at a bare cell always covers that
            // cell, so the loop can't chase slivers forever.
            var costs: [Int] = []
            var stalled = 0
            for _ in 0..<20 {
                let cov = ScreenCoverage(frame: screen, cellSize: cfg.cell)
                var n = 0
                while !cov.isFull && n < 5_000 { cov.add(Planner.next(on: cov, cfg: cfg).rect); n += 1 }
                if !cov.isFull { stalled += 1 }
                costs.append(n)
            }
            t.equal(stalled, 0, "every fill terminated")

            let mean = Double(costs.reduce(0, +)) / Double(costs.count)
            t.expect(mean > 15 && mean < 60,
                     "mean fill cost \(Int(mean)) windows is in range (documented 24-40)")

            // "Full" is exact, not sampled: rectangles snap to the same lattice the
            // coverage grid uses, so no hairline seam can hide between neighbours.
            let cov = ScreenCoverage(frame: screen, cellSize: cfg.cell)
            var rects: [CGRect] = []
            while !cov.isFull { let r = Planner.next(on: cov, cfg: cfg).rect; cov.add(r); rects.append(r) }
            t.equal(cov.bare, 0, "a full screen has zero bare cells")
            t.near(cov.fraction, 1.0, 1e-12, "coverage fraction is exactly 1")

            // The invariant the churn rests on: a window is retired only once every cell
            // it covers is held by something else, so the wall never flashes desktop.
            var retired = 0, exposures = 0
            for _ in 0..<2_000 {
                let r = Planner.next(on: cov, cfg: cfg).rect
                cov.add(r); rects.append(r)
                guard rects.count > cfg.liveWindows,
                      let i = Planner.evictionCandidate(rects, screens: [cov]) else { continue }
                cov.remove(rects.remove(at: i))
                retired += 1
                if cov.bare > 0 { exposures += 1 }
            }
            t.equal(exposures, 0, "retirement never exposed bare screen")
            t.expect(retired > 1_000,
                     "retirement kept up (\(retired) of 2000); a stall means the population creeps")

            let probe = ScreenCoverage(frame: screen, cellSize: 12)
            let r = CGRect(x: 0, y: 0, width: 240, height: 240)
            probe.add(r)
            t.expect(probe.wouldExpose(r), "the only cover for a cell is not removable")
            probe.add(r)
            t.expect(!probe.wouldExpose(r), "a doubly-covered region is safe to thin")
        }
    }
}

enum FileSwarmPatternTests {
    private static let grid = Grid(cols: 16, rows: 10, origin: .zero,
                                   cell: CGSize(width: 82, height: 94))

    static func run(_ t: TestHarness) {
        t.suite("FileSwarm") { t in
            t.equal(PatternLibrary.all().count, 7, "pattern count")
            for id in ["spiral", "wave", "rain", "ripple", "life", "marquee", "constellation"] {
                t.notNil(PatternLibrary.make(id: id), "pattern \(id) is registered")
            }

            for pattern in PatternLibrary.all() {
                // A seeded pattern replays identically — what lets a take be repeated.
                let replay = PatternLibrary.make(id: pattern.id)!
                pattern.reset(grid: grid, seed: 7)
                replay.reset(grid: grid, seed: 7)

                var union = Set<Cell>()
                var outOfBounds = 0
                var diverged = false
                for step in 0..<40 {
                    let cells = pattern.cells(step: step)
                    if cells != replay.cells(step: step) { diverged = true }
                    outOfBounds += cells.filter { !grid.contains($0) }.count
                    union.formUnion(cells)
                }
                t.expect(!union.isEmpty, "\(pattern.id) lit at least one cell")
                t.equal(outOfBounds, 0, "\(pattern.id) stayed in bounds")
                t.expect(!diverged, "\(pattern.id) is deterministic for a fixed seed")
            }

            // The gate is what stops the show touching ~/Desktop unasked: a disabled
            // controller must not even construct a store.
            let c = FileSwarmController()
            t.expect(!c.enabled, "fileSwarm is disabled by default")
            c.begin(FileSwarmParams(id: "x"), at: 0, bpm: 120)
            c.update(now: 1)
            c.closeAll()
        }
    }
}

enum GlitchEngineTests {
    private static func bitmap(_ w: Int, _ h: Int) -> Bitmap {
        let b = Bitmap(width: w, height: h)
        for i in 0..<(w * h * 4) { b.pixels[i] = UInt8((i / 4) % 251) }
        return b
    }

    private static func bytes(_ b: Bitmap) -> [UInt8] {
        Array(UnsafeBufferPointer(start: b.pixels, count: b.width * b.height * 4))
    }

    static func run(_ t: TestHarness) {
        t.suite("Glitch") { t in
            let src = bitmap(160, 120)
            guard
                let a = try? glitch(src, settings: GlitchSettings(intensity: 0.7, seed: 42)),
                let b = try? glitch(src, settings: GlitchSettings(intensity: 0.7, seed: 42)),
                let c = try? glitch(src, settings: GlitchSettings(intensity: 0.7, seed: 43))
            else { return t.expect(false, "glitch threw") }

            t.equal(bytes(a), bytes(b), "the same seed reproduces exactly")
            t.expect(bytes(a) != bytes(c), "a different seed differs")
            t.expect(bytes(a) != bytes(src), "the output actually differs from the input")

            // Intensity scales the effect, but it is NOT an identity at 0: corruptBlocks
            // floors its block count at `Int(18 * intensity) + 1`, so one block is always
            // stamped. Upstream behaviour, kept as-is — what's asserted is the property
            // that actually holds, that 0 disturbs far less than a real intensity does.
            let quiet = bitmap(64, 64)
            if let low = try? glitch(quiet, settings: GlitchSettings(intensity: 0, seed: 1)),
               let high = try? glitch(quiet, settings: GlitchSettings(intensity: 0.9, seed: 1)) {
                let lowChanged = zip(bytes(low), bytes(quiet)).filter { $0 != $1 }.count
                let highChanged = zip(bytes(high), bytes(quiet)).filter { $0 != $1 }.count
                t.expect(lowChanged < highChanged,
                         "intensity 0 disturbs less than 0.9 (\(lowChanged) vs \(highChanged) bytes)")
            } else { t.expect(false, "glitch threw on the intensity sweep") }

            // Frames must stay on disk while displayed (macOS stores the path, not a
            // copy), so the sweep is what stops a show leaving files behind.
            if let url = try? WallpaperImage.solid(gray: 0) {
                t.expect(FileManager.default.fileExists(atPath: url.path), "a frame was written")
                WallpaperImage.cleanUp()
                t.expect(!FileManager.default.fileExists(atPath: url.path), "frames are swept")
            } else { t.expect(false, "could not write a solid frame") }
        }
    }
}

enum ScreenGeometryTests {
    static func run(_ t: TestHarness) {
        t.suite("ScreenGeometry") { t in
            guard let screen = NSScreen.screens.first else {
                return t.expect(false, "no screen to test against")
            }
            let sf = screen.frame

            // Timeline frames are top-left origin; AppKit's are bottom-left. This flip
            // used to be written out three times.
            let r = ScreenGeometry.rect(from: [10, 20, 100, 50], on: screen)
            t.near(r.minX, sf.minX + 10, 0.001, "x measured from the left")
            t.near(r.maxY, sf.maxY - 20, 0.001, "y measured down from the top")

            // Negative coordinates anchor to the far edge, keeping authored frames
            // resolution-independent.
            let far = ScreenGeometry.rect(from: [-36, -36, 176, 64], on: screen)
            t.near(far.maxX, sf.maxX - 36, 0.001, "negative x anchors to the right")
            t.near(far.minY, sf.minY + 36, 0.001, "negative y anchors to the bottom")

            t.notNil(ScreenGeometry.screen(99), "out-of-range screen index falls back")
            t.notNil(ScreenGeometry.screen(-1), "negative screen index falls back")

            let centred = ScreenGeometry.rectOrCentred(nil, size: NSSize(width: 200, height: 100),
                                                       on: screen)
            t.near(centred.midX, sf.midX, 0.001, "no frame given is centred in x")
            t.near(centred.midY, sf.midY, 0.001, "no frame given is centred in y")

            // An incomplete frame array is treated as absent rather than read past its end.
            let short = ScreenGeometry.rectOrCentred([10, 20], size: NSSize(width: 200, height: 100),
                                                     on: screen)
            t.near(short.midX, sf.midX, 0.001, "a short frame array falls back to centred")
        }
    }
}
