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
    /// `[width, height]` of the canvas the show's frames, cursor points and sizes were
    /// authored in. When present, ScreenGeometry maps that canvas onto each real
    /// screen, so a bigger display gets the same composition scaled up — not the
    /// authored pixels huddled in its top-left corner. Absent: raw points, 1:1.
    let authoredSize: [Double]?
}

/// `brickBreaker`: the machine's own furniture, racked up and knocked down. Bricks are
/// real windows, the ball is the system's beach ball, and the paddle is wherever the
/// viewer's pointer happens to be. Ends on `closeWindow` with the same `id`.
struct BrickBreakerParams: Decodable {
    let id: String
    /// The play area, authored [x, y, w, h]; the whole screen if absent.
    var frame: [Double]? = nil
    var rows: Int? = nil          // default 4
    var cols: Int? = nil          // default 8
    var speed: Double? = nil      // ball speed in authored points/sec (default 520)
    var ball: Double? = nil       // ball diameter, authored points (default 44)
    var paddle: [Double]? = nil   // [width, height], authored points (default [190, 26])
    var screen: Int? = nil
    var seed: Int? = nil          // fixes the serve angles
}

/// `segSwarm`: the imported segmenter with the desktop as its canvas — every segment it
/// finds becomes its own window holding the frame it was cut from. Ends on `closeWindow`
/// with the same `id`.
struct SegSwarmParams: Decodable {
    let id: String
    /// A video file to segment; absent means the machine's camera. The Syphon feed did
    /// not come across from segcam, but there is a third source that did not exist
    /// upstream: `window`.
    var path: String? = nil
    /// The id of a window the show already has open — segment THAT. Cue 14's map is run
    /// through the segmenter this way. Takes precedence over `path` and the camera, and
    /// needs no Screen Recording: the window draws itself into a bitmap in-process.
    var window: String? = nil
    /// How often that window is redrawn for the segmenter (default 15). Drawing happens
    /// on the main thread, so this is deliberately not 30.
    var windowHz: Double? = nil
    var mode: String? = nil        // "motion" (default here) | "threshold" | "face"
    var intensity: Double? = nil   // that segmenter's one knob, 0…1, always "more"
    var invert: Bool? = nil        // threshold only: take the dark regions instead
    var mirror: Bool? = nil        // defaults on for the camera, off for a clip
    var maxWindows: Int? = nil     // how deep the pile goes before the oldest is recycled
    /// The keyline round each panel: a hex, or `"none"` for a bare window. Absent, it is
    /// segcam's own green — which marks a detection, and reads as a debug overlay when
    /// the panels are meant to be the furniture rather than an annotation of it.
    var border: String? = nil
    /// Window level, same vocabulary as `openWindow`: "below" puts the pile under
    /// everything the show opens (still over the desktop), which is how another act gets
    /// to play on top of it. Absent, it is segcam's own — above everything.
    var level: String? = nil
    var hz: Double? = nil          // file pull rate (default 30)
    /// The pile LEAVES over this many seconds on its close, oldest panel first, instead
    /// of on one frame. 0 (default) is a few panels per run-loop pass — quick, but not
    /// one stall.
    var clearSeconds: Double? = nil
    var screen: Int? = nil
}

// MARK: - Event parameter payloads

/// A real Apple Maps camera move, for `content.kind == "map"`. The camera flies from
/// the `lat`/`lon`/`altitude`/`heading` pose to the `to*` pose over `seconds`; anything
/// omitted holds. Needs a network connection to fetch tiles.
struct MapSpec: Decodable {
    let lat: Double
    let lon: Double
    /// Fly over the viewer's OWN location: the most recent CoreLocation fix replaces
    /// the authored coordinates, which remain the fallback when no fix has arrived.
    var here: Bool? = nil
    let toLat: Double?
    let toLon: Double?
    let altitude: Double?     // metres from the ground, default 900
    let toAltitude: Double?
    let pitch: Double?        // degrees off straight-down, default 60
    let toPitch: Double?
    let heading: Double?      // compass degrees, default 0
    let toHeading: Double?
    let seconds: Double?      // the whole shot, default 14
    let style: String?        // "flyover" (default) | "satellite" | "hybrid" | "standard"
    /// The shot is two legs. `zoomSeconds` is how long the FALL takes — the
    /// altitude/pitch/centre move — and it defaults to `seconds`, which is what every
    /// timeline did before this field existed: one move filling the whole shot.
    /// Setting it shorter lands the camera early and leaves the rest of `seconds` for…
    var zoomSeconds: Double? = nil
    /// …the orbit: degrees of heading travelled around the point it landed on, on top
    /// of the descent's own `heading` → `toHeading` sweep. Default 0 — no orbit, so an
    /// old timeline flies exactly as it did.
    var orbitDegrees: Double? = nil
}

