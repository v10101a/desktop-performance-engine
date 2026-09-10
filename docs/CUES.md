# The cue list

The show, as it plays today — one row per cue, in the order the viewer meets them.

This is the **source document for the cut**. `tools/generate_show.py` mirrors it as the
`CUES` table at the top of the file and builds `Sources/DPECore/Resources/timeline.json`
from it; the two are edited together, and nothing else in the app hard-codes a time.
Everything the show *says* — what a window types, what a dialog reads, the credits — is
in **`docs/copy/`**, one plain-text file per passage; the rows below point at them. How an
event *works* is not described here: that is `README.md`, one section per event kind.

Rows are written in the present tense and describe the cut as it is. What changed, and
when, is the **changelog** at the bottom.

**Positions are frames at 30 fps, on the show clock** — the clock that starts when the
intro gate is answered, not wall-clock from launch. 30 fps because that is what the app's
own transport counts in: `MainWindowController` carries `fps = 30` and displays
`floor(t × 30)` next to the beat, so a number in this sheet is the number on the scrubber.
Nothing in the engine is frame-quantised — it runs off the audio clock in seconds — so a
frame here is a reading, not a grid the show snaps to.

    frame = floor(seconds × 30)        seconds = OFFSET + beat × 60 / BPM

Every cue is written as a position **inside a phrase** — `PHRASE + bars.beats` — so
`CHORUS 1A + 0.0` is that phrase's downbeat (the changeover) and `CHORUS 1A + 5.0` is the
hook, five bars in. Move a phrase and its cues move with it; nothing reaches into the
next phrase. A cue may sit up to a bar *before* its phrase — `CHORUS 2A − 1.0` is the bar
the vocal comes in on — never past its end. **fires on** is the frame and beat that
position resolves to.

Track: `assets/03 - Give it 2 me.mp3` — 128.5 BPM, first downbeat frame 11, **5095 frames
long (2:49.85)**. One beat is 14.0 frames, one bar 56.0.

## The phrases

The track is twelve 8-bar phrases, counted from the drop at bar 17 and each one a real
boundary in the audio (per-bar loudness, bass and vocal energy, kicks). A cue that changes
the section belongs on one of these lines; the last column is which cues sit inside each
phrase.

| phrase | bar | time | frame | cues |
|---|---|---|---|---|
| INTRO A | 1 | 0:00.40 | f 11 | 1, 2, 3 |
| INTRO B | 9 | 0:15.34 | f 460 | 4, 5, 6 |
| CHORUS 1A | 17 | 0:30.28 | f 908 | 7, 8, 9, 10, 11 |
| CHORUS 1B | 25 | 0:45.22 | f 1356 | 12 |
| BRIDGE A | 33 | 1:00.16 | f 1804 | 13 |
| BRIDGE B | 41 | 1:15.10 | f 2253 | 14, 15, 16 |
| BREAKDOWN | 49 | 1:30.04 | f 2701 | 17, 18 |
| INSTRUMENTAL A | 57 | 1:44.99 | f 3149 | 19, 20, 21, 22, 23 |
| INSTRUMENTAL B | 65 | 1:59.93 | f 3597 | 24, 25, 26 |
| CHORUS 2A | 73 | 2:14.87 | f 4046 | 27 |
| CHORUS 2B | 81 | 2:29.81 | f 4494 | 28, 29 |
| BREAK | 87 | 2:41.02 | f 4830 | 30, 31 |

The vocal pickup ("what I want") lands one bar *before* each chorus phrase — bars 16, 72
and 80. The hooks land at phrase + 5 bars: 22, 30, 78 and 86. The bass leaves in bar 52
and the kicks stop for 53–55; bar 56 is the pickup back in.

## The list

