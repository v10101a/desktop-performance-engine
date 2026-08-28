# The cue list

The show, as authored — one row per cue, in the order the viewer meets them.

This is the **source document**. `tools/generate_show.py` mirrors it as the `CUES` table
at the top of the file and builds `Sources/DPECore/Resources/timeline.json` from it; the
two must be edited together. Nothing else in the app hard-codes a time.

**Times are seconds on the show clock**, which starts when the intro gate is answered —
not wall-clock from launch. They were authored by ear against the recording, so they do
not land on bar lines: the generator puts each cue on the **nearest beat**, which moves
it by at most ±0.23 s and keeps every cut tight to the music. Both numbers are below.

Track: `assets/03 - Give it 2 me.mp3` — 128.5 BPM, first downbeat 0.395 s, **169.85 s
long (2:49.85)**. One beat is 0.467 s, one bar 1.868 s.

## The list

| # | authored | on the grid | what happens | how |
|---|---|---|---|---|
| 1 | 0:00 → ~0:10 | beat 0 | The intro sequence **as it is** — the stalled restart card, the face, the photosensitivity alert, DO YOU WANT THE MALWARE?. Every permission the show needs is raised here. The desktop is already DJ blue. | `IntroGate` (untouched) + `deskWallpaper` solid `#020AF5` |
| 2 | 0:16 | beat 33 · 15.80 s | The blue desktop goes and the viewer's **own** wallpaper is back. | the Act-1 `deskWallpaper` expires; `WallpaperController` restores the snapshot |
| 3 | 0:18 | beat 38 · 18.14 s | A centred window: *"welcome to the DJ Dave malware…"* — **placeholder** for the glitchy ASCII piece. | `openWindow` · `ascii` |
| 4 | 0:25 | beat 53 · 25.14 s | The welcome window closes; the **system probe** opens and starts typing. | `closeWindow` + `systemProbe` |
| 5 | 0:30 | beat 63 · 29.81 s | Hydra sketches **dragged onto the screen** — one full open→drag→resize→run, then two more. | `openWindow` · `livecode` + `cursorPath` + `moveWindow` |
| 6 | 0:38 | beat 81 · 38.22 s | The desktop goes **blue** again. | `deskWallpaper` solid |
| 7 | 0:39 | beat 83 · 39.15 s | The desktop becomes **pixelface.jpg**. | `deskWallpaper` slides, one image |
| 8 | 0:39.5 | beat 84 · 39.62 s | One main window travels **up and down** the screen, leaving a **trail of windows** behind it. | `openWindow` + `moveWindow` + trail `openWindow`s |
| 9 | 0:43 | beat 91 · 42.89 s | The **spiral of lyrics** — one card per cue, winding out from the centre. | `openWindow` · `lyric`, `anchor: center` |
| 10 | 0:47 | beat 100 · 47.09 s | A **placeholder** centre window, to hold a single video later. | `openWindow` · `color` |
| 11 | 0:48 | — | **TBD — deliberately empty.** | — |
| 12 | 0:54 | beat 115 · 54.09 s | The desktop becomes the **lyrics**, word by word; a **trail of windows dragged by the mouse**. | `deskWallpaper` slides + `cursorPath` + `cursorTrail` stamp |
| 13 | 1:09 | beat 147 · 69.03 s | The **magic torus**, and a window typing itself out: *"Greetings, I am the magic torus…"* | `glassTorus` + `typeText` |
| 14 | 1:24 | beat 179 · 83.97 s | **Apple Maps**, falling out of orbit onto the viewer's own location. | `openWindow` · `map`, `here: true` |
| 15 | 1:27 | beat 185 · 86.78 s | Windows start opening, **slowly filling the screen**. | ramped `openWindow` |
| 16 | 1:37 | beat 207 · 97.05 s | The desktop **fades to black**; the windows close **one by one**. | `deskWallpaper` solid `#000000` + staggered `closeWindow` |
| 17 | 1:39 | beat 211 · 98.92 s | **TBD — cool graphic.** A labelled placeholder holds the slot. | `openWindow` · `color` |
| 18 | 1:47 | beat 228 · 106.85 s | **Photo Booth** opens on the viewer; 3 · 2 · 1; the shutter. | `photoBooth` |
| 19 | 1:54 | beat 243 · 113.86 s | The viewer's **own photos** spam and fill the screen. | `photoWall` |
| 20 | 1:58 | beat 252 · 118.06 s | The spam continues; **pixelface.jpg strobes** over it. | `openWindow` · `image`, toggled |
| 21 | 2:00 | beat 256 · 119.93 s | Everything cuts to the bare desktop; the **horse** gallops across. | `closeWindow` × n + `sprite` |
| 22 | 2:05 | beat 267 · 125.06 s | The horse goes; the **glass torus** and a **circle of lyric windows**. | `glassTorus` + `openWindow` · `lyric` |
| 23 | 2:08 | beat 273 · 127.87 s | All of it stays; the **placeholder video window** comes in on top. | `openWindow` · `color` |
| 24 | 2:09 | beat 275 · 128.80 s | Torus and lyric windows cut; a **full black window** with the video placeholder on top. | `closeWindow` × n + `openWindow` · `color` |
| 25 | 2:16 | beat 290 · 135.80 s | Everything cuts. **TBD content.** | placeholder |
| 26 | 2:18 | beat 295 · 138.14 s | More **TBD** content, and the **mouse spinner**. | placeholder + `spinner` *(new event — see Gaps)* |
| 27 | 2:23 | beat 305 · 142.81 s | A **ton of crazy UI windows**, spammed. | the eruption: `openWindow`/`fakeDialog`/`jiggle` |
| 28 | 2:38 | beat 338 · 158.22 s | The **wallpaper glitches** repeatedly, and the lyrics desktop glitches with it. | `deskWallpaper` glitch ⇄ slides |
| 29 | 2:47 | beat 357 · 167.09 s | A **ton of windows**, and the **whole screen** glitches. | eruption + strobe splice |
| 30 | 2:51 | beat 365 · 170.82 s | The **lyrics desktop**. | `deskWallpaper` slides |
| 31 | 2:54 | beat 372 · 174.09 s | **The ending.** | `credits`, held |

