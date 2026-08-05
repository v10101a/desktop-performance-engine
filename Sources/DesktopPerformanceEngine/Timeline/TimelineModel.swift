import Foundation

// MARK: - Document

struct TimelineDocument: Decodable {
    let meta: Meta
    let events: [TimelineEvent]
}

struct Meta: Decodable {
    let audioFile: String?
    let bpm: Double
    let beatOffset: Double?
    let timelineLatency: Double?
    /// Wallpaper swap is DISABLED by default: on modern macOS it can't be restored
    /// for Aerial/dynamic wallpapers and applies unreliably via the public API, which
    /// breaks the reversibility guarantee. Set true only if you accept that a `wallpaper`
    /// event may not fully restore the original.
    let allowWallpaper: Bool?
}

// MARK: - Event parameter payloads

struct ContentSpec: Decodable {
    let kind: String      // "color" | "text" | "image"
    let hex: String?
    let text: String?
    let path: String?
}

struct AnimateSpec: Decodable {
    let kind: String      // "springIn" | "fadeIn" | "none"
}

struct OpenWindowParams: Decodable {
    let id: String
    let screen: Int?
    let content: ContentSpec
    let frame: [Double]   // [x, y, w, h], top-left origin, relative to the target screen
    let animate: AnimateSpec?
}

struct FakeDialogParams: Decodable {
    let id: String
    let title: String
    let body: String
    let buttons: [String]?
    let screen: Int?
    let frame: [Double]?
}

struct CloseWindowParams: Decodable {
    let id: String
}

struct MoveWindowParams: Decodable {
    let id: String
    let frame: [Double]           // [x, y] or [x, y, w, h], top-left origin
    let durationBeats: Double?
    let durationSeconds: Double?
    let easing: String?
}

struct ScreenFlashParams: Decodable {
    let color: String?
    let durationBeats: Double?
    let durationSeconds: Double?
    let screen: Int?
}

// Modeled now so the document format is stable; executors land in later phases.
struct CursorPathParams: Decodable {
    let path: String?
    let points: [[Double]]
    let durationBeats: Double?
    let durationSeconds: Double?
    let easing: String?
    let mode: String?
}

struct RearrangeIconsParams: Decodable {
    let layout: String?
    let seed: Int?
}

struct JiggleParams: Decodable {
    let id: String                // a spawned window's id
    let durationBeats: Double?
    let durationSeconds: Double?
    let amplitude: Double?         // px, default 14
    let frequency: Double?         // Hz, default 10
}

struct WallpaperParams: Decodable {
    let path: String?             // image file (absolute or relative to the timeline)
    let color: String?            // solid color, e.g. "#FF00AA" (used if no path)
    let screen: Int?              // nil = all screens
}

// MARK: - Event

enum EventAction {
    case openWindow(OpenWindowParams)
    case fakeDialog(FakeDialogParams)
    case closeWindow(CloseWindowParams)
    case moveWindow(MoveWindowParams)
    case screenFlash(ScreenFlashParams)
    case cursorPath(CursorPathParams)         // Phase 2
    case rearrangeIcons(RearrangeIconsParams) // Phase 3
    case jiggle(JiggleParams)                 // Phase 4
    case wallpaper(WallpaperParams)           // Phase 4
}

/// A single authored event. `beat`/`t` are resolved to an absolute `fireTime`
/// by the loader (which knows the document BPM/offset), then sorted.
struct TimelineEvent: Decodable {
    let beat: Double?
    let t: Double?
    let action: EventAction

    private enum CodingKeys: String, CodingKey {
        case beat, t, type, params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beat = try c.decodeIfPresent(Double.self, forKey: .beat)
        t = try c.decodeIfPresent(Double.self, forKey: .t)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "openWindow":
            action = .openWindow(try c.decode(OpenWindowParams.self, forKey: .params))
        case "fakeDialog":
            action = .fakeDialog(try c.decode(FakeDialogParams.self, forKey: .params))
        case "closeWindow":
            action = .closeWindow(try c.decode(CloseWindowParams.self, forKey: .params))
        case "moveWindow":
            action = .moveWindow(try c.decode(MoveWindowParams.self, forKey: .params))
        case "screenFlash":
            action = .screenFlash(try c.decode(ScreenFlashParams.self, forKey: .params))
        case "cursorPath":
            action = .cursorPath(try c.decode(CursorPathParams.self, forKey: .params))
        case "rearrangeIcons":
            action = .rearrangeIcons(try c.decode(RearrangeIconsParams.self, forKey: .params))
        case "jiggle":
            action = .jiggle(try c.decode(JiggleParams.self, forKey: .params))
        case "wallpaper":
            action = .wallpaper(try c.decode(WallpaperParams.self, forKey: .params))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown event type \"\(type)\"")
        }
    }
}

/// An event with its absolute fire time resolved.
struct ResolvedEvent {
    let fireTime: Double
    let action: EventAction
}
