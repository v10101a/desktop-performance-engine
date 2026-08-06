# Desktop Performance Engine

An experimental **music video that runs as software**. It plays a song and, in
precise sync with the song's playback position, fires a scripted timeline of
desktop "havoc" events — opening windows, popping absurd (obviously-fake) dialogs,
flashing the screen, and (in later phases) moving the cursor and rearranging desktop
icons. The running app *is* the piece; there's no video capture.

Everything is **fully reversible**: state is snapshotted on launch and restored on
quit or via a global **panic hotkey (⌃⌥⌘Esc)**. Real files are never touched.

## Build & run

Quick dev loop (SwiftPM executable):

```bash
swift build
swift run DesktopPerformanceEngine                 # uses the bundled sample timeline
swift run DesktopPerformanceEngine path/to/timeline.json
```

Packaged `.app` (needed for Phase 3's Finder Automation to prompt cleanly):

```bash
./bundle.sh                                         # → build/DesktopPerformanceEngine.app (ad-hoc signed)
open build/DesktopPerformanceEngine.app
open -a "$PWD/build/DesktopPerformanceEngine.app" --args examples/timeline_cursor.json
```

Ad-hoc signing works but macOS resets Accessibility/Automation grants on each
rebuild. For grants that persist, create a self-signed **Code Signing** certificate
once (Keychain Access ▸ Certificate Assistant) and run
`SIGN_IDENTITY="Your Cert Name" ./bundle.sh`.

Press **Play** to start; **PANIC / Stop** (or ⌃⌥⌘Esc anywhere) to stop and restore.
The control window has a **scrubbable timeline** with a live playhead and a position
readout (`time / total · beat · frame` at a nominal 30 fps). Drag the bar to seek:
while playing it jumps audio + visuals live; while stopped it sets where Play begins.
Stop leaves the playhead where it is, so Play resumes from there.

### Backing track

Set `meta.audioFile` in the timeline to your track — an absolute path, or a repo-
relative one like `assets/track.wav`. It's resolved against the timeline dir, the
working dir, and parents of the app/executable, so it works from both `swift run` and
the packaged `.app`. Formats: anything AVAudioFile reads (wav/aiff/caf/m4a/mp3).
Large/copyrighted audio is git-ignored (`assets/*.wav` etc.) — keep it local.

If no track is found, the engine synthesizes a **metronome click track** at the
timeline's BPM so the show still runs on a real, sample-accurate clock.

### Track analysis & markers

`tools/analyze_track.py` estimates the track's **BPM** (onset-flux autocorrelation with a
tempo prior that resolves ×2/×1.5 metrical errors) and finds **structural key points**
(section boundaries / drops / breaks from RMS-energy novelty, snapped to downbeats):

```bash
python3 -m venv .venv && .venv/bin/pip install -r tools/requirements-analysis.txt   # + ffmpeg
.venv/bin/python tools/analyze_track.py "assets/track.mp3" markers.json
```

It writes `meta.analyzedBpm` and a `meta.markers` array (`{t, bar, label, kind}`, absolute
seconds) into the timeline. The scrubber renders them as **color-coded ticks** (drop = red,
high-energy = teal, section = blue, break/start = gray) — **click a tick to jump there** —
and the readout shows the current section. Markers use absolute time, so they stay valid
regardless of `meta.bpm`; the detected tempo is stored as `analyzedBpm` and does **not**
re-time existing beat-based events (change `meta.bpm` yourself if you want that).

### Dev tools

```bash
swift run DesktopPerformanceEngine --autoplay          # play whole show, log per-event
                                                       # timing drift, then restore + quit
swift run DesktopPerformanceEngine --snapshot=out.png  # render the window content to a PNG
```

## Timeline format

JSON. `meta` sets the clock; each event fires at `beat` (converted via BPM + offset)
or an explicit `t` in seconds. Windows carry an `id` so later events can close them.

```jsonc
{
  "meta": { "audioFile": "song.wav", "bpm": 120, "beatOffset": 0.0, "timelineLatency": 0.0 },
  "events": [
    { "beat": 0, "type": "openWindow",  "params": { "id": "w1", "content": { "kind": "color", "hex": "#FF2D95" }, "frame": [120,120,360,260], "animate": { "kind": "springIn" } } },
    { "beat": 4, "type": "fakeDialog",  "params": { "id": "d1", "title": "CRITICAL VIBES", "body": "…", "buttons": ["MORE","EVEN MORE"] } },
    { "beat": 6, "type": "screenFlash", "params": { "color": "#FFFFFF", "durationBeats": 0.5 } },
    { "t": 12.0, "type": "closeWindow", "params": { "id": "w1" } }
  ]
}
```

`frame` is `[x, y, w, h]` in points, **top-left origin**, relative to the target
`screen` (index into `NSScreen.screens`, default 0). Content kinds: `color` (`hex`),
`text` (big centered `text`), `code` (monospaced terminal block — also used for system-
stats readouts), `image` (`path` to any image; decoded off-thread + cached).
Animations: `springIn`, `fadeIn`, `none`. Any content can add fake window `chrome`
(`"browser" | "terminal" | "mac" | "mixed"`, plus a `title` shown in the bar/URL pill) —
drawn by us at any size, deliberately stylized, never a pixel-accurate imitation of
real system UI.

