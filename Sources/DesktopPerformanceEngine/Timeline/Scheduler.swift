import Foundation

/// Fires timeline events against the audio clock using a single advancing cursor.
///
/// Events are pre-sorted by fire time. Each tick fires every event whose time has
/// passed, so a burst catches up cleanly after a frame drop. O(events fired),
/// deterministic, and repeatable across takes.
final class Scheduler {
    private var events: [ResolvedEvent] = []
    private var cursor = 0

    /// When true, accumulate drift stats (max/mean) in memory and report a single
    /// summary at the end — NOT one NSLog per event, whose cost would itself lag the
    /// main thread and pollute the measurement.
    var logFiring = false
    private(set) var driftMax = 0.0
    private(set) var driftSum = 0.0
    private(set) var driftCount = 0

    func load(_ events: [ResolvedEvent]) {
        self.events = events
        cursor = 0
    }

    func reset() {
        cursor = 0
        driftMax = 0; driftSum = 0; driftCount = 0
    }

    /// Move the cursor to the first event at or after `time` (events are sorted), so
    /// playback resumes from a scrubbed position without firing everything before it.
    func seek(to time: Double) {
        cursor = events.firstIndex { $0.fireTime >= time } ?? events.count
    }

    var isFinished: Bool { cursor >= events.count }

    func tick(now: Double, ctx: EventContext) {
        while cursor < events.count, events[cursor].fireTime <= now {
            let ev = events[cursor]
            if logFiring {
                let d = abs(now - ev.fireTime)
                if d > driftMax { driftMax = d }
                driftSum += d
                driftCount += 1
            }
            ctx.execute(ev.action, now: now)
            cursor += 1
        }
    }

    var driftSummary: String {
        guard driftCount > 0 else { return "no events fired" }
        return String(format: "drift max=%.1fms mean=%.1fms over %d events",
                      driftMax * 1000, (driftSum / Double(driftCount)) * 1000, driftCount)
    }
}
