# The cue list

The show, as authored — one row per cue, in the order the viewer meets them.

This is the **source document**. `tools/generate_show.py` mirrors it as the `CUES` table
at the top of the file and builds `Sources/DPECore/Resources/timeline.json` from it; the
two must be edited together. Nothing else in the app hard-codes a time.

**Positions are frames at 30 fps, on the show clock** — the clock that starts when the
intro gate is answered, not wall-clock from launch. 30 fps because that is what the app's
own transport counts in: `MainWindowController` carries `fps = 30` and displays
`floor(t × 30)` next to the beat, so a number in this sheet is the number on the scrubber.
Nothing in the engine is frame-quantised — it runs off the audio clock in seconds — so a
frame here is a reading, not a grid the show snaps to.

    frame = floor(seconds × 30)        seconds = OFFSET + beat × 60 / BPM

**authored** is the cue as written, converted. **fires on** is where it actually lands:
the cues were authored by ear against the recording, so they do not sit on bar lines, and
the generator puts each on the **nearest beat**. That moves a cue by at most **7 frames**
and keeps every cut tight to the music — authoring each at its literal position instead
would drift them against the grid by a different amount, which is audible on hard cuts.

Track: `assets/03 - Give it 2 me.mp3` — 128.5 BPM, first downbeat frame 11, **5095 frames
long (2:49.85)**. One beat is 14.0 frames, one bar 56.0.

## The list

| # | authored | fires on | what happens | how |
|---|---|---|---|---|
| 1 | f 0 → ~f 300 | f 11 · beat 0 | The intro sequence **as it is** — the stalled restart card, the face, the photosensitivity alert, DO YOU WANT THE MALWARE?. Every permission the show needs is raised here. The desktop is already DJ blue. | `IntroGate` (untouched) + `deskWallpaper` solid `#020AF5` |
| 2 | f 480 | f 474 · beat 33 | The blue desktop goes and the viewer's **own** wallpaper is back. | the Act-1 `deskWallpaper` expires; `WallpaperController` restores the snapshot |
| 3 | f 540 | f 544 · beat 38 | A centred window: *"welcome to the DJ Dave malware…"* — **placeholder** for the glitchy ASCII piece. | `openWindow` · `ascii` |
| 4 | f 750 | f 754 · beat 53 | The welcome window closes; the **system probe** opens and starts typing. | `closeWindow` + `systemProbe` |
| 5 | f 900 | f 894 · beat 63 | Hydra sketches **dragged onto the screen** — one full open→drag→resize→run, then two more. | `openWindow` · `livecode` + `cursorPath` + `moveWindow` |
| 6 | f 1140 | f 1146 · beat 81 | The desktop goes **blue** again. | `deskWallpaper` solid |
| 7 | f 1170 | f 1174 · beat 83 | The desktop becomes **pixelface.jpg**. | `deskWallpaper` slides, one image |
| 8 | f 1185 | f 1188 · beat 84 | One main window travels **up and down** the screen, leaving a **trail of windows** behind it. | `openWindow` + `moveWindow` + trail `openWindow`s |
| 9 | f 1290 | f 1286 · beat 91 | The **spiral of lyrics** — one card per cue, winding out from the centre. | `openWindow` · `lyric`, `anchor: center` |
| 10 | f 1410 | f 1412 · beat 100 | A **placeholder** centre window, to hold a single video later. | `openWindow` · `color` |
| 11 | f 1440 | — | **TBD — deliberately empty.** | — |
| 12 | f 1620 | f 1622 · beat 115 | The desktop becomes the **lyrics**, word by word; a **trail of windows dragged by the mouse**. | `deskWallpaper` slides + `cursorPath` + `cursorTrail` stamp |
| 13 | f 2070 | f 2070 · beat 147 | The **magic torus**, and a window typing itself out: *"Greetings, I am the magic torus…"* | `glassTorus` + `typeText` |
| 14 | f 2520 | f 2519 · beat 179 | **Apple Maps**, falling out of orbit onto the viewer's own location. | `openWindow` · `map`, `here: true` |
| 15 | f 2610 | f 2603 · beat 185 | Windows start opening, **slowly filling the screen**. | ramped `openWindow` |
| 16 | f 2910 | f 2911 · beat 207 | The desktop **fades to black**; the windows close **one by one**. | `deskWallpaper` solid `#000000` + staggered `closeWindow` |
| 17 | f 2970 | f 2967 · beat 211 | **TBD — cool graphic.** A labelled placeholder holds the slot. | `openWindow` · `color` |
| 18 | f 3210 | f 3205 · beat 228 | **Photo Booth** opens on the viewer; 3 · 2 · 1; the shutter. | `photoBooth` |
| 19 | f 3420 | f 3415 · beat 243 | The viewer's **own photos** spam and fill the screen. | `photoWall` |
| 20 | f 3540 | f 3541 · beat 252 | The spam continues; **pixelface.jpg strobes** over it. | `openWindow` · `image`, toggled |
| 21 | f 3600 | f 3597 · beat 256 | Everything cuts to the bare desktop; the **horse** gallops across. | `closeWindow` × n + `sprite` |
| 22 | f 3750 | f 3751 · beat 267 | The horse goes; the **glass torus** and a **circle of lyric windows**. | `glassTorus` + `openWindow` · `lyric` |
| 23 | f 3840 | f 3835 · beat 273 | All of it stays; the **placeholder video window** comes in on top. | `openWindow` · `color` |
| 24 | f 3870 | f 3863 · beat 275 | Torus and lyric windows cut; a **full black window** with the video placeholder on top. | `closeWindow` × n + `openWindow` · `color` |
| 25 | f 4080 | f 4074 · beat 290 | Everything cuts. **TBD content.** | placeholder |
| 26 | f 4140 | f 4144 · beat 295 | More **TBD** content, and the **mouse spinner**. | placeholder + `spinner` *(new event — see Gaps)* |
| 27 | f 4290 | f 4284 · beat 305 | A **ton of crazy UI windows**, spammed. | the eruption: `openWindow`/`fakeDialog`/`jiggle` |
| 28 | f 4740 | f 4746 · beat 338 | The **wallpaper glitches** repeatedly, and the lyrics desktop glitches with it. | `deskWallpaper` glitch ⇄ slides |
| 29 | f 5010 | f 5012 · beat 357 | A **ton of windows**, and the **whole screen** glitches. | eruption + strobe splice |
| 30 | f 5130 | f 5124 · beat 365 | The **lyrics desktop**. | `deskWallpaper` slides |
| 31 | f 5220 | f 5222 · beat 372 | **The ending.** | `credits`, held |