/// Optional fields carry `= nil` so the synthesized memberwise initializer has
/// defaults — dev-tool and preview code that builds these by hand then doesn't need
/// touching every time the format gains a field.
struct ContentSpec: Decodable {
    let kind: String      // "color" | "text" | "lyric" | "code" | "image" | "ascii" | "asciilog" | "glitch" | "automaton" | "shader" | "uichaos" | "fileworks" | "cursors" | "mandala" | "livecode" | "map" | "doom"
    var hex: String? = nil
    var text: String? = nil
    var path: String? = nil
    /// `text`/`lyric` only: the type colour (`hex` is the ground). A `lyric` card is a
    /// lyric-video frame — one line, set as large as the window allows, centred — so a
    /// fullscreen one is the whole screen going blue with the words on it.
    var fg: String? = nil
    /// `text` only: a fixed point size (default 42). `lyric` always fits to the window.
    var fontSize: Double? = nil
    /// Optional fake window chrome: "browser" | "terminal" | "mac" | "mixed" | "none".
    /// Drawn by us at any size — never a pixel-accurate imitation of real system UI.
    var chrome: String? = nil
    var title: String? = nil    // chrome bar text (browser shows it as the URL pill)
    var loop: Bool? = nil       // video: play round again (default true)
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
    // "shader" kind: a GLSL fragment shader at `path`, run live in a WebGL context.
    // These are the artist's own scalar uniforms; the samplers the shaders declare are
    // bound to black by the host (see shader.html).
    var drop: Double? = nil
    var vol: Double? = nil
    var midi: Double? = nil
    /// "shader" only: turn the canvas, in degrees per second (0/absent = still). The
    /// canvas is scaled up to keep covering its window as it goes — see `layoutCanvas`.
    var spin: Double? = nil
    // "automaton" kind: an elementary cellular automaton, running and scrolling.
    var rule: Int? = nil        // Wolfram's numbering, 0…255 (default 30)
    var hz: Double? = nil       // generations per second (default 12)
    // "asciilog" kind: a live monospaced text plane, transparent, usually full screen.
    // Set in Monaco (see `AsciiFont`). Reuses `hex` as the type colour, `fontSize`,
    // `hz`, `seed` and `cols` from the fields above.
    /// Which generator feeds the plane:
    ///   "hex"     — a memory dump, scrolling at `hz`
    ///   "lines"   — `lines`, pushed one at a time at `hz` as log records
    ///   "text"    — `text`, drawn once and left
    ///   "windows" — the show's own windows as box art, redrawn as they come and go
    /// "cursors" + `mode: "school"` only: which scene the shoal is in — where the
    /// cursors spawn AND the flock weights that then hold them there. "spiral"
    /// (default) | "ring" | "grid" | "burst" | "stream". Re-open the same window id
    /// with a different one and the screen CUTS between pictures; a new seed alone is
    /// the same picture shuffled. Never reads the viewer's pointer in any of them —
    /// that is `mode: "school"`, not the pattern.
    var pattern: String? = nil
    /// "lyric" only: re-pick the FACE this many times a second, at random, from every
    /// font on the viewer's machine that can set the words — their own `~/Library/Fonts`
    /// included. Absent or 0 keeps the show's Hack Bold. `seed` fixes the sequence.
    ///
    /// The fit is redone on every change, not just the font: families differ by ~6× in
    /// width at one point size, so a card that only swapped the face would overflow the
    /// window half the time and set the line a third too small the rest.
    var fontCycleHz: Double? = nil
    var source: String? = nil
    /// `source: "lines"` only: the records to push, cycled.
    var lines: [String]? = nil
    /// 0…1. Stacks combining diacriticals over, under and through every glyph, so the
    /// text bleeds into the rows above and below. 0 (default) leaves it clean.
    var zalgo: Double? = nil
    /// The plane's ground. ABSENT MEANS TRANSPARENT, which is the usual case — the
    /// screen shows through the gaps between the glyphs. Set it and the plane covers
    /// what is under it.
    var bg: String? = nil
    /// Strobe rate in Hz, 0/absent = steady. The plane alternates between drawn and
    /// GONE — not dimmed — so the real screen shows through on the off phase.
    /// Photosensitivity: this is a full-screen change at twice this rate. Keep the
    /// show's total out of the 15–20 Hz band and re-measure after changing it.
    var strobe: Double? = nil
    // "glitch" kind: `path` torn once by the wallpaper's own glitch pass.
    var intensity: Double? = nil   // 0…1, scales every part of the tear (default 0.6)
    var seed: Int? = nil           // the tear is a pure function of this — same every take
    /// "cursors" kind: how the swarm moves. "chase" (default) hunts the viewer's own
    /// pointer; "school" ignores it entirely, laying the cursors out on a spiral and
    /// flocking them like fish.
    ///
    /// "particles" kind: which behaviour — "vortex" (default), "rain" or "orbit".
    var mode: String? = nil
    /// "cursors" kind: seconds over which the swarm arrives, one pointer at a time.
    /// Absent or 0 puts the whole population up on one frame. (Not `ramp` — that name
    /// is the ascii kind's character ramp.)
    var spawnSeconds: Double? = nil
    /// "segcam" kind: mirror the picture (a camera is a mirror, a clip is not — the
    /// default follows from whether `path` is set) and label each segment with its id.
    var mirror: Bool? = nil
    var labels: Bool? = nil
    /// "particles" kind: what the particles are made of — "icons" (default, the system's
    /// own file icons), "cursors" (the Mac pointer) or "beachballs" (the real spinner,
    /// all fifteen frames of it).
    var sprite: String? = nil
}

