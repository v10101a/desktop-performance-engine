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

Every cue is written as a position **inside a phrase** — `PHRASE + bars.beats` — so
`CHORUS 1A + 0.0` is that phrase's downbeat (the changeover) and `CHORUS 1A + 5.0` is the
hook, five bars in. Move a phrase and its cues move with it; nothing reaches into the
next phrase. A cue may sit up to a bar *before* its phrase — `CHORUS 2A − 1.0` is the bar
the vocal comes in on — never past its end. **fires on** is the frame and beat that
position resolves to.

The cue list was first written in seconds off a reference video whose clock starts
**~9 s before the music** (the boot-up sequence, "f 0 → ~f 300"). Shifted back by those
9 s the cues land on the phrase starts — the drop, chorus 1B, both bridges, the
breakdown, both instrumentals, chorus 2A/2B and the break — which unshifted they missed
by a beat or a bar, and the last cues no longer sit past the end of the file. This table
is the shifted list, snapped to its phrase start where it was within a second of one.

Track: `assets/03 - Give it 2 me.mp3` — 128.5 BPM, first downbeat frame 11, **5095 frames
long (2:49.85)**. One beat is 14.0 frames, one bar 56.0.

## The phrases

The track is twelve 8-bar phrases, counted from the drop at bar 17 and each one a real
boundary in the audio (per-bar loudness, bass and vocal energy, kicks — 2026-08-28).
A cue that changes the section belongs on one of these lines; the last column is which
cues sit inside each phrase.

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
| 1 | INTRO A + 0.0 | f 11 · beat 0 | The intro sequence **as it is** — the stalled restart card, the face, the photosensitivity alert, DO YOU WANT THE MALWARE?. Every permission the show needs is raised here. The desktop is already DJ blue. | `IntroGate` (untouched) + `deskWallpaper` solid `#020AF5` |
| 2 | INTRO A + 3.2 | f 207 · beat 14 | At bar 4 the blue desktop goes and the viewer's **own** wallpaper is back. | the Act-1 `deskWallpaper` expires; `WallpaperController` restores the snapshot |
| 3 | INTRO A + 4.2 | f 263 · beat 18 | A centred **Terminal window types itself out**, one line a beat with a block cursor — the same surface and cadence as the credits on the end card. It says what the show is about to do to the machine, and ends on `⌃⌥⌘Esc` and `$ ./giveit2me --play`. 12 lines, the last landing f 432 — half a bar of air before cue 4 takes it. | `typeText` · `chrome: terminal` |
| 4 | INTRO B + 0.0 | f 460 · beat 32 | The welcome window closes; the **system probe** opens in real macOS chrome, titled `./scan_identity`, and starts typing. | `closeWindow` + `systemProbe` |
| 5 | INTRO B + 3.0 | f 628 · beat 44 | Hydra sketches **dragged onto the screen** — one full open→drag→resize→run, then two more. | `openWindow` · `livecode` + `cursorPath` + `moveWindow` |
| 6 | INTRO B + 7.1 | f 866 · beat 61 | The desktop goes **blue** again. | `deskWallpaper` solid |
| 7 | CHORUS 1A + 0.0 | f 908 · beat 64 | **The drop.** The face lands in the **middle of the blue desktop** — a 2560×1600 wallpaper the generator bakes (`assets/pixelface_desktop.jpg`): the face at 20% of the height on its own field colour (`#001FFD`, so there is no edge where it sits). Not the artwork stretched over the screen, and not composed at run time either — a picture has less to go wrong mid-show. | `deskWallpaper` slides |
| 8 | CHORUS 1A + 0.0 | f 908 · beat 64 | One main window travels **up and down** the screen, dragging a **delay line**: 20 identical copies, each 1% of the screen further left and one frame further behind, so link *k* sits where the leader was *k* frames ago. The tail is 0.67 s behind the head — most of a leg — so the chain snakes rather than follows. The trail hangs left, so the leader sits right of centre by half the chain and the **assembly** straddles the middle (x 432→1008 of 1440). It travels for the whole time it is up: 16 legs, f 908 → f 1320, ending on cue 12's close rather than stopping after two bars and sitting there. | `openWindow` ×21 + `moveWindow` ×336 |
| 9 | CHORUS 1A + 0.0 | f 908 · beat 64 | The drop. The **spiral of lyrics** — every phrase of chorus 1A's lyric, one big Hack-Bold card each, landing on its sung line (`lyrics.py` at CHORUS 1A's position; the first line is the pickup and lands with the drop: 16 cards, f 908 → f 1291), winding out from the centre. | `openWindow` · `lyric`, `anchor: center` |
| 10 | CHORUS 1A + 4.1 | f 1146 · beat 81 | **The desktop goes up in the air.** A transparent full-screen overlay: shells rise from the bottom, hang, and burst radially, and every spark is a **macOS file icon with a filename under it** — the system's own icons, on real UTTypes. The lyric spiral keeps winding out underneath and shows through. Up until cue 13, about 22 s. | `openWindow` · `fileworks` |
| 11 | CHORUS 1A + 4.3 | f 1174 · beat 83 | **TBD — deliberately empty.** | — |
| 12 | CHORUS 1B + 0.0 | f 1356 · beat 96 | Chorus 1B. The desktop becomes the **whole lyric, word by word as it is sung** (`lyrics.py` CUES at CHORUS 1B's position: 49 cards from the pickup at f 1333 to f 1767, each applied 300 ms early to cover the swap; the last holds to cue 13); a **trail of windows dragged by the mouse**. | `deskWallpaper` slides with an `at` schedule + `cursorPath` + `cursorTrail` stamp |
| 13 | BRIDGE A + 0.0 | f 1804 · beat 128 | Vocals out. The **magic torus**, and a window typing itself out: *"Greetings, I am the magic torus… ask me anything"*. At **f 1992**, once that has finished typing, it actually asks: a dialog with a **text field the viewer can type into**. It answers on Return, or by itself at f 2132, and is cut with the torus at cue 14. | `glassTorus` + `typeText` + `oracle` |
| 14 | BRIDGE B + 0.0 | f 2253 · beat 160 | Vocals back. **Apple Maps**, falling out of orbit onto the viewer's own location. | `openWindow` · `map`, `here: true` |
| 15 | BRIDGE B + 1.2 | f 2337 · beat 166 | Windows start opening, **slowly filling the screen**. Five of the 13 flat cards come up broken instead, interleaved: three **torn** (pixelface f 2488, the horse f 2570, the credits tile f 2604 — the same glitch pass the desktop gets at cue 28, once each, tearing harder as it goes: 0.45 → 0.63 → 0.81) and two **Wolfram automata actually running** — black on white, scrolling a generation at a time (rule 30 f 2506, rule 110 f 2588). The fill decays as it thickens. | ramped `openWindow` + `glitch` / `automaton` content |
| 16 | BRIDGE B + 7.0 | f 2645 · beat 188 | The bar before the breakdown: the desktop **fades to black**; the windows close **one by one**. | `deskWallpaper` solid `#000000` + staggered `closeWindow` |
| 17 | BREAKDOWN + 0.0 | f 2701 · beat 192 | The desktop is black and every window has closed, so this arrives on an empty screen and is the only thing on it until Photo Booth: the artist's **GLSL raymarcher**, running live in a WebGL canvas, centred at 52% of the screen. Recoloured to the show's own palette (#020AF5 / #68BDF8 / #F2F4FE) — it swept the whole hue circle as written. | `openWindow` · `shader` |
| 18 | BREAKDOWN + 4.½ | f 2932 · beat 208.5 | Bar 53, the kicks stop: **Photo Booth** opens on the viewer; 3 · 2 · 1 a bar apart; the shutter lands on cue 19. | `photoBooth` |
| 19 | BREAKDOWN + 7.½ | f 3100 · beat 220.5 | The bass hits back in — an "and", half a beat into bar 56, 1.6 s before the phrase line. The shutter, then the viewer's **own photos** spam and fill the screen. | `photoWall` |
| 20 | INSTRUMENTAL A + 2.1 | f 3275 · beat 233 | The spam continues; **pixelface.jpg strobes** over it. | `openWindow` · `image`, toggled |
| 21 | INSTRUMENTAL A + 3.1 | f 3331 · beat 237 | Everything cuts to the bare desktop; the **horse** gallops across. | `closeWindow` × n + `sprite` |
| 22 | INSTRUMENTAL A + 6.0 | f 3485 · beat 248 | The horse goes; the **glass torus** and a **circle of lyric windows**. | `glassTorus` + `openWindow` · `lyric` |
| 23 | INSTRUMENTAL A + 7.2 | f 3569 · beat 254 | All of it stays; the **placeholder video window** comes in on top. | `openWindow` · `color` |
| 24 | INSTRUMENTAL B + 0.0 | f 3597 · beat 256 | Torus and lyric windows cut; a **full black window** with the video placeholder on top. | `closeWindow` × n + `openWindow` · `color` |
| 25 | INSTRUMENTAL B + 3.3 | f 3807 · beat 271 | Everything cuts, and **the pointers come for the pointer**: a transparent full-screen swarm of Mac cursors, 11–90pt, chasing the viewer's real mouse and each turning to face the way it is going. Small ones quick, big ones heavy and late. Held to f 3863, where cue 26 takes it. | `openWindow` · `cursors` |
| 26 | INSTRUMENTAL B + 4.3 | f 3863 · beat 275 | **A mandala of beach balls.** Five concentric rings of the **real** macOS spinner — sliced out of the system's own cursor file, all 15 frames at its own 30 fps — each ring turning against its neighbour, shrinking outward. The sheet asked for *the mouse spinner*; nothing in the app sets the pointer, so this is the other reading — the machine hung everywhere at once. | `openWindow` · `mandala` |
| 27 | CHORUS 2A − 1.0 | f 3990 · beat 284 | The vocal comes in (bar 72, the pickup bar before chorus 2A): a **ton of crazy UI windows**, spammed. | the eruption: `openWindow`/`fakeDialog`/`jiggle` |
| 28 | CHORUS 2B − 1.0 | f 4438 · beat 316 | The vocal pickup bar before chorus 2B (bar 80). The **wallpaper glitches** repeatedly, and the lyrics desktop glitches with it. | `deskWallpaper` glitch ⇄ slides: the tear at 1.5 Hz, the lyric at 2.8 Hz (`LYRIC_FLASH`). The section averages ~2.2 desktop swaps/s. It stuttered at ~5 — the repaint starves the WindowServer and every window on screen pays for it — so this is the headroom, not a free dial |
| 29 | CHORUS 2B + 4.2 | f 4746 · beat 338 | A **ton of windows**, and the **whole screen** glitches. A quarter of the eruption's flat cards come up **packed with real macOS interface** instead — system icons, buttons, checkboxes, sliders, segmented controls, heaped over each other and running off the edges. Set on both eruptions, because they share one pool of 14 window ids and most of what is on screen here was opened at cue 27. | eruption + strobe splice + `uichaos` |
| 30 | BREAK − 0.1 | f 4816 · beat 343 | Everything stops (160.6 s, a beat before the bar line). The **lyrics desktop** — fired a beat early so the ~300 ms swap is seen on the stop. Asks for 5.6 Hz, gets the WallpaperAgent's ~3: above the ceiling the rate is a request, not a result. | `deskWallpaper` slides |
| 31 | BREAK + 2.0 | f 4942 · beat 352 | **The ending.** | `credits`, held |

## Things worth knowing about this list

**The ending is on the track now.** Before the 9 s shift the last two cues sat past the end
of the file; the end card now comes up at f 4942 (2:44.75), two bars into the break, and
holds past the last note at f 5095 as it was built to.

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

Three slots are marked TBD by the author and hold labelled placeholder windows, so the
One slot is still marked TBD by the author and left deliberately empty: **f 1174**.
(**f 1146** is the fireworks, **f 2701** the GLSL graphic, **f 3807** the cursor swarm
and **f 3863** the beach-ball mandala.)

One placeholder stands in for work that isn't built yet:

- **the video window** (cues 23, 24) — a flat colour card titled as a video slot. There
  is no video content kind yet. Cue 10 no longer holds one: it is the fireworks.

Still true about the pointer: nothing in the tree **sets** it, so a beach ball on the
cursor itself remains impossible. Cue 26 draws its own instead. The comment in
`CreditsController.freeze` about the pointer becoming the spinner describes what macOS
does on its own when the main thread stalls — it is not something the show does.
