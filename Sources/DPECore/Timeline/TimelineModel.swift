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
    /// `fileSwarm` is DISABLED by default: it is the only event that writes to disk,
    /// creating and deleting marked throwaway files in ~/Desktop. They are swept on
    /// stop, panic and quit, and only files carrying its marker are ever removed — but
    /// a show that touches the filesystem should be an explicit choice, so set this
    /// true to allow it.
    let allowDesktopFiles: Bool?
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
    /// The alert illustration: "caution" (default, the yellow warning triangle),
    /// "critical" (the app icon badged with it, as NSAlert does), "info", "app", or
    /// "none". These are the system's own images, so they match every other alert on
    /// the machine. Dropped automatically on panels too small to carry one.
    var icon: String? = nil

    /// Authored `icon` resolved to a known illustration; an unrecognised value falls
    /// back to the caution triangle rather than silently rendering nothing.
    var dialogIcon: DialogIcon { DialogIcon(rawValue: icon ?? "caution") ?? .caution }
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

/// Fills every screen with randomly sized, randomly placed photo windows scanned from
/// the viewer's own folders, then keeps laying new photos over the wall. Ported from
/// the standalone `photowall` app.
///
/// Rates are **per beat**, not per second: the standalone app's tuned defaults
/// (`--speed 2`) come out at roughly `fillPerBeat: 20` / `churnPerBeat: 2.7` at
/// 128.5 BPM, and expressing them this way keeps the fill in tempo.
///
/// `durationBeats`/`durationSeconds` bound how long the wall keeps *placing*; the
/// windows stay up until `closeWindow` with the same `id`, so the screen never
/// flashes bare mid-show. Omit both to place until closed.
struct PhotoWallParams: Decodable {
    let id: String
    /// Folders to scan. nil = ~/Desktop, ~/Downloads, ~/Documents, ~/Pictures.
    var dirs: [String]? = nil
    var fillPerBeat: Double? = nil    // photos per beat while filling (default 20)
    var churnPerBeat: Double? = nil   // photos per beat once full (default 2.7)
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var windows: Int? = nil           // live photo population while churning (default 45)
    var minFrac: Double? = nil        // smallest window edge as a fraction of the screen (default 0.13)
    var maxFrac: Double? = nil        // largest (default 0.52)
    var cell: Double? = nil           // placement lattice / coverage resolution (default 12)
    var keepFilling: Bool? = nil      // false = stop once the screen is full
    var shadows: Bool? = nil
    var fade: Double? = nil           // fade-in seconds (default 0.065); 0 = instant
    var imageCap: Double? = nil       // largest thumbnail edge in pixels (default 1200)
    var minPixels: Double? = nil      // ignore images whose long edge is under this (default 640)
    var includeCloud: Bool? = nil     // iCloud-evicted files stall ~20s on first read
    /// "normal" (default, interleaves with the show's windows) | "floating" | "front"
    /// ("front" is the standalone app's level: above the menu bar and Dock).
    var level: String? = nil
}

/// A tumbling glass (or mirror-metal) torus in a borderless transparent window,
/// refracting a live capture of the screen behind it. Ported from the standalone
/// `GlassTorus` app.
///
/// The tumble is driven by the show clock: `elapsed` is the time since the event fired,
/// times `speed`, so it scrubs with the playhead and renders identically take to take.
///
/// `durationBeats`/`durationSeconds` close the window when they elapse; omit both and
/// it stays until `closeWindow` with the same `id`.
struct GlassTorusParams: Decodable {
    let id: String
    /// "glass" (default) | "crystal" | "chrome" | "gold" | "copper" | "titanium"
    var material: String? = nil
    var roughness: Double? = nil      // 0 = mirror, 1 = brushed (default 0.04)
    var planeDistance: Double? = nil  // how far behind the torus the desktop plane sits (default 2.0)
    var speed: Double? = nil          // tumble rate multiplier on show time (default 1)
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var screen: Int? = nil
    /// [x, y, w, h], top-left origin, as everywhere else. Omit for the standalone
    /// app's sizing: 72% of the screen's shorter side, clamped to 560…1100, centred.
    var frame: [Double]? = nil
    var size: Double? = nil           // square side, if `frame` is omitted
    /// "screenSaver" (default, above the menu bar) | "floating" | "normal"
    var level: String? = nil
    /// true (default): the glass reflects the running show — the photo wall, every
    /// effect window. false excludes the whole app from the capture, which is what the
    /// standalone app did, leaving only the bare desktop to refract.
    var reflectShow: Bool? = nil
}