struct AnimateSpec: Decodable {
    let kind: String      // "springIn" | "fadeIn" | "none"
}

struct OpenWindowParams: Decodable {
    let id: String
    var screen: Int? = nil
    let content: ContentSpec
    let frame: [Double]   // [x, y, w, h], top-left origin, relative to the target screen
    /// `"center"`: `frame` is `[dx, dy, w, h]` — the window's centre, offset from the
    /// screen's centre (dy positive = down). Anything else, or nothing, is top-left.
    var anchor: String? = nil
    var animate: AnimateSpec? = nil
    /// Let the viewer grab it: draggable by its body, closable by its traffic lights.
    /// Off by default — click-through is what keeps a choreographed cursor from
    /// snagging on the scenery.
    var interactive: Bool? = nil
    /// Closing it doesn't get rid of it. The window comes back a beat later, which is
    /// only interesting on the ones that matter.
    var respawn: Bool? = nil
    /// Window level, same vocabulary as `glassTorus` and `photoWall`: "normal"
    /// (default), "floating", "front". The show's z-order is otherwise just the order
    /// things opened in — anything opened later lands on top — so this is how a layer
    /// that has to STAY on top says so, rather than being buried by the next event.
    var level: String? = nil
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
    /// Same vocabulary as `openWindow`: `"center"` reads `frame` as `[dx, dy, w, h]`
    /// about the screen's centre, so a dialog meant to sit in the middle is authored
    /// from the middle rather than from a top-left corner that moves with the display.
    var anchor: String? = nil
    /// Window level, same vocabulary as `openWindow`: `"floating"` keeps the dialog
    /// above everything opened after it, including the `screenFlash` overlays. Omit
    /// for `"normal"`, where it stacks in open order like every other window.
    var level: String? = nil
    /// How a FRESH id comes up: `"springIn"` (the default — scales in from 60%),
    /// `"fadeIn"`, or `"none"` — on its frame, the way a real alert lands. Re-opening
    /// an id that is already up swaps its content in place with no animation whatever
    /// this says.
    var animate: String? = nil

    /// Authored `icon` resolved to a known illustration; an unrecognised value falls
    /// back to the caution triangle rather than silently rendering nothing.
    var dialogIcon: DialogIcon { DialogIcon(rawValue: icon ?? "caution") ?? .caution }
}

