import AppKit

/// Drives Finder's `desktop position` so a newly created file's icon lands on the
/// grid slot the pattern asked for. Without this the demo still runs — Finder just
/// auto-places every icon in its own top-right stack, so the pattern reads in time
/// but not in space.
///
/// Two hard-won details, inherited from DesktopPerformanceEngine:
///   * scripts run through the `osascript` subprocess, not in-process NSAppleScript,
///     which is orders of magnitude faster for bulk Finder work;
///   * positions are batched into a single `tell application "Finder"` block and
///     coalesced, so a slow Finder round-trip can never build an unbounded backlog.
///
/// Needs Automation → Finder permission, which macOS only grants to a signed,
/// bundled app — run `build/FileSwarm.app`, not the bare SwiftPM binary.
final class DesktopIconPositioner {
    private let queue = DispatchQueue(label: "com.computerart.fileswarm.icons")
    private var pending: [String: CGPoint] = [:]
    private var inFlight = false
    private let lock = NSLock()

    private(set) var lastError: String?
    private(set) var isAuthorized: Bool?

    /// One cheap round-trip to find out whether Automation → Finder is granted.
    /// Errors are reported, never fatal: positioning is an enhancement.
    @discardableResult
    func probeAuthorization() -> Bool {
        let ok = run("tell application \"Finder\" to get name of desktop") != nil
        isAuthorized = ok
        if !ok {
            NSLog("[FileSwarm] Finder automation unavailable: \(lastError ?? "unknown")")
        }
        return ok
    }

    /// Queues icon placements. Safe to call every tick — calls made while a script
    /// is running are merged into the next batch instead of piling up.
    func place(_ positions: [String: CGPoint]) {
        guard !positions.isEmpty else { return }
        lock.lock()
        pending.merge(positions) { _, new in new }
        let shouldStart = !inFlight
        if shouldStart { inFlight = true }
        lock.unlock()
        guard shouldStart else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            if batch.isEmpty {
                inFlight = false
                lock.unlock()
                return
            }
            lock.unlock()
            run(Self.script(for: batch))
        }
    }

    /// Reads one icon's current position, for verifying that Finder still remembers
    /// where a slot belongs.
    func position(of name: String) -> CGPoint? {
        let safe = name.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        guard let out = run("tell application \"Finder\" to get desktop position of item \"\(safe)\" of desktop") else {
            return nil
        }
        let parts = out.components(separatedBy: ",")
        guard parts.count >= 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Blocks until the queue is empty — used before quitting so the last batch
    /// cannot outlive the files it refers to.
    func waitForQuiet(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let busy = inFlight || !pending.isEmpty; lock.unlock()
            if !busy { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Script generation

    static func script(for positions: [String: CGPoint]) -> String {
        var lines = ["tell application \"Finder\""]
        for (name, p) in positions.sorted(by: { $0.key < $1.key }) {
            let safe = name.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            // `try` per item: a file deleted between batch and run must not abort
            // the placements queued behind it.
            lines.append("try")
            lines.append("set desktop position of item \"\(safe)\" of desktop to {\(Int(p.x)), \(Int(p.y))}")
            lines.append("end try")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - osascript runner

    @discardableResult
    private func run(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let stdIn = Pipe(), stdOut = Pipe(), stdErr = Pipe()
        proc.standardInput = stdIn
        proc.standardOutput = stdOut
        proc.standardError = stdErr
        do { try proc.run() } catch {
            lastError = "osascript launch failed: \(error.localizedDescription)"
            return nil
        }
        stdIn.fileHandleForWriting.write(Data(source.utf8))
        stdIn.fileHandleForWriting.closeFile()
        let out = stdOut.fileHandleForReading.readDataToEndOfFile()
        let err = stdErr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            lastError = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed"
            return nil
        }
        return String(data: out, encoding: .utf8)
    }
}

enum DesktopArrangement {
    /// "Keep arranged by" and Stacks both override manual icon positions, which
    /// silently flattens every pattern. Cheaper to warn than to debug.
    static func warning() -> String? {
        guard let plist = readDefaults() else { return nil }
        var problems: [String] = []
        let icons = plist["IconViewSettings"] as? [String: Any] ?? [:]
        if let arrange = icons["arrangeBy"] as? String, arrange.lowercased() != "none" {
            problems.append("Sort By is set to \"\(arrange)\"")
        }
        if let group = plist["GroupBy"] as? String, group.lowercased() != "none" {
            problems.append("Stacks are grouped by \"\(group)\"")
        }
        guard !problems.isEmpty else { return nil }
        return problems.joined(separator: "; ")
            + " — Finder will override icon positions. Right-click the desktop ▸ Sort By ▸ None, and turn off Use Stacks."
    }

    private static func readDefaults() -> [String: Any]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["export", "com.apple.finder", "-"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any])?["DesktopViewSettings"] as? [String: Any]
    }
}
