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
func resourceBundles(in dir: URL, fm: FileManager = .default) -> [URL] {
    let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "bundle" }
    let isCore = { (u: URL) in u.lastPathComponent.hasSuffix("_DPECore.bundle") }
    return all.filter(isCore) + all.filter { !isCore($0) }
}
