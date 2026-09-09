import Foundation
import ImageIO

/// Recursively finds real photo files under the given roots and hands them out in a
/// shuffled, endlessly recycling order.
///
/// The filtering here is not incidental. A plain walk of this machine's home folder
/// turns up ~7,500 "images", of which 6,890 are 300x150 video-scrubber thumbnails in
/// an app cache, and many others are iCloud-evicted placeholders whose first read
/// blocks for *twenty seconds* while macOS materialises them. Both are excluded.
final class PhotoIndex: @unchecked Sendable {
    private static let exts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff",
        "bmp", "webp", "avif", "jp2", "dng", "cr2", "nef", "arw", "raf", "orf"
    ]

    /// Directories that hold generated images rather than photographs.
    private static let skipDirs: Set<String> = [
        "cache", "caches", "thumbnail", "thumbnails", "library", "node_modules",
        ".git", "derivedata", "pods", "build", "dist", ".next", "venv", ".venv",
        "site-packages", "__pycache__", "target", ".trash", "containers", "coverage"
    ]

    private static let sfDataless: UInt32 = 0x4000_0000   // SF_DATALESS, sys/stat.h

    struct Stats: Sendable {
        var kept = 0, tooSmall = 0, evicted = 0, unreadable = 0
    }

    private let lock = NSLock()
    private var urls: [URL] = []
    private var cursor = 0
    private var stats = Stats()

    var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
    var snapshot: Stats { lock.lock(); defer { lock.unlock() }; return stats }

    /// Scans off the main thread; `progress` fires on the main queue as batches land,
    /// so the first windows can open before the whole disk walk finishes.
    /// `progress(count, finished)` fires on the main queue.
    func scan(roots: [URL], cfg: PhotoWallConfig, limit: Int = 40_000,
              progress: @escaping @Sendable (Int, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            var total = 0
            var batch: [URL] = []
            func flush() {
                guard !batch.isEmpty else { return }
                add(batch: batch)
                batch.removeAll(keepingCapacity: true)
                DispatchQueue.main.async { progress(self.count, false) }
            }
            outer: for root in roots {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let e = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) else { continue }

                while let u = e.nextObject() as? URL {
                    let rv = try? u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                    if rv?.isDirectory == true {
                        if PhotoIndex.skipDirs.contains(u.lastPathComponent.lowercased()) { e.skipDescendants() }
                        continue
                    }
                    guard rv?.isRegularFile == true,
                          PhotoIndex.exts.contains(u.pathExtension.lowercased()) else { continue }
                    guard (rv?.fileSize ?? 0) >= cfg.minBytes else { bump(\Stats.tooSmall); continue }
                    guard cfg.includeCloud || !PhotoIndex.isEvicted(u) else { bump(\Stats.evicted); continue }
                    guard let px = PhotoIndex.pixelSize(u) else { bump(\Stats.unreadable); continue }
                    guard max(px.width, px.height) >= cfg.minPixels else { bump(\Stats.tooSmall); continue }

                    batch.append(u)
                    bump(\Stats.kept)
                    total += 1
                    if batch.count >= 24 { flush() }
                    if total >= limit { break outer }
                }
                flush()
            }
            flush()
            DispatchQueue.main.async { progress(self.count, true) }
        }
    }

    /// True for a file whose bytes live only in the cloud. Reading one would block for
    /// as long as the download takes; `stat` alone never triggers that materialisation.
    private static func isEvicted(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return true }
        return st.st_flags & sfDataless != 0
    }

    /// Reads only the image header — enough to reject icons, sprites and scrub thumbnails.
    private static func pixelSize(_ url: URL) -> (width: Double, height: Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return (w, h)
    }

    private func bump(_ key: WritableKeyPath<Stats, Int>) {
        lock.lock(); stats[keyPath: key] += 1; lock.unlock()
    }

    private func add(batch: [URL]) {
        lock.lock()
        urls.append(contentsOf: batch)
        // Keep the unseen tail shuffled so early windows aren't all from one folder.
        if cursor < urls.count { urls[cursor...].shuffle() }
        lock.unlock()
    }

    /// Throw the index away. Loading a different show with different authored roots must
    /// not inherit the last one's photographs — the scan is deliberately kept across
    /// teardowns (re-walking a home folder on every replay would stall the show), so
    /// something has to say when it is no longer the right index.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        urls.removeAll()
        cursor = 0
        stats = Stats()
    }

    /// Next photo, reshuffling and recycling once every photo has been shown.
    func next() -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard !urls.isEmpty else { return nil }
        if cursor >= urls.count { urls.shuffle(); cursor = 0 }
        let u = urls[cursor]
        cursor += 1
        return u
    }
}
