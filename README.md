# Desktop Performance Engine

An experimental **music video that runs as software**. It plays a song and, in
precise sync with the song's playback position, fires a scripted timeline of
desktop "havoc" events — opening windows, popping absurd (obviously-fake) dialogs,
flashing the screen, and (in later phases) moving the cursor and rearranging desktop
icons. The running app *is* the piece; there's no video capture.

Everything is **fully reversible**: state is snapshotted on launch and restored on
quit or via a global **panic hotkey (⌃⌥⌘Esc)**. Your files are never touched.

One event is an exception worth stating plainly: `fileSwarm` draws patterns out of real
file icons, so it *creates and deletes its own* throwaway files in `~/Desktop` — marked
with an extended attribute, swept on stop/panic/quit, and never touching anything it
didn't make. It is gated behind `meta.allowDesktopFiles` and off by default, as is the
`deskWallpaper` swap behind `meta.allowWallpaper`.

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

The bundle is **self-contained** — it carries the show, the backing track and its icon,
so it runs from anywhere (Applications, a USB stick, another Mac). Verify a copy with:

```bash
/path/to/DesktopPerformanceEngine.app/Contents/MacOS/DesktopPerformanceEngine --check
```

⚠️ Don't reach for SwiftPM's `Bundle.module` to find bundled resources here. It searches
only the top level of the .app and an **absolute path into the build machine's `.build`
directory**, then calls `fatalError` — so an app that keeps its resources in the normal
`Contents/Resources` runs perfectly on the machine that built it and crashes on launch
everywhere else. `AppDelegate.bundledTimelineURL()` checks `Contents/Resources` first and
keeps `Bundle.module` as the last resort for `swift run`.

**After changing anything the show depends on, both steps are needed** — nothing rebuilds
the `.app` on its own:

```bash
python3 tools/generate_show.py && ./bundle.sh
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

### Pausing

**Pause** (button, or `P`) holds the show exactly where it is: the playhead stops, the
audio holds its sample, and every window the show has opened **stays on screen**. Resume picks up on the same sample, with no jump.

**Inspect** (checkbox) stamps every live window with its timeline id and the moment it
opened — `hy3 · 24.37s`. the badge is how you tell which window on screen is which entry in
`PATCHES`, so you can go edit the right one. It is an authoring overlay only: never part
of the piece, and gone the moment the show stops.

### Shipping it to someone else

`bundle.sh` is the dev loop; **`ship.sh`** is what you hand out. It builds both
architectures, lipos them into a universal binary (so it runs on Intel Macs too),
re-signs, and writes a `.dmg` and a `.zip` into `build/dist/`.

```bash
./ship.sh                                                    # universal, ad-hoc signed
SIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./ship.sh
SIGN_IDENTITY="Developer ID Application: You (TEAMID)" NOTARY_PROFILE=dpe ./ship.sh
```

**USB stick: works as-is.** Files copied from removable media are never given the
`com.apple.quarantine` attribute, so Gatekeeper lets an ad-hoc signed app run.

**A download does not.** Anything delivered by a browser, Mail or AirDrop is quarantined,
and an app without a Developer ID signature is refused — the recipient has to go to
System Settings ▸ Privacy & Security ▸ Open Anyway. For a link people can just click you
need the Apple Developer Program ($99/yr): a *Developer ID Application* certificate,
`notarytool` to notarize, and `stapler` to attach the ticket. Store the credentials once:

```bash
xcrun notarytool store-credentials dpe --apple-id you@example.com \
      --team-id TEAMID --password <app-specific-password>
