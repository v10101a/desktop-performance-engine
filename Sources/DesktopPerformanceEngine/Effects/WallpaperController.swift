import AppKit

/// Swaps the desktop wallpaper during the show and restores the original per-screen
/// image afterward. `NSWorkspace.setDesktopImageURL` needs no special permission.
final class WallpaperController {
    /// Off by default. Only true when the timeline sets `meta.allowWallpaper = true`,
    /// acknowledging the swap may not fully restore (see Meta.allowWallpaper).
    var enabled = false

    /// Resolves relative `path` params against the timeline file's directory.
    var baseDir: URL?

    private var original: [(screen: NSScreen, url: URL)] = []
    private var generatedColors: [String: URL] = [:]

    var hasSnapshot: Bool { !original.isEmpty }

    // MARK: - Snapshot / restore

    func snapshot() {
        original = NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return (screen, url)
        }
        NSLog("[DPE] wallpaper snapshot: \(original.count) screen(s)")
    }

    func restore() {
        guard hasSnapshot else { return }
        for (screen, url) in original {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        NSLog("[DPE] wallpaper restored (\(original.count) screen(s))")
    }

    // MARK: - Apply

    func set(_ p: WallpaperParams) {
        guard enabled else {
            NSLog("[DPE] wallpaper event skipped — disabled for reversibility (set meta.allowWallpaper=true to enable)")
            return
        }
        guard let url = resolve(p) else {
            NSLog("[DPE] wallpaper: could not resolve image (path=\(p.path ?? "nil") color=\(p.color ?? "nil"))")
            return
        }
        let screens: [NSScreen]
        if let i = p.screen, i >= 0, i < NSScreen.screens.count {
            screens = [NSScreen.screens[i]]
        } else {
            screens = NSScreen.screens
        }
        NSLog("[DPE] wallpaper set → \(url.path) exists=\(FileManager.default.fileExists(atPath: url.path)) on \(screens.count) screen(s)")
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                NSLog("[DPE] wallpaper set error: \(error)")
            }
        }
    }

    // MARK: - Image resolution

    private func resolve(_ p: WallpaperParams) -> URL? {
        if let path = p.path {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            if let base = baseDir { return base.appendingPathComponent(path) }
            return URL(fileURLWithPath: path)
        }
        if let color = p.color { return solidColorImage(hex: color) }
        return nil
    }

    /// Render (and cache) a solid-color image so `color` wallpapers work without an asset.
    private func solidColorImage(hex: String) -> URL? {
        if let cached = generatedColors[hex] { return cached }
        guard let color = NSColor(hex: hex) else { return nil }
        let size = NSSize(width: 1920, height: 1080)
        let image = NSImage(size: size)
        image.lockFocus()
        color.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpe_wall_\(hex.replacingOccurrences(of: "#", with: "")).png")
        do {
            try png.write(to: url)
            generatedColors[hex] = url
            return url
        } catch {
            NSLog("[DPE] wallpaper: failed to write color image: \(error)")
            return nil
        }
    }
}