| # | phrase | fires on | what happens | how |
|---|---|---|---|---|
| 1 | INTRO A + 0.0 | f 11 · beat 0 | **The gate, then the blue.** Before the clock starts: **PERMISSION IS REQUESTED** — what the piece is about to do to the machine, the acceptance, the photosensitivity warning — answered GIVE IT 2 ME or DENY. The card leaves the screen, the macOS permission prompts land on the bare desktop and are each accepted or denied, and only then the **restart card**: it stalls at 60%, the ground cuts to DJ blue, the logo becomes the face (which blinks), and the track starts out of it. Frame 0 is the moment that card finishes. Every other app is hidden so the desktop is in view, and it is already blue. | `IntroGate` (before the timeline) + `hideOtherApps` + `deskWallpaper` solid `#020AF5` |
| 2 | INTRO A + 2.0 | f 123 · beat 8 | The blue goes and the viewer's **own** wallpaper is back, under a short white flash. | the cue-1 `deskWallpaper` expires; the desktop layer closes and the real wallpaper — never touched — is simply there · `screenFlash` |
| 3 | INTRO A + 2.2 | f 151 · beat 10 | A centred **Terminal window types itself out**, one line a beat with a block cursor, blue ground and white type. It reads as the program's own startup log — what it has taken, that a restore point is saved — and ends on the quit chord and `$ ./giveit2me --play`. Closed by cue 4; the generator asserts the copy finishes at least two beats before that, so the file can be rewritten freely. | `typeText` · `chrome: terminal`, `hex` + `fg` · words: `docs/copy/welcome.txt` |
| 4 | INTRO B + 0.0 | f 460 · beat 32 | The welcome closes and the **system probe** opens as **five windows, one per section** — identity, machine, network, geolocation, contacts — scattered across the desktop, a beat apart, all typing at once in real macOS chrome, blue ground and white type. It stops typing at f 623. Two of the windows close there; three stay standing on a diagonal under the game until cue 6 clears the screen. | `closeWindow` + `systemProbe` ×5 with `focus` |
| 5 | INTRO B + 3.0 | f 628 · beat 44 | **Brick Breaker**, played on the machine's own furniture, f 628 → f 863. Every brick is a real window (4×8, the show's palette and drawn chrome), the ball is the system's **beach ball**, and the paddle is the viewer's **pointer** — moving the mouse plays it, whether they meant to or not. It serves on the frame it opens, re-serves a missed ball and re-racks when the last brick goes, so nothing in it can stall a cue. It arrives on a desktop, not a blank: in the bar before, eight small windows fill in round the edges of the play area (f 572 → f 621), and the rack comes up on them and on the three probes. Game, ramp and probes all close on cue 6. | `brickBreaker` + `openWindow` ×8 |
| 6 | INTRO B + 7.1 | f 866 · beat 61 | Everything closes and the desktop goes **blue** again. | `closeWindow` + `deskWallpaper` solid |
| 7 | CHORUS 1A + 0.0 | f 908 · beat 64 | **The drop.** The face lands in the **middle of the blue desktop** — a 2560×1600 wallpaper the generator bakes (`assets/pixelface_desktop.jpg`), the face at 20% of the height on its own field colour so there is no edge where it sits. Applied a frame early so it is there on the beat. | `deskWallpaper` slides |
| 8 | CHORUS 1A + 0.0 | f 908 · beat 64 | One window travels **up and down** the screen dragging a **delay line**: 20 copies, each 1% of the screen further left and one frame further behind, so the chain snakes rather than follows. Eight legs, f 908 → f 1114, and it leaves on the last leg — leader first, the chain following it off. | `openWindow` ×21 + `moveWindow` ×168 + staggered `closeWindow` |
| 9 | CHORUS 1A + 0.0 | f 908 · beat 64 | **The spiral of lyrics.** Every phrase of the chorus, one big ALL-CAPS Hack-Bold card each, landing on its sung line and winding out from the centre. The first two are the pickup and land just before the drop (f 878, f 899); 16 cards to f 1291. Closes with cue 12. | `openWindow` · `lyric`, `anchor: center` · timed by `tools/lyrics.py` |
| 10 | CHORUS 1A + 4.1 | f 1146 · beat 81 | **The kick.** A floating layer of ~40 pointers runs the whole phrase and is **cut on every kick** — the 33 real onsets in `assets/track_analysis.json`, f 908 → f 1311, not a beat grid — over the traveller and the spiral, swept with them at f 1322. At one cut a beat only the spawn shapes are ever seen; that is the rhythm. 1A pulses, 1B breathes. | `openWindow` · `cursors` ×33 on the kick, `level: floating` |
| 11 | CHORUS 1A + 4.3 | f 1174 · beat 83 | **The hydra act.** Somebody sets a sketch up by hand in the middle of the drop: it appears small with its code written but not running, the cursor takes it by the title bar and hauls it down the screen, pulls it bigger by the corner and hits **run**; two more arrive already running. Every offset scaled by 0.70 to fit the thirteen beats before cue 12. Closes with the spiral. | `livecode` + `cursorPath` + `moveWindow` |
| 12 | CHORUS 1B + 0.0 | f 1356 · beat 96 | The desktop becomes **the whole lyric, as it is sung**: 31 full-bleed cards drawn a phrase at a time — WHAT I · WANT · I · TOLD YOU · THAT I · NEED YOUR LOVE · SO GIVE · IT 2 ME … — f 1325 → f 1752, each landing on the first word of its phrase and holding through it; the last holds to cue 13. Each card is composited onto a 4:3 field of its own blue, so any display Apple ships crops field rather than letters. Nothing else competes: spiral, traveller, hydra and kick layer all close. Over it, a **shoal** of ~63 cursors flocking, cutting between five shapes — spiral, ring, grid, burst, stream — 25 cuts in 15.8 s with holds of a half to three beats, so the flock has time to gather into a body. Gone before the torus. | `deskWallpaper` slides with an `at` schedule (`lyrics.DESKTOP`; cards in `assets/lyrics_desktops/`) + `cursors` · `mode: school` ×25 |
| 13 | BRIDGE A + 0.0 | f 1804 · beat 128 | Vocals out. **The torus dimension.** A full-screen **cloudy tunnel** opens as the room (f 1804 → f 2248), in the show's three colours, washed to white where the torus sits; the **glass torus** floats inside it and refracts the tunnel's own weather (a baked plane, `assets/torus_dimension.jpg`); the ground under it all is white. To the right of the torus a window types the torus's **greeting** at 28 characters a beat (f 1818 → f 2031). A beat after it finishes, the torus **asks**: a dialog with a text field the viewer can type into, f 2045, answered on Return or by itself at f 2185. All of it is cut at cue 14 and the desktop comes back to blue. | `shader` + `glassTorus` · `environment` + `typeText` + `oracle` · words: `docs/copy/torus_greeting.txt`, `docs/copy/torus_oracle.txt` |
| 14 | BRIDGE B + 0.0 | f 2253 · beat 160 | Vocals back. **Apple Maps** falls out of orbit onto the viewer's own location and has the screen to itself for the phrase: a 3 s **fall**, 2,600 km down to 260 m (landed by f 2343), then a 180° **orbit** of the fix, still turning when the tiles bury it at f 2676. Two windows low and left, on the picture, say what the machine is doing: a terminal types a **locate trace** through the fall (f 2260), and a dialog, **Location identified**, lands a beat after the camera does (f 2357). Both dissolve out at f 2639, ahead of the wipe. `{city}` and `{ip}` are filled in window titles only. | `openWindow` · `map`, `here: true`, `zoomSeconds` + `orbitDegrees` + `typeText` + `fakeDialog` · words: `docs/copy/locate.txt`, `docs/copy/location_found.txt` |
| 15 | BRIDGE B + 1.2 | f 2337 · beat 166 | **Pulled.** The window fill that covered the map. Kept behind `FILL_ACT`; the slot keeps its number. | — |
| 16 | BRIDGE B + 7.0 | f 2645 · beat 188 | **The way out of the map.** The desktop goes black and 30 tiles on a 6×5 grid fill the screen one a frame, scattered, gapless by f 2674; the map closes behind that cover at f 2676, so its orbit is never seen to stop. From f 2686 the tiles **dissolve**, three a frame, a quarter-second each, timed so the last are still going transparent as the raymarcher springs in. The build accumulates and the dissolve fades, so the one black flash is the only full-screen change in the cue. | `deskWallpaper` solid `#000000` + `openWindow` ×30 + `closeWindow` with `fadeSeconds` |
| 17 | BREAKDOWN + 0.0 | f 2701 · beat 192 | On an empty black screen, the artist's **GLSL raymarcher**, live in a WebGL canvas at 52% of the screen, in the show's palette and **turning** at 8°/s. Over it, unhurried, a **hydra sketch is set up by hand**: the cursor walks over (f 2722), the sketch spawns under it (f 2764), is hauled up by its title bar, pulled bigger by the corner and run (f 2890) — low on the left, clear of the booth. It renders until cue 21. | `openWindow` · `shader` + `livecode` + `cursorPath` + `moveWindow` |
| 18 | BREAKDOWN + 4.½ | f 2932 · beat 208.5 | Bar 53, the kicks stop: **Photo Booth**. The window opens a bar early (f 2876), camera live and counting nothing, so the picture is up before the count; **3 · 2 · 1** a bar apart; the shutter lands on cue 19. | `photoBooth`, fired 4 beats early |
| 19 | BREAKDOWN + 7.½ | f 3100 · beat 220.5 | The bass hits back in, half a beat into bar 56: the shutter, then the viewer's **own photos** spam and fill the screen. A machine that refuses Files and Folders gets the bundled pool of broken screens instead. | `photoWall` |
| 20 | INSTRUMENTAL A + 2.1 | f 3275 · beat 233 | **Pulled.** The face strobing over the wall. Kept behind `FACESTROBE_ACT`; the slot keeps its number. | — |
| 21 | INSTRUMENTAL A + 3.1 | f 3331 · beat 237 | Everything cuts to the bare desktop, which goes **blue** and stays blue to the end card — and **the eruption** goes straight in on top of it: windows, terminals, alerts and lyric cards bursting out of the middle for 47 beats, to the vocal pickup at f 3988, with the original strobe spliced over the whole screen (657 of its 667 events) and the ground flashing on every kick. A quarter of the flat cards come up **packed with real macOS interface**. The lyric cards change **face three times a second**, at random from the fonts on the viewer's own machine. Through it, a **shoal**: 54 pointers laid out on a spiral and flocked over a vortex, floating above the cards and the flashes and click-through, f 3331 → f 3988. From the midpoint twelve windows **cross the screen**, six each way at their own speeds, looping off one edge and on from the other (f 3660 → f 4816). The pointer swarm of cues 24–25 starts filling underneath at f 3492. | `deskWallpaper` solid + the eruption (`openWindow`/`fakeDialog`/`jiggle` + strobe splice + `uichaos`, alert text from `tools/lyrics.py`) + `cursors` · `mode: school` + `moveWindow` ×12 looping |
| 22 | INSTRUMENTAL A + 6.0 | f 3485 · beat 248 | **Pulled.** The second glass torus and its ring of faces. The cue's screen flash stays — it is the cut, not the act. Kept behind `TORUS2_ACT`. | `screenFlash` |
| 23 | INSTRUMENTAL A + 7.2 | f 3569 · beat 254 | **Pulled.** The video slot (DooM) is empty. Kept behind `DOOMVID_ACT`; the `doom` content kind and its engine are intact. | — |
| 24 | INSTRUMENTAL B + 0.0 | f 3597 · beat 256 | The **pointer swarm** is filling: 90 Mac cursors, transparent, over everything under the eruption's cards, arriving one at a time over 10.7 s from f 3492 and at full strength by f 3813. | the swarm, still filling (`cursors` with `spawnSeconds`) |
| 25 | INSTRUMENTAL B + 3.3 | f 3807 · beat 271 | The swarm is full and **chasing the viewer's pointer**: cursors 11–90 pt following the real mouse, small ones quick, big ones heavy and late. The only cue in the piece that reads the pointer. | the swarm, chasing (`mode: chase`) |
| 26 | INSTRUMENTAL B + 4.3 | f 3863 · beat 275 | **Pulled.** The beach-ball mandala. The pointer swarm closes here. Kept behind `MANDALA_ACT`. | `closeWindow` |
| 27 | CHORUS 2A − 1.0 | f 3990 · beat 284 | The vocal comes in (bar 72): **the segmenter.** `assets/giveit2meclip.mov` segmented for motion — every region that moves becomes its own titled window holding the piece of frame it was cut from, pinned where it was found, up to 60 before the oldest is recycled. Nothing is tracked between frames, so a thing that keeps moving mints a new window every frame and the screen fills. It opens at the normal level so cue 28 can climb on top of it. Cue 21's eruption pool is swept a quarter beat after it opens (f 3993), and from there to f 4438 the swarm is the only thing on screen. It runs a bar and a half into cue 28, buried a card at a time, and is swept at f 4522. | `segSwarm` at the normal level + `closeWindow` (the eruption pool) |
| 28 | CHORUS 2B − 1.0 | f 4438 · beat 316 | The vocal pickup before chorus 2B (bar 80): **the eruption again, and it closes the piece** — dense from the first beat, the ground flashing on every kick, the cards burying the segmenter. Over it, **the machine's own voice**: four full-screen transparent ASCII planes set in Monaco, 6.75 beats each, floating, escalating into the silence — **the dump** (hex spam), **the log** (the lyric as syslog records), **the corruption** (the same words with combining marks stacked until the lines bleed into each other), and **the machine looking at itself** (every window the show has open drawn as ASCII box art, strobing at 3 Hz between the real windows and their rendering; synthesised from the engine's own frames, nothing captured). The lyric cards cycle the viewer's fonts here too. | the eruption + `asciilog` ×4 · alert text from `tools/lyrics.py`, planes from `lyrics.LINES` |
| 29 | CHORUS 2B + 4.0 | f 4718 · beat 336 | **Pulled.** The lyric desktop under the strobe. The desktop stays blue from cue 21 into the card; the slot keeps its number. | — |
| 30 | BREAK − 0.1 | f 4816 · beat 343 | **The stop.** A beat before the bar line (160.6 s) everything **closes on the silence** — the eruption pool, the ASCII planes, the shoal, the crossing windows, swept a quarter beat late so a final open cannot outlive its close. Then **nine seconds of plain blue with nothing on it**, f 4816 → f 5082, while the last of the music runs out: the beat before the ending, not a gap in it. The blue expires two beats after the card is up, invisibly under it, so the viewer's desktop is back before quit. | `screenFlash` + staggered `closeWindow` |
| 31 | BREAK + 4.2 | f 5082 · beat 362 | **The end card, once the song has finished.** The photo the booth took under *I SURVIVED THE GIVE IT 2 ME MALWARE EXPERIENCE!*, the machine's vitals, and the **credits typing themselves out** one line a beat over the tiling face — the icon's artwork, blue on white. Then the force-quit alert, the memory dump, and the app quits, which is the viewer's own desktop back. No boot bar: the piece opened on a machine restarting and does not do it twice. Beat 362 is the latest this can fire — see below. | `credits`, held · words: `docs/copy/credits.txt` |

