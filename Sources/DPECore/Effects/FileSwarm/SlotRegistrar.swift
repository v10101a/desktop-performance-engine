import AppKit

/// Teaches Finder where each grid slot lives — once — and then gets out of the way.
///
/// Positioning an icon costs about 85 ms of fixed Finder round-trip plus ~10 ms per
/// item, which is hopeless at ten frames a second. But Finder stores a desktop
/// position per filename in `.DS_Store` and honours it when a file with that name
/// reappears. So the whole grid is registered in one pass — create every slot file,
/// position them, delete them — and from then on the pattern is pure create/unlink
/// at ~0.08 ms per file.
///
/// The registration survives in `.DS_Store` between runs, so later runs only pay for
/// a single probe icon to confirm the memory is still good.
final class SlotRegistrar {
    struct Result {
        var registered = 0      // slots positioned this pass
        var skipped = false     // cached registration was still valid
        var authorized = true
        var seconds: Double = 0
        var error: String?
    }

    private let positioner = DesktopIconPositioner()
    private let stateURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("FileSwarm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("slots.json")
    }

    /// Blocking — call from a background queue. Leaves no files behind.
    func prepare(grid: Grid, store: SwarmFileStore, force: Bool = false) -> Result {
        let started = Date()
        var result = Result()

        guard positioner.probeAuthorization() else {
            result.authorized = false
            result.error = positioner.lastError
            result.seconds = Date().timeIntervalSince(started)
            return result
        }

        let cells = (0..<grid.rows).flatMap { row in (0..<grid.cols).map { Cell(col: $0, row: row) } }
        if !force, cachedSignature() == signature(for: grid), probePasses(grid: grid, store: store) {
            result.skipped = true
            result.seconds = Date().timeIntervalSince(started)
            return result
        }

        // Finder can only be told about a file that exists, so the slots are briefly
        // materialised, positioned, then removed again.
        var placements: [String: CGPoint] = [:]
        for cell in cells {
            guard let url = store.create(for: cell, note: "slot registration") else { continue }
            placements[url.lastPathComponent] = grid.point(cell)
        }
        positioner.place(placements)
        positioner.waitForQuiet(timeout: 30)
        for cell in cells { store.delete(store.url(for: cell)) }

        result.registered = placements.count
        result.error = positioner.lastError
        result.seconds = Date().timeIntervalSince(started)
        writeSignature(signature(for: grid))
        return result
    }

    /// Creates a single corner file and checks Finder puts it back on its slot. If
    /// `.DS_Store` was rebuilt or the desktop was re-sorted, this fails and the
    /// caller re-registers everything.
    private func probePasses(grid: Grid, store: SwarmFileStore) -> Bool {
        let cell = Cell(col: grid.cols - 1, row: grid.rows - 1)
        guard let url = store.create(for: cell, note: "probe") else { return false }
        defer { store.delete(url) }
        // Give Finder a beat to notice the file before asking where it put it.
        Thread.sleep(forTimeInterval: 0.35)
        guard let actual = positioner.position(of: url.lastPathComponent) else { return false }
        let expected = grid.point(cell)
        return abs(actual.x - expected.x) < 1 && abs(actual.y - expected.y) < 1
    }

    // MARK: - Cached signature

    /// Registration is only valid for the grid geometry it was made for; a screen
    /// or resolution change invalidates it.
    private func signature(for grid: Grid) -> String {
        "\(grid.cols)x\(grid.rows)@\(Int(grid.origin.x)),\(Int(grid.origin.y))"
        + "+\(Int(grid.cell.width))x\(Int(grid.cell.height))/\(SwarmFileStore.prefix)"
    }

    private func cachedSignature() -> String? {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["signature"] as? String
    }

    private func writeSignature(_ value: String) {
        let obj: [String: Any] = ["signature": value]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: stateURL)
    }
}
