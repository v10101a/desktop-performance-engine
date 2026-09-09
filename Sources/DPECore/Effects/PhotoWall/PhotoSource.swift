import Foundation

/// Where the photo wall's pictures come from.
///
/// Decided at *scan* time, not at config time, because it depends on two things a JSON
/// file cannot know: whether this viewer granted Files and Folders access, and what is
/// sitting on their Desktop.
///
/// Three sources, in order of preference:
///
/// 1. **A folder they made for this.** `~/Desktop/giveit2me` — if it is there and
///    readable, it *is* the wall and nothing else is. Someone who put that folder on
///    their Desktop has said exactly what they want the piece to show, and mixing their
///    Downloads back in would be ignoring them.
/// 2. **Their machine.** The authored roots (Desktop, Downloads, Documents, Pictures).
///    The original behaviour, and still what most runs do.
/// 3. **The bundle.** Photographs of broken computers, shipped inside the .app.
///
/// Three exists because of what used to happen without it: `PhotoWallController.spawn`
/// returns early when the index is empty, so a viewer who said no to Files and Folders
/// got a `photoWall` cue that opened *nothing at all* — a hole in the middle of the show
/// that read as a crash. The wall is now always a wall; on a locked-down machine it is a
/// wall of somebody else's broken screens.
enum PhotoSource {
    /// `~/Desktop/giveit2me`, the folder the viewer curated.
    case curated(URL)
    /// The authored roots, readable.
    case user([URL])
    /// Photographs from inside the app bundle.
    case bundled([URL])

    var roots: [URL] {
        switch self {
        case .curated(let url): return [url]
        case .user(let urls):   return urls
        case .bundled(let urls): return urls
        }
    }

    var label: String {
        switch self {
        case .curated(let url): return "curated (~/Desktop/\(url.lastPathComponent))"
        case .user:             return "the viewer's folders"
        case .bundled:          return "bundled photographs"
        }
    }

    var isBundled: Bool { if case .bundled = self { return true }; return false }

    /// The count below which this source has not produced a wall and the bundled
    /// photographs are added to it.
    var floor: Int {
        switch self {
        case .curated: return 1                        // whatever they chose, however little
        case .user:    return PhotoSource.minUserPhotos
        case .bundled: return 0                        // nothing left to fall back to
        }
    }

    // MARK: - The folder the viewer curated

    /// Matched case-insensitively. The instruction people are given is "make a folder
    /// called giveit2me"; nobody is going to be told it has to be lowercase, and a
    /// `GiveIt2Me` that silently did nothing would be the worst kind of bug — one where
    /// the viewer did everything right.
    static let curatedFolderName = "giveit2me"

    /// The curated folder, if the Desktop is readable and it is there.
    ///
    /// Returns nil when the Desktop is *unreadable*, which is exactly the case that
    /// matters: a refused Files and Folders prompt makes `contentsOfDirectory` fail, and
    /// that failure is how we learn to fall back rather than opening an empty wall.
    static func curatedFolder(in home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL? {
        let desktop = home.appendingPathComponent("Desktop")
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: desktop, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return nil }
        return entries.first { url in
            url.lastPathComponent.caseInsensitiveCompare(curatedFolderName) == .orderedSame
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    // MARK: - The bundled photographs

    /// The two folders the fallback draws on, by the paths `resolveResourcePath` knows.
    ///
    /// `broken_screens` is the six shots the cut already uses by name; `photo_fallback`
    /// is the rest of the same drop, downsized and committed by
    /// `generate_show.py:build_photo_fallback`. Disjoint on purpose — the six are not
    /// repeated in the second folder — so the pool is every photograph once rather than
    /// six of them twice.
    static let bundledFolders = ["assets/photo_fallback", "assets/broken_screens"]

    static func bundledRoots() -> [URL] {
        bundledFolders
            .map { URL(fileURLWithPath: resolveResourcePath($0)) }
            .filter { isReadable($0) }
    }

    // MARK: - Resolution

    /// A directory we can actually list. On a denied folder this returns false without
    /// raising anything: by the time a wall scans, the gate's preflight has already made
    /// macOS record an answer, and a recorded "no" fails immediately rather than
    /// prompting again.
    ///
    /// **Call this off the main thread.** On a *first* run the answer may not be
    /// recorded yet, and then the read blocks until the viewer decides.
    static func isReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Pick a source. Off the main thread — see `isReadable`.
    static func resolve(_ cfg: PhotoWallConfig) -> PhotoSource {
        if let curated = curatedFolder(), isReadable(curated) {
            return .curated(curated)
        }
        let readable = cfg.roots.filter(isReadable)
        if !readable.isEmpty { return .user(readable) }
        return .bundled(bundledRoots())
    }

    // MARK: - Filters

    /// The selection filters to scan this source with.
    ///
    /// The defaults exist to keep icons, sprites and video-scrubber thumbnails out of a
    /// walk of somebody's whole home folder. A curated folder is not that walk — the
    /// viewer chose every file in it — so "load all of the photos from that folder"
    /// means all of them, and the size floors come down to the point where they only
    /// reject things that are not photographs at all.
    ///
    /// `includeCloud` stays false even for the curated folder: an iCloud-evicted file
    /// blocks for ~20 seconds on first read, and a wall that stalls mid-cue is worse
    /// than a wall missing a picture.
    func filters(_ cfg: PhotoWallConfig) -> PhotoWallConfig {
        guard case .curated = self else { return cfg }
        var c = cfg
        c.minPixels = 64
        c.minBytes = 1024
        return c
    }

    /// Below this many photographs, a `.user` scan is treated as not having found a
    /// wall and is topped up from the bundle.
    ///
    /// Permission can be granted and the folders still be effectively empty — a fresh
    /// machine, a locked-down work laptop, an account that keeps everything in iCloud
    /// and has it all evicted. Four photographs recycled across forty windows is not a
    /// collage, it is the same picture forty times.
    ///
    /// A `.curated` scan is never topped up, only replaced if it finds literally
    /// nothing: a viewer who put six photographs in the folder gets a wall of those six.
    static let minUserPhotos = 12
}
