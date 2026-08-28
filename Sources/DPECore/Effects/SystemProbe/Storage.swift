import Foundation

/// The home folders the census reports on. Shared with `Permissions.preflight`, which
/// warms the gated ones at the intro gate so their prompts don't land over the report.
let censusFolderNames = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]

func storageSection() -> [TermLine] {
    var out = section("storage")
    let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsEncryptedKey,
        .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey
    ]
    // .volumeTypeNameKey is macOS 13.3+ and DPE deploys to 13.0, so it is requested
    // (and read below) only where it exists. volumeLocalizedFormatDescription is
    // preferred anyway, so the fallback loses nothing in practice.
    let typeKeys: [URLResourceKey] = {
        if #available(macOS 13.3, *) { return keys + [.volumeTypeNameKey] }
        return keys
    }()
    let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: typeKeys,
                                                     options: [.skipHiddenVolumes]) ?? []
    if vols.isEmpty { out.append(warn("no volumes enumerated")) }

    for url in vols {
        guard let r = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        let total = Int64(r.volumeTotalCapacity ?? 0)
        guard total > 0 else { continue }
        let free = Int64(r.volumeAvailableCapacityForImportantUsage ?? Int64(r.volumeAvailableCapacity ?? 0))
        let used = max(0, total - free)
        let frac = Double(used) / Double(total)

        var tags: [String] = []
        if r.volumeIsInternal == true { tags.append("internal") } else { tags.append("external") }
        if r.volumeIsRemovable == true { tags.append("removable") }
        if r.volumeIsEjectable == true { tags.append("ejectable") }
        if r.volumeIsEncrypted == true { tags.append("encrypted") }

        out.append(TermLine(text: "", kind: .plain))
        out.append(TermLine(label: "volume", text: (r.volumeName ?? url.lastPathComponent) + "   " + tags.joined(separator: " · "),
                            kind: .alert))
        out.append(kv("  mount point", url.path))
        var typeName: String? = nil
        if #available(macOS 13.3, *) { typeName = r.volumeTypeName }
        out.append(kv("  format", r.volumeLocalizedFormatDescription ?? typeName))
        out.append(kv("  volume uuid", r.volumeUUIDString))
        out.append(kv("  capacity", "\(bytes(used)) used of \(bytes(total))   \(bytes(free)) free"))
        out.append(TermLine(label: "  usage", text: "[\(bar(frac))] \(pct(frac))",
                            kind: frac > 0.9 ? .alert : (frac > 0.75 ? .warn : .ok)))
    }

    out.append(TermLine(text: "", kind: .plain))
    out.append(TermLine(text: "  home directory census", kind: .section))
    let fm = FileManager.default
    for name in censusFolderNames {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else {
            out.append(kv("  ~/\(name)", nil)); continue
        }
        var size: Int64 = 0
        var newest: Date?
        for i in items {
            let rv = try? i.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size += Int64(rv?.fileSize ?? 0)
            if let d = rv?.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
        }
        var s = "\(items.count) items, \(bytes(size)) at top level"
        if let n = newest { s += "  · last touched \(stamp(n))" }
        out.append(kv("  ~/\(name)", s))
    }
    return out
}
