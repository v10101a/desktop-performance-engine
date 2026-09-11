import SwiftUI

/// The disclosure report: a queue of lines revealed one at a time.
///
/// **Changed in the port.** The standalone app ran the reveal on a 0.012 s `Timer` and
/// resampled live stats on a 1 s `Timer`. Both are gone — `SystemProbeController` calls
/// `revealOne()` and `resample()` from the show clock instead, so the report types out
/// in tempo, freezes when the transport stops, and lands the same line on the same beat
/// every take. Sections are still built off the main thread, but on a serial queue of
/// their own, so they splice into the report in the order `start()` asks for them
/// rather than in whatever order they finish.
@MainActor
final class Probe: ObservableObject {
    @Published private(set) var lines: [TermLine] = []
    @Published private(set) var live = LiveStats()
    @Published private(set) var streaming = true

    private var queue: [TermLine] = []
    private var wait = 0
    private var pendingAsync = 0
    private var footerAdded = false
    private let sampler = Sampler()
    private let locationProbe = LocationProbe()

    /// Sections are built off the main thread, but the report has to READ in the order
    /// `start()` asks for them. On the global CONCURRENT queue they landed in whichever
    /// order they happened to finish, so a slow builder shuffled the report — the
    /// identity block, which the piece opens the disclosure on, could arrive behind the
    /// hardware one. One serial queue instead: still off main, still never blocking the
    /// pump, but the appends happen in call order. Reordering the report now means
    /// reordering the `gather` lines in `start()` and nothing else.
    private let sections = DispatchQueue(label: "dpe.probe.sections", qos: .userInitiated)

    /// The full report — or, with `focus`, just the named sections, highlighted.
    func start(focus: [String]? = nil) {
        live = sampler.sample()

        queue.append(TermLine(text: "", kind: .plain))

        if let focus {
            queue.append(TermLine(text: "  > probe --focus " + focus.joined(separator: ","), kind: .prompt, pause: 8))
            gatherFocused(focus)
            return
        }
        queue.append(TermLine(text: "  > opening sensor bus …", kind: .prompt, pause: 8))

        let displays = displayLines()
        let snapshot = live

        gather { identitySection() }
        gather { machineSection() }
        gather { performanceSection(snapshot) }
        gather { storageSection() }
        gather { devicesSection(displays: displays) }

        pendingAsync += 1
        locationProbe.run { [weak self] lines in
            Task { @MainActor in self?.enqueue(lines); self?.pendingAsync -= 1 }
        }
    }

    /// Clear the terminal and read out ONLY `focus`, every line of it highlighted —
    /// the machine going back to the parts that matter. The window, the live-stats
    /// bar and the reveal pacing are untouched; only the text starts over.
    func rerun(focus: [String]) {
        queue.removeAll()
        lines.removeAll()
        wait = 0
        footerAdded = false
        streaming = true
        queue.append(TermLine(text: "  > clear", kind: .prompt, pause: 3))
        queue.append(TermLine(text: "  > probe --rerun --focus " + focus.joined(separator: ","), kind: .prompt, pause: 8))
        queue.append(TermLine(text: "  re-reading where you are …", kind: .dim, pause: 8))
        gatherFocused(focus)
    }

    /// Names → section builders. Unknown names are skipped with a line saying so,
    /// rather than a typo in the timeline silently reading out nothing.
    private func gatherFocused(_ focus: [String]) {
        for name in focus {
            switch name {
            case "geolocation":
                pendingAsync += 1
                // A fresh prober: the first one has finished and won't fire again.
                let lp = LocationProbe()
                focusProbes.append(lp)
                lp.run { [weak self] lines in
                    Task { @MainActor in self?.enqueue(highlighted(lines)); self?.pendingAsync -= 1 }
                }
            case "network":
                gather(highlight: true) { section("network") + networkLines() }
            case "identity":
                gather(highlight: true) { identitySection() }
            case "machine":
                gather(highlight: true) { machineSection() }
            case "hardware":
                // `displayLines()` is @MainActor and we're on main here; capture it and
                // hand it to the off-main builder (as `devicesSection` does).
                let displays = displayLines()
                gather(highlight: true) { hardwareDeepSection(displays: displays) }
            default:
                queue.append(warn("  unknown section \"\(name)\" — skipped"))
            }
        }
    }
    private var focusProbes: [LocationProbe] = []

    /// Collect a section off the main thread, then splice it into the reveal queue.
    /// Not private so the ordering guarantee above can be tested directly with a slow
    /// builder and a fast one — the only way to tell a serial queue from a concurrent
    /// one, since the real sections all finish in about the same time.
    func gather(highlight: Bool = false, _ build: @escaping () -> [TermLine]) {
        pendingAsync += 1
        sections.async {
            let lines = build()
            Task { @MainActor in
                self.enqueue(highlight ? highlighted(lines) : lines)
                self.pendingAsync -= 1
            }
        }
    }

    private func enqueue(_ new: [TermLine]) { queue.append(contentsOf: new) }

    /// Reveal the next line, honouring its `pause`. Driven by the show clock.
    /// Returns false when the queue is drained and the footer has been written.
    @discardableResult
    func revealOne() -> Bool {
        tick()
        return !queue.isEmpty || wait > 0 || pendingAsync > 0
    }

    /// Re-read the live stats block (CPU, memory, battery, network). The standalone
    /// app did this on a 1 s timer; the controller now calls it once a second of
    /// *show* time.
    func resample() { live = sampler.sample() }

    private func tick() {
        if wait > 0 { wait -= 1; return }
        guard !queue.isEmpty else {
            if pendingAsync == 0 && !footerAdded {
                footerAdded = true
                streaming = false
                queue.append(contentsOf: [
                    TermLine(text: "", kind: .plain),
                    TermLine(text: "  " + String(repeating: "═", count: 62), kind: .section),
                    TermLine(text: "  probe complete · \(lines.count) records extracted in one pass", kind: .ok),
                    TermLine(text: "  every field above was readable by any app you have already trusted.", kind: .warn),
                    TermLine(text: "", kind: .plain),
                    TermLine(text: "  >", kind: .prompt)
                ])
            }
            return
        }
        let line = queue.removeFirst()
        lines.append(line)
        wait = line.pause
    }

    var plainText: String {
        lines.map { l in
            if let label = l.label { return pad(label, 20) + "  " + l.text }
            return l.text
        }.joined(separator: "\n")
    }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
