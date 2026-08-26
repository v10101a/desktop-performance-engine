import AppKit

/// The end card's copy is the last thing the piece says, and it types itself out. These
/// pin the two properties that make that work at all.
enum CreditsTests {
    static func run(_ t: TestHarness) {
        t.suite("credits") { t in
            // The copy is authored at the last beat of the track, so `PerformanceEngine
            // .step` reaches its end-of-piece branch on the next tick and — with `hold`
            // set — calls `pause()`, which stops the pump. If the typing were driven by
            // `update(now:)` like every other effect, it would freeze a character or two
            // in and stay frozen for the whole hold. It runs on its own wall-clock timer
            // instead; this asserts the copy still advances with the engine hook never
            // being called.
            let c = CreditsController()
            let lines = ["GiveIt2Me", "by DJ_Dave", "", "Bye"]
            // `outro: false` — the ending quits the app, which a test must not do.
            c.begin(CreditsParams(id: "t", lines: lines, showInfo: false,
                                  charsPerSecond: 200, outro: false),
                    at: 0, bpm: 128)
            let deadline = Date().addingTimeInterval(2.0)
            var typed = ""
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                typed = c.typedTextForTesting ?? ""
                if typed.hasSuffix("Bye") { break }
            }
            t.equal(typed, lines.joined(separator: "\n"),
                    "credits finish typing without the engine's update(now:) hook")

            // Interior blanks are the stanza breaks in the real copy. The original code
            // filtered every empty entry out, which collapsed the three stanzas into one.
            t.expect(typed.contains("DJ_Dave\n\nBye"),
                     "interior blank lines survive as stanza breaks")
            c.closeAll()

            // The outro is on unless a show turns it off: the piece ends by quitting.
            let defaults = CreditsParams(id: "d")
            t.equal(defaults.outro ?? true, true, "outro defaults on")
            t.equal(defaults.glitchSeconds ?? 0.5, 0.5, "glitch defaults to half a second")

            // The show names the backdrop by path. A missing file only logs and falls
            // back to black, so nothing else would catch it going astray.
            let tile = resolveResourcePath("assets/credits_tile.png")
            t.expect(FileManager.default.fileExists(atPath: tile),
                     "the end card's tile asset resolves — looked at \(tile)")

            // Nothing in the end card may write to the tile asset. An earlier version
            // keyed the artwork's white out with `NSBitmapImageRep.setColor`, which writes
            // through to the backing store — and an `NSImage` loaded from a path can be
            // backed by the mapped file, so building the card silently edited a committed
            // asset on disk. The keying is gone; this pins that the card stays read-only.
            let before = (try? Data(contentsOf: URL(fileURLWithPath: tile))) ?? Data()
            let probe = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            probe.wantsLayer = true
            CreditsController.addDriftingTile("assets/credits_tile.png", to: probe,
                                              secondsPerTile: 4, padding: 1.0, scale: 0.05)
            let after = (try? Data(contentsOf: URL(fileURLWithPath: tile))) ?? Data()
            t.expect(!before.isEmpty && before == after,
                     "building the tiled backdrop leaves the asset file untouched")

            // The dump is pixelated and 1-bit-per-channel: every pixel it emits must be
            // a corner of the colour cube, never an intermediate value.
            let frames = OutroController.previewFrames(from: nil, size: NSSize(width: 320, height: 200))
            t.expect(frames.count == 8, "the dump renders eight frames — got \(frames.count)")
            if let first = frames.first,
               let data = NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:]),
               let rep = NSBitmapImageRep(data: data) {
                var offGrid = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                        guard let c = rep.colorAt(x: x, y: y) else { continue }
                        for ch in [c.redComponent, c.greenComponent, c.blueComponent]
                        where ch > 0.02 && ch < 0.98 { offGrid += 1 }
                    }
                }
                t.equal(offGrid, 0, "every channel is hard 0 or 1 — \(offGrid) samples were neither")
            }
        }
    }
}
