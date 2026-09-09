import Foundation

/// Every file on disk the show names, gathered from a loaded timeline.
///
/// Written once, here, rather than case by case at each call site. An asset kind that is
/// added to the format and forgotten is a picture that silently does not appear on
/// somebody else's machine — and *silently* is the whole problem: a missing wallpaper
/// just leaves the desktop as it was, and a missing torn card is an empty window. The
/// show does not stop to tell you.
///
/// `--check-assets` uses this to prove a packaged .app is self-contained; `TimelineTests`
/// uses it to prove nothing is named but absent.
enum TimelineAssets {

    /// Authored asset paths, de-duplicated, in the order the show first names them. The
    /// backing track is included — it is the one asset that lives in `meta` rather than
    /// on an event.
    ///
    /// The photo wall's fallback pool is NOT here: no event names it, because which
    /// photographs the wall shows is decided at run time from what the viewer allowed.
    /// `PhotoSource.bundledFolders` is the list; `bundledPoolCount` counts it.
    static func paths(in tl: LoadedTimeline) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ p: String?) {
            guard let p, !p.isEmpty, seen.insert(p).inserted else { return }
            out.append(p)
        }
        add(tl.meta.audioFile)
        for ev in tl.events {
            switch ev.action {
            case .openWindow(let p):    add(p.content.path)
            case .wallpaper(let p):     add(p.path)
            case .deskWallpaper(let p): p.images?.forEach(add)
            case .glassTorus(let p):    add(p.environment)
            case .segSwarm(let p):      add(p.path)
            case .credits(let p):       add(p.tile)
            default:                    break
            }
        }
        return out
    }

    /// Where `name` lands when only the .app is allowed to answer.
    ///
    /// `resolveResourcePath` deliberately also searches the working directory and seven
    /// levels above the bundle. That is what makes a repo checkout work — and what makes
    /// a broken bundle look perfect when you test it from the repo, because the repo
    /// root is one of the places it looks. This asks the stricter question the USB stick
    /// asks: is the file actually inside the .app?
    ///
    /// `flatAllowed` mirrors the split between the two resolvers the show really uses.
    /// `resolveAudioURL` accepts a flat `<Resources>/track.mp3`; `resolveResourcePath`
    /// does not, so an image copied only flat would pass a lenient check here and still
    /// come up missing at show time. It has before — see the note in bundle.sh.
    static func bundledPath(_ name: String, flatAllowed: Bool = false) -> String? {
        guard !name.isEmpty, let res = Bundle.main.resourceURL else { return nil }
        if name.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: name) ? name : nil
        }
        let basename = (name as NSString).lastPathComponent
        var candidates = [res.appendingPathComponent(name),
                          res.appendingPathComponent("assets").appendingPathComponent(basename)]
        if flatAllowed { candidates.append(res.appendingPathComponent(basename)) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    /// One line per asset, saying whether the .app carries it. `ok` is false if any
    /// asset the show names is not inside the bundle.
    static func audit(_ tl: LoadedTimeline) -> (lines: [String], ok: Bool) {
        var lines: [String] = []
        var ok = true
        for name in paths(in: tl) {
            let flat = (name == tl.meta.audioFile)
            if let found = bundledPath(name, flatAllowed: flat) {
                let inside = found.replacingOccurrences(of: Bundle.main.bundleURL.path + "/",
                                                        with: "")
                lines.append("  ✓ \(name)  →  \(inside)")
            } else {
                ok = false
                let elsewhere = resolveResourcePath(name)
                let note = FileManager.default.fileExists(atPath: elsewhere)
                    ? " (resolves to \(elsewhere) — OUTSIDE the .app, so it travels only from this checkout)"
                    : " (not found anywhere)"
                lines.append("  ✗ \(name)\(note)")
            }
        }
        return (lines, ok)
    }

    /// How many photographs the fallback pool carries inside the bundle. Zero means a
    /// viewer who refuses Files and Folders gets an empty wall.
    static func bundledPoolCount() -> Int {
        PhotoSource.bundledFolders.reduce(0) { total, folder in
            guard let dir = bundledPath(folder) else { return total }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return total + files.filter { $0.lowercased().hasSuffix(".jpg") }.count
        }
    }
}
