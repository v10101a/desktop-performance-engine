import Foundation

// MARK: - Document

struct TimelineDocument: Decodable {
    let meta: Meta
    let events: [TimelineEvent]
}

/// A structural cue from track analysis (section boundary, drop, break, …). Rendered
/// on the scrubber for navigation. Times are absolute seconds, so they're valid
/// regardless of `meta.bpm`. See tools/analyze_track.py.
struct Marker: Decodable {
    let t: Double
    let bar: Int?
    let label: String?
    let kind: String?
}

struct Meta: Decodable {
    let audioFile: String?
    let bpm: Double
    let beatOffset: Double?
    let timelineLatency: Double?
    /// Tempo detected from the audio (informational; does not re-time beat events).
    let analyzedBpm: Double?
    /// Structural key points from track analysis.
    let markers: [Marker]?
    /// Wallpaper swap is DISABLED by default: on modern macOS it can't be restored
    /// for Aerial/dynamic wallpapers and applies unreliably via the public API, which
    /// breaks the reversibility guarantee. Set true only if you accept that a `wallpaper`
    /// event may not fully restore the original.
    let allowWallpaper: Bool?
}

// MARK: - Event parameter payloads

/// A real Apple Maps camera move, for `content.kind == "map"`. The camera flies from
/// the `lat`/`lon`/`altitude`/`heading` pose to the `to*` pose over `seconds`; anything
/// omitted holds. Needs a network connection to fetch tiles.
struct MapSpec: Decodable {
    let lat: Double
    let lon: Double
    let toLat: Double?
    let toLon: Double?
    let altitude: Double?     // metres from the ground, default 900
    let toAltitude: Double?
    let pitch: Double?        // degrees off straight-down, default 60
    let toPitch: Double?
    let heading: Double?      // compass degrees, default 0
    let toHeading: Double?
    let seconds: Double?      // fly duration, default 14
    let style: String?        // "flyover" (default) | "satellite" | "hybrid" | "standard"
}

/// Optional fields carry `= nil` so the synthesized memberwise initializer has
/// defaults — dev-tool and preview code that builds these by hand then doesn't need
/// touching every time the format gains a field.
struct ContentSpec: Decodable {
    let kind: String      // "color" | "text" | "code" | "image" | "ascii" | "livecode" | "map"
    var hex: String? = nil
    var text: String? = nil
    var path: String? = nil
    /// Optional fake window chrome: "browser" | "terminal" | "mac" | "mixed" | "none".
    /// Drawn by us at any size — never a pixel-accurate imitation of real system UI.
    var chrome: String? = nil
    var title: String? = nil    // chrome bar text (browser shows it as the URL pill)
    /// Camera flight for `kind == "map"`.
    var map: MapSpec? = nil
    /// Page to load for `kind == "web"`.
    var url: String? = nil
    /// `livecode` only: has the patch been evaluated yet? A window opened with
    /// `running: false` shows the source over a dead black canvas — re-open the same
    /// `id` with `running: true` and the sketch starts, which is how the show fakes
    /// someone hitting run.
    var running: Bool? = nil
    // "ascii" kind: literal `text` OR an image `path` converted to ASCII.
    var cols: Int? = nil        // character-grid width for image→ASCII (default 80)
    var invert: Bool? = nil     // flip the light/dark ramp
    var colorized: Bool? = nil  // tint each glyph with its source pixel color
    var ramp: String? = nil     // custom character ramp (dark→light)
}

struct AnimateSpec: Decodable {
    let kind: String      // "springIn" | "fadeIn" | "none"
}

