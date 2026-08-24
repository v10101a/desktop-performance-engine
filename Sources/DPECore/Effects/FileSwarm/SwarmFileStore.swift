import Foundation

/// Creates and removes the swarm's throwaway files — and refuses to touch anything else.
///
/// Every deletion has to clear four independent gates, so a bug in the pattern code
/// can never reach a real file:
///   1. the file sits directly in `~/Desktop` (resolved, no symlink games),
///   2. its name starts with `SwarmFileStore.prefix`,
///   3. it carries our extended-attribute marker, written at creation time,
///   4. it is a regular file, not a directory, package, or symlink.
///
/// The marker is what makes cleanup safe across crashes: a file left behind by a
/// killed run is still provably ours, and a file the user happens to name
/// `swarm-whatever.txt` is provably not.
final class SwarmFileStore {
    static let prefix = "swarm-"
    static let markerName = "com.computerart.fileswarm"

    enum StoreError: Error, CustomStringConvertible {
        case noDesktop
        var description: String { "Could not resolve ~/Desktop" }
    }

    let desktop: URL
    let sessionTag: String

    private(set) var createdCount = 0
    private(set) var deletedCount = 0
    private(set) var refusedCount = 0
    private(set) var lastError: String?

    private var sequence = 0
    private let fm = FileManager.default

    /// Different extensions give different Finder icons, which is most of the
    /// visual interest once a few dozen of them are on screen at once.
    private let extensions = ["txt", "md", "json", "csv", "html", "xml", "yml", "log", "rtf"]

    init(sessionTag: String? = nil) throws {
        guard let dir = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw StoreError.noDesktop
        }
        desktop = dir.resolvingSymlinksInPath().standardizedFileURL
        self.sessionTag = sessionTag ?? String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: - Names

    /// Every grid slot has one fixed filename, for the whole reason the engine is
    /// fast: Finder remembers a desktop position per *name* in `.DS_Store`, so once
    /// a slot's file has been positioned, deleting and recreating it puts the icon
    /// straight back on that slot with no scripting at all.
    func url(for cell: Cell) -> URL {
        let ext = extensions[abs(cell.col &* 7 &+ cell.row) % extensions.count]
        return desktop.appendingPathComponent("\(Self.prefix)c\(cell.col)r\(cell.row).\(ext)")
    }

    // MARK: - Create

    /// Writes the tiny file for `cell` and marks it as ours. Returns nil on failure.
    @discardableResult
    func create(for cell: Cell, note: String) -> URL? {
        sequence += 1
        let url = self.url(for: cell)
        let body = """
        FileSwarm — temporary demo file, safe to delete.
        slot \(cell.col),\(cell.row)  \(note)
        """
        do {
            try Data(body.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            // Already there (a previous run that never got swept) is not a failure —
            // it is the very file this slot wants.
            if isOurs(url) { createdCount += 1; return url }
            lastError = "create \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
        guard mark(url) else {
            // Unmarked files can never be deleted by the guarded path, so rather
            // than orphan one we back the creation out immediately.
            try? fm.removeItem(at: url)
            lastError = "could not mark \(url.lastPathComponent) — creation rolled back"
            return nil
        }
        createdCount += 1
        return url
    }

    // MARK: - Delete

    @discardableResult
    func delete(_ url: URL) -> Bool {
        guard isOurs(url) else {
            refusedCount += 1
            lastError = "refused to delete \(url.lastPathComponent) — not a swarm file"
            NSLog("[FileSwarm] REFUSED delete: \(url.path)")
            return false
        }
        do {
            try fm.removeItem(at: url)
            deletedCount += 1
            return true
        } catch {
            lastError = "delete \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// The full gauntlet. Anything that is not unambiguously a file we made this
    /// run (or a previous one) fails here.
    func isOurs(_ url: URL) -> Bool {
        let std = url.resolvingSymlinksInPath().standardizedFileURL
        guard std.deletingLastPathComponent().path == desktop.path else { return false }
        guard std.lastPathComponent.hasPrefix(Self.prefix) else { return false }
        guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]),
              vals.isRegularFile == true, vals.isSymbolicLink != true, vals.isDirectory != true else { return false }
        return hasMarker(std)
    }

    // MARK: - Sweep

    /// Removes every marked swarm file on the Desktop, including orphans from a
    /// run that was force-quit. Returns how many it removed.
    @discardableResult
    func sweep() -> Int {
        guard let items = try? fm.contentsOfDirectory(at: desktop,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsSubdirectoryDescendants]) else { return 0 }
        var removed = 0
        for url in items where url.lastPathComponent.hasPrefix(Self.prefix) {
            if delete(url) { removed += 1 }
        }
        return removed
    }

    /// Files on the Desktop that are *not* ours — reported so the UI can show the
    /// user that the count never moves while a performance is running.
    func foreignFileCount() -> Int {
        guard let items = try? fm.contentsOfDirectory(at: desktop,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsSubdirectoryDescendants]) else { return 0 }
        return items.filter { !isOurs($0) }.count
    }

    // MARK: - Extended-attribute marker

    private func mark(_ url: URL) -> Bool {
        let value = Data("\(sessionTag)".utf8)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withUnsafeBytes { buf in
                setxattr(path, Self.markerName, buf.baseAddress, buf.count, 0, 0) == 0
            }
        }
    }

    private func hasMarker(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, Self.markerName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }
}
