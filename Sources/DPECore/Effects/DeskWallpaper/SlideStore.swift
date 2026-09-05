import AppKit
import ImageIO

/// Decoded slides for the `deskWallpaper` layer path, kept a few ahead of the one on
/// screen.
///
/// The real-wallpaper surface never needed this: it hands macOS a *path* and the window
/// server does the reading. The layer takes a `CGImage`, so somebody has to decode, and
/// the show's slides are full-screen (3024×1964) — around 24 MB each once unpacked, and
/// 10–20 ms of work. Two rules follow.
///
/// **Decode off the main thread, ahead of time.** A slide fetched at the moment it is due
/// costs the pump that whole decode. `prewarm` walks a lookahead window on a background
/// queue so the frame that is due is already sitting in memory.
///
/// **Force the decode where it is asked for.** `CGImageSourceCreateImageAtIndex` hands
/// back a *lazily* decoded image by default: the real work then happens when the
/// compositor first reads the pixels, on the frame it is shown, which is exactly the
/// stall this class exists to avoid. `kCGImageSourceShouldCacheImmediately` moves it back
/// onto the background queue where it belongs.
///
/// Bounded, because holding all nineteen lyric cards decoded is ~450 MB. Slides already
/// played are dropped; the window is small and moves forward.
final class SlideStore {
    /// How many slides ahead of the current one to keep decoded. Three is two swaps of
    /// headroom at the layer's 12 Hz cap plus the one on screen — enough that a decode
    /// never lands in the same tick as the swap that needs it.
    static let lookahead = 3

    private var decoded: [String: CGImage] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.dpe.wallpaper.slides", qos: .userInitiated)

    /// Pixel size to decode to — the layer's own backing size, so nothing is carried at a
    /// resolution the screen cannot show.
    var maxPixel: Int = 3024

    /// The slide, if it is ready. `nil` means "still decoding": the caller drops the tick
    /// rather than blocking the pump, exactly as it does for an in-flight wallpaper swap.
    func image(at url: URL) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return decoded[url.path]
    }

    /// Decode `urls` (the current slide and the next few) if they are not already in hand,
    /// and drop anything outside that window.
    func prewarm(_ urls: [URL]) {
        let window = Array(urls.prefix(Self.lookahead + 1))
        let keep = Set(window.map(\.path))

        lock.lock()
        for path in decoded.keys where !keep.contains(path) { decoded[path] = nil }
        let wanted = window.filter { decoded[$0.path] == nil && !inFlight.contains($0.path) }
        for url in wanted { inFlight.insert(url.path) }
        lock.unlock()

        for url in wanted {
            queue.async { [weak self] in
                let image = SlideStore.decode(url, maxPixel: self?.maxPixel ?? 3024)
                guard let self else { return }
                self.lock.lock()
                self.inFlight.remove(url.path)
                if let image { self.decoded[url.path] = image }
                self.lock.unlock()
                if image == nil {
                    NSLog("[DPE] deskWallpaper: could not decode slide \(url.lastPathComponent)")
                }
            }
        }
    }

    func removeAll() {
        lock.lock()
        decoded.removeAll()
        lock.unlock()
    }

    private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // See the class note: without this the decode follows the image onto the
            // compositor's thread and shows up as a dropped frame instead.
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
