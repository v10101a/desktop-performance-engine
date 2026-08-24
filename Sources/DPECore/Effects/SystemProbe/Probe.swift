import SwiftUI

/// The disclosure report: a queue of lines revealed one at a time.
///
/// **Changed in the port.** The standalone app ran the reveal on a 0.012 s `Timer` and
/// resampled live stats on a 1 s `Timer`. Both are gone — `SystemProbeController` calls
/// `revealOne()` and `resample()` from the show clock instead, so the report types out
/// in tempo, freezes when the transport stops, and lands the same line on the same beat
/// every take. The gathering is untouched: sections are still built off the main thread
/// and spliced into the queue as they land.
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

    private let banner = [
        "  ██████╗ ██████╗  ██████╗ ██████╗ ███████╗",
        "  ██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔════╝",
        "  ██████╔╝██████╔╝██║   ██║██████╔╝█████╗  ",
        "  ██╔═══╝ ██╔══██╗██║   ██║██╔══██╗██╔══╝  ",
        "  ██║     ██║  ██║╚██████╔╝██████╔╝███████╗",
        "  ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝"
    ]

    func start() {
        live = sampler.sample()

        for b in banner { queue.append(TermLine(text: b, kind: .banner)) }
        queue.append(TermLine(text: "  self-directed disclosure report · everything this machine knows about you", kind: .dim, pause: 4))
        queue.append(TermLine(text: "  all readings are local — nothing leaves this computer", kind: .ok, pause: 10))
        queue.append(TermLine(text: "", kind: .plain))
        queue.append(TermLine(text: "  > opening sensor bus …", kind: .prompt, pause: 8))


        let displays = displayLines()
        let snapshot = live

        gather { identitySection() }
        gather { machineSection() }
        gather { performanceSection(snapshot) }
        gather { storageSection() }
        gather { devicesSection(displays: displays) }

        pendingAsync += 2
        contactCard { [weak self] lines in
            Task { @MainActor in self?.enqueue(lines); self?.pendingAsync -= 1 }
        }
        locationProbe.run { [weak self] lines in
            Task { @MainActor in self?.enqueue(lines); self?.pendingAsync -= 1 }
        }
    }

    /// Collect a section off the main thread, then splice it into the reveal queue.
    private func gather(_ build: @escaping () -> [TermLine]) {
        pendingAsync += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = build()
            Task { @MainActor in
                self.enqueue(lines)
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
