import AppKit

/// The ASCII planes, the face they are set in, and the corrupter.
enum AsciiLogTests {
    static func run(_ t: TestHarness) {
        t.suite("AsciiFont") { t in
            // Monaco is the whole reason this needs no asset. If a future macOS drops it
            // or makes it proportional the planes still draw — `AsciiFont` falls back —
            // but the window map's rules go ragged, so it is worth knowing.
            let f = AsciiFont.font(ofSize: 13)
            t.expect(f.isFixedPitch, "the ascii face is monospaced (\(AsciiFont.familyName))")
            t.equal(AsciiFont.familyName, AsciiFont.systemFace,
                    "with no drop-in face it is \(AsciiFont.systemFace)")

            // The grid is ruled by column arithmetic, so equal advances are load bearing:
            // one wider glyph and every box edge after it on that row is a character out.
            // Pure ASCII, and that is the point: Monaco has no box-drawing glyphs, so
            // `┌ ─ │ ░` get substituted from another face and come back 7.83pt against
            // ASCII's 7.80. Three hundredths of a point is three quarters of a character
            // by column 193 — every box edge drifts out of true with the rows above it.
            // This is the check that keeps the window map on characters Monaco actually
            // has; it caught the Unicode set the first time round.
            var widths = Set<Int>()
            for ch in "iWM1l.@#+-|:=*" + String(AsciiLogView.shades) {
                let w = NSAttributedString(string: String(ch), attributes: [.font: f]).size().width
                widths.insert(Int((w * 100).rounded()))
            }
            t.equal(widths.count, 1,
                    "every glyph the planes use advances the same (\(widths.sorted()))")

            let cell = AsciiFont.cell(ofSize: 13)
            t.expect(cell.width > 0 && cell.height > 0, "the cell has a size (\(cell))")
        }

        t.suite("Zalgo") { t in
            let src = "NEED YOUR LOVE"
            let a = Zalgo.corrupt(src, intensity: 0.8, seed: 7)
            let b = Zalgo.corrupt(src, intensity: 0.8, seed: 7)
            let c = Zalgo.corrupt(src, intensity: 0.8, seed: 8)
            t.equal(a, b, "the same seed corrupts identically")
            t.expect(a != c, "a different seed differs")
            // SCALARS, not characters. A combining mark joins the base character's
            // grapheme cluster, so `String.count` is identical before and after — the
            // first version of this test compared `.count` and passed 14 vs 14 while
            // asserting nothing at all.
            t.expect(a.unicodeScalars.count > src.unicodeScalars.count,
                     "marks were actually added (\(a.unicodeScalars.count) vs \(src.unicodeScalars.count) scalars)")
            t.equal(a.count, src.count, "…and they fold into the base characters' clusters")
            t.equal(Zalgo.corrupt(src, intensity: 0, seed: 7), src, "intensity 0 is the identity")

            // The base text has to survive: this is corrupted TEXT, not noise, and the
            // words are the song's. Stripping the combining marks must give it back.
            let stripped = String(a.unicodeScalars.filter { !(0x0300...0x036F).contains($0.value)
                                                        && !(0x0483...0x0489).contains($0.value) })
            t.equal(stripped, src, "the base characters are untouched under the marks")

            // Spaces carry nothing — marks on a space smear the gaps and the line reads
            // as static rather than as text under attack.
            let spaced = Zalgo.corrupt("A B", intensity: 1.0, seed: 3)
            let afterSpace = spaced.unicodeScalars.drop { $0 != " " }.dropFirst().first
            t.equal(afterSpace, "B", "a space is followed by the next base character, not a mark")

            // Monaco does not have U+0489, so the set must not use it — one mark falling
            // back to another face mid-word is worse than no mark.
            t.expect(!Zalgo.corrupt(src, intensity: 1.0, seed: 11).unicodeScalars.contains { $0.value == 0x0489 },
                     "U+0489 is not used — Monaco has no glyph for it")
        }

        t.suite("asciilog in the shipped show") { t in
            guard let url = Bundle.module.url(forResource: "timeline", withExtension: "json"),
                  let tl = try? TimelineLoader.load(from: url) else {
                return t.expect(false, "could not load the shipped show")
            }
            var planes: [(String, ContentSpec)] = []
            for ev in tl.events {
                guard case .openWindow(let p) = ev.action, p.content.kind == "asciilog" else { continue }
                planes.append((p.id, p.content))
                t.equal(p.frame, [0, 0, 0, 0], "\(p.id) fills the screen")
                t.equal(p.content.chrome ?? "", "none", "\(p.id) wears no chrome")
                // The eruption raises a window every fifth of a beat. At the normal level
                // the plane is buried by the second bar — the same reason the shoal floats.
                t.equal(p.level ?? "normal", "floating", "\(p.id) floats over the eruption")
                // Every plane is closed. One left open covers the rest of the show.
                let closed = tl.events.contains {
                    if case .closeWindow(let c) = $0.action { return c.id == p.id }
                    return false
                }
                t.expect(closed, "\(p.id) is closed by the timeline")
            }
            t.equal(planes.count, 4, "the show runs four ascii planes")
            t.equal(planes.map { $0.1.source ?? "hex" }.sorted(),
                    ["hex", "lines", "text", "windows"],
                    "one of each source")

            for (id, c) in planes {
                if let z = c.zalgo { t.expect(z >= 0 && z <= 1, "\(id) zalgo \(z) is in 0…1") }
                if (c.source ?? "") == "lines" {
                    t.expect(!(c.lines ?? []).isEmpty, "\(id) has lines to log")
                }
                if (c.source ?? "") == "windows" {
                    // Without a ground the map does not cover anything, which is the act.
                    t.expect(c.bg != nil, "\(id) has a ground, so it covers the screen")
                }
                // PHOTOSENSITIVITY. A strobe is TWO full-screen changes per cycle, so the
                // band to stay out of is halved. This is the guard that fails a cut that
                // quietly speeds it up; the whole-show measure is the other half.
                if let s = c.strobe, s > 0 {
                    t.expect(s * 2 < 15,
                             "\(id) strobes at \(s)Hz = \(s * 2) full-screen changes/s, under 15")
                }
            }

            // They belong to the ERUPTION, and they have to be gone before the end card.
            //
            // This used to pin them ahead of the segmenter swarm, which was the closing act
            // and had nothing over it. The 2026-09-07 swap put the segmenter FIRST — it
            // opens the second chorus and the eruption buries it — so the planes now run
            // where the swarm used to and that ordering is inverted. What has not changed,
            // and is the thing actually worth pinning, is that four full-screen planes must
            // not still be up when the credits come in underneath them.
            let cardAt = tl.events.compactMap { ev -> Double? in
                if case .credits = ev.action { return ev.fireTime }
                return nil
            }.min()
            if let cardAt {
                let lastClose = tl.events.compactMap { ev -> Double? in
                    if case .closeWindow(let c) = ev.action, c.id.hasPrefix("asciilog") {
                        return ev.fireTime
                    }
                    return nil
                }.max() ?? 0
                t.expect(lastClose <= cardAt,
                         "the ascii planes are all gone before the end card (\(lastClose)s vs \(cardAt)s)")
            }
        }
    }
}