struct OpenWindowParams: Decodable {
    let id: String
    var screen: Int? = nil
    let content: ContentSpec
    let frame: [Double]   // [x, y, w, h], top-left origin, relative to the target screen
    var animate: AnimateSpec? = nil
    /// Let the viewer grab it: draggable by its body, closable by its traffic lights.
    /// Off by default — click-through is what keeps a choreographed cursor from
    /// snagging on the scenery.
    var interactive: Bool? = nil
    /// Closing it doesn't get rid of it. The window comes back a beat later, which is
    /// only interesting on the ones that matter.
    var respawn: Bool? = nil
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

/// A "window zoetrope": animation frames encoded as rows of characters, each lit
/// cell rendered by a pooled micro-window. The whole sprite can translate (gallop)
/// via `velocity` while frames advance on the beat.
struct SpriteParams: Decodable {
    let id: String
    let frames: [[String]]        // each frame = rows; any char except "." or " " is a lit cell
    let cell: Double?             // cell width in points (default 30)
    let cellAspect: Double?       // cell height = cell * aspect (default 0.72)
    let gap: Double?              // spacing between cells (default 4)
    let origin: [Double]          // [x, y] top-left origin, relative to `screen`
    let screen: Int?
    let velocity: [Double]?       // points/sec [vx, vy] in top-left space (+y down)
    /// Arrival mode (overrides `velocity`): translate origin → `target` over
    /// `travelBeats`/`travelSeconds` with `travelEasing` (default easeOut), then hold
    /// there while frames keep cycling — run into frame, stay in frame.
    let target: [Double]?
    let travelBeats: Double?
    let travelSeconds: Double?
    let travelEasing: String?
    /// Optional exit leg: in the final `exitBeats`/`exitSeconds` of the sprite's
    /// duration, translate target → `exit` (default easing easeIn) — run out of frame.
    let exit: [Double]?
    let exitBeats: Double?
    let exitSeconds: Double?
    let exitEasing: String?
    let beatsPerFrame: Double?    // default 0.5
    let durationBeats: Double?    // nil (and no seconds) = run until closeWindow(id)
    let durationSeconds: Double?
    let chrome: String?           // "browser" | "terminal" | "mac" | "mixed" (default) | "none"
    let colors: [String]?         // body colors cycled across the pool
}

/// Windows that trace the real cursor. `stamp` drops persistent breadcrumbs every
/// `spacing` px of travel (a jump > 4×spacing is treated as pen-up: no stamps across
/// it, so a cursor warping between letter strokes doesn't smear). `follow` is a
/// comet tail of windows chasing the cursor with a staggered delay.
struct CursorTrailParams: Decodable {
    let id: String
    let mode: String?             // "stamp" (default) | "follow"
    let spacing: Double?          // stamp: px between breadcrumbs (default 28)
    let count: Int?               // follow: tail length (default 8); stamp: max breadcrumbs (default 160)
    let delay: Double?            // follow: seconds between successive windows (default 0.07)
    let size: [Double]?           // [w, h] of each window (default [46, 34])
    let chrome: String?           // as SpriteParams.chrome (default "mixed")
    let colors: [String]?
    let durationBeats: Double?    // sampling window; stamps persist after until closed
    let durationSeconds: Double?
}

/// A text editor that opens and writes itself out, in tempo. `charsPerBeat` sets the
/// typing rate (a rate, not a duration, so editing the copy doesn't retime the scene);
/// `durationBeats` is optional and only trims the scene short. The window stays up,
/// caret blinking, until `closeWindow` by `id`.
struct TypeTextParams: Decodable {
    let id: String
    var screen: Int? = nil
    let frame: [Double]           // [x, y, w, h], top-left origin
    let text: String
    var charsPerBeat: Double? = nil     // default 16
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var title: String? = nil            // window chrome title, e.g. "Untitled 2"
    var fontSize: Double? = nil         // default 13
    /// Let the viewer pick the document up and move it around while it types.
    var interactive: Bool? = nil
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
    case sprite(SpriteParams)                 // Phase 5
    case cursorTrail(CursorTrailParams)       // Phase 5
    case typeText(TypeTextParams)             // Phase 6
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
        case "sprite":
            action = .sprite(try c.decode(SpriteParams.self, forKey: .params))
        case "cursorTrail":
            action = .cursorTrail(try c.decode(CursorTrailParams.self, forKey: .params))
        case "typeText":
            action = .typeText(try c.decode(TypeTextParams.self, forKey: .params))
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