```

Test a build the way a recipient gets it, by faking the quarantine flag:

```bash
xattr -w com.apple.quarantine '0081;0;Safari;' build/dist/DesktopPerformanceEngine.zip
```

The piece needs **no permission prompts** — the show uses `cursorPath` in `warp` mode
(no Accessibility) and no `rearrangeIcons` (no Automation). It does want the network,
for the Apple Maps flyover. Note also that `hdiutil` needs real disk-image privileges, so
`ship.sh` won't make a `.dmg` from inside a sandboxed shell.

Two things travel inside the bundle that are worth a thought before handing it out: the
**licensed backing track**, and `assets/letter.txt`, which is baked into the timeline and
names real people.

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

### Tests

```bash
swift run dpe-tests          # 109 checks; exits non-zero on failure
```

Covers the pacing accumulator, the timeline format and every event type's decode, the
photo-wall coverage/retirement invariants, all seven swarm patterns, the glitch engine,
screen geometry, the probe's section builders, and a real offscreen torus render.

**Why an executable and not `swift test`.** This project builds with the Command Line
Tools toolchain, which ships neither XCTest nor swift-testing, so a `.testTarget` cannot
compile — which is presumably why the app grew `--test-*` NSLog modes instead. Those
printed an expectation next to a result and left a human to compare them, so a
regression printed `3/6` beside `(expect 6/6)` and **still exited 0**. `dpe-tests` is a
plain executable with real assertions and a real exit code, so CI can gate on it.

The `--test-*` flags that remain on the app are the ones that genuinely need a running
NSApplication — Finder automation, MapKit, engine seek — not pure logic.

### Dev tools

```bash
swift run DesktopPerformanceEngine --autoplay          # play whole show, log per-event
                                                       # timing drift, then restore + quit
swift run DesktopPerformanceEngine --snapshot=out.png  # render the window content to a PNG
swift run DesktopPerformanceEngine --snapshot-scenes=out.png   # preview the livecode + typeText scenes
swift run DesktopPerformanceEngine --snapshot-torus=t.png --torus-material=chrome  # torus frame, alpha intact
swift run DesktopPerformanceEngine --snapshot-chrome=c.png     # real window chrome + alerts, alpha intact
swift run DesktopPerformanceEngine --validate=examples/timeline_show.json   # load + count a timeline
swift run DesktopPerformanceEngine --test-hydra=out.png        # nine live hydra sketches at once:
                                                       # proves they render, prints processes/MB/CPU
swift run DesktopPerformanceEngine --parse-hydra patch.txt     # what the impression reads out of a patch
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
`ascii` (see below), `livecode` (a running Strudel-style REPL — see below), `map`
(a real Apple Maps flythrough — see below).
Animations: `springIn`, `fadeIn`, `none`. Any content can add fake window `chrome`
(`"browser" | "terminal" | "mac" | "mixed"`, plus a `title` shown in the bar/URL pill) —
drawn by us at any size, deliberately stylized, never a pixel-accurate imitation of
real system UI.

### `ascii` content

Renders monospaced ASCII art, auto-fit to the window. Either literal art via `text`
(newlines with `\n`), or an image via `path` converted to ASCII: `cols` sets the grid
width (default 80), `invert` flips the light/dark ramp, `ramp` overrides the character
ramp (dark→light, default `" .:-=+*#%@"`), and `colorized: true` tints each glyph with
its source pixel color. `hex` is the text color (default matrix-green `#8CF2A6`). Image
conversion runs off the main thread and is cached, like the `image` kind. Works with
`chrome`/`title` too. See `examples/timeline_ascii.json`; preview with
`DPE_ASCII_DEMO=1 swift run DesktopPerformanceEngine --snapshot=ascii.png`.

Event types implemented: `openWindow`, `closeWindow`, `moveWindow`, `fakeDialog`,
`screenFlash`, `cursorPath`, `rearrangeIcons`, `jiggle`, `sprite`, `cursorTrail`,
`typeText`, `photoWall`, `glassTorus`, `systemProbe`.
Gated off by default: `wallpaper`, `deskWallpaper` (`meta.allowWallpaper`), `fileSwarm`
(`meta.allowDesktopFiles`).


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
| 56 | **FLYOVER** | three Apple Maps flights, the kicks lighting the room back up between them |
| 57 | **PROBE** | `system_probe` opens lower-right and types out its disclosure report — the machine reading you back to yourself — while the maps fly |
| 68 | **SWARM** | the desktop icons themselves start drawing: `rain`, then Conway's `life` running out the track. *Gated: `ALLOW_DESKTOP_FILES=1`* |
| 82 | **WALLPAPER** | the last act. The desktop shows a screenshot of itself, so the probe and the swarm recurse into the background; then it glitches, then strobes to the end. *Gated: `ALLOW_WALLPAPER=1`* |
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

