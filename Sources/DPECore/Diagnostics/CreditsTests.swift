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

            // The restart bar: rises, catches at 60%, then finishes. A still can only
            // catch one frame of that, so the shape is asserted here.
            let rise = RestartCardView.risePortion, pause = RestartCardView.pausePortion
            t.near(Double(RestartCardView.barFraction(at: 0)), 0, 0.001, "bar starts empty")
            t.near(Double(RestartCardView.barFraction(at: rise)), 0.6, 0.001,
                   "bar reaches exactly 60% at the catch")
            t.near(Double(RestartCardView.barFraction(at: rise + pause)), 0.6, 0.001,
                   "bar is still at 60% when the pause ends — it holds, not creeps")
            t.near(Double(RestartCardView.barFraction(at: (rise + rise + pause) / 2)), 0.6, 0.001,
                   "bar sits at 60% through the middle of the pause")
            t.near(Double(RestartCardView.barFraction(at: 1)), 1.0, 0.001,
                   "bar finishes full — it resumes after the pause")
            t.expect(RestartCardView.barFraction(at: rise + pause + 0.05) > 0.6,
                     "bar moves again once the pause is over")
            // Monotonic: it must never go backwards at a segment join.
            var last: CGFloat = -1, monotonic = true
            for i in 0...200 {
                let v = RestartCardView.barFraction(at: Double(i) / 200)
                if v < last - 0.0001 { monotonic = false }
                last = v
            }
            t.expect(monotonic, "bar never runs backwards across the joins")

            // By the line: `linesPerSecond` lands whole lines, the way the probe reveals
            // its report, so the copy is never seen half-spelt. The first thing on the
            // terminal is the whole first line; the copy still finishes; and while it
            // types, the caret waits on its own line under the last one, like a prompt.
            let byLine = CreditsController()
            byLine.begin(CreditsParams(id: "l", lines: lines, showInfo: false, linesPerSecond: 6,
                                       outro: false),
                         at: 0, bpm: 128)
            var first = "", sawPromptCaret = false, final = ""
            let lineDeadline = Date().addingTimeInterval(3.0)
            while Date() < lineDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                let raw = byLine.credits_rawTextForTesting ?? ""
                let typed = raw.replacingOccurrences(of: "\u{2588}", with: "")
                if first.isEmpty, !typed.isEmpty { first = typed }
                if raw.hasSuffix("\n\u{2588}") { sawPromptCaret = true }
                final = typed
                if final == lines.joined(separator: "\n") { break }
            }
            t.expect(first == "GiveIt2Me" || first == "GiveIt2Me\n",
                     "typing by the line lands the whole first line at once — first saw \"\(first)\"")
            t.expect(sawPromptCaret, "by the line, the caret waits on the next line while it types")
            t.equal(final, lines.joined(separator: "\n"), "typing by the line finishes the copy")
            byLine.closeAll()

            // The layout is a centred group, and every window stays on the screen.
            let sf = NSRect(x: 0, y: 0, width: 1512, height: 982)
            let lay = CreditsController.layout(in: sf, photo: NSSize(width: 520, height: 500),
                                               roll: NSSize(width: 450, height: 380),
                                               info: NSSize(width: 440, height: 230), showInfo: true)
            let groupMidX: CGFloat = (lay.photo.minX + lay.roll.maxX) / 2
            t.near(groupMidX, sf.midX, 1,
                   "the photo + credits group is centred on the screen")
            t.expect(lay.photo.maxX > lay.roll.minX, "the photo laps over the credits' edge")
            t.expect(lay.info.minY < lay.roll.minY && abs(lay.info.maxX - lay.roll.maxX) < 0.5,
                     "the summary sits under the credits, flush right with them")
            for r in [lay.photo, lay.roll, lay.info] {
                t.expect(sf.contains(r), "every end-card window is on the screen — \(r)")
            }
            let tiny = NSRect(x: 0, y: 0, width: 1000, height: 640)
            let squeezed = CreditsController.layout(in: tiny, photo: NSSize(width: 520, height: 500),
                                                    roll: NSSize(width: 450, height: 380),
                                                    info: NSSize(width: 440, height: 230), showInfo: true)
            for r in [squeezed.photo, squeezed.roll, squeezed.info] {
                t.expect(tiny.contains(r), "a small screen shifts the windows on rather than losing them — \(r)")
            }
            // A tilted card's window is its bounding box, never smaller than the card.
            let box = CreditsController.tiltedBounds(NSSize(width: 400, height: 300), degrees: -4)
            t.expect(box.width > 400 && box.height > 300, "the tilted card's box is larger than the card")
            let flat = CreditsController.tiltedBounds(NSSize(width: 400, height: 300), degrees: 0)
            t.near(flat.width, 400, 0.001, "no tilt, no growth")

            // The caption is a serif — Apple Garamond where installed, Hoefler Text
            // otherwise — never the handwriting face it used to be.
            let face = CreditsController.captionFont(size: 20).fontName
            t.expect(face.hasPrefix("AppleGaramond") || face.hasPrefix("HoeflerText") || face == "Georgia",
                     "the caption face is a Mac serif — got \(face)")

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
