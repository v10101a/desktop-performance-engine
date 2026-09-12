import AppKit
import CoreText

/// Every face on this machine that can actually set the show's words.
///
/// The point of the act is that it is the VIEWER's font library — whatever they happen
/// to have installed, including their own `~/Library/Fonts`, which is why this enumerates
/// the system rather than shipping a list. On the machine this was built on that is 238
/// families, 77 of them the user's own.
///
/// **Seventy-three of those 238 cannot set the words** — Apple Braille, Apple Color Emoji,
/// the Hebrew and Arabic faces, and the Wingdings — and a card that lands on one of those
/// is not chaotic, it is a blank window with tofu in it. So every family is asked for
/// glyphs for a probe string first and the ones that cannot are dropped. Measured: 165
/// usable, 77 of the machine's fonts being the user's own.
///
/// Enumerated ONCE. `availableFontFamilies` plus a coverage check per family is tens of
/// milliseconds, and this is used by an act that rebuilds cards several times a second.
enum LyricFontPool {
    /// The characters the lyric ACTUALLY contains, curly apostrophe included.
    ///
    /// That apostrophe is not a nicety. The show's phrases are written with U+2019
    /// (`I CAN\u{2019}T`, `I\u{2019}M GIVING THAT`), and probing with the straight ASCII
    /// quote instead passes nine families that have no glyph for the curly one — so
    /// `CAN\u{2019}T` comes up with a tofu box in the middle of the word. Measured: 174
    /// families pass the straight probe, 165 pass this one.
    ///
    /// It also, usefully, drops Webdings and Wingdings 1–3. Those DO have glyphs for A–Z
    /// — pictograms — so a Latin-only probe keeps them and the card sets the lyric as a
    /// row of dingbats. Not "the words in another face"; just noise.
    private static let probe = "GIVEIT2MEABCDFHJKLNOPQRSUVWXYZ\u{2019}' "

    static let families: [String] = {
        let all = NSFontManager.shared.availableFontFamilies
        var usable: [String] = []
        for family in all {
            guard let font = NSFont(name: family, size: 24) else { continue }
            var chars = Array(probe.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let ok = CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count)
            // A zero glyph is "no glyph for this character" — the tofu box.
            if ok && !glyphs.contains(0) { usable.append(family) }
        }
        NSLog("[DPE] lyric font pool: \(usable.count) of \(all.count) families can set the words")
        // Sorted so a seed picks the same face on the same machine take to take. Across
        // machines it cannot and should not — the act IS the viewer's own library.
        return usable.sorted()
    }()

    /// The face for step `n` of a cycle, or the show's own Hack Bold if the machine has
    /// somehow nothing usable.
    static func font(step: Int, seed: UInt64, ofSize pt: CGFloat) -> NSFont {
        guard !families.isEmpty else { return LyricFont.font(ofSize: pt) }
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(step)))
        let family = families[Int(rng.next() % UInt64(families.count))]
        return NSFont(name: family, size: pt) ?? LyricFont.font(ofSize: pt)
    }
}

/// A lyric card whose face is re-picked from the viewer's own font library on a clock.
///
/// It exists because **the fit has to be redone on every change**. The lyric kind sets
/// its line as large as the window allows by stepping the point size down until the
/// wrapped block fits; different families are wildly different widths at the same size —
/// measured on this machine, a 6.1× spread between the narrowest and widest usable face
/// at 40pt for the same string. Swapping only `label.font` would leave half the faces
/// overflowing the window and the other half a third of the size they should be.
///
/// So each tick picks a face AND re-runs the shrink-to-fit for it. That is the whole
/// class: a timer, a pool, and the fit loop lifted out of `makeEffectContentView` so both
/// callers use the same one rather than two that drift.
final class CyclingLyricView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let text: String
    private let seed: UInt64
    private let hz: Double
    private var step = 0
    private var timer: Timer?

    init(size: NSSize, text: String, fg: NSColor, hz: Double, seed: UInt64) {
        self.text = text
        self.seed = seed
        self.hz = max(0.1, hz)
        super.init(frame: NSRect(origin: .zero, size: size))
        label.stringValue = text
        label.textColor = fg
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        refit()
    }

    required init?(coder: NSCoder) { nil }

    deinit { timer?.invalidate() }

    /// Cycles only while the card is on screen (`WindowVisibility`): the eruptions'
    /// cards are built at load, prewarmed, and fifty of them re-fitting their type three
    /// times a second from then was a steady cost across the whole piece for nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.follow(window)
    }

    private lazy var visibility = WindowVisibility { [weak self] visible in
        self?.setRunning(visible)
    }

    private func setRunning(_ running: Bool) {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            self?.step += 1
            self?.refit()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refit()
    }

    private func refit() {
        let font = LyricFontPool.font(step: step, seed: seed, ofSize: 24)
        let fitted = CyclingLyricView.fit(label: label, text: text, in: bounds.size,
                                          family: font.fontName)
        label.frame = NSRect(x: fitted.pad, y: (bounds.height - fitted.size.height) / 2,
                             width: bounds.width - fitted.pad * 2, height: fitted.size.height)
    }

    /// Shrink to fit, for one family. Lifted from `makeEffectContentView`'s `lyric` case
    /// so the static card and the cycling one cannot drift apart.
    ///
    /// Starts at a fifth of the height and steps down until the wrapped block fits both
    /// ways. A word wider than the window wraps mid-word, which reads as broken, so that
    /// counts as not fitting either.
    @discardableResult
    static func fit(label: NSTextField, text: String, in size: NSSize,
                    family: String?) -> (size: NSSize, pad: CGFloat) {
        let pad = max(8, min(size.width, size.height) * 0.07)
        let room = NSSize(width: size.width - pad * 2, height: size.height - pad * 2)
        var pt = max(12, size.height * 0.22)
        var fitted = NSSize.zero
        while pt > 8 {
            let font = family.flatMap { NSFont(name: $0, size: pt) } ?? LyricFont.font(ofSize: pt)
            label.font = font
            fitted = label.sizeThatFits(NSSize(width: room.width, height: .greatestFiniteMagnitude))
            let widest = text.split(separator: " ")
                .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            if fitted.height <= room.height && widest <= room.width { break }
            pt -= max(1, pt * 0.06)
        }
        return (fitted, pad)
    }
}