### `livecode` — hydra, for real

A hydra sketch, **actually running** — and since the piece ships hydra itself, "actually"
now means actually. There are two engines behind this window kind:

**Real hydra** (`Effects/HydraWebView.swift`) runs ojack's hydra-synth 1.3.29 on a WebGL
canvas in a `WKWebView`. The patch is evaluated by hydra, so everything in the language
works: UV modulation, `o0` feedback, arrow functions, anything you can type into
hydra.ojack.xyz. This is the default whenever the library is in the bundle.

**The impression** (`Effects/HydraView.swift`) is the fallback: it reads the chain and
rebuilds it out of CALayers and Core Image filters. It is a good impression and it costs
almost nothing, but it cannot warp UVs, feed a frame back into itself, or run an
expression. It is used when the library is missing, when `DPE_HYDRA=fake` is set, and by
the still renderer — an off-screen `cacheDisplay` draws layers and skips web views, so a
snapshot of a real canvas would come out empty.

Either way the source sits on top in hydra's own style: no gutter, a dark box behind each
line, numbers in pink.

| | real hydra | the impression |
|---|---|---|
| fidelity | the language, entire | the chain, approximated |
| 9 sketches at once | 9 processes, ~410MB, ~15% CPU | one layer tree, negligible |
| renders in `--snapshot` | no | yes |

```bash
DPE_HYDRA=fake      ./build/DesktopPerformanceEngine.app/Contents/MacOS/DesktopPerformanceEngine
DPE_HYDRA_MAX=3     # cap live canvases; sketches past the cap fall back to the impression
```

The canvases are pooled and built during `prewarm`, before the clock starts — a
`WKWebView` plus a 205KB library is nowhere near cheap enough to build inside a pump
tick — and handed back when their window lets go of them. They drive their own render
loop (see `Resources/hydra.html`) so a canvas standing by costs a GL context and nothing
else; hydra's own loop cannot be stopped once started. `--test-hydra` stands up the
show's nine-sketch peak and prints the bill on your machine.

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

In the impression, every bit of the motion is **Core Animation and Core Image on the
render server**, with periods keyed to `dpeShowBPM` (published from `WindowManager.bpm`).
Nothing runs on the pump, so a stack of these keeps playing — in tempo — while the
timeline is busy elsewhere. Generated textures are cached, so repeats of a patch cost
nothing.

That tempo-keying is also the impression's one deliberate infidelity: hydra reads a bare
number in a speed slot as a static offset, and a sketch that never moves is not what this
act is for, so a constant animates on the beat grid instead. An explicit `()=>time*k` is
taken literally — 0.4 radians a second really is 0.4 radians a second.

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

This **is** Apple Maps — `MKMapView` is MapKit, the same framework and the same Apple
tile servers Maps.app uses. `style` picks how it renders:

| style | |
|---|---|
| `flyover` (default) | Apple's 3-D flyover imagery, **no labels, no roads** |
| `hybrid` | the same imagery **with** roads and place names — closest to Maps' own 3-D satellite view |
| `satellite` | flat satellite, no labels |
| `standard` | the plain vector map with streets and names |

Regenerate the show's flights with `MAP_STYLE=hybrid python3 tools/generate_show.py` to
compare. Anything omitted from the `to*` pose holds.

Three things worth knowing before performing with it:

- **It needs the network.** Tiles stream from Apple; flyover's 3-D meshes are heavier
  than flat imagery, so on a cold cache the first seconds can arrive blurry and sharpen.
  Playing the show once on the venue's network beforehand warms the cache.
