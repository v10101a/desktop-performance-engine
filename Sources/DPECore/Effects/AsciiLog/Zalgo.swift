import Foundation

/// Corrupted text: combining diacriticals stacked over, under and through each glyph so
/// it bleeds into the lines above and below.
///
/// Deterministic — a pure function of (text, intensity, seed) — for the same reason the
/// glitch tear is: an act that re-rolls every frame flickers, and one that re-rolls every
/// take cannot be reviewed. `SplitMix64` is the show's own generator, shared with the icon
/// layouts and the tear.
///
/// Marks go on BASE characters and never on a space: marks on a space have nothing to sit
/// on and just smear the gaps between words, which reads as static rather than as text
/// under attack.
///
/// **Why the bleed works at all.** Measured on Monaco, a corrupted string reports the same
/// line height as a plain one (18.0pt at 14pt either way) — the marks do not push the line
/// box open. Drawn on a fixed grid they therefore overflow into the rows above and below
/// instead of spacing them apart, which is exactly the look. On a face whose metrics grow
/// with the marks the effect would be spacing, not bleeding.
enum Zalgo {
    // The standard three sets. Above and below stack — they are what makes it bleed into
    // neighbouring rows. Through is the overstrike group, kept sparse: a slash on every
    // glyph makes a line unreadable rather than corrupted.
    private static let above: [UInt32] = [
        0x030d, 0x030e, 0x0304, 0x0305, 0x033f, 0x0311, 0x0306, 0x0310, 0x0352, 0x0357,
        0x0351, 0x0307, 0x0308, 0x030a, 0x0342, 0x0343, 0x0344, 0x034a, 0x034b, 0x034c,
        0x0303, 0x0302, 0x030c, 0x0350, 0x0300, 0x0301, 0x030b, 0x030f, 0x0312, 0x0313,
        0x0314, 0x033d, 0x0309, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    ]
    private static let below: [UInt32] = [
        0x0316, 0x0317, 0x0318, 0x0319, 0x031c, 0x031d, 0x031e, 0x031f, 0x0320, 0x0324,
        0x0325, 0x0326, 0x0329, 0x032a, 0x032b, 0x032c, 0x032d, 0x032e, 0x032f, 0x0330,
        0x0331, 0x0332, 0x0333, 0x0339, 0x033a, 0x033b, 0x033c, 0x0345, 0x0347, 0x0348,
        0x0349, 0x034d, 0x034e, 0x0353, 0x0354, 0x0355, 0x0356, 0x0359, 0x035a, 0x0323,
    ]
    /// U+0489 (COMBINING CYRILLIC MILLIONS SIGN) is in every zalgo set on the internet and
    /// is NOT in Monaco — checked, 11 of these 12 are present and that one is not. Left in,
    /// CoreText would substitute some other face for that one mark, so a corrupted word
    /// would carry one glyph in a different font. Dropped instead.
    private static let through: [UInt32] = [0x0315, 0x031b, 0x0338, 0x0337, 0x0361]

    /// `intensity` 0…1 scales how many marks each glyph carries. At 1 a character takes
    /// up to eight above and eight below, which is about where the lines above and below
    /// stop being readable — the cap is the point, not a limitation.
    static func corrupt(_ text: String, intensity: Double, seed: UInt64) -> String {
        let k = min(max(intensity, 0), 1)
        guard k > 0 else { return text }
        var rng = SplitMix64(seed: seed)
        let maxStack = Int((k * 8).rounded())
        var out = String.UnicodeScalarView()
        for ch in text.unicodeScalars {
            out.append(ch)
            if ch == " " || ch == "\n" || ch == "\t" { continue }
            for _ in 0..<Int(rng.nextUnit() * Double(maxStack + 1)) {
                if let s = Unicode.Scalar(above[Int(rng.nextUnit() * Double(above.count))]) {
                    out.append(s)
                }
            }
            for _ in 0..<Int(rng.nextUnit() * Double(maxStack + 1)) {
                if let s = Unicode.Scalar(below[Int(rng.nextUnit() * Double(below.count))]) {
                    out.append(s)
                }
            }
            if rng.nextUnit() < k * 0.35,
               let s = Unicode.Scalar(through[Int(rng.nextUnit() * Double(through.count))]) {
                out.append(s)
            }
        }
        return String(out)
    }
}