## Things worth knowing about this list

**The ending is after the track.** The stop is at f 4816 (2:40.55) and the end card at
**f 5082 (2:49.42)** — after the last of the music, with 0.43 s of margin before the file
ends at f 5095. Everything on the card — the typing, the whole outro — runs on wall-clock
timers from there while the engine holds paused on the last frame. **The card cannot go
any later, and that is a hard edge:** the engine tests for the end of the piece *before*
it ticks the scheduler, and a `credits` event has no duration of its own, so a card placed
at the end of the file would make the piece end on the tick before it fired and never
come up. Do not close that margin.

**Cue 1 is the gate, and the gate is not on the timeline.** The intro sequence runs
*before* the transport starts — it is what arms it — so its length is the gate's own pace,
set by how fast the viewer reads and answers, not a slot on the clock. **GIVE IT 2 ME**
does not start the clock: it starts the *restart card*, and frame 0 is the moment that
card finishes, about seven seconds later, on the blue screen with the face. The only cue-1
event on the timeline is the desktop going blue. The gate's copy is in `IntroGate.swift`,
not in `docs/copy/`.

**Every changeover is stitched.** Eight of the twelve phrase boundaries carry a *seam*:
eight small windows thrown across the line, opening in the beat before it and dissolving
out over the beat after, two of them torn. It is meant to be felt rather than watched — a
changeover is covered by something moving instead of showing a bare desktop for a few
frames. BREAKDOWN is left out because cue 16's wipe is already the transition there, BREAK
because the end card is the point, and INSTRUMENTAL B because the eruption is already
carrying that section. Each seam seeds its own RNG from its phrase name (`zlib.crc32`), so
two runs of the generator produce byte-identical output; that is worth checking after any
change to this file.

