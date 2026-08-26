import Foundation

/// SwiftPM resource bundles sitting next to the executable's resources, in the order
/// they should be searched.
///
/// The bundle name is `<package>_<target>.bundle` — derived from the package name AND
/// the target that declares the resources — so it moves on every project rename or
/// target split and must never be hardcoded. DPECore's bundle is returned first: it is
/// where the resources actually live since the library split, and a stale
/// executable-target bundle left in `.build` once shadowed it under `swift run`,
/// playing the previous show while the new timeline sat unread.
///
/// Within each group the FRESHEST bundle comes first — the one whose `timeline.json`
/// was written most recently. A rename leaves the old package's `_DPECore.bundle`
/// behind next to the new one, and alphabetically the stale one can sort first; by
/// date it never does.
func resourceBundles(in dir: URL, fm: FileManager = .default) -> [URL] {
    let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "bundle" }
    let isCore = { (u: URL) in u.lastPathComponent.hasSuffix("_DPECore.bundle") }
    func written(_ u: URL) -> Date {
        let tl = u.appendingPathComponent("timeline.json")
        let probe = fm.fileExists(atPath: tl.path) ? tl : u
        return (try? fm.attributesOfItem(atPath: probe.path)[.modificationDate] as? Date) ?? .distantPast
    }
    let newestFirst = { (a: URL, b: URL) in written(a) > written(b) }
    let core = all.filter(isCore).sorted(by: newestFirst)
    if core.count > 1 {
        NSLog("[DPE] resources: \(core.count) DPECore bundles in \(dir.lastPathComponent) — using the newest, "
              + "\(core[0].lastPathComponent); the rest are stale build output and can be deleted")
    }
    return core + all.filter { !isCore($0) }.sorted(by: newestFirst)
}
