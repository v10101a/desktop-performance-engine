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

Packaged `.app` — **double-click it and the piece runs**, no terminal. Also what
Phase 3's Finder Automation needs to prompt cleanly. It carries its own icon (a BSOD-blue
tile with a little window and a pink glitch bar through it; redraw with
`python3 tools/make_icon.py`) and embeds the backing track, so it runs from anywhere:

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

### Act 0 — the intro gate

Launching the app opens the piece on the **F.B.I. anti-piracy screen** every rental
tape started with — blue field, white box, giant condensed FBI, a seal, a justified
block of white legalese — rebuilt from shapes in `VHSWarningView`, carrying a parody
notice and the real photosensitivity warning. It then shrinks to a small **popup window**
on the desktop asking **DO YOU WANT THE MALWARE?** with two answers: **YES. INFECT ME.**
or **no thank you** (which quits).

Cards auto-advance after their `dwell` or step on click/space; **Esc** leaves from
anywhere; **Return** takes the default on the choice card. "Yes" starts the show through
the same path as the Play button, so the transport stays in sync.

Every word of it is a joke and the seal is drawn from scratch (rings, tick marks, a
shield) rather than reproduced. Title and body both **shrink to fit** their panel, so
rewriting the copy can't push text off the card.

```bash
swift run DesktopPerformanceEngine --no-gate                    # skip it (dev loop)
swift run DesktopPerformanceEngine --snapshot-gate=cards.png    # render the cards to a PNG montage
```

`--autoplay` skips the gate too, since it drives itself. Edit the copy in
`IntroGate.script` (`App/IntroGate.swift`) — one `IntroCard` per screen. `dwell: nil`
marks the card that waits for an answer; `style` picks `.vhs` (full screen), `.popup`
(small window, title and buttons only) or `.plain` (centered type on black); `glyph` is
the big word in the left column.

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

It also detects **kick onsets** (sub-bass transients, isolated from the bassline) and the
first downbeat. It writes `meta.markers` (`{t, bar, label, kind}`, absolute seconds) plus a
`kicks` list into the analysis JSON. The scrubber renders them as **color-coded ticks** (drop = red,
high-energy = teal, section = blue, break/start = gray) — **click a tick to jump there** —
and the readout shows the current section. Markers use absolute time, so they stay valid
regardless of `meta.bpm`.

The committed analysis lives at **`assets/track_analysis.json`**, and
`tools/generate_show.py` reads it — BPM, `beatOffset` (the first downbeat) and every kick
time come from the audio, so the generator owns the tempo map and nothing has to be
patched in afterwards.

⚠️ The **section detector is a hint, not gospel.** On this track it put the first chorus
at 35.87 s; a per-bar energy probe shows the sub-bass actually drops out at 26.54 s
(bar 15), returns at 28.41 s, and the real drop lands at **30.28 s** (bar 17). The show's
act boundaries are those verified bars, and the generator adds its own markers for them.

### Dev tools