**The tear is in four places.** The displacement/chroma-split glitch pass is on every
ninth flat card in both eruptions, two of the cue-16 wipe tiles, and one card in every
seam. Chosen by counter, never by a draw on the act's RNG — a roll taken on one branch and
not another re-scatters every window after it.

**"Fades" are cuts.** The desktop layer has no fade — a change lands on the next frame —
so cue 2 ("fade away into original desktop") and cue 16 ("fade to black") are hard swaps,
each covered by a short `screenFlash` so the change reads as intentional rather than as a
dropped frame.

**Photosensitivity, measured on this cut.** Counting every full-screen change out of the
generated timeline — `screenFlash`, any window opened at full size, and a strobing plane
twice per cycle — the show runs a median **2.9 Hz** and peaks at **12.0 Hz**; nothing at or
above 15 Hz. The 3 Hz ASCII strobe at cue 28 is six changes a second. The desktop layer is
clamped at 12 Hz in the engine. **Re-measure after any change to a cadence** — the numbers
come straight out of `Resources/timeline.json`.

**What is pulled stays in the generator**, behind a flag, so a slot keeps its number and
the act can come back with one line: `FILL_ACT` (15), `FACESTROBE_ACT` (20), `TORUS2_ACT`
(22), `DOOMVID_ACT` (23), `WORKS_ACT` (the icon fireworks, last at 25), `MANDALA_ACT` (26),
`MAPSEG_ACT` (segmenting the map at 14), `HORSE_ACT` (the horse at 21). The `glitch` and
`automaton` content kinds are off the screen with the fill; `particles` is unused.