## Things worth knowing about this list

**The last two cues are past the end of the track.** The music stops at 2:49.85; cues 30
and 31 are at 2:51 and 2:54. They play over silence, which the piece already does — the
end card is built to hold past the last note — but it does mean the show now ends ~4.8 s
after the audio rather than on it.

**"Fades" are cuts.** `NSWorkspace.setDesktopImageURL` has no fade and takes ~300 ms per
call, so cue 2 ("fade away into original desktop") and cue 16 ("fade to black") are hard
swaps. Both are covered by a short `screenFlash` so the change reads as intentional
rather than as a dropped frame.

**Cue 1 is the gate, and the gate is not on the timeline.** The intro sequence runs
*before* the transport starts — it is what arms it — so "0:00 → 0:10" is the gate's own
pace, set by how fast the viewer reads and answers, not a ten-second slot on the clock.
The show clock's 0:00 is the moment they press **YES. INFECT ME.**, and the only cue-1
event on the timeline is the desktop going blue. If the intent was for the intro to play
*over* the first ten seconds of music instead, that is a different build and the gate
would have to move onto the timeline.

## Gaps

Four slots are marked TBD by the author and hold labelled placeholder windows, so the
timing is real and the content can be dropped in without re-cutting anything: **0:48**
(left empty), **1:39**, **2:16**, **2:18**.

Two placeholders stand in for work that isn't built yet:

- **the video window** (cues 10, 23, 24) — a flat colour card titled as a video slot.
  There is no video content kind yet.
- **the ASCII piece** (cue 3) — literal placeholder text in an `ascii` window. The kind
  already renders real art and image→ASCII; only the artwork is missing.

One cue needs a capability the app does not have:

- **the mouse spinner** (cue 26). Nothing in the tree sets the pointer. The comment in
  `CreditsController.freeze` about the pointer becoming the spinner describes what macOS
  does on its own when the main thread stalls — it is not something the show does.