- **Flyover coverage is per-city.** Where Apple hasn't modeled 3-D geometry, `flyover`
  falls back to draped imagery and looks flat. Check each location by eye.
- **In mainland China** Apple Maps renders on GCJ-02, so a WGS-84 coordinate can land
  a few hundred metres off. Nudge the lat/lon until the camera is over what you want.

If you'd rather have the *real Maps.app window* on screen instead of a map inside one of
ours, that's a different thing: we can launch it with a `maps://` URL, but its camera
can't be animated and closing it again is messy — it would break the reversibility
guarantee the rest of the piece keeps. The camera is stepped by the view's own 30 Hz timer rather than
the show's pump — a map redraw waits on tiles and is far too unpredictable to let near the
beat. All interaction is disabled: it's a shot in a film, not a map the viewer drives.

```bash
swift run DesktopPerformanceEngine examples/timeline_map.json
swift run DesktopPerformanceEngine --test-map     # proves the camera actually moves
```

`--test-map` builds a real map window off-screen and samples its camera twice, so you
can tell a flight that isn't running from tiles that haven't loaded.

### `glassTorus`

A tumbling glass (or mirror-metal) torus in a borderless, fully transparent window,
refracting a live capture of the screen behind it. Ported from the standalone
`GlassTorus` app; `TorusScene` (pipeline + Metal shader source), `TorusMesh`, `Math`
and `Snapshot` are that app's code unchanged, under `Effects/GlassTorus/`.

```jsonc
{ "beat": 4,  "type": "glassTorus", "params": { "id": "torus", "material": "glass" } }
{ "beat": 16, "type": "glassTorus", "params": {
    "id": "torus", "material": "chrome", "roughness": 0.02, "speed": 1.6 } }
{ "beat": 32, "type": "closeWindow", "params": { "id": "torus" } }
```

Materials: `glass` (default), `crystal`, `chrome`, `gold`, `copper`, `titanium`. The two
dielectrics refract the capture per channel at slightly different indices, which is
where the coloured fringing comes from; the conductors weight an environment reflection
by Schlick-Fresnel, with `roughness` (0 = mirror, 1 = brushed) driving the mip LOD.
`planeDistance` (default 2.0) sets how far behind the torus the desktop plane sits —
nearer gives a tight, strongly curved reflection. Firing a second `glassTorus` with the
same `id` swaps the material live, as in the example above.

`speed` (default 1) multiplies the tumble rate. `durationBeats`/`durationSeconds` close
the window; omit both and it stays until `closeWindow` by `id`. Geometry is `frame`
(`[x, y, w, h]`, top-left origin) or `size`, defaulting to the standalone app's sizing —
72% of the screen's shorter side, clamped to 560…1100, centred. `level` is
`"screenSaver"` by default (above the menu bar, as the standalone app ran), or
`"floating"` / `"normal"` to sit inside the show's window stack.

Three things the port had to change:

- **The show clock drives the frame.** MTKView is put in `isPaused` mode and drawn from
  the pump with `elapsed` written from the timeline position, so the tumble scrubs with
  the playhead, freezes when the transport stops, and is identical take to take. The
  standalone renderer accumulated wall-clock deltas.
- **The glass reflects the show.** The standalone app excluded its whole *application*
  from the capture to stop the reflection recursing into itself. Inside the show that
  would exclude the show — the photo wall, every effect window — leaving only the bare
  desktop to refract. Only the torus's own window is excluded now, which is the minimum
  that breaks the feedback loop. Set `reflectShow: false` for the old behaviour.
- **The window never takes focus and has no keys.** The standalone app's shortcuts
  (material, roughness, plane, pause, quit) are authored per event instead, and `Esc`
  belongs to the panic hotkey.

Metal is built lazily, on the first `glassTorus` event: a show that never uses one
neither compiles the pipeline nor triggers the **Screen Recording** prompt. That
permission is optional — refused, the torus falls back to the procedural studio
environment and still runs, it just reflects a studio instead of your desktop.