Event types implemented: `openWindow`, `closeWindow`, `moveWindow`, `fakeDialog`,
`screenFlash`, `cursorPath`, `rearrangeIcons`, `jiggle`, `sprite`, `cursorTrail`.
Present but disabled by default: `wallpaper`.

The bundled default demo (`Resources/timeline.json`) is **the show**
(`examples/timeline_show.json`, ~35 s, regenerate with `python3 tools/generate_show.py`),
four acts on one clock: the Muybridge **window-horse** runs in, gallops in place
~2 s, runs out — as it leaves, the cursor glides over and **draws one long arrow**
pointing down-right, stamped in little pages — then, from exactly the spot the
arrow points at, the **chaos** builds elastically (small, slow, and close at
first; accelerating, swelling, and flinging wider on a curve) until it tips over
into the original full-speed **strobe** finale (`examples/timeline_strobe.json`,
spliced in verbatim). ~8 ms mean A/V drift across all 786 events.

The strobe also still runs standalone:

```bash
swift run DesktopPerformanceEngine examples/timeline_strobe.json
```

Regenerate / tune the strobe with its generator:

```bash
python3 tools/generate_strobe.py                 # sanitized (placeholder stats, no local images)
PERSONALIZE=1 python3 tools/generate_strobe.py   # bakes in YOUR real system stats + ~/Desktop images
P_COLOR=0.06 P_ALERT=0.2 python3 tools/generate_strobe.py   # per-lane pacing overrides
```

The committed timeline is the sanitized one. `PERSONALIZE=1` pulls your hostname, specs,
and desktop images into the show — great locally, but don't commit that output.

⚠️ **Photosensitivity:** it flashes rapidly — kept out of the worst 15–20 Hz seizure
band, but if you push the flash cadence faster in the JSON, be aware of the risk.

### Performance notes

