import Foundation

struct LoadedTimeline {
    let meta: Meta
    let events: [ResolvedEvent]   // sorted ascending by fireTime

    /// End of the show: the last event fire time PLUS that event's own running
    /// time (a sprite or trail fires once but plays for many beats).
    var duration: Double {
        events.map { $0.fireTime + TimelineLoader.intrinsicDuration(of: $0.action, bpm: meta.bpm) }
              .max() ?? 0
    }

    /// Whether the show touches desktop icons — gates the (permission-prompting)
    /// icon snapshot so timelines that don't use icons never ask for Automation.
    var usesIcons: Bool {
        events.contains { if case .rearrangeIcons = $0.action { return true } else { return false } }
    }

    /// Whether the show changes the machine's REAL desktop picture — gates the snapshot
    /// and the restore of the original, on every Space.
    ///
    /// `deskWallpaper` counts only when it asks for `surface: "wallpaper"`. On the
    /// default layer surface nothing about the machine changes, so there is nothing to
    /// snapshot and nothing to put back.
    ///
    /// It used to check `.wallpaper` alone. That missed `deskWallpaper` entirely — and
    /// the shipped show is *all* `deskWallpaper` — so `wallpaperArmed` was false through
    /// a run that painted the desktop blue, and `restoreAllSpaces()` never ran. The
    /// active Space came back (the effect's own teardown does that); every other desktop
    /// kept the show's blue.
    var usesWallpaper: Bool {
        events.contains {
            switch $0.action {
            case .wallpaper: return true
            case .deskWallpaper(let p): return p.surface == "wallpaper"
            default: return false
            }
        }
    }
}

enum TimelineLoader {
    /// How long an event keeps running after it fires (0 for instant events).
    /// Defaults mirror the executors' own defaults.
    static func intrinsicDuration(of action: EventAction, bpm: Double) -> Double {
        func secs(_ beats: Double?, _ seconds: Double?, or def: Double = 0) -> Double {
            seconds ?? beats.map { $0 * 60.0 / bpm } ?? def
        }
        switch action {
        case .sprite(let p):      return secs(p.durationBeats, p.durationSeconds)
        case .cursorTrail(let p): return secs(p.durationBeats, p.durationSeconds)
        case .cursorPath(let p):  return secs(p.durationBeats, p.durationSeconds, or: 60.0 / bpm)
        case .moveWindow(let p):  return secs(p.durationBeats, p.durationSeconds)
        case .jiggle(let p):      return secs(p.durationBeats, p.durationSeconds, or: 60.0 / bpm)
        case .screenFlash(let p): return secs(p.durationBeats, p.durationSeconds, or: 0.2)
        case .typeText(let p):
            // The scene runs as long as it takes to type the text, unless trimmed.
            let typing = Double(p.text.count) / max(1, p.charsPerBeat ?? 16) * 60.0 / bpm
            return secs(p.durationBeats, p.durationSeconds, or: typing)
        default:                  return 0
        }
    }
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
