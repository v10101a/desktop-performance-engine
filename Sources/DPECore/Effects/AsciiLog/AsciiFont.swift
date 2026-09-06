import AppKit
import CoreText

/// The face the ASCII plane is set in: **Monaco**, the system's own bitmap-descended
/// monospace, with an optional drop-in override.
///
/// Monaco is on every Mac, which is the point — it needs no asset, no licence file and no
/// registration, and it is the face this machine has been drawing terminals in since
/// 1984. Measured on this system before it was picked:
///
/// - `isFixedPitch` is true and every glyph probed (`iWM1l.@#`) advances 8.4pt at 14pt.
///   That matters more here than anywhere else in the show: the window map rules its
///   boxes by column arithmetic, and a proportional face turns every edge ragged.
/// - It carries 11 of the 12 combining marks `Zalgo` uses. The twelfth, U+0489, is not
///   in Monaco and has been dropped from the set rather than left to fall back to some
///   other face mid-word — see the note there.
///
/// `assets/fonts/pixel/` still wins if it has a face in it. That is the way in for a
/// genuine pixel font later: drop a `.ttf` in and every ASCII act takes it, with the same
/// fixed-pitch check applied. Nothing needs the folder to exist.
enum AsciiFont {
    static let systemFace = "Monaco"
    private static let overrideDir = "assets/fonts/pixel"

    /// The family actually in use, resolved once. Never nil in practice — Monaco is a
    /// system face — but the last fallback is honest about it if it ever is.
    private static let resolved: String? = {
        if let dropped = registerOverride() { return dropped }
        guard let monaco = NSFont(name: systemFace, size: 12) else {
            NSLog("[DPE] ascii font: \(systemFace) is not on this system — falling back to "
                + "the system monospace face")
            return nil
        }
        guard monaco.isFixedPitch else {
            // Belt and braces: a future macOS shipping a proportional "Monaco" would
            // silently ragged every box rule in the window map, and that is the kind of
            // thing nobody looks for.
            NSLog("[DPE] ascii font: \(systemFace) is not fixed pitch on this system — "
                + "falling back to the system monospace face")
            return nil
        }
        return systemFace
    }()

    /// A face dropped into `assets/fonts/pixel/` overrides Monaco. Scanned rather than
    /// named, so installing one is just putting the file there; the first by name wins.
    private static func registerOverride() -> String? {
        let path = resolveResourcePath(overrideDir)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        let faces = names
            .filter { $0.lowercased().hasSuffix(".ttf") || $0.lowercased().hasSuffix(".otf") }
            .sorted()
        guard let first = faces.first else { return nil }
        let url = URL(fileURLWithPath: path).appendingPathComponent(first)
        var error: Unmanaged<CFError>?
        // "Already registered" is a failure by the API's lights and a success by ours —
        // same note as LyricFont. The family is read off the file, not guessed from the
        // filename, which is almost never the family.
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor],
              let desc = descs.first,
              let name = CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute)
                as? String,
              let probe = NSFont(name: name, size: 12) else {
            NSLog("[DPE] ascii font: \(first) would not register — staying on \(systemFace)")
            return nil
        }
        guard probe.isFixedPitch else {
            NSLog("[DPE] ascii font: \(name) is not monospaced — refusing it and staying on "
                + "\(systemFace). The window map rules by column; a proportional face makes "
                + "every edge ragged.")
            return nil
        }
        NSLog("[DPE] ascii font: \(name) (\(first)) overriding \(systemFace)")
        return name
    }

    /// What the diagnostics report, so a run says which face it actually drew in.
    static var familyName: String { resolved ?? "system monospace" }

    static func font(ofSize pt: CGFloat) -> NSFont {
        if let resolved, let f = NSFont(name: resolved, size: pt) { return f }
        return .monospacedSystemFont(ofSize: pt, weight: .regular)
    }

    /// Cell size for a grid set in this face. Measured off the face rather than assumed:
    /// the advance is what every column position is computed from, and hardcoding a
    /// ratio is how a grid drifts a character to the right by the end of a long line.
    static func cell(ofSize pt: CGFloat) -> NSSize {
        let f = font(ofSize: pt)
        let advance = NSAttributedString(string: "0", attributes: [.font: f]).size().width
        // Line height from the face's own metrics, so descenders and the marks that hang
        // below them have somewhere to go.
        return NSSize(width: advance, height: ceil(f.ascender - f.descender + f.leading))
    }
}
