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
| 1 | INTRO A + 0.0 | f 11 · beat 0 | The intro sequence **as it is** — the stalled restart card, the face, the permissions alert, PERMISSION IS REQUESTED. Every permission the show needs is raised here. Every other app is hidden so the desktop is in view, and it is already DJ blue. | The intro sequence, **reordered 2026-09-02**: the permissions list, the acceptance and the photosensitivity warning — **PERMISSION IS REQUESTED** — come FIRST, and the machine "restarts" on the answer — consent, then the consequence. The restart card is now the last thing before the music: it stalls at 60%, the ground cuts to DJ blue, the logo becomes the face (which blinks), and **the track starts out of it**. Every permission the show needs is raised **on the answer**, before the restart: GIVE IT 2 ME, the
question card leaves the screen, then the prompts on the bare desktop, each accepted or
denied, and only then the restart card. Every other app is hidden so the desktop is in view, and it is already blue.
| 2 | INTRO A + 2.0 | f 123 · beat 8 | At bar 3 the blue desktop goes and the viewer's **own** wallpaper is back. | the Act-1 `deskWallpaper` expires; the desktop layer closes and the real wallpaper — never touched — is simply there |
| 3 | INTRO A + 2.2 | f 151 · beat 10 | A centred **Terminal window types itself out**, one line a beat with a block cursor — the same surface and cadence as the credits on the end card. It says what the show is about to do to the machine, and ends on `⌃⌥⌘Esc` and `$ ./giveit2me --play`. 12 lines, the last landing f 320 — two and a half bars of air before cue 4 takes it. | A centred **Terminal window types itself out**, one line a beat with a block cursor. It says what the show is about to do to the machine, and ends on `⌃⌥⌘Esc` and `$ ./giveit2me --play`. 12 lines, the last landing f 320 — two and a half bars of air before cue 4 takes it. **Blue ground, white type** (2026-09-03): the first window of the piece should look like the piece, not like a shell that happens to be open. | `typeText` · `chrome: terminal`, `hex` + `fg` |
| 4 | INTRO B + 0.0 | f 460 · beat 32 | The welcome window closes; the **system probe** opens in real macOS chrome, titled `./scan_identity`, and starts typing. | The welcome window closes and the **system probe** opens — as **five windows, one per section**, scattered across the desktop and all typing at once (2026-09-03): `identity`, `machine`, `network`, `geolocation`, `contacts`, a beat apart, each in real macOS chrome titled for the scan that produced it, blue ground and white type like the welcome card. It was one tall report in the middle of the screen reading itself out top to bottom; this is a machine interrogating itself and leaving the windows where they fell. The session is **half what it was** — it closes at f 623 and cue 5 takes the rest of INTRO B. | `systemProbe` ×5 with `focus` |
| 5 | INTRO B + 3.0 | f 628 · beat 44 | **Pulled for now** — the hydra act (sketches dragged on, resized, run) is out of the cut, maybe back later. The slot keeps its number. | **BRICK BREAKER**, played on the machine's own furniture, f 628 → f 863. Every brick is a real window (4×8, the show's palette and drawn chrome), the ball is the system's **beach ball** — all fifteen frames of it, spinning — and the paddle is the viewer's **pointer**: moving the mouse plays it, and moving the mouse is the only thing anyone can do here, so whoever is at the machine is playing whether they meant to be or not. It starts moving on the frame it opens; a missed ball is served again, and when the last brick goes the rack comes back, so nothing in it can stall a cue. The slot is the pulled hydra act's. | `brickBreaker` |
| 6 | INTRO B + 7.1 | f 866 · beat 61 | The desktop goes **blue** again. | `deskWallpaper` solid |
| 7 | CHORUS 1A + 0.0 | f 908 · beat 64 | **The drop.** The face lands in the **middle of the blue desktop** — a 2560×1600 wallpaper the generator bakes (`assets/pixelface_desktop.jpg`): the face at 20% of the height on its own field colour (`#001FFD`, so there is no edge where it sits). Not the artwork stretched over the screen, and not composed at run time either — a picture has less to go wrong mid-show. Applied 60 ms early (2×`DESK_LATENCY`) so the change has **finished** before the drop. It used to be 600 ms: on the real wallpaper the swap took ~300 ms and, fired closer, was still in flight when the drop's window opens hit — the whole entrance stuttered. On the desktop layer the change lands on the next vsync, so the lead is a frame's worth and the drop is exact. | `deskWallpaper` slides |
| 8 | CHORUS 1A + 0.0 | f 908 · beat 64 | One main window travels **up and down** the screen, dragging a **delay line**: 20 identical copies, each 1% of the screen further left and one frame further behind, so link *k* sits where the leader was *k* frames ago. The tail is 0.67 s behind the head — most of a leg — so the chain snakes rather than follows. The trail hangs left, so the leader sits right of centre by half the chain and the **assembly** straddles the middle (x 432→1008 of 1440). It travels for the whole time it is up: 16 legs, f 908 → f 1320, ending on cue 12's close rather than stopping after two bars and sitting there. | One main window travels **up and down** the screen dragging a **delay line** of 20 copies, each 1% of the screen further left and one frame further behind, so the chain snakes rather than follows. **Half the run it used to have** (2026-09-02): 8 legs, f 908 → f 1114, and it now LEAVES on the last leg — leader first, the chain following it off in the order the delay line already puts them in — rather than parking for the rest of chorus 1A. A wave that stops and sits is what the full-length version was written to avoid. | `openWindow` ×21 + `moveWindow` ×168 + staggered `closeWindow` |
| 9 | CHORUS 1A + 0.0 | f 908 · beat 64 | The drop. The **spiral of lyrics** — every phrase of chorus 1A's lyric, one big ALL-CAPS Hack-Bold card each, landing on its sung line (`lyrics.py` at CHORUS 1A's position; the first two lines are the pickup and land on their sung lines just **before** the drop — f 878 and f 899 — so the drop's own instant isn't buried under simultaneous opens: 16 cards, f 878 → f 1291), winding out from the centre. | `openWindow` · `lyric`, `anchor: center` |
| 10 | CHORUS 1A + 4.1 | f 1146 · beat 81 | **The desktop goes up in the air.** A transparent full-screen overlay: shells rise from the bottom, hang, and burst radially, and every spark is a **macOS file icon with a filename under it** — the system's own icons, on real UTTypes. The lyric spiral keeps winding out underneath and shows through. Up until cue 12, where it closes with the spiral: a live full-screen particle layer kept the compositor repainting everything under the word swaps, and chorus 1B dragged for it. | **Moved to cue 25** (2026-09-02) — the desktop going up in the air used to happen here, over the spiral and the traveller, with the drop's own wallpaper underneath: three moving pictures at once and no room to watch a single shell rise. The act is unchanged, it just happens later. The slot is empty. | moved — see cue 25 |
| 11 | CHORUS 1A + 4.3 | f 1174 · beat 83 | **TBD — deliberately empty.** | **THE HYDRA ACT**, moved here from cue 5 (2026-09-03). Somebody sets a sketch up by hand in the middle of the drop: it appears small with its code written but **not running**, the cursor takes it by the title bar and hauls it down the screen, pulls it bigger by its lower-right corner, and hits **run** — then two more arrive already running. Every offset and every drag duration is scaled by 0.70 to fit the thirteen beats between here and cue 12; unscaled, the last sketch would land on the frame the screen clears. Closes with the spiral on cue 12. | `livecode` + `cursorPath` + `moveWindow` |
| 12 | CHORUS 1B + 0.0 | f 1356 · beat 96 | Chorus 1B. The desktop becomes the **whole lyric, word by word as it is sung** (`lyrics.py` CUES at CHORUS 1B's position, regrouped by `lyrics.DESKTOP`: **31 cards over the 59 sung words**, f 1325 to f 1752, each applied 30 ms early — a frame, not the 300 ms the old wallpaper swap needed; the last holds to cue 13). The cards are the artist's, drawn a **phrase** at a time and full bleed — WHAT I · WANT · I · TOLD YOU · THAT I · NEED YOUR LOVE · SO GIVE · IT 2 ME — so a card lands on the first word of its phrase and holds through the rest of it. They arrive 1920×1080 and the desktop is 1.54:1, so the generator composites each onto a **4:3 field of its own blue**: filled to the screen, the crop eats field rather than a letter on any display from 4:3 to 16:9 — which is every panel Apple ships, and is the whole band a 16:9 full-bleed drawing can be safe in. A third-party ultrawide would trim the letters top and bottom. On the desktop layer **every** card lands — the tightest gap is 233 ms against the ~12 ms a full-screen card costs, and the next few are decoded ahead of the one on screen. Pinned by `DesktopLayerTests`, which walks the whole schedule and counts.. Nothing else competes: the spiral, the traveller and the fireworks all close, and the desktop is the only picture. | `deskWallpaper` slides with an `at` schedule |
| 13 | BRIDGE A + 0.0 | f 1804 · beat 128 | Vocals out. The **magic torus**, and a window typing itself out: *"I am the Magic Torus! I am shaped like a question that answers itself… Ask me one (1) question. Make it yes or no — I only speak in absolutes, and I would hate to disappoint you."*. At **f 2045**, once that has finished typing, it actually asks: a dialog with a **text field the viewer can type into**. It answers on Return, or by itself at f 2185 (10 beats — it sits open, waiting), and is cut with the torus at cue 14. The monologue is three times the length of the one it replaced and the phrase is the same 32 beats, so it types at 28 chars a beat and the waiting beats come off the oracle's end. The greeting sits fully to the right of the torus rather than covering it, and runs from mid-height down to the question's baseline — ten wrapped lines need the room; the desktop goes blue under it 30 ms early, replacing the words before they can expire into a restore flicker. | `glassTorus` + `typeText` + `oracle` |
| 14 | BRIDGE B + 0.0 | f 2253 · beat 160 | Vocals back. **Apple Maps**, falling out of orbit onto the viewer's own location — and **alone on the screen for the whole phrase**: nothing opens over it until cue 16's wipe covers it (cue 15's fill is pulled). The shot is **two legs**. The **fall** is 3.0 s — 2,600 km down to 260 m, landed by f 2343, under a quarter of the shot — and everything after it **orbits the fix**: 180° at ~16°/s, eased in out of the landing and then **held at rate**, so the camera is still going round when the tiles bury it at f 2676. The flight is sized to the window's life, not to the bar line. The segmentation of it is **pulled** (2026-09-03, `MAPSEG_ACT = False`): the fall and the orbit play on their own. | `openWindow` · `map`, `here: true`, `zoomSeconds` + `orbitDegrees` |
| 15 | BRIDGE B + 1.2 | f 2337 · beat 166 | **Pulled (2026-08-31)** — the fill is out of the cut. All 26 of its windows opened on top of the map, so the descent played out under a thickening pile of them and the map was never once seen whole; bridge B is the map's alone now. Kept in the generator behind `FILL_ACT = False`: the ramp from one window a bar to four a beat walking outward from the centre, with three **torn** cards and two running **Wolfram automata** among them. Nothing else in the cut uses the `glitch` or `automaton` content kinds, so both are off the screen until this act returns. The slot keeps its number. | kept in the generator behind `FILL_ACT = False` |
| 16 | BRIDGE B + 7.0 | f 2645 · beat 188 | The bar before the breakdown, and **the way out of the map**: the desktop goes black and the screen **fills with windows** — 30 tiles on a 6×5 grid, one a frame, scattered, gapless by f 2674. The map closes behind that cover at f 2676, so its orbit is never seen to stop. Then the tiles **dissolve**, three a frame from f 2686, a quarter-second of alpha each, timed backward from cue 17 so the last of them are still going transparent as the raymarcher springs in at f 2701 — the shader is uncovered rather than cut to. The build accumulates and the dissolve fades, so neither reverses the screen: the one-a-frame cadence is not a flash rate, and the cue's single black `screenFlash` is still the only full-screen change in it. | `openWindow` ×30 + `closeWindow` with `fadeSeconds` |
| 17 | BREAKDOWN + 0.0 | f 2701 · beat 192 | The desktop is black and every window has closed, so this arrives on an empty screen and is the only thing on it until Photo Booth: the artist's **GLSL raymarcher**, running live in a WebGL canvas, centred at 52% of the screen and **turning** — 8°/s, about 170° over the time it is up, so it is visibly moving without ever coming back round. The rotation is in the SHADER (every `gl_FragCoord` read rewritten to a coordinate turned about the centre), not on the canvas: rotating the canvas meant scaling it up to cover its own corners, and that scale cropped the shot to a magnified fragment. Recoloured to the show's own palette (#020AF5 / #68BDF8 / #F2F4FE) — it swept the whole hue circle as written. Over it, a **hydra sketch is set up by hand, taking its time**: the cursor walks over (f 2722), the sketch spawns under it (f 2764), gets hauled up by its title bar, pulled bigger by the lower-right corner, and run (f 2890) just as Photo Booth arrives. It lives LOW on the left — its right edge stops short of the booth's frame, so nothing overlaps the countdown — and the patch is hy1's sketch from the pulled intro act; it keeps rendering until cue 21 cuts it. | `openWindow` · `shader` + `livecode` + `cursorPath` + `moveWindow` |
| 18 | BREAKDOWN + 4.½ | f 2932 · beat 208.5 | Bar 53, the kicks stop: the **3** lands here — but the **window opens a bar early (f 2876), camera live and counting nothing**, so the picture is up before the countdown starts (the count is anchored to the shutter, so opening early only buys warm-up). 3 · 2 · 1 a bar apart; the shutter lands on cue 19. | `photoBooth`, fired 4 beats early |
| 19 | BREAKDOWN + 7.½ | f 3100 · beat 220.5 | The bass hits back in — an "and", half a beat into bar 56, 1.6 s before the phrase line. The shutter, then the viewer's **own photos** spam and fill the screen. | `photoWall` |
| 20 | INSTRUMENTAL A + 2.1 | f 3275 · beat 233 | The spam continues; **pixelface.jpg strobes over the wall in a window** — 518×390, centred, its own aspect — not over the whole screen. Same 6 Hz, same 21 frames. | **Pulled (2026-09-02)** — the window that alternated the face with a flat blue card at 6 Hz. It was the only thing in the piece that flashed a whole window's ground on and off, it landed immediately after the photo spam (the busiest picture in the show), and it read as a fault rather than as a beat. The wall now runs to the horse unaccompanied. Kept behind `FACESTROBE_ACT`; the slot keeps its number. | out in the generator |
| 21 | INSTRUMENTAL A + 3.1 | f 3331 · beat 237 | Everything cuts to the bare desktop and the desktop goes **blue** (it stays that way to the end card) — and the noise goes straight in on top of it. **Swapped with cue 28 (2026-09-05):** the eruption and the original strobe spliced over it used to close the piece and the segmenter swarm used to hold this stretch; they have traded places, so the loudest picture in the show now lands on the instrumental and the piece ends quiet. Straight in, no four-bar wait, and the window is 47 beats instead of 27 — **657 of the strobe's 667 events** now run (it was 529), over 21.9 s to the vocal pickup at f 3988. A quarter of the flat cards come up **packed with real macOS interface**, set on both eruptions (they share one pool of 14 window ids). **Under all of it, a shoal**: 54 Mac pointers laid out on a 2½-turn spiral from the centre and then flocked — separation, alignment and cohesion over a vortex that keeps the whole body turning — swimming from f 3331 to f 3988. It ignores the viewer's pointer entirely (cues 24–25 were the swarm that wanted it; this is the same particles with the mouse taken away), and it swims **over everything** — `level: floating`, because the show's z-order is otherwise just the order things opened in and this cue raises a window every fifth of a beat, which buried it. Floating also puts it above the strobe's `screenFlash` overlays, so the flashes no longer white the fish out; it stays click-through, so the cards underneath are still the viewer's. **From the midpoint the screen picks up a horizontal current**: twelve windows crossing it, six going each way, every one at its own speed (a full traverse in 2.4–3.6 beats, about a second and a half) and every one **looping** — off one edge and straight back on from the other. They are their own windows, not the eruption's recycled pool: a window being re-opened at a fresh position every fifth of a beat and moved at the same time snaps instead of travelling. **The pointer swarm of cues 24–25 now runs underneath this** rather than alone — it opens at f 3492 and is buried by the cards. The horse act is still kept behind `HORSE_ACT = False`. | `deskWallpaper` solid + eruption + strobe splice + `uichaos` + `cursors` · `mode: school` + `moveWindow` ×12 looping |
| 22 | INSTRUMENTAL A + 6.0 | f 3485 · beat 248 | **Pulled (2026-09-03)** — the glass torus and its ring of faces and hydra sketches are out of the cut (`TORUS2_ACT = False`). The cue's screen flash stays: it is the cut, not the act. What plays here is the segmenter's swarm, up since bar 59, and the pointer swarm filling underneath it. | out in the generator (the flash remains) |
| 23 | INSTRUMENTAL A + 7.2 | f 3569 · beat 254 | **Pulled (2026-09-03)** — the video slot is empty again (`DOOMVID_ACT = False`). The `doom` content kind and its engine are untouched and one line brings the window back; nothing in the cut opens one. | out in the generator |
| 24 | INSTRUMENTAL B + 0.0 | f 3597 · beat 256 | Torus and ring cut, leaving the DooM window alone on the **blue desktop** (the black backdrop is gone), and the **pointer swarm rises with it** — transparent, over everything, building while the video plays. | Torus and ring cut, leaving the **DooM window** alone on the **blue desktop** (the black backdrop is gone). The **pointer swarm** is already up and filling: it opens back at cue 22 and arrives **one pointer at a time** over ~10.7 s (`spawnSeconds`), so it bleeds through the torus act and across the section line instead of landing as a wall of ninety cursors on one frame, and it is at full strength exactly when cue 25 leaves it alone with the viewer's pointer. | `closeWindow` × n + the swarm, still filling |
| 25 | INSTRUMENTAL B + 3.3 | f 3807 · beat 271 | The video slot has already gone and the **swarm is alone with the viewer's pointer**: Mac cursors 11–90pt chasing the real mouse, small ones quick, big ones heavy and late. The **icon explosions are pulled** (2026-09-03, `WORKS_ACT = False`) — they were moved here from cue 10 and are now out of the cut entirely. | the swarm, still chasing |
| 26 | INSTRUMENTAL B + 4.3 | f 3863 · beat 275 | **Pulled (2026-09-03)** — the beach-ball mandala is out (`MANDALA_ACT = False`). The pointer swarm still closes on this cue, so what runs from here to the eruption is the segmenter's swarm alone. | out in the generator |
| 27 | CHORUS 2A − 1.0 | f 3990 · beat 284 | The vocal comes in (bar 72, the pickup bar before chorus 2A): a **ton of crazy UI windows**, spammed; its lyric cards are ALL CAPS like the spiral's. **Over it, from 2026-09-06, the machine's own voice: four full-screen ASCII planes, 8 beats each, running out exactly where the segmenter takes the screen.** All four are `asciilog` — a live monospaced plane set in Monaco, transparent, `floating` so the eruption does not bury it (the shoal went with cue 21, so the level is free). An escalation: **the dump** (f 3990, hex spam at 26 lines a second — a wall before it is a list), **the log** (f 4102, the lyric coming out as syslog records, timestamp and level and `giveit2me[1337]`), **the corruption** (f 4214, the same words in 30pt with combining marks stacked over and under until the lines bleed into each other), and **the machine looking at itself** (f 4326, every window the show has open drawn as pure-ASCII box art on the show's blue, **strobing at 3 Hz** so the screen alternates between the real windows and its rendering of them — six full-screen changes a second, and the cut still peaks at 12 Hz, nothing at or above 15). The map is synthesised from the rectangles the engine already owns; nothing is captured. It closes at f 4437, one frame before the segmenter opens. | the eruption: `openWindow`/`fakeDialog`/`jiggle` + `asciilog` ×4 |
| 28 | CHORUS 2B − 1.0 | f 4438 · beat 316 | The vocal pickup bar before chorus 2B (bar 80): **the segmenter swarm, and it closes the piece.** **Swapped with cue 21 (2026-09-05)** — see there. `assets/giveit2meclip.mov` segmented for **motion**, every region that moves becoming its own titled window holding the piece of frame it was cut from, pinned where it was found. Nothing is tracked between frames, so a thing that keeps moving mints a new window every frame and the screen fills — up to 60, then the oldest panel is recycled. It reads as the sentence the horse read as, the desktop taken over by one moving thing, in the show's own furniture rather than a sprite. It runs to the stop at f 4816 with **nothing else on screen** — cue 27's eruption pool (`w0…w13`, `d0…d3`) is closed on the beat this opens, or sixty panels would build up behind fourteen recycled cards. No `level: below` any more either: that was there so the torus, the video slot and the pointer swarm could arrive ON the pile, and here the swarm IS the screen. | `segSwarm` at the normal level |
| 29 | CHORUS 2B + 4.0 | f 4718 · beat 336 | **Pulled (2026-09-01)** — the lyric desktop under the strobe is out: the strobe starved the swap queue, so each word stuck for whole seconds, and a lingering word right before the end card read as a weird wallpaper flash. (There is no swap queue to starve now the desktop is a layer; the slot stays empty because the cut was rebuilt around it, not because it could not be done.) The desktop stays blue from the horse straight into the card; the slot keeps its number. | out in the generator |
| 30 | BREAK − 0.1 | f 4816 · beat 343 | Everything stops (160.6 s, a beat before the bar line) and **closes on the silence**. Nothing else moves: the desktop has been plain blue since cue 21, so nothing is in flight — or possible — when the end card fires. The blue expires two beats after the card is up, invisibly under it, so the viewer's desktop is back before quit. | flash + staggered `closeWindow` |
| 31 | BREAK − 0.1 | f 4816 · beat 343 | **The ending, ON the stop: the break is the end card.** The photo the booth took under *I SURVIVED THE GIVE IT 2 ME MALWARE EXPERIENCE!*, the machine's vitals, the song's own credit block and ours typing themselves out over the **tiling face** — the app icon's own artwork with the colours the other way round, blue on white to sit on the card's white ground, rebuilt from `pixelface.jpg` so it is the same face as the icon and the desktop pixel for pixel rather than the soft rounded rendition it was while the track's silent tail runs out underneath; the copy is fifteen lines now, so the hold after it is 2 s rather than 4 and the outro still quits at ~169.6 s, right at the file's end. | `credits`, held |

## Things worth knowing about this list

**The ending is on the track now.** Before the 9 s shift the last two cues sat past the end
of the file; the end card now comes up at f 4942 (2:44.75), two bars into the break, and
holds past the last note at f 5095 as it was built to.

**Every changeover is stitched.** Eight of the twelve phrase boundaries carry a *seam*
(`seam()` in the generator): eight small windows thrown across the line, opening in the
beat before it and dissolving out over the beat after, two of them torn. It is meant to
be felt rather than watched — the seam exists so a changeover is covered by something
moving instead of showing a bare desktop for a few frames. BREAKDOWN is left out because
cue 16's 30-tile wipe is already the transition there, BREAK because the end card is the
point, and INSTRUMENTAL B because the segmenter's swarm is already carrying that section
(taken out in the timeline, 2026-09-03).

**The seams were not reproducible until 2026-09-03.** Each one seeds its own RNG from its
phrase name, and it did that through Python's `hash()` — which is salted per process, so
every invocation of the generator laid every seam out differently and the show was not the
same twice. It is `zlib.crc32` now. Two runs of the generator produce byte-identical
output; that is worth checking after any change to this file.

**The tear is in four places now** (2026-09-02). The displacement/chroma-split pass that
had gone off the screen with the pulled fill is back: every ninth flat card in both
eruptions, two of the cue-16 wipe tiles, and one card in every seam. Chosen by counter,
never by a draw on the act's RNG — a roll taken on one branch and not another re-scatters
every window after it.

**"Fades" are cuts.** `NSWorkspace.setDesktopImageURL` has no fade and takes ~9 frames
per call, so cue 2 ("fade away into original desktop") and cue 16 ("fade to black") are
hard swaps. Both are covered by a short `screenFlash` so the change reads as intentional
rather than as a dropped frame.

**Cue 1 is the gate, and the gate is not on the timeline.** The intro sequence runs
*before* the transport starts — it is what arms it — so its frames are the gate's own
pace, set by how fast the viewer reads and answers, not a slot on the clock. **GIVE IT 2
ME** no longer starts the clock: it starts the *restart card*, and frame 0 is the
moment that card finishes, about seven seconds later, on the blue screen with the face.
The only cue-1 event on the timeline is the desktop going blue. If the intent was for the intro to play *over* the first three
hundred frames of music instead, that is a different build and the gate would have to
move onto the timeline.

## Gaps

Three slots are marked TBD by the author and hold labelled placeholder windows, so the
One slot is still marked TBD by the author and left deliberately empty: **f 1174**.
(**f 1146** is the fireworks, **f 2701** the GLSL graphic, **f 3807** the cursor swarm
and **f 3863** the beach-ball mandala.)

One placeholder stands in for work that isn't built yet:

- ~~the video window (cues 23, 24)~~ — **filled** (2026-09-02): the slot runs DooM. There
  is still no video content kind, and cue 10 no longer holds one either — it is the
  fireworks.

Still true about the pointer: nothing in the tree **sets** it, so a beach ball on the
cursor itself remains impossible. Cue 26 draws its own instead. The comment in
`CreditsController.freeze` about the pointer becoming the spinner describes what macOS
does on its own when the main thread stalls — it is not something the show does.
