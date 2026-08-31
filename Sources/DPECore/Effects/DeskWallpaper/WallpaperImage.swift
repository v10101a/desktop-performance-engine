import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Image plumbing shared by the `deskWallpaper` modes; the per-mode pixel work stays
/// in `GlitchImage.swift`.
///
/// macOS stores the *path* of a wallpaper, not a copy of the image, so every frame this
/// writes has to stay on disk while it is displayed. They live in a `DPE` folder under
/// Application Support and are swept by `cleanUp()`.
enum WallpaperImage {
    /// Wallpapers are stretched to fill, so the strobe frames are deliberately tiny —
    /// a 64×64 PNG keeps each swap cheap when they're swapping at ~17 Hz.
    static let solidSize = 64

    static let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
        .allowClipping: true,
    ]

    /// Frames written by this run. Kept so `cleanUp()` can remove exactly what it made.
    private static var written: Set<String> = []

    static func supportDirectory() throws -> URL {
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("DPE/wallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Solid-grey PNG, cached by level — the strobe reuses two files forever rather
    /// than writing a new one per toggle.
    /// A solid grey. Kept as the `strobe` mode's entry point; `solid(hex:)` is the
    /// general case underneath it.
    static func solid(gray: CGFloat) throws -> URL {
        let name = String(format: "solid-%03d.png", Int(gray * 255))
        let url = try supportDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { written.insert(url.path); return url }

        guard let context = CGContext(
            data: nil, width: solidSize, height: solidSize, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw GlitchError("could not create a \(solidSize)×\(solidSize) bitmap context") }

        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: solidSize, height: solidSize))
        guard let image = context.makeImage() else {
            throw GlitchError("could not render the solid bitmap")
        }
        try write(image, to: url)
        return url
    }

    /// A solid colour, cached by hex so the show writes one file per colour no matter
    /// how many times the event fires.
    static func solid(hex: String) throws -> URL {
        // Parsed straight back out of the hex and written into an sRGB context, rather
        // than round-tripped through `NSColor.usingColorSpace(.deviceRGB)`. That
        // conversion shifts the value — an authored rgb(2, 10, 245) came back off by ten
        // in the blue channel — and the desktop is meant to be exactly the colour the
        // timeline asked for.
        var t = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else {
            throw GlitchError("not a colour: \(hex)")
        }
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        let name = "solid-" + hex.replacingOccurrences(of: "#", with: "").lowercased() + ".png"
        let url = try supportDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { written.insert(url.path); return url }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: solidSize, height: solidSize, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw GlitchError("could not create a \(solidSize)×\(solidSize) bitmap context") }
        context.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])
                             ?? CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: solidSize, height: solidSize))
        guard let image = context.makeImage() else {
            throw GlitchError("could not render the solid bitmap")
        }
        try write(image, to: url)
        return url
    }

    /// AppKit ignores `setDesktopImageURL` when the URL matches what is already set, so
    /// modes that re-apply a changing image need a fresh filename each pass.
    static func uniqueURL(prefix: String, sequence: Int) throws -> URL {
        try supportDirectory().appendingPathComponent("\(prefix)-\(sequence).jpg")
    }

    static func write(_ image: CGImage, to url: URL, quality: Double = 0.92) throws {
        let type = url.pathExtension.lowercased() == "png"
            ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type as CFString, 1, nil
        ) else { throw GlitchError("could not open \(url.path) for writing") }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw GlitchError("could not write the image to \(url.path)")
        }
        written.insert(url.path)
    }

    static func load(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GlitchError("could not read an image from \(url.path)")
        }
        return image
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Screenshot of one display, for `recursive`.
    ///
    /// Needs Screen Recording. Async, so the caller kicks this off and applies the
    /// result when it lands — the show never blocks on it.
    ///
    /// `SCScreenshotManager` is macOS 14+ and DPE deploys to 13, so the older path uses
    /// `CGDisplayCreateImage`. That is deprecated on 14 (hence the guard rather than
    /// using it unconditionally) but functional, and gated by the same permission.
    static func captureDisplay(_ id: CGDirectDisplayID) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw GlitchError("display \(id) is not available to capture")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                             configuration: config)
        }
        guard let image = CGDisplayCreateImage(id) else {
            throw GlitchError("could not capture display \(id)")
        }
        return image
    }

    /// Remove every frame this run wrote. Called from restore, so the show leaves no
    /// files behind on the way out.
    static func cleanUp() {
        for path in written {
            try? FileManager.default.removeItem(atPath: path)
        }
        written.removeAll()
    }
}