Driving ~750 events with ~25 simultaneous windows at 150 BPM stays frame-accurate
because of a few deliberate choices: the display pump **coalesces** (never more than one
tick queued, so it can't build an unbounded backlog); flashes are one **persistent
fullscreen overlay toggled by GPU layer-opacity** (animating a fullscreen window's
alpha, or showing/hiding it per flash, was the single biggest source of stalls);
windows are **reused** on re-open rather than recreated; images decode as **downsampled
thumbnails off the main thread**; dialogs avoid `NSVisualEffectView`/autolayout.

### `cursorPath`

Choreographs the real system cursor. `points` are `[x, y]` global display points
(top-left origin). `path`: `"linear"` or `"catmullRom"` (smooth spline, needs ≥3
points). `easing`: `linear` / `easeIn` / `easeOut` / `easeInOut`. Duration via
`durationBeats` or `durationSeconds`. `mode`:

- `"warp"` (default) — `CGWarpMouseCursorPosition`, instant, **no permission needed**.
- `"post"` — synthetic HID `.mouseMoved` events (other apps see hover states), but
  requires **Accessibility** permission or it silently no-ops.

The cursor is snapshotted at play and warped home on stop/panic.

### `rearrangeIcons`

Rearranges Finder desktop icons (icon *coordinates* only — never files). `layout`:
`scatter` (seeded, repeatable), `circle`, `grid`, `pile`. `seed` makes scatter
deterministic. Needs **Automation → Finder** permission — run from the `.app` so the
consent prompt is attributed to a stable identity. Positions are read in bulk at play
(~1.5s) and every icon is restored to its exact original spot on stop/panic/quit.
Note: if the desktop uses "Keep arranged by" / Stacks, Finder overrides manual
positions — turn that off to see the effect.

### `moveWindow`

Flies a spawned window (`id`) to a new `frame` (`[x,y]` keeps size, or `[x,y,w,h]`),
pump-synced with `easing` over `durationBeats`/`durationSeconds`. Omit the duration for
an instant snap. Cheaper and smoother than recreating windows — the fast way to sling
things around. (Move and jiggle are mutually exclusive per window; starting one cancels
the other.)

### `jiggle`

Shakes a spawned window (`id`) with a decaying sinusoid, pump-synced so it's
take-repeatable. `amplitude` (px, default 14), `frequency` (Hz, default 10),
`durationBeats`/`durationSeconds`. The window settles exactly back to its origin.

### `sprite`

A **window zoetrope**: animation frames encoded as rows of characters (`"..XX.."` —
any non-`.`/space char is a lit cell), each lit cell rendered by one pooled
micro-window with fake chrome. Frames advance every `beatsPerFrame`; windows are
assigned to cells nearest-previous-position first so they glide between poses.
Motion: either constant `velocity` (`[vx, vy]` pt/s, gallop across), or the arrival
system — `origin` → `target` over `travelBeats` (`travelEasing`, default easeOut),
hold there galloping in place, then optionally `exit` over the final `exitBeats`
(`exitEasing`, default easeIn): run into frame, stay in frame, run out of frame.
`cell`/`cellAspect`/`gap` set cell geometry, `colors` cycles body colors,
`durationBeats`/`durationSeconds` ends it (or `closeWindow` by `id`).

Keep the max lit cells per frame around **~60 or under**: the pool moves every window
each frame. Pools are **prewarmed at load** (creating dozens of NSPanels mid-show
stalls the pump ~100 ms; see `WindowManager.prewarm`).

The bundled demo is Muybridge's 1878 *Horse in Motion* — the first motion picture,
replayed as browser windows:

```bash
python3 tools/generate_horse.py      # assets/muybridge_horse.gif → examples/timeline_horse.json
SPAN=0.88 HOLD=20 COLS=19 python3 tools/generate_horse.py   # size / hold / grid overrides
swift run DesktopPerformanceEngine examples/timeline_horse.json
```

### `cursorTrail`

Windows that trace the real cursor (reads position only — no permission needed;
works whether the cursor is choreographed or user-driven).

- `mode: "stamp"` (default) — drop a persistent breadcrumb window every `spacing` px
  of cursor travel. A jump > 4×spacing is treated as **pen-up** (no stamps across it),
  so a cursor warping between letter strokes leaves clean words. Stamps persist after
  the `durationBeats` sampling window until `closeWindow` by `id` (max `count`, default 160).
- `mode: "follow"` — a comet tail: `count` windows chase the cursor, each delayed
  `delay` s more than the last, fading down the tail.

The spelling scene — the cursor handwrites "look" huge in a single-stroke plotter
font, draws an actual arrow pointing down-right, then glides trail-off to the spot
the arrow points at (in the full show, that's where the chaos erupts):

```bash
python3 tools/spell_path.py          # → examples/timeline_look.json (standalone)
TEXT="oh no" python3 tools/spell_path.py    # any text the stroke font covers
swift run DesktopPerformanceEngine examples/timeline_look.json
```

### `wallpaper` (disabled by default)

Swaps the desktop wallpaper (`path` to an image, or a solid `color` hex; `screen` or
all). **Off unless `meta.allowWallpaper` is `true`**, because on modern macOS the
public API (`NSWorkspace.setDesktopImageURL`) can't restore Aerial/dynamic wallpapers
and applies unreliably without restarting the WallpaperAgent — so it can't meet the
reversibility guarantee. Enable only if you accept it may not fully restore the
original.

## Architecture

- **Clock/** — `AudioClock` (AVAudioEngine sample time, the spine) + `DisplayPump`
  (CVDisplayLink vsync tick).
- **Timeline/** — `TimelineModel` (Codable document), `TimelineLoader` (beat↔sec
  resolution), `Scheduler` (sorted advancing cursor).
- **Events/** — `EventContext` dispatches a resolved `EventAction` to an executor.
- **Effects/** — `WindowManager` + `EffectWindow`/`FakeDialogWindow`/`FlashWindow`.
- **State/** — `StateSnapshot` + `RestoreManager` (idempotent restore).
- **Panic/** — `PanicController` (Carbon global hotkey).

The JSON document model is deliberately clean so a Primative-style **visual editor**
can be layered on later against the same format.

## Status

- **Phase 1 (MVP) — done & verified.** Audio-clock scheduler (events fire within
  ~1–9 ms of their beat), windows + fake dialogs + screen flash, panic/restore.
- **Phase 2 — done & verified.** Real cursor choreography (`cursorPath`), Catmull-Rom
  + easing, warp/post modes, cursor snapshot/restore. Warp mode read back to within
  ~1 px of target. Packaged as a signed `.app` via `bundle.sh`.
- **Phase 3 — done & verified.** Desktop icon rearranging (`rearrangeIcons`) via
  Finder AppleScript (bulk snapshot ~1.4s, deterministic layouts, pixel-exact
  restore verified on a single-icon roundtrip). Needs **Automation → Finder** — run
  from the `.app` so consent is attributed correctly.
- **Phase 4 — done & verified.** Window `jiggle` (pump-synced decaying shake, settles
  exactly back — verified 20px peak, exact settle). `wallpaper` swap built but
  **disabled by default**: modern macOS can't reversibly restore Aerial/dynamic
  wallpapers via the public API, so it's opt-in (`meta.allowWallpaper`) to preserve the
  reversibility guarantee.
- **Phase 5 — done & verified.** Virus-homage sequences: `sprite` window-zoetrope
  (Muybridge horse: run in → hold center → run out; pools prewarmed at load,
  ~9 ms drift), `cursorTrail` stamp/follow modes with pen-up detection, fake
  window chrome (browser/terminal/mac) at any size, single-stroke cursor
  spelling generator. Self-tested via `--test-sprites`; sprite frames render
  offscreen via `--snapshot=out.png timeline.json`.
- **Phase 6** — visual timeline/node editor.

## License

MIT — see [LICENSE](LICENSE).
