import AppKit

/// The lyric card's shrink-to-fit, across every face the viewer's machine can offer it.
///
/// The eruption re-picks the font three times a second out of ~174 families, and those
/// families differ by about 6× in width at one point size. So the fit is not a detail of
/// one card — it is the thing that has to hold for every face in the pool, and the only
/// way to know it does is to try them all.
enum LyricFontTests {
    static func run(_ t: TestHarness) {
        t.suite("lyric font cycling") { t in
            let pool = LyricFontPool.families
            t.expect(pool.count > 20, "the pool has \(pool.count) usable families")

            // Nothing in the pool may be a face that cannot set the words — that is the
            // whole reason the pool is filtered rather than being `availableFontFamilies`.
            // Braille and emoji have no Latin at all. The Wingdings DO have glyphs for
            // A–Z — pictograms — so a Latin-only probe keeps them and the card sets the
            // lyric as a row of dingbats; they are excluded by the curly apostrophe,
            // which they lack. Both failure modes, pinned.
            for family in ["Apple Braille", "Apple Color Emoji", "Webdings",
                           "Wingdings", "Wingdings 2", "Wingdings 3"] where
                NSFontManager.shared.availableFontFamilies.contains(family) {
                t.expect(!pool.contains(family), "\(family) is filtered out of the pool")
            }

            // Deterministic per (seed, step), so a take is reproducible on one machine.
            let a = LyricFontPool.font(step: 4, seed: 7700, ofSize: 30)
            let b = LyricFontPool.font(step: 4, seed: 7700, ofSize: 30)
            let c = LyricFontPool.font(step: 5, seed: 7700, ofSize: 30)
            t.equal(a.fontName, b.fontName, "the same (seed, step) picks the same face")
            t.expect(a.fontName != c.fontName || pool.count == 1,
                     "the next step picks a different one")

            // THE FIT, over every face in the pool, at the smallest card the eruption
            // opens (`max(w, 260)` wide) and the longest word the lyric contains.
            //
            // A word wider than the card wraps MID-WORD, which reads as broken rather
            // than as chaotic — "MY CURRENTS" coming up as "MY CURRENT / S" is the exact
            // failure this is here to catch.
            // The REAL smallest card the eruption opens and the REAL phrases, curly
            // apostrophes and all — read off the generated timeline rather than guessed.
            // The first version of this test used 260×150 and straight quotes, passed,
            // and proved nothing about the show: the cards are 293×207 at their smallest
            // and the lyric is written with U+2019.
            let card = NSSize(width: 293, height: 207)
            let phrases = ["ALL I GOT", "I CAN\u{2019}T GET ENOUGH", "I TOLD YOU THAT I",
                           "I\u{2019}M GIVING THAT", "MY CURRENTS", "NEED YOUR LOVE",
                           "OF THIS FEELING BABY", "RUNNING UP", "SO GIVE IT TO ME",
                           "SO GIVE IT UP", "WHAT I WANT"]
            var broken: [String] = []
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            for family in pool {
                for phrase in phrases {
                    label.stringValue = phrase
                    let fitted = CyclingLyricView.fit(label: label, text: phrase,
                                                      in: card, family: family)
                    let room = card.width - fitted.pad * 2
                    let widest = phrase.split(separator: " ")
                        .map { (String($0) as NSString)
                            .size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 12)]).width }
                        .max() ?? 0
                    if widest > room + 0.5 { broken.append("\(family)/\(phrase)") }
                }
            }
            t.equal(broken.count, 0,
                    "every face sets every phrase without wrapping mid-word"
                    + (broken.isEmpty ? "" : " — \(broken.prefix(6).joined(separator: ", "))"))
        }
    }
}