```bash
swift run DesktopPerformanceEngine --autoplay          # play whole show, log per-event
                                                       # timing drift, then restore + quit
swift run DesktopPerformanceEngine --snapshot=out.png  # render the window content to a PNG
swift run DesktopPerformanceEngine --snapshot-scenes=out.png   # preview the livecode + typeText scenes
python3 tools/make_icon.py                             # redraw assets/AppIcon.icns
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
`screen` (index into `NSScreen.screens`, default 0). **Negative `x`/`y` anchor to the
far edge** (resolution-independent): `x < 0` measures from the right, `y < 0` from the
bottom — e.g. `[36, -36, 176, 64]` is the lower-left corner. Content kinds: `color` (`hex`),
`text` (big centered `text`), `code` (monospaced terminal block — also used for system-
stats readouts), `image` (`path` to any image; decoded off-thread + cached),
`livecode` (a running Strudel-style REPL — see below), `map` (a real Apple Maps
flythrough — see below).
Animations: `springIn`, `fadeIn`, `none`. Any content can add fake window `chrome`
(`"browser" | "terminal" | "mac" | "mixed"`, plus a `title` shown in the bar/URL pill) —
drawn by us at any size, deliberately stylized, never a pixel-accurate imitation of
real system UI.

Event types implemented: `openWindow`, `closeWindow`, `moveWindow`, `fakeDialog`,
`screenFlash`, `cursorPath`, `rearrangeIcons`, `jiggle`, `sprite`, `cursorTrail`,
`typeText`.
Present but disabled by default: `wallpaper`.

The bundled default demo (`Resources/timeline.json`) is **the show**
(`examples/timeline_show.json`, regenerate with `python3 tools/generate_show.py`),
scored bar by bar to the real track at 128.5 BPM:

| bars | act | |
|---|---|---|
| 1–4 | **HORSE** | the Muybridge window-zoetrope runs in, gallops in place ~2 s, runs out |
| 5–8 | **POINT** | the cursor draws one long arrow, stamped in little pages — unhurried, with the `>` head in a single stroke |
| 8–11 | **HYDRA** | somebody using a computer: the instant the pointer finishes, a little browser opens at **exactly the spot the arrow pointed at**; the cursor drags it up by the title bar, grabs the **lower-right corner** and pulls it bigger (top-left pinned, so the code never leaves its corner), then clicks run — and only *then* does the sketch start rendering |
| 12–15 | **MORE** | **four** more sketches, already running, with the gap closing (`SPREAD_GAPS`) |
| — | **RISER** | the run-up collapses into **one second**: four more, each faster than the last, the final one landing on the drop (`RISER_SECONDS` / `RISER_COUNT`) |
| 17 | **CHORUS** | the drop. Everything blows away, the background flashes on every detected **kick**, and the chaos erupts from the focal point |
| 24 | **STROBE** | the original strobe finale (`examples/timeline_strobe.json`), spliced in verbatim at 43.35 s |
| 33 | **LETTER** | a plain text editor opens and writes itself out in tempo (`assets/letter.txt`), short white pulses flashing behind it on every fourth kick, until it's flashed away at bar 76 |
| 56 | **FLYOVER** | the letter has finished writing, so it's flashed away and the screen opens onto real Apple Maps flights over Shanghai and New York — the two cities the letter is about — kicks flashing again, until the break at 161 s clears everything |

The drop fires **`CHORUS_LEAD` seconds ahead of the bass** (1.0 s by default). The
sub-bass really lands at 30.28 s, but cutting exactly on it reads as late — the eye
needs the change to have already started when the ear arrives.

Deliberately **simple before the chorus** — one element at a time, so the viewer can
catch on to what each one is — then all of it at once. The stretch between the strobe and the letter is **not scored yet**: a small `(kick)`
window blinks the beat in the lower-left as a placeholder.

The flyover uses the native `map` kind rather than a `web` Google Maps window on
purpose — google.com is blocked from mainland China, and the piece has to work where
it's being performed.

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

⚠️ **Photosensitivity:** it flashes rapidly. Measured on the current show: the chorus
kick-flash pass peaks at **3 Hz**, but the spliced strobe finale runs a median 6.7 Hz and
touches **20 Hz** at its fastest — inside the risk band. The intro gate warns the viewer
before anything plays; keep that card, and re-measure if you push the cadence faster.

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

The arrow is drawn as a shaft plus a `>` head in **one continuous stroke** (barb →
tip → barb, forced to `linear` so the spline doesn't round the tip off) — two separate
barb strokes read as two stray marks rather than a pointer. Stroke `speed` is px per
beat and is deliberately unhurried (200): a fast stroke can outrun the pump on a loaded
machine and drop most of its breadcrumb stamps, so the arrow arrives half-drawn.

The spelling scene — the cursor handwrites "look" huge in a single-stroke plotter
font, draws an actual arrow pointing down-right, then glides trail-off to the spot
the arrow points at (in the full show, that's where the chaos erupts):

```bash
python3 tools/spell_path.py          # → examples/timeline_look.json (standalone)
TEXT="oh no" python3 tools/spell_path.py    # any text the stroke font covers
swift run DesktopPerformanceEngine examples/timeline_look.json
```

### `livecode` — a very small hydra

A hydra sketch, **actually running**. `Effects/HydraView.swift` parses the chain and
**builds the layer stack the code describes**, so the visual in the window is what the
source printed over it says. The source sits on top in hydra's own style: no gutter, a
dark box behind each line, numbers in pink.

```jsonc
{ "kind": "livecode", "chrome": "browser", "title": "hydra.ojack.xyz", "hex": "#68BDF8",
  "running": false, "text": "osc(40, 0.1, 0.8)\n  .kaleid(5)\n  .rotate(0.2, 0.1)\n  .out()" }