**The pointer is never set.** Nothing in the app changes the cursor image, so a beach
ball on the cursor itself is impossible; anything in the piece that looks like one is
drawn in a window.

## Changelog

Newest first. A row above describes the cut as it plays; this is how it got there.

- **2026-09-11 — the doc split.** This sheet describes the cut only, in the present
  tense, with the history here. Every word the show speaks moves out of the generator
  into `docs/copy/` (welcome, torus greeting, torus question and answers, locate trace,
  location alert, credits); the torus's answers are authored there rather than taken from
  the engine's defaults. `README.md` no longer narrates the cut or names cue numbers. The
  generator runs from a clean checkout: every derived asset step skips when its
  gitignored source drop is absent and keeps the committed copy.
- **2026-09-07.** Cue 10 takes the **kick swarm** (the fireworks are out of the cut
  entirely). Cue 13 gets its **tunnel room** and the torus refracts a baked plane. Cue 14's
  map gets the **locate trace and the Location identified alert**. Cue 5's brick breaker
  arrives on a desktop: eight ramp windows and three probes left standing. Cues 27 and 28
  **swap**: the segmenter is 27, the eruption closes the piece as 28 and the ASCII planes go
  with it. Cue 30 opens nine seconds of blue; cue 31 fires **after the track ends**, and the
  outro drops its boot bar.