Verify headlessly with `--test-glasstorus`: it compiles the pipeline on the real GPU
(the shaders are built from source at runtime, so a clean build proves nothing about
them) and renders a frame offscreen, asserting both that the torus is drawn and that
the background stays transparent — a fully opaque frame would mean a black box over the
show. `--snapshot-torus=out.png` writes one to look at.

`examples/timeline_glasstorus.json` runs the torus over the photo wall, which is the
combination the two ports are for.

### `systemProbe`

The `system_probe` disclosure report typing itself out in a window: a terminal reading
back everything this machine knows about whoever is sitting at it — hardware, storage,
displays, network, battery, the Contacts "me" card, a location fix. Ported from the
standalone systemprobe app.

```jsonc
{ "beat": 224, "type": "systemProbe", "params": {
    "id": "probe", "linesPerBeat": 24, "frame": [576, 144, 806, 630] } }
{ "beat": 360, "type": "closeWindow", "params": { "id": "probe" } }
```

`linesPerBeat` (default 24) is a rate, not a duration — as with `typeText.charsPerBeat`,
editing the report doesn't retime the scene. The standalone app ran the reveal on a
0.012 s `Timer`; here it is driven from the pump, so the report types in tempo, freezes
when the transport stops, and lands the same line on the same beat every take. Section
gathering still happens off the main thread and splices in as it lands.

**This event triggers two TCC prompts the rest of the show doesn't**: Contacts and
Location Services, for the identity section. That is the point of the piece, but it is
worth knowing before you run it in front of people. Refused, those lines read
`<unavailable>` and the report continues. A show with no `systemProbe` event never
constructs a `Probe`, so nothing is asked for.

`--test-systemprobe` covers the section builders, the formatting helpers and the reveal
pacing. It deliberately does *not* call `Probe.start()`, because a test that fired two
permission prompts would be a bad citizen.

### `fileSwarm`

Patterns drawn on the desktop out of **real file icons** — a spiral, rain, Conway's
life, scrolling text — one throwaway file per lit cell, placed on a grid by Finder.
Ported from the standalone FileSwarm app.

```jsonc
{ "beat": 268, "type": "fileSwarm", "params": {
    "id": "swarm", "pattern": "rain", "ticksPerBeat": 2, "maxLive": 70, "seed": 3 } }
```

Patterns: `spiral`, `wave`, `rain`, `ripple`, `life`, `marquee` (set `text`),
`constellation`.

**Gated behind `meta.allowDesktopFiles`, off by default.** This is the only event in the
show that writes to disk. Files are tiny, prefixed `swarm-`, carry an extended-attribute
marker, and are removed by the pattern, by `closeWindow`, by panic, by seek and on quit;
`SwarmFileStore.sweep()` also catches orphans from a run that was killed. Only files
carrying its own marker are ever deleted, so nothing of yours can be touched.

**Do not author this to land on a beat.** The standalone app measured Finder's desktop
view: a *deletion* shows in ~85 ms reliably, a *creation* takes 0.7–3 s and erratically
doesn't show at all before it's deleted again. Touching the folder, `update desktop`,
hidden flags, renames and activating Finder were all tried and none of them help — it is
the window server's limit. Treat it as a texture running under a section. The `erase`
option inverts the trade: fill the grid and cut the pattern *out* of it, so the moving
edge is the crisp 85 ms deletion and the lag is in the healing behind.

It also needs **Automation ▸ Finder** to place icons on the grid. Refused, the pattern
still runs — Finder just puts each icon where it likes, so it reads in time but not in
space.

`--test-fileswarm` runs all seven patterns against a synthetic grid, asserting in-bounds
cells and that a seeded pattern replays identically. It touches no files.

### `deskWallpaper`

The desktop wallpaper itself as a surface. The three standalone wallpaper tools folded
into one event:

