import Foundation

/// Resolved settings for one `photoWall` event.
///
/// This is the show-side replacement for the standalone photowall app's CLI `Config`.
/// The placement knobs (`minFrac`/`maxFrac`/`cell`) and the photo-selection filters
/// (`minPixels`/`minBytes`/`includeCloud`) carry the same meanings and defaults; the
/// rates do not — the standalone app measures them in seconds, and here they are
/// **per beat**, so the wall fills in tempo (see `PhotoWallParams`).
struct PhotoWallConfig {
    var roots: [URL] = PhotoWallConfig.defaultRoots

    /// Photos placed per beat while first filling the screen.
    var fillPerBeat: Double = 20
    /// Photos placed per beat once the screen is full and the wall is churning.
    var churnPerBeat: Double = 2.7

    var minFrac: Double = 0.13        // window edge as a fraction of the screen edge
    var maxFrac: Double = 0.52
    var cell: Double = 12             // coverage grid resolution, points

    var keepFilling = true            // keep laying photos after the screen is full
    var shadows = true
    var liveWindows = 45              // photo population kept on screen while churning
    var maxWindows = 160              // safety net when nothing is buried enough to retire
    var imageCap: Double = 1200       // largest thumbnail edge in pixels, memory guard
    var fade: Double = 0.065          // fade-in seconds; 0 = appear instantly

    var minPixels: Double = 640       // reject icons, sprites, scrub thumbnails
    var minBytes: Int = 12 * 1024
    var includeCloud = false          // iCloud-evicted files block for ~20s on first read

    /// Window stacking. `.normal` interleaves the wall with the show's other effect
    /// windows, which is what makes it read as one piece; `.front` is the standalone
    /// app's behaviour — above the menu bar and Dock, covering everything.
    var level: Level = .normal
    enum Level: String { case normal, floating, front }

    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Downloads", "Documents", "Pictures"].map {
            home.appendingPathComponent($0)
        }
    }

    /// Resolve authored JSON into settings, filling in defaults and normalising the
    /// couple of fields that have to hold an invariant.
    init(_ p: PhotoWallParams) {
        if let dirs = p.dirs, !dirs.isEmpty {
            roots = dirs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        if let v = p.fillPerBeat { fillPerBeat = max(0.01, v) }
        if let v = p.churnPerBeat { churnPerBeat = max(0.01, v) }
        if let v = p.minFrac { minFrac = v }
        if let v = p.maxFrac { maxFrac = v }
        if let v = p.cell { cell = max(2, v) }
        if let v = p.keepFilling { keepFilling = v }
        if let v = p.shadows { shadows = v }
        if let v = p.windows { liveWindows = max(8, v); maxWindows = max(160, v * 2) }
        if let v = p.imageCap { imageCap = max(64, v) }
        if let v = p.fade { fade = max(0, v) }
        if let v = p.minPixels { minPixels = max(0, v) }
        if let v = p.includeCloud { includeCloud = v }
        if let v = p.level, let l = Level(rawValue: v) { level = l }
        if maxFrac < minFrac { swap(&minFrac, &maxFrac) }
    }
}