```

Sources: `osc(freq, sync, offset)`, `noise(scale, speed)`, `voronoi(scale, speed)`,
`shape(sides, radius)`, `gradient(speed)`, `solid`. Ops: `kaleid(n)`, `rotate(a, speed)`,
`scale`, `repeat`/`repeatX`/`repeatY`, `pixelate`, `colorama`/`color`, `thresh`, `invert`,
`scrollX`/`scrollY`, and `blend`/`diff`/`mult`/`add` against a second source. `modulate*`
is approximated, not real feedback. Anything unrecognised is skipped, so a patch that uses
more of the language still renders the part we understand.

`kaleid` masks the source to one wedge before replicating it around the circle —
rotating an opaque full-bleed layer just hides every copy under the last one.

**`running: false`** draws the source over a dead black canvas: the state the page is in
before you hit run. Re-opening the same window `id` with `running: true` swaps in the live
version, which is how the show fakes someone clicking run.

A `moveWindow` resize doesn't rebuild a window's content, so the code label, prompt and
toolbar all carry autoresizing masks that pin them to their own corners, and the sketch
layer stretches with the window. Re-opening the same id at the final size rebuilds the
composition cleanly — which is what the show does once the corner-drag settles.

Every bit of the motion is **Core Animation and Core Image on the render server**, with
periods keyed to `dpeShowBPM` (published from `WindowManager.bpm`). Nothing runs on the
pump, so a stack of these keeps playing — in tempo — while the timeline is busy elsewhere.
Generated textures are cached, so repeats of a patch cost nothing.

### Grabbable windows

`openWindow` takes two flags that hand a window to the viewer:

```jsonc
{ "id": "hy0", "interactive": true, "respawn": true, "frame": [...], "content": {...} }
```

`interactive` makes it **draggable by its body** and **closable by its fake traffic
lights**. It still never becomes key, so grabbing one can't pull focus mid-show. Off by
default — click-through is what stops a choreographed cursor snagging on the scenery.

`respawn` means closing it doesn't get rid of it: the window is back 0.8 s later. Only
interesting on the ones that matter. `typeText` takes `interactive` too — the letter can
be shoved around while it writes itself, with no close zone armed so it can't be
dismissed by accident. A pending respawn is cancelled by `closeAll`
(panic/stop), so nothing can pop up on a restored desktop.

### `web`

Any page, in a `WKWebView`, inside one of our windows — including Google Maps.

```jsonc
{ "kind": "web", "chrome": "browser", "title": "google.com/maps",
  "url": "https://www.google.com/maps/@31.2304,121.4737,4000a,35y,60t/data=!3m1!1e3" }
```

Needs the network, and needs the host to actually be reachable — worth knowing that
google.com is blocked from mainland China, where Apple's `map` flyover still works.

### `typeText`

A text editor that opens and **writes itself out in tempo**. `charsPerBeat` (default 16)
sets the rate — a rate, not a duration, so rewriting the copy doesn't retime the scene.
The window stays up with its caret blinking at 2 Hz until `closeWindow` by `id`.

```jsonc
{ "beat": 128, "type": "typeText", "params": {
    "id": "letter", "frame": [300, 120, 840, 590], "text": "Dear …",
    "charsPerBeat": 16, "fontSize": 14, "title": "resignation.txt — Edited" } }
```

The text lives in a **CATextLayer**, not an NSTextField: the typewriter rewrites it ~30
times a second, and the layer lays out on the render server where a text field would
re-run cell layout on the main thread every keystroke. The visible count is cached, so a
tick that reveals no new character does no work at all.

### `map`

A real **MKMapView** flying its camera between two poses — Apple's own 3-D flyover tiles,
inside one of our windows. No API key needed on macOS; it **does** need a network
connection, and with no route to Apple's tile servers the window just sits there grey.

```jsonc
{ "kind": "map", "chrome": "browser", "title": "maps://shanghai",
  "map": { "lat": 31.2304, "lon": 121.4737, "altitude": 1400, "toAltitude": 500,
           "pitch": 70, "heading": 20, "toHeading": 200, "seconds": 16,
           "style": "flyover" } }
```

`style` is `flyover` (default) / `satellite` / `hybrid` / `standard`; anything omitted
from the `to*` pose holds. The camera is stepped by the view's own 30 Hz timer rather than
the show's pump — a map redraw waits on tiles and is far too unpredictable to let near the
beat. All interaction is disabled: it's a shot in a film, not a map the viewer drives.

```bash
swift run DesktopPerformanceEngine examples/timeline_map.json
swift run DesktopPerformanceEngine --test-map     # proves the camera actually moves
```

`--test-map` builds a real map window off-screen and samples its camera twice, so you
can tell a flight that isn't running from tiles that haven't loaded.

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