- **2026-09-06.** The **shoal** over cue 12. The four **ASCII planes**. Lyric cards in the
  eruptions cycle the viewer's **fonts**. The horse's frames leave the tear sources.
- **2026-09-05.** Cues 21 and 28 swap: the eruption and strobe land on the instrumental
  and the segmenter takes the end (swapped again two days later, above).
- **2026-09-03.** The welcome terminal goes blue with white type. The probe becomes
  **five windows**. The **hydra act** moves from cue 5 to cue 11. Pulled: segmenting the map
  (`MAPSEG_ACT`), the second torus and ring (`TORUS2_ACT`), the DooM video slot
  (`DOOMVID_ACT`), the icon fireworks (`WORKS_ACT`), the mandala (`MANDALA_ACT`). The seams
  become reproducible (`zlib.crc32` instead of Python's salted `hash()`).
- **2026-09-02.** The **gate reordered**: consent first, then the prompts on the bare
  desktop, then the restart card, which starts the track. The probe half as long. The
  traveller halved and leaving on its last leg. The fireworks move from cue 10 to cue 25.
  The face strobe pulled (`FACESTROBE_ACT`). The tear back in four places. The video slot
  runs DooM (pulled the next day).
- **2026-09-01.** Cue 29, the lyric desktop under the strobe, pulled.
- **2026-08-31.** Cue 15, the fill, pulled (`FILL_ACT`): its 26 windows opened on top of
  the map and the map was never once seen whole.
- **2026-08-28.** The cue list, first written in seconds off a reference video whose
  clock starts ~9 s before the music, shifted back by those 9 s onto the phrase starts and
  rewritten as `PHRASE + bars.beats`, in frames at 30 fps. The last cues no longer sit past
  the end of the file.
