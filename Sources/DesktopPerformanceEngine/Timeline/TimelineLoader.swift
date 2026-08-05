import Foundation

struct LoadedTimeline {
    let meta: Meta
    let events: [ResolvedEvent]   // sorted ascending by fireTime

    var duration: Double { events.map(\.fireTime).max() ?? 0 }

    /// Whether the show touches desktop icons — gates the (permission-prompting)
    /// icon snapshot so timelines that don't use icons never ask for Automation.
    var usesIcons: Bool {
        events.contains { if case .rearrangeIcons = $0.action { return true } else { return false } }
    }

    /// Whether the show swaps the wallpaper — gates snapshot/restore of the original.
    var usesWallpaper: Bool {
        events.contains { if case .wallpaper = $0.action { return true } else { return false } }
    }
}

enum TimelineLoader {
    /// Parse a JSON timeline and resolve every event to an absolute time in seconds.
    /// `beat` values are converted with the document BPM + offset; explicit `t`
    /// (seconds) wins when present.
    static func load(from url: URL) throws -> LoadedTimeline {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(TimelineDocument.self, from: data)

        let bpm = doc.meta.bpm
        let offset = doc.meta.beatOffset ?? 0

        let resolved: [ResolvedEvent] = doc.events.map { ev in
            let time: Double
            if let t = ev.t {
                time = t
            } else if let beat = ev.beat {
                time = offset + beat * 60.0 / bpm
            } else {
                time = 0
            }
            return ResolvedEvent(fireTime: time, action: ev.action)
        }
        .sorted { $0.fireTime < $1.fireTime }

        return LoadedTimeline(meta: doc.meta, events: resolved)
    }
}