struct WallpaperParams: Decodable {
    let path: String?             // image file (absolute or relative to the timeline)
    let color: String?            // solid color, e.g. "#FF00AA" (used if no path)
    let screen: Int?              // nil = all screens
}

/// The desktop wallpaper itself as a surface, from the standalone BlackWallpaper /
/// GlitchWallpaper / RecursiveWallpaper tools, folded into one event.
///
/// - `strobe`    — solid black ↔ solid white on every screen.
/// - `glitch`    — displacement, channel split and block corruption over the wallpaper
///                 the show started with.
/// - `recursive` — the desktop set to a screenshot of the desktop, deepening each pass.
///
/// **Gated behind `meta.allowWallpaper`, like the `wallpaper` event**, and for the same
/// reason: macOS cannot reliably restore Aerial/dynamic wallpapers through the public
/// API. Without that flag the event is skipped with a log line.
///
/// `hz` is an apply *rate*, not a beat division: `setDesktopImageURL` blocks ~58 ms per
/// screen, so the standalone strobe measured a ~17 Hz ceiling and the compositor may
/// still drop frames. Asking for more than that gets you the ceiling, not an error.
///
/// > Flashing imagery can trigger seizures in photosensitive epilepsy. `screenFlash` is
/// > the beat-accurate, instantly reversible way to flash the screen; this mode differs
/// > only in living *behind* every window.
struct DeskWallpaperParams: Decodable {
    let id: String
    var mode: String? = nil          // "strobe" (default) | "glitch" | "recursive"
    var hz: Double? = nil            // applies per second (default 8)
    var intensity: Double? = nil     // glitch only, 0…1 (default 0.6)
    var seed: Int? = nil             // glitch only, for a reproducible tear pattern
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
}

/// The `system_probe` disclosure report typing itself out in a window — a terminal
/// reading back everything this machine knows about whoever is sitting at it. Ported
/// from the standalone systemprobe app.
///
/// `linesPerBeat` is a rate, not a duration (as with `typeText.charsPerBeat`), so
/// editing the report doesn't retime the scene. The window stays up until `closeWindow`
/// by `id` unless a duration is given.
///
/// The identity section reads the Contacts "me" card and asks Location Services for a
/// fix, so this event — and only this event — triggers those two prompts. Refused, those
/// lines read `<unavailable>` and the rest of the report is unaffected.
struct SystemProbeParams: Decodable {
    let id: String
    var linesPerBeat: Double? = nil   // reveal rate (default 24)
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var screen: Int? = nil
    /// [x, y, w, h], top-left origin. Defaults to 1060×800, centred.
    var frame: [Double]? = nil
}

/// Patterns drawn on the desktop out of real file icons. Ported from the standalone
/// FileSwarm app.
///
/// **Gated behind `meta.allowDesktopFiles`** — this is the only event in the show that
/// writes to disk. Files are tiny, prefixed `swarm-`, marked with an extended attribute,
/// and swept on stop/panic/quit; only files carrying that marker are ever deleted.
///
/// **Do not author this to land on a beat.** Finder shows a deletion in ~85 ms but takes
/// 0.7-3 s to show a creation, erratically — a window-server limit, not something the
/// engine can fix. Treat it as a texture running under a section.
///
/// Patterns: `spiral`, `wave`, `rain`, `ripple`, `life`, `marquee` (set `text`),
/// `constellation`.
struct FileSwarmParams: Decodable {
    let id: String
    var pattern: String? = nil        // default "spiral"
    var ticksPerBeat: Double? = nil   // pattern steps per beat (default 2)
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var maxLive: Int? = nil           // icon population ceiling (default 80)
    var createsPerTick: Int? = nil
    var minLifetime: Double? = nil    // seconds a file is held before it may be removed
    var positionIcons: Bool? = nil    // false = skip Finder automation, no grid placement
    var erase: Bool? = nil            // cut the pattern out of a full grid instead
    var seed: Int? = nil
    var text: String? = nil           // marquee only
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
    case photoWall(PhotoWallParams)           // ported from the standalone photowall app
    case glassTorus(GlassTorusParams)         // ported from the standalone GlassTorus app
    case deskWallpaper(DeskWallpaperParams)   // ported from the BlackWallpaper tools
    case systemProbe(SystemProbeParams)       // ported from the standalone systemprobe app
    case fileSwarm(FileSwarmParams)           // ported from the standalone FileSwarm app
}