```jsonc
{ "beat": 324, "type": "deskWallpaper", "params": { "id": "wall", "mode": "recursive", "hz": 0.7 } }
{ "beat": 348, "type": "deskWallpaper", "params": { "id": "wall", "mode": "glitch", "hz": 6, "intensity": 0.75 } }
{ "beat": 364, "type": "deskWallpaper", "params": { "id": "wall", "mode": "strobe", "hz": 10 } }
```

- **`strobe`** — solid black ↔ solid white on every screen.
- **`glitch`** — horizontal displacement, per-channel chroma split, scanlines and block
  corruption, applied to the wallpaper *the show started with* (read from the snapshot,
  not from the current wallpaper — compounding each pass would dissolve to noise in a
  second). `intensity` 0…1, `seed` for a reproducible tear.
- **`recursive`** — the desktop set to a screenshot of the desktop, deepening each pass.
  Needs Screen Recording.

**Gated behind `meta.allowWallpaper`**, same as the `wallpaper` event and for the same
reason: macOS cannot reliably restore Aerial/dynamic wallpapers through the public API.

`hz` is an apply rate, not a beat division, and it has a hard ceiling that isn't ours:
`setDesktopImageURL` blocks roughly 58 ms per screen, which the standalone app measured
as a ~17 Hz wall, and the compositor may still drop frames. Asking for more gets you the
ceiling. Because of that cost the applies are rate-limited off the pump rather than run
every frame, and `recursive` never has more than one capture in flight.

> **Flashing imagery can trigger seizures in photosensitive epilepsy.** `screenFlash` is
> the beat-accurate, instantly reversible way to flash the screen; `strobe` differs only
> in living *behind* every window. Prefer `screenFlash` unless you specifically need the
> wallpaper.

Frames are written under `~/Library/Application Support/DPE/wallpaper` (macOS stores the
path, not a copy, so they have to stay on disk while displayed) and swept on restore.

`--test-wallpaper` checks the gate, the glitch engine's determinism, and that frames are
written and swept. It never calls `setDesktopImageURL` — a test that changed your actual
wallpaper would be a bad citizen.

### `photoWall`

Fills every screen with randomly sized, randomly placed photo windows pulled from the
viewer's **own** folders, then keeps laying new photos over the wall. Ported from the
standalone `photowall` app; `Planner`, `ScreenCoverage` and `PhotoIndex` are that app's
code unchanged, under `Effects/PhotoWall/`.

```jsonc
{ "beat": 68, "type": "photoWall", "params": {
    "id": "wall", "fillPerBeat": 20, "churnPerBeat": 2.7, "windows": 45 } }
{ "beat": 100, "type": "closeWindow", "params": { "id": "wall" } }
```

Rates are **per beat**, not per second — that is the one substantive change from the
standalone app, which ran two `NSTimer`s (a fast fill, then a slower churn). Here
placement is paced by a beat-credit accumulator on the display pump, so the wall fills
in tempo. The standalone defaults (`--speed 2`) land at roughly `fillPerBeat: 20` /
`churnPerBeat: 2.7` at 128.5 BPM.