## Things worth knowing about this list

**The last two cues are past the end of the track.** The music stops at frame 5095; cues
30 and 31 fire at 5124 and 5222. They play over silence, which the piece already does —
the end card is built to hold past the last note — but it does mean the show now ends
about 145 frames after the audio rather than on it.

**"Fades" are cuts.** `NSWorkspace.setDesktopImageURL` has no fade and takes ~9 frames
per call, so cue 2 ("fade away into original desktop") and cue 16 ("fade to black") are
hard swaps. Both are covered by a short `screenFlash` so the change reads as intentional
rather than as a dropped frame.

**Cue 1 is the gate, and the gate is not on the timeline.** The intro sequence runs
*before* the transport starts — it is what arms it — so its ~300 frames are the gate's
own pace, set by how fast the viewer reads and answers, not a slot on the clock. Frame 0
is the moment they press **YES. INFECT ME.**, and the only cue-1 event on the timeline is
the desktop going blue. If the intent was for the intro to play *over* the first three
hundred frames of music instead, that is a different build and the gate would have to
move onto the timeline.

## Gaps

Four slots are marked TBD by the author and hold labelled placeholder windows, so the
timing is real and the content can be dropped in without re-cutting anything: **f 1440**
(left empty), **f 2967**, **f 4074**, **f 4144**.

Two placeholders stand in for work that isn't built yet:

- **the video window** (cues 10, 23, 24) — a flat colour card titled as a video slot.
  There is no video content kind yet.
- **the ASCII piece** (cue 3) — literal placeholder text in an `ascii` window. The kind
  already renders real art and image→ASCII; only the artwork is missing.

One cue needs a capability the app does not have:

- **the mouse spinner** (cue 26). Nothing in the tree sets the pointer. The comment in
  `CreditsController.freeze` about the pointer becoming the spinner describes what macOS
  does on its own when the main thread stalls — it is not something the show does.