struct CloseWindowParams: Decodable {
    let id: String
    /// Dissolve instead of cut: run the window's alpha down over this many seconds.
    /// Default (nil/0) is the hard cut every close did before this existed. A fade in
    /// flight is still swept instantly by stop, quit and panic — see `close(id:)`.
    var fadeSeconds: Double? = nil
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

/// A window that opens and writes itself out, in tempo. `charsPerBeat` sets the typing
/// rate (a rate, not a duration, so editing the copy doesn't retime the scene);
/// `durationBeats` is optional and only trims the scene short. The window stays up,
/// caret blinking, until `closeWindow` by `id`.
struct TypeTextParams: Decodable {
    let id: String
    var screen: Int? = nil
    let frame: [Double]           // [x, y, w, h], top-left origin
    let text: String
    var charsPerBeat: Double? = nil     // default 16
    /// Type whole LINES at this rate instead of characters, the way the end card's
    /// credits do — the caret then waits at the start of the next line, the way a
    /// prompt does after a command has printed. Set it and `charsPerBeat` is ignored.
    var linesPerBeat: Double? = nil
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var title: String? = nil            // window chrome title, e.g. "Untitled 2"
    var fontSize: Double? = nil         // default 13 ("mac"), 11 ("terminal")
    /// Which surface writes itself out: `"mac"` (default) is a white document in real
    /// macOS chrome; `"terminal"` is Terminal.app's own window — the same surface the
    /// credits type into, monospaced with a block cursor; `"bubble"` is Clippy's balloon,
    /// a pale yellow Office Assistant speech bubble with a spike pointing at whoever is
    /// talking. A bubble has no title bar, so `title` is ignored for it.
    var chrome: String? = nil
    /// `"bubble"` chrome only: which edge the spike comes off, and so where the speaker
    /// is. `"left"` (default) points at something to the balloon's left; `"bottom"` is
    /// the canonical Office Assistant arrangement, the balloon above the character.
    var tail: String? = nil
    /// The surface's colours, `"terminal"` chrome only: `hex` the ground, `fg` the type.
    /// Absent, it is Terminal's own Basic profile — black on white.
    var hex: String? = nil
    var fg: String? = nil
    /// Let the viewer pick the window up and move it around while it types.
    var interactive: Bool? = nil
    /// Window level, same vocabulary as `openWindow` and `fakeDialog`; omit for
    /// `"normal"`. Typed windows used to be left at the base window's screen-saver
    /// level, which put a terminal over every alert the timeline opened after it.
    var level: String? = nil
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
    /// An image the glass refracts INSTEAD of the viewer's own desktop picture.
    ///
    /// The plane behind the torus is the machine's wallpaper by default, which is right
    /// when the torus is a thing sitting on the viewer's desktop and wrong the moment the
    /// cue puts it somewhere else — cue 13 now opens a tunnel under it, and a torus
    /// refracting a stranger's Big Sur wallpaper inside a tunnel belongs to neither
    /// picture. Any path ImageIO can read; it is resolved like every other asset and
    /// falls back to the desktop picture if it cannot be read.
    var environment: String? = nil
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
    var mode: String? = nil          // "strobe" (default) | "solid" | "slides" | "glitch" | "recursive"
    var hex: String? = nil           // solid only: the colour (default the signature blue)
    var images: [String]? = nil      // slides only: paths, cycled one per tick at `hz`
    /// `slides` only: a schedule instead of a rate — seconds from the event's start at
    /// which each image lands, one per entry of `images`, ascending. With it the list is
    /// played ONCE, in time (the lyric on the desktop follows the sung words), the last
    /// image holds until the event ends, and `hz` is ignored.
    var at: [Double]? = nil
    var hz: Double? = nil            // applies per second (default 8)
    /// Which surface the desktop change is made on.
    ///
    /// `"layer"` (the default) draws into a window pinned at the desktop level — above
    /// the wallpaper picture, under the desktop icons. It looks the same, costs a layer
    /// assignment instead of a ~300 ms `setDesktopImageURL` round trip, and is reversible
    /// by construction: the window dies with the process, so nothing survives a crash or
    /// a `kill -9`. `hz` is honoured up to `WallpaperController.layerMaxHz`.
    ///
    /// `"wallpaper"` sets the machine's actual desktop picture. It is a real, persistent
    /// change to the viewer's Mac, so it is gated on `meta.allowWallpaper`, and it is
    /// capped at ~3 Hz by the window server no matter what `hz` asks for. Use it only
    /// when the point is that the wallpaper is *really* changed.
    var surface: String? = nil       // "layer" (default) | "wallpaper"
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
/// The geolocation section asks Location Services for a fix, so this event — and only
/// this event — triggers that prompt. Refused, those lines read `<unavailable>` and the
/// rest of the report is unaffected. (Nothing reads Contacts; the ex-`contacts` panel is
/// now a hardware readout.)
struct SystemProbeParams: Decodable {
    let id: String
    var linesPerBeat: Double? = nil   // reveal rate (default 24)
    var durationBeats: Double? = nil
    var durationSeconds: Double? = nil
    var screen: Int? = nil
    /// [x, y, w, h], top-left origin — the OUTER frame, title bar included. Defaults
    /// to 1060×800, centred.
    var frame: [Double]? = nil
    /// The title bar's text. The report wears real macOS chrome like the rest of the
    /// show's big windows, so it needs a name; it is the command that produced it.
    var title: String? = nil        // default "./scan_identity"
    /// The report's colours: `hex` the ground, `fg` the type. Absent, it prints the way
    /// Terminal ships — black on white. Every probe window in a show shares one look;
    /// see `Phosphor.use`.
    var hex: String? = nil
    var fg: String? = nil
    /// Fired at an id that is already on screen: the terminal is cleared and ONLY these
    /// sections are read out again, every line of them highlighted — the machine going
    /// back to the parts that matter. Names: `geolocation`, `network`, `identity`,
    /// `machine`, `hardware`. A new window with `focus` set reads out just those.
    var focus: [String]? = nil
}

/// A fake reboot: the screen goes black, the boot glyph comes up, and a progress bar
/// fills over the event's duration. Stays up until `closeWindow` by `id`, so the
/// generator decides when the desktop "comes back". Driven by the show clock — the
/// bar scrubs with the playhead like everything else.
struct RebootParams: Decodable {
    let id: String
    var screen: Int? = nil
    var durationBeats: Double? = nil    // how long the bar takes to fill (default 8 beats)
    var durationSeconds: Double? = nil
    var delayBeats: Double? = nil       // black + glyph before the bar starts (default 1)
    var glyph: String? = nil            // the boot logo; default "\u{F8FF}" (the  glyph in Apple fonts)
    var color: String? = nil            // glyph + bar colour (default white)
}

/// The magic torus: an alert that asks the viewer to type a question, and answers it
/// when they click OK — or on its own after `answerBeats`, so the show can't stall on
/// an audience that won't play. The one window in the show allowed to take keyboard
/// focus (the text field needs it); it gives focus back the moment it answers.
struct OracleParams: Decodable {
    let id: String
    var screen: Int? = nil
    var frame: [Double]? = nil          // [x, y, w, h]; default 460×200 centred below the torus
    var title: String? = nil            // default "hey, i'm the magic torus"
    var body: String? = nil             // default "ask me a question"
    var placeholder: String? = nil      // text-field ghost text
    var answers: [String]? = nil        // default: yes / no / maybe / don't count on it / …
    var answerBeats: Double? = nil      // auto-answer if nobody clicks (default 8)
    var answerSeconds: Double? = nil
    var icon: String? = nil             // as fakeDialog (default "app")
}

/// A Photo Booth: the viewer's own camera in a window, a 3·2·1 countdown in tempo, and
/// a photo taken on the last beat. The picture is kept in memory only — never written
/// to disk — and shown again by `credits`. Camera access is asked for at the intro
/// gate (`Permissions.preflight`); refused, the preview is black and no photo is taken.
struct PhotoBoothParams: Decodable {
    let id: String
    var screen: Int? = nil
    var frame: [Double]? = nil          // [x, y, w, h]; default 640×480 centred
    var title: String? = nil            // window title (default "Photo Booth")
    var durationBeats: Double? = nil    // open → shutter (default 16)
    var durationSeconds: Double? = nil
    var count: Int? = nil               // countdown length (default 3)
    var stepBeats: Double? = nil        // beats per countdown number (default 4)
    var mirror: Bool? = nil             // mirror the preview like Photo Booth does (default true)
    var flash: String? = nil            // shutter flash colour inside the window (default white)
    /// Keep the window (frozen on the photo) after the shutter until `closeWindow`.
    /// Default false: the window goes with the flash.
    var hold: Bool? = nil
}

/// The end card: the photo the computer took, in a frame; the machine's own vitals in
/// the probe's terminal style; an "i survived" alert; and the credits. The screen holds
/// there — past the end of the track — until the viewer dismisses it or hits panic, so
/// there is time to take a screenshot.
struct CreditsParams: Decodable {
    let id: String
    var screen: Int? = nil
    var lines: [String]? = nil          // credits copy, one entry per line
    var title: String? = nil            // credits dialog title (default "credits")
    var caption: String? = nil          // under the photo
    var showInfo: Bool? = nil           // the machine-info terminal (default true)
    var hold: Bool? = nil               // stay up past the end of the track (default true)
    var backdrop: String? = nil         // hex behind everything (default black)
    var filter: String? = nil           // "instant" (default) | "chrome" | "fade" | "none"
    var charsPerSecond: Double? = nil   // credits typing rate (default 7 — deliberately slow)
    var linesPerSecond: Double? = nil   // set: type whole LINES at this rate, the way the probe reveals
    var fontSize: Double? = nil         // credits type size in points (default 11, Terminal's own)
    var photoTilt: Double? = nil        // the photo card's tilt in degrees, +ve anticlockwise (default -4)
    var tile: String? = nil             // image tiled behind the card, drifting diagonally
    var tileDriftSeconds: Double? = nil // seconds to drift one tile (default 4)
    var tilePadding: Double? = nil      // gap around each tile, as a fraction of its size (default 1.0)
    var tileScale: Double? = nil        // tile artwork redrawn at this scale (default 0.05)
    var allowSave: Bool? = nil          // show the card's "save photo" button (default true)
    var outro: Bool? = nil              // run the force-quit → glitch → boot → quit ending (default true)
    var outroDelay: Double? = nil       // pause after the last character before it starts (default 2)
    var glitchSeconds: Double? = nil    // length of the fullscreen glitch (default 0.5)
    var bootSeconds: Double? = nil      // length of the closing boot bar (default 5)
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

/// `hideOtherApps`: hide every other running app so the desktop is in view. Undone on
/// stop/panic/seek, or by `closeWindow` with the same `id`.
struct HideOtherAppsParams: Decodable {
    /// Default `"otherApps"`.
    var id: String? = nil
    /// Bundle identifiers to leave alone (e.g. `"com.apple.finder"`).
    var except: [String]? = nil
}

enum EventAction {
    case openWindow(OpenWindowParams)
    case fakeDialog(FakeDialogParams)
    case closeWindow(CloseWindowParams)
    case moveWindow(MoveWindowParams)
    case screenFlash(ScreenFlashParams)
    case cursorPath(CursorPathParams)
    case rearrangeIcons(RearrangeIconsParams)
    case jiggle(JiggleParams)
    case wallpaper(WallpaperParams)
    case sprite(SpriteParams)
    case cursorTrail(CursorTrailParams)
    case typeText(TypeTextParams)
    case photoWall(PhotoWallParams)
    case glassTorus(GlassTorusParams)
    case deskWallpaper(DeskWallpaperParams)
    case systemProbe(SystemProbeParams)
    case fileSwarm(FileSwarmParams)
    case reboot(RebootParams)
    case oracle(OracleParams)
    case photoBooth(PhotoBoothParams)
    case credits(CreditsParams)
    case hideOtherApps(HideOtherAppsParams)
    case brickBreaker(BrickBreakerParams)
    case segSwarm(SegSwarmParams)
}

extension EventAction {
    /// The `"type"` string this case is authored as.
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
        case .reboot: return "reboot"
        case .oracle: return "oracle"
        case .photoBooth: return "photoBooth"
        case .credits: return "credits"
        case .hideOtherApps: return "hideOtherApps"
        case .brickBreaker: return "brickBreaker"
        case .segSwarm: return "segSwarm"
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

    /// `"type"` string → payload decoder. A table rather than a `switch` so a new event
    /// added to one place and not the other is caught by `catalogIsConsistent()`.
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
        "reboot": { .reboot(try $0.decode(RebootParams.self, forKey: .params)) },
        "oracle": { .oracle(try $0.decode(OracleParams.self, forKey: .params)) },
        "photoBooth": { .photoBooth(try $0.decode(PhotoBoothParams.self, forKey: .params)) },
        "credits": { .credits(try $0.decode(CreditsParams.self, forKey: .params)) },
        "hideOtherApps": { .hideOtherApps(try $0.decode(HideOtherAppsParams.self, forKey: .params)) },
        "brickBreaker": { .brickBreaker(try $0.decode(BrickBreakerParams.self, forKey: .params)) },
        "segSwarm": { .segSwarm(try $0.decode(SegSwarmParams.self, forKey: .params)) },
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