`durationBeats`/`durationSeconds` bound how long the wall keeps *placing*; the windows
stay up until `closeWindow` by `id`, so the screen never flashes bare mid-show. Other
params: `dirs` (default `~/Desktop ~/Downloads ~/Documents ~/Pictures`), `windows`
(live population, default 45), `minFrac`/`maxFrac` (window edge as a fraction of the
screen, 0.13/0.52), `cell` (placement lattice, 12), `fade` (seconds, 0.065),
`minPixels` (640), `imageCap` (1200), `includeCloud`, `keepFilling`, `shadows`, and
`level` (`"normal"` default — the wall interleaves with the show's other windows;
`"front"` is the standalone app's level, above the menu bar and Dock).

Three things the port had to change, all of which would otherwise break the show:

- **The windows never take focus and ignore the mouse.** The standalone app made its
  first window key and closed a photo on click; here that would pull focus off the
  control window and let a stray click dismantle the wall mid-performance.
- **The disk walk is prewarmed at load**, alongside the sprite/trail pools. A cold scan
  of four home folders takes seconds and a `photoWall` fires on a beat, so an unwarmed
  index would come up empty and fill in late, off the music.
- **`closeAll()` is wired into panic and restore.** The wall is only ever windows the
  app opened — no cursor warp, no icon moves — so tearing them down restores the desktop
  exactly, and ⌃⌥⌘Esc works regardless of what is covering the screen.

Photo selection is the standalone app's, unchanged: app caches and generated images are
skipped by directory name and size, and iCloud-evicted files are skipped because reading
one blocks while macOS downloads it (measured at 21 seconds for a 3.5 KB file). Pass
`includeCloud: true` to use them anyway. Nothing is copied, moved or modified — the
scan is read-only, and the `.app` declares the Desktop/Documents/Downloads usage strings
macOS prompts with.

Verify the ported math headlessly with `--test-photowall`: it asserts the fill
terminates with exact coverage, that 2,000 churn placements retire ~1,980 windows
without ever exposing a bare cell, and that the beat pacing yields the expected rate.

### `wallpaper` (disabled by default)

Swaps the desktop wallpaper (`path` to an image, or a solid `color` hex; `screen` or
all). **Off unless `meta.allowWallpaper` is `true`**, because on modern macOS the
public API (`NSWorkspace.setDesktopImageURL`) can't restore Aerial/dynamic wallpapers
and applies unreliably without restarting the WallpaperAgent — so it can't meet the
reversibility guarantee. Enable only if you accept it may not fully restore the
original.

## Targets

| Target | What |
| --- | --- |
| `DPECore` | everything: clock, scheduler, executors, timeline |
| `DesktopPerformanceEngine` | the executable; `main.swift` and nothing else |
| `dpe-tests` | the test runner (`swift run dpe-tests`) |

The library was split out of the executable so the tests could reach it — an executable
target with top-level code in `main.swift` cannot be imported. If you add resources,
note that SwiftPM names the resource bundle after the *target* that declares them;
`bundle.sh` copies whatever bundles exist rather than a hardcoded name, because a
hardcoded one silently shipped an `.app` with no `timeline.json`.

Two directories are worth knowing about:

- **`Support/`** — the pieces every executor shares. `Cadence` (fractional per-beat
  pacing, burst caps, seek handling), `Beats` (duration resolution), `ScreenGeometry`
  (the top-left-origin frame convention), and the `Executor` protocol.
- **`Diagnostics/`** — the test suites, in the library so they can see internal types
  without a test target's `@testable import`.

`Effects/VENDORING.md` documents which ported files may be refactored and which must
stay byte-identical to their upstream app.

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

MIT — see [LICENSE](LICENSE) — **except** that the app now bundles
[hydra-synth](https://github.com/ojack/hydra-synth) 1.3.29, which is **AGPL-3.0**.

That is a decision about distribution, not about running the piece. Building and
performing it on your own machine raises nothing. Handing out the `.app` — the `.dmg` and
`.zip` that `ship.sh` produces — distributes hydra-synth with it, and AGPL is copyleft:
the combined work goes out under AGPL terms, with source offered to whoever receives it.

Three ways through, pick deliberately:

1. **Ship it AGPL.** Relicense the distributed work, keep the source public. Simplest if
   the repo is public anyway — but it is not only a relicence. The vendored bundle is a
   browserify build that carries **no licence notice of its own**: grep it for `AGPL`,
   `Affero`, `GNU` or `ojack` and you get nothing, and the only copyright strings in it
   belong to bundled MIT dependencies. AGPL-3.0 §4–5 require the licence and copyright
   notices to travel with the work, so this option means *adding* what the artefact is
   missing: the full AGPL-3.0 text and an ojack/hydra-synth attribution alongside it.
2. **Ship without it.** Delete `Sources/DesktopPerformanceEngine/Resources/hydra-synth.js`
   and `hydra.html` from the bundle; every sketch falls back to the MIT-licensed
   impression and the show still runs. This is the only path that keeps the shipped work
   MIT.
3. **Don't distribute.** Perform from your own build.
