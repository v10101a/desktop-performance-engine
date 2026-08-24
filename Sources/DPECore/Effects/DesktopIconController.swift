import AppKit

/// Rearranges Finder desktop icons during the show and restores their exact
/// positions afterward. Only icon *coordinates* are touched — never files.
///
/// Requires **Automation → Finder** permission. Scripts run via the `osascript`
/// subprocess rather than in-process `NSAppleScript`: in testing NSAppleScript took
/// ~20 s to read 61 icons (which would freeze the pump), while `osascript` did the
/// same in well under a second. Rearranges run on a background queue so a mid-show
/// icon move never blocks the audio/visual pump; snapshot and restore run
/// synchronously (before the show starts / after it ends).
final class DesktopIconController {
    struct Icon { let name: String; let pos: CGPoint }

    private(set) var snapshotIcons: [Icon] = []
    private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.computerart.dpe.icons")

    var hasSnapshot: Bool { !snapshotIcons.isEmpty }

    // MARK: - Snapshot (synchronous — run once at play, before the clock starts)

    @discardableResult
    func snapshot() -> Bool {
        // Retrieve names + positions in BULK (one Finder round-trip each — ~0.7s),
        // then format the delimited string from the in-memory lists. A per-item loop
        // that queries Finder each iteration takes ~20s for 60 icons; this is ~1.5s.
        let source = """
        tell application "Finder"
            set nm to name of every item of desktop
            set ps to desktop position of every item of desktop
        end tell
        set out to ""
        repeat with i from 1 to (count of nm)
            set p to item i of ps
            set out to out & (item i of nm) & tab & ((item 1 of p) as integer) & tab & ((item 2 of p) as integer) & linefeed
        end repeat
        return out
        """
        guard let out = runOSA(source) else { return false }
        snapshotIcons = DesktopIconController.parse(out)
        NSLog("[DPE] icon snapshot: \(snapshotIcons.count) icons")
        return hasSnapshot
    }

    static func parse(_ raw: String) -> [Icon] {
        raw.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 3, let x = Double(f[1].trimmingCharacters(in: .whitespaces)),
                  let y = Double(f[2].trimmingCharacters(in: .whitespaces)) else { return nil }
            return Icon(name: f[0], pos: CGPoint(x: x, y: y))
        }
    }

    // MARK: - Rearrange (async — never blocks the pump)

    func rearrange(_ p: RearrangeIconsParams) {
        guard hasSnapshot else {
            NSLog("[DPE] rearrangeIcons: no snapshot (Automation not granted?) — skipping")
            return
        }
        let targets = DesktopIconController.layout(p.layout ?? "scatter",
                                                   names: snapshotIcons.map(\.name),
                                                   seed: UInt64(p.seed ?? 1),
                                                   bounds: Self.desktopBounds())
        let script = Self.buildSetScript(targets)
        queue.async { [weak self] in self?.runOSA(script) }
    }

    // MARK: - Restore (synchronous — guarantees completion before quit)

    func restore() {
        guard hasSnapshot else { return }
        runOSA(Self.buildSetScript(snapshotIcons.map { ($0.name, $0.pos) }))
        NSLog("[DPE] icon positions restored (\(snapshotIcons.count))")
    }

    /// Move a single icon and return true on success — used by the self-test to
    /// verify the set/restore path with minimal disruption.
    @discardableResult
    func setPosition(name: String, to p: CGPoint) -> Bool {
        runOSA(Self.buildSetScript([(name, p)])) != nil
    }

    /// Read a single icon's current position.
    func getPosition(name: String) -> CGPoint? {
        let safe = name.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        guard let out = runOSA("tell application \"Finder\" to get desktop position of item \"\(safe)\" of desktop") else { return nil }
        let parts = out.components(separatedBy: ",")
        guard parts.count >= 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Layout math (pure, testable)

    static func desktopBounds() -> CGSize {
        (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    static func layout(_ kind: String, names: [String], seed: UInt64, bounds: CGSize) -> [(String, CGPoint)] {
        let margin: CGFloat = 90
        let w = max(bounds.width - margin * 2, 100)
        let h = max(bounds.height - margin * 2, 100)
        let cx = bounds.width / 2, cy = bounds.height / 2
        let n = names.count
        var rng = SplitMix64(seed: seed == 0 ? 1 : seed)

        switch kind {
        case "pile":
            return names.map { ($0, CGPoint(x: cx + rng.nextUnit() * 40 - 20,
                                            y: cy + rng.nextUnit() * 40 - 20)) }
        case "circle":
            let r = min(w, h) / 2
            return names.enumerated().map { i, name in
                let a = 2 * Double.pi * Double(i) / Double(max(n, 1))
                return (name, CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r))
            }
        case "grid":
            let cols = max(1, Int((Double(n)).squareRoot().rounded(.up)))
            return names.enumerated().map { i, name in
                let c = i % cols, r = i / cols
                let gx = margin + CGFloat(c) * (w / CGFloat(cols))
                let gy = margin + CGFloat(r) * 90
                return (name, CGPoint(x: gx, y: gy))
            }
        default: // "scatter"
            return names.map { name in
                (name, CGPoint(x: margin + CGFloat(rng.nextUnit()) * w,
                               y: margin + CGFloat(rng.nextUnit()) * h))
            }
        }
    }

    // MARK: - Script generation

    static func buildSetScript(_ positions: [(String, CGPoint)]) -> String {
        var lines = ["tell application \"Finder\""]
        for (name, p) in positions {
            let safe = name.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("set desktop position of item \"\(safe)\" of desktop to {\(Int(p.x)), \(Int(p.y))}")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - osascript runner

    @discardableResult
    private func runOSA(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let stdIn = Pipe(), stdOut = Pipe(), stdErr = Pipe()
        proc.standardInput = stdIn
        proc.standardOutput = stdOut
        proc.standardError = stdErr
        do {
            try proc.run()
        } catch {
            lastError = "\(error)"
            NSLog("[DPE] osascript launch failed: \(error)")
            return nil
        }
        stdIn.fileHandleForWriting.write(Data(source.utf8))
        stdIn.fileHandleForWriting.closeFile()
        let outData = stdOut.fileHandleForReading.readDataToEndOfFile()
        let errData = stdErr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            lastError = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[DPE] osascript error: \(lastError ?? "unknown")")
            return nil
        }
        return String(data: outData, encoding: .utf8)
    }
}

/// Small deterministic PRNG so scatter layouts are repeatable for a given seed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}