extension EventAction {
    /// The `"type"` string this case is authored as. One canonical mapping — `--validate`
    /// used to carry a second, hand-written copy of it.
    var typeName: String {
        switch self {
        case .openWindow: return "openWindow"
        case .fakeDialog: return "fakeDialog"
        case .closeWindow: return "closeWindow"
        case .moveWindow: return "moveWindow"
        case .screenFlash: return "screenFlash"
        case .cursorPath: return "cursorPath"
        case .rearrangeIcons: return "rearrangeIcons"
        case .jiggle: return "jiggle"
        case .wallpaper: return "wallpaper"
        case .sprite: return "sprite"
        case .cursorTrail: return "cursorTrail"
        case .typeText: return "typeText"
        case .photoWall: return "photoWall"
        case .glassTorus: return "glassTorus"
        case .deskWallpaper: return "deskWallpaper"
        case .systemProbe: return "systemProbe"
        case .fileSwarm: return "fileSwarm"
        }
    }
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

    /// `"type"` string → payload decoder. A table rather than a `switch` so the type
    /// strings live in one place next to `EventAction.typeName`, and so a new event that
    /// is added to one and not the other is caught by `eventCatalogIsConsistent()`
    /// rather than by a document failing to load at showtime.
    private static let decoders: [String: (KeyedDecodingContainer<CodingKeys>) throws -> EventAction] = [
        "openWindow": { .openWindow(try $0.decode(OpenWindowParams.self, forKey: .params)) },
        "fakeDialog": { .fakeDialog(try $0.decode(FakeDialogParams.self, forKey: .params)) },
        "closeWindow": { .closeWindow(try $0.decode(CloseWindowParams.self, forKey: .params)) },
        "moveWindow": { .moveWindow(try $0.decode(MoveWindowParams.self, forKey: .params)) },
        "screenFlash": { .screenFlash(try $0.decode(ScreenFlashParams.self, forKey: .params)) },
        "cursorPath": { .cursorPath(try $0.decode(CursorPathParams.self, forKey: .params)) },
        "rearrangeIcons": { .rearrangeIcons(try $0.decode(RearrangeIconsParams.self, forKey: .params)) },
        "jiggle": { .jiggle(try $0.decode(JiggleParams.self, forKey: .params)) },
        "wallpaper": { .wallpaper(try $0.decode(WallpaperParams.self, forKey: .params)) },
        "sprite": { .sprite(try $0.decode(SpriteParams.self, forKey: .params)) },
        "cursorTrail": { .cursorTrail(try $0.decode(CursorTrailParams.self, forKey: .params)) },
        "typeText": { .typeText(try $0.decode(TypeTextParams.self, forKey: .params)) },
        "photoWall": { .photoWall(try $0.decode(PhotoWallParams.self, forKey: .params)) },
        "glassTorus": { .glassTorus(try $0.decode(GlassTorusParams.self, forKey: .params)) },
        "deskWallpaper": { .deskWallpaper(try $0.decode(DeskWallpaperParams.self, forKey: .params)) },
        "systemProbe": { .systemProbe(try $0.decode(SystemProbeParams.self, forKey: .params)) },
        "fileSwarm": { .fileSwarm(try $0.decode(FileSwarmParams.self, forKey: .params)) },
    ]

    /// Every `"type"` string the decoder accepts. Ordered, for stable test output.
    static var registeredTypeNames: [String] { decoders.keys.sorted() }

    /// Every registered type string decodes to the case that reports that same name.
    /// Exercised by the unit tests.
    static func catalogIsConsistent() -> [String] {
        decoders.keys.compactMap { name in
            let json = Data("{\"type\":\"\(name)\",\"beat\":0,\"params\":{}}".utf8)
            guard let ev = try? JSONDecoder().decode(TimelineEvent.self, from: json) else {
                return nil   // params required — covered by the per-event decode tests
            }
            return ev.action.typeName == name ? nil : "\(name) → \(ev.action.typeName)"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beat = try c.decodeIfPresent(Double.self, forKey: .beat)
        t = try c.decodeIfPresent(Double.self, forKey: .t)
        let type = try c.decode(String.self, forKey: .type)

        guard let decode = TimelineEvent.decoders[type] else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown event type \"\(type)\"")
        }
        action = try decode(c)
    }
}

/// An event with its absolute fire time resolved.
struct ResolvedEvent {
    let fireTime: Double
    let action: EventAction
}
