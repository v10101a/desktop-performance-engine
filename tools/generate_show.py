"""The show, cut to docs/CUES.md.

`docs/CUES.md` is the source document — one row per cue. `CUES` below mirrors it, and
everything in this file hangs off those numbers. **Edit the two together, in both
directions** — see CLAUDE.md.

    python3 tools/generate_show.py
    W=1440 H=900 COLS=22 python3 tools/generate_show.py

Writes examples/timeline_show.json and Sources/DPECore/Resources/timeline.json.

The recut's seconds were read off a video whose clock starts ~9 s before the music;
shifted back by RECUT_SHIFT they land on the phrase starts. `WAS` keeps the original
numbers so the printout shows each cue against where the recut fired it.

The track is twelve 8-bar PHRASES, each verified in the audio; `PHRASES` is the bar
each starts on. Every cue is a position INSIDE a phrase — `(phrase, bars in, beats
in)` — so moving a phrase moves its cues without touching the next one. The engine
runs in beats; the cue sheet is in FRAMES at 30 fps because that is what the app's
transport shows. This script prints every cue's frame; those must match docs/CUES.md.

The lyric is timed by `tools/lyrics.py` (the sung words, in beats from the lyric's own
zero, which sits CHORUS_LEAD before the phrase's downbeat); the spiral (cue 9) and the
desktop words (cue 12) both read that list, so tuning a word moves both.

Seeded, so the show is identical take to take.
"""
import json, math, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_horse import PALETTE, build_frames, horse_event
import lyrics

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
W = int(os.environ.get("W", "1440"))
H = int(os.environ.get("H", "900"))
# The horse: grid columns and how much of the screen it spans. 22 columns is 63
# windows at the widest frame — under the ~70 where the pool starts to lag.
HORSE_COLS = int(os.environ.get("COLS", "22"))
HORSE_SPAN = float(os.environ.get("SPAN", "0.96"))
# "flyover" is Apple's 3-D mode with no labels, "hybrid" the same imagery WITH labels,
# "standard" the plain vector map — the same MKMapView either way.
MAP_STYLE = os.environ.get("MAP_STYLE", "hybrid")
AUDIO = "assets/03 - Give it 2 me.mp3"

# The lyric cards' two colours. Cards alternate ground/type between them.
BLUE = "#0078D7"
WHITE = "#F2F4FE"
BLACK = "#000000"

# The signature blue: PALETTE[1], the blue the horse and the strobe are built from —
# NOT the lighter #0078D7 the lyric cards use.
DJ_BLUE = "#020AF5"

# --- the tempo map, straight from the analysis ---
with open(os.path.join(ROOT, "assets", "track_analysis.json")) as f:
    analysis = json.load(f)
BPM = analysis["bpm"]                  # 128.5
OFFSET = analysis["firstDownbeat"]     # 0.395 — beat 0 sits on the first downbeat
BEAT = 60.0 / BPM
KICKS = analysis["kicks"]
DURATION = analysis["duration"]        # 169.85 — the last two cues are past this

# One desktop swap takes ~300 ms to land (WallpaperController, measured) — anything
# that must be SEEN on a beat is applied this early.
DESK_LATENCY = 0.30

def secs(beat):
    """Absolute seconds for a timeline beat (matches the loader's beat→time math)."""
    return OFFSET + beat * BEAT

# docs/CUES.md and this script's printout are in frames. 30 fps is not an engine
# property — it is the rate the app's transport counts in (`MainWindowController.fps`),
# so a frame number here is the number on the scrubber. Change one, change the other.
FPS = 30

def frame_at(t):
    """The frame the transport shows at second `t`. NOT named `frame`: `lyric_card`
    and `placeholder` take a `frame` argument that would shadow it."""
    return int(t * FPS)

# =============================================================================
# THE PHRASES — the track's twelve 8-bar phrases, each verified in the audio (per-bar
# loudness, bass and vocal energy, kicks; 2026-08-28). docs/CUES.md carries the same
# table. Bars count from the first downbeat; bar 17 is the drop.
# =============================================================================
PHRASES = {
    "introA":         1,     #  0:00.40
    "introB":         9,     #  0:15.34
    "chorus1A":      17,     #  0:30.28  THE DROP — vocals in; the hook lands in bar 22
    "chorus1B":      25,     #  0:45.22  the lyric again; the hook in bar 30
    "bridgeA":       33,     #  1:00.16  vocals out, the beat carries
    "bridgeB":       41,     #  1:15.10  vocals back
    "breakdown":     49,     #  1:30.04  bass leaves at 52, the kicks stop 53–55
    "instrumentalA": 57,     #  1:44.99  full beat, no vocals
    "instrumentalB": 65,     #  1:59.93  the vocal pickup returns in bar 72
    "chorus2A":      73,     #  2:14.87  vocals in; the hook in bar 78
    "chorus2B":      81,     #  2:29.81  the hook in bar 86, right before the break
    "break":         87,     #  2:41.02  everything stops; the file ends 2:49.85
}
def phrase_beat(name):
    return (PHRASES[name] - 1) * 4

# =============================================================================
# THE CUE LIST — docs/CUES.md. Every cue is (phrase, bars in, beats in); (p, 0, 0) is
# the phrase's downbeat, the changeover; (chorus, -1, 0) is the bar before it, where the
# vocal comes in ("what I want"). Every hook is at (chorus, 5, 0). Beats may be halves. `WAS` is the
# recut's authored second for each cue (whole seconds, snapped to the nearest beat),
# kept so the printout shows exactly what moved and by how much.
# =============================================================================
CUES = {
    "blue":       ("introA",        0, 0),   #  1  intro gate + the desktop goes DJ blue
    "restore":    ("introA",        2, 0),   #  2  blue goes, the viewer's own wallpaper is back (beat 8)
    "welcome":    ("introA",        2, 2),   #  3  the welcome terminal (beat 10)
    "probe":      ("introB",        0, 0),   #  4  the system probe
    "hydra":      ("introB",        3, 0),   #  5  sketches dragged onto the screen
    "blue2":      ("introB",        7, 1),   #  6  blue again — the bar before the drop
    "face":       ("chorus1A",      0, 0),   #  7  THE DROP: the desktop becomes pixelface.jpg
    "traveller":  ("chorus1A",      0, 0),   #  8  one window up and down, trailing windows
    "spiral":     ("chorus1A",      0, 0),   #  9  the drop: the spiral of lyrics, every phrase on its sung line
    "video1":     ("chorus1A",      4, 1),   # 10  placeholder for a video
    "tbd_048":    ("chorus1A",      4, 3),   # 11  TBD — deliberately empty
    "words":      ("chorus1B",      0, 0),   # 12  the whole lyric on the desktop, word by word as sung
    "torus1":     ("bridgeA",       0, 0),   # 13  vocals out: the magic torus introduces itself
    "map":        ("bridgeB",       0, 0),   # 14  vocals back: Apple Maps onto the viewer's location
    "fill":       ("bridgeB",       1, 2),   # 15  windows start filling the screen
    "black":      ("bridgeB",       7, 0),   # 16  the bar before the breakdown: desktop to black
    "tbd_099":    ("breakdown",     0, 0),   # 17  the GLSL raymarcher
    "booth":      ("breakdown",     4, 0.5), # 18  the kicks stop: Photo Booth; 3·2·1 a bar apart, the shutter on `wall`
    "wall":       ("breakdown",     7, 0.5), # 19  the bass hits back in (an "and", half a beat into bar 56): shutter + the photo wall
    "facestrobe": ("instrumentalA", 2, 1),   # 20  pixelface strobes over the wall
    "horse":      ("instrumentalA", 3, 1),   # 21  everything cuts; the horse
    "torus2":     ("instrumentalA", 6, 0),   # 22  glass torus + a circle of lyric windows
    "video2":     ("instrumentalA", 7, 2),   # 23  the video placeholder on top of all of it
    "video3":     ("instrumentalB", 0, 0),   # 24  cut to black, video placeholder alone on it
    "tbd_136":    ("instrumentalB", 3, 3),   # 25  everything cuts; TBD
    "spinner":    ("instrumentalB", 4, 3),   # 26  TBD + the mouse spinner
    "spam":       ("chorus2A",     -1, 0),   # 27  the vocal pickup bar (72): a ton of crazy UI windows
    "glitch":     ("chorus2B",     -1, 0),   # 28  the vocal pickup bar (80): the eruption + the strobe, straight in
    "allglitch":  ("chorus2B",      4, 0),   # 29  PULLED — was the lyric desktop under the strobe; the slot keeps its number
    "lastwords":  ("break",         0, -1),  # 30  everything stops at 160.6 and closes on the silence
    "ending":     ("break",         0, -1),  # 31  the stop IS the end card — no lyric section after the music
}
# The recut's authored seconds, and the clock they were read on: a video with ~9 s of
# boot-up before the music. `WAS - RECUT_SHIFT` is where each cue sits in the track.
RECUT_SHIFT = 9.0
WAS = {"blue": 0.0, "restore": 16.0, "welcome": 18.0, "probe": 25.0, "hydra": 30.0,
       "blue2": 38.0, "face": 39.0, "traveller": 39.5, "spiral": 43.0, "video1": 47.0,
       "tbd_048": 48.0, "words": 54.0, "torus1": 69.0, "map": 84.0, "fill": 87.0,
       "black": 97.0, "tbd_099": 99.0, "booth": 107.0, "wall": 114.0, "facestrobe": 118.0,
       "horse": 120.0, "torus2": 125.0, "video2": 128.0, "video3": 129.0, "tbd_136": 136.0,
       "spinner": 138.0, "spam": 143.0, "glitch": 158.0, "allglitch": 167.0,
       "lastwords": 171.0, "ending": 174.0}
B = {name: phrase_beat(p) + bars * 4 + beats for name, (p, bars, beats) in CUES.items()}
# A cue may sit up to a bar BEFORE its phrase: the vocal pickup bar of a chorus, or the
# beat before a stop so a wallpaper swap is seen on it. Never past the phrase's end.
for name, (p, bars, beats) in CUES.items():
    assert -4 <= bars * 4 + beats < 32 or p == "break", f"{name}: {bars} bars {beats} beats is outside {p}"

# --- the lyric's clock ---
# lyrics.CUES counts beats from the lyric's own zero: "what I want", the pickup, sung
# one bar before the chorus's downbeat. CHORUS_LEAD is that lead in seconds — the
# artist tuned CUES with the cards starting 1 s before bar 17.
CHORUS_LEAD = 1.0
def lyric_zero(phrase):
    return phrase_beat(phrase) - CHORUS_LEAD / BEAT
def lyric_beat(zero, when):
    """A lyrics.py cue → absolute beat: beats from the lyric's zero, or a "34.10s" track time."""
    if isinstance(when, str) and when.endswith("s"):
        return (float(when[:-1]) - OFFSET) / BEAT
    return zero + when
phrases = lyrics.phrase_cues()             # [(when, phrase, line)], timed off the tuned words
phrase_texts = [p for _, p, _ in phrases]
n_cue = len(phrases)
HOOK_AT = next(when for when, _, line in phrases if line == 6)   # "I told you that I", second time

events = []
def add(beat, typ, params):
    events.append({"beat": round(beat, 3), "type": typ, "params": params})
def add_t(t, typ, params):
    events.append({"t": round(t, 3), "type": typ, "params": params})

def kicks_between(b0, b1):
    """Kick times (absolute seconds) inside [beat b0, beat b1)."""
    return [kt for kt in KICKS if secs(b0) <= kt < secs(b1)]

def fullscreen():
    return [0, 0, 0, 0]          # w/h of 0 stretch to the far edge on any display

def lyric_card(wid, beat, text, i, frame=None, chrome="none", animate="none", anchor=None):
    """One lyric-video frame. `i` alternates the ground/type between blue and white."""
    blue_ground = (i % 2 == 0)
    params = {"id": wid, "frame": frame or fullscreen(),
              "content": {"kind": "lyric", "text": text,
                          "hex": BLUE if blue_ground else WHITE,
                          "fg": WHITE if blue_ground else BLUE,
                          "chrome": chrome, "title": "give it 2 me — lyrics"},
              "animate": {"kind": animate}}
    if anchor:
        params["anchor"] = anchor
    add(beat, "openWindow", params)

def placeholder(wid, beat, label, frame, hex=BLACK, fg=WHITE, anchor="center",
                title=None, animate="springIn"):
    """A labelled stand-in for content that isn't made yet. Deliberately legible: a
    slot that looks finished is a slot nobody fills — see Gaps in docs/CUES.md."""
    params = {"id": wid, "frame": frame,
              "content": {"kind": "text", "text": label, "hex": hex, "fg": fg,
                          "fontSize": 26, "chrome": "mac",
                          "title": title or "placeholder"},
              "animate": {"kind": animate}}
    if anchor:
        params["anchor"] = anchor
    add(beat, "openWindow", params)

VIDEO_LABEL = "[ video goes here ]\n\nplaceholder — single video, centre screen"
# Cues 23 and 24 still hold this slot open (cue 10 is the fireworks now), so the size
# lives here rather than in whichever cue is first.
VIDEO_W, VIDEO_H = round(W * 0.34), round(H * 0.32)

# =============================================================================
# Cue 1 (0:00) — THE BLUE. The desktop takes the signature blue; the duration IS cue 2:
# when the deskWallpaper expires, WallpaperController puts the viewer's own picture
# back. Gated on `meta.allowWallpaper`; the snapshot is taken before the first swap and
# restored on stop, panic and quit as well.
# =============================================================================
# Clear the stage: other apps are hidden, not minimised — `unhide` puts each window
# back exactly where it was, on stop/panic too.
add(0, "hideOtherApps", {"id": "apps"})
add(0, "deskWallpaper", {"id": "desk", "mode": "solid", "hex": DJ_BLUE,
                         "durationSeconds": round(secs(B["restore"]) - secs(0), 3)})

# =============================================================================
# Cue 2 (beat 8) — the blue goes and the viewer's own desktop is underneath it.
# setDesktopImageURL has no fade and takes ~300 ms, so a white wash covers the swap.
# =============================================================================
add(B["restore"], "screenFlash", {"color": WHITE, "durationBeats": 0.5})

# =============================================================================
# Cue 3 (beat 10) — the welcome. A Terminal window that types itself out, one line a
# beat — the same surface and cadence as the end card's credits. `⌃⌥⌘Esc` stays the
# last line the viewer reads before anything starts moving.
# =============================================================================
WELCOME_LINES = [
    "$ ./giveit2me --install",
    "installing ......................... done",
    "",
    "DJ_Dave — GiveIt2Me, as software.",
    "for one song this computer is the video:",
    "its windows, its cursor, its wallpaper,",
    "its photos, and one new photo of you.",
    "all of it borrowed. all of it put back.",
    "",
    "⌃⌥⌘Esc gives the computer back early.",
    "",
    "$ ./giveit2me --play",
]
WELCOME = "\n".join(WELCOME_LINES)
# One line a beat — CREDITS_LPS is the same rate in the other unit. The copy has to
# FINISH before cue 4 takes the window away, so the fit is asserted rather than eyeballed:
# rewriting it either fits in the gap or fails the build.
WELCOME_LPB = 1.0
WELCOME_HOLD = 2                              # beats the finished card sits before the probe
assert len(WELCOME_LINES) / WELCOME_LPB + WELCOME_HOLD <= B["probe"] - B["welcome"], (
    f"welcome copy: {len(WELCOME_LINES)} lines at {WELCOME_LPB}/beat does not finish "
    f"{WELCOME_HOLD} beats before the probe ({B['probe'] - B['welcome']:g} beats of room)")
# Sized to the copy (cf. CreditsController.rollSize). SF Mono advances 0.6 em, lines
# set at ~1.25 em. A line that does not fit WRAPS, which reads as a bug in a window
# pretending to be Terminal — so the width is measured, not guessed.
def mono_cols(line):
    """Columns a line occupies in SF Mono: one per ASCII glyph, two for the symbols
    (— ⌃⌥⌘) this copy uses, which are drawn at roughly double width."""
    return sum(1 if ord(c) < 128 else 2 for c in line)
WELCOME_PT = 20
WELCOME_W = round((max(mono_cols(l) for l in WELCOME_LINES) + 4) * WELCOME_PT * 0.6 + 24)
WELCOME_H = round((len(WELCOME_LINES) + 2) * WELCOME_PT * 1.25 + 40)
add(B["welcome"], "typeText", {
    "id": "welcome",
    "frame": [round((W - WELCOME_W) / 2), round((H - WELCOME_H) / 2), WELCOME_W, WELCOME_H],
    "text": WELCOME, "chrome": "terminal", "linesPerBeat": WELCOME_LPB,
    "fontSize": WELCOME_PT, "interactive": True})

# =============================================================================
# Cue 4 (0:25) — the welcome window goes and the probe opens, typing out what the
# machine knows about whoever is sitting at it. The report is long, so the rate is set
# from the gap to the end of the hydra act rather than picked.
# =============================================================================
add(B["probe"], "closeWindow", {"id": "welcome"})
# The frame is the OUTER one, title bar included — the report wears real macOS chrome
# and is named for the command that produced it.
PROBE_FRAME = [round(W * 0.18), round(H * 0.08), round(W * 0.64), round(H * 0.84)]
add(B["probe"], "systemProbe", {"id": "probe", "linesPerBeat": 6, "frame": PROBE_FRAME,
                                "title": "./scan_identity"})

# =============================================================================
# Cue 5 (0:30) — a hydra sketch is dragged onto the screen, pulled bigger by its
# corner, and run; two more arrive on the downbeats. The window and the pointer travel
# together on every leg — that is what makes it read as a drag. It plays to the LEFT
# of the probe's terminal, which owns the middle of the screen until 0:38.
# =============================================================================
PATCHES = [
    ("osc(10, 0.1, 300)\n  .color(0.2, 0.9, 1)\n  .diff(\n    osc(10, 0.1, 1)\n    .color(0.9, 0.1, 1)\n    .rotate(()=>time*0.4)\n    .kaleid()\n  )\n  .scrollY(()=>-time * 0.5)\n  .colorama()\n  .luma()\n  .color(0.7, 0.2, 2)\n  .repeat(4)\n  .modulate(o0, 0.1)\n  .scale(2)\n  .out()", "hydra.ojack.xyz"),
    ("osc(10, 0.01, 1.4)\n    .rotate(0, 0.4)\n    .mult(osc(10, 1).modulate(osc(10).rotate(0, -0.1), 1)).colorama().luma()\n    .color(0.1,0.9,3)\n    .scrollX(()=>time*0.1)\n    .pixelate(100)\n  .out()", "hydra.ojack.xyz"),
    ("osc(4,0.7).color(0,0.8,10)\n  .pixelate(60)\n  .kaleid()\n  .rotate(0, 0.2).modulate(o0,0.9)\n  .out()", "hydra.ojack.xyz"),
    ("shape(6, 0.9, 0.01)\n  .repeat(4, 3)\n  .rotate(0, 0.02).pixelate(100)\n  .modulate(osc(10, 0.08).rotate(0, -0.01), 0.5)\n  .color(0.1, 0.5, 3)\n  .modulate(o0,0.02)\n .out()", "hydra.ojack.xyz"),
    ("shape(3, 0.6, 0.02)\n  .kaleid(8)\n  .rotate(()=>time*0.08)\n  .diff(shape(3, 0.45, 0.02).kaleid(8).rotate(()=>-time*0.05))\n  .color(0.3, 0.7, 2.5)\n  .pixelate(120)\n  .out()", "hydra.ojack.xyz"),
    ("noise(3, 0.1)\n  .rotate(1, -0.2)\n  .colorama(0.5)\n  .kaleid(3)\n  .out()", "hydra.ojack.xyz"),
]

def hydra_window(wid, beat, frame, patch, running, animate="none", interactive=True):
    src, title = patch
    add(beat, "openWindow", {"id": wid, "frame": [round(v) for v in frame],
        "content": {"kind": "livecode", "text": src, "title": title,
                    "chrome": "browser", "hex": "#68BDF8", "running": running},
        "animate": {"kind": animate},
        "interactive": interactive, "respawn": interactive})

# PULLED from the cut for now (2026-09-01) — kept behind HYDRA_ACT for when it returns.
# The hand-built hydra sketch itself lives on in the show: it moved to the breakdown,
# where it is set up over the raymarcher (cue 17).
HYDRA_ACT = False
hydra_ids = []
if HYDRA_ACT:
    hy = B["hydra"]
    DRAG_ID = "hy0"
    hydra_ids = [DRAG_ID]

    # 1. it appears, small, code written but NOT running
    d_small = (round(W * 0.04), round(H * 0.18), 320, 200)
    hydra_window(DRAG_ID, hy, d_small, PATCHES[1], running=False, animate="springIn")

    # 2. the cursor takes it by the title bar and hauls it down the screen
    d_grab = (d_small[0] + d_small[2] * 0.5, d_small[1] + 12)
    add(hy + 1, "cursorPath", {"path": "linear", "durationBeats": 1.2, "easing": "easeInOut",
        "mode": "warp", "points": [[round(W * 0.02), round(H * 0.08)],
                                   [round(d_grab[0]), round(d_grab[1])]]})
    d_lift = (round(W * 0.05), round(H * 0.48), d_small[2], d_small[3])
    add(hy + 2.4, "moveWindow", {"id": DRAG_ID, "frame": [d_lift[0], d_lift[1]],
        "durationBeats": 1.6, "easing": "easeInOut"})
    add(hy + 2.4, "cursorPath", {"path": "linear", "durationBeats": 1.6, "easing": "easeInOut",
        "mode": "warp", "points": [[round(d_grab[0]), round(d_grab[1])],
                                   [round(d_lift[0] + d_small[2] * 0.5), round(d_lift[1] + 12)]]})

    # 3. resize by the LOWER-RIGHT CORNER: the top-left stays put and the window grows down
    # and to the right, so the code never moves off its corner.
    d_corner = (d_lift[0] + d_lift[2], d_lift[1] + d_lift[3])
    d_big = (d_lift[0], d_lift[1], round(W * 0.28), round(H * 0.32))
    d_new_corner = (d_big[0] + d_big[2], d_big[1] + d_big[3])
    add(hy + 4.2, "cursorPath", {"path": "linear", "durationBeats": 1.0, "easing": "easeInOut",
        "mode": "warp", "points": [[round(d_lift[0] + d_small[2] * 0.5), round(d_lift[1] + 12)],
                                   [round(d_corner[0]), round(d_corner[1])]]})
    add(hy + 5.4, "moveWindow", {"id": DRAG_ID,
        "frame": [d_big[0], d_big[1], d_big[2], d_big[3]],
        "durationBeats": 1.8, "easing": "easeOut"})
    add(hy + 5.4, "cursorPath", {"path": "linear", "durationBeats": 1.8, "easing": "easeOut",
        "mode": "warp", "points": [[round(d_corner[0]), round(d_corner[1])],
                                   [round(d_new_corner[0]), round(d_new_corner[1])]]})
    # Re-open at the final size once the drag settles: the layout stretched during the
    # resize gets rebuilt cleanly at the new dimensions. Still not running.
    hydra_window(DRAG_ID, hy + 7.4, d_big, PATCHES[1], running=False)

    # 4. up to hydra's run button, top-right — and the sketch starts.
    d_play = (d_big[0] + d_big[2] - 26, d_big[1] + 34)
    add(hy + 7.6, "cursorPath", {"path": "linear", "durationBeats": 1.2, "easing": "easeInOut",
        "mode": "warp", "points": [[round(d_new_corner[0]), round(d_new_corner[1])],
                                   [round(d_play[0]), round(d_play[1])]]})
    HYDRA_RUN = hy + 9.0
    hydra_window(DRAG_ID, HYDRA_RUN, d_big, PATCHES[1], running=True)
    add(HYDRA_RUN, "screenFlash", {"color": "#68BDF8", "durationSeconds": 0.06})

    # …and two more, already running, on the downbeats — right-hand side, clear of
    # both the probe and the dragged window.
    for i, (dx, dy, s) in enumerate([(0.62, 0.10, 0.30), (0.70, 0.52, 0.26)], start=1):
        wid = f"hy{i}"
        hydra_ids.append(wid)
        beat = HYDRA_RUN + 2 + 2 * (i - 1)
        hydra_window(wid, beat, (round(W * dx), round(H * dy),
                                 round(W * s), round(H * s * 1.05)),
                     PATCHES[(i + 1) % len(PATCHES)], running=True, animate="springIn")

# =============================================================================
# Cue 6 (0:38) — the desktop goes blue again, and the screen is cleared for it.
# No duration: cue 7 replaces it a beat later. An expiry would restore the viewer's
# picture for the two frames before the face lands — a flicker of the wrong image.
# =============================================================================
for wid in hydra_ids + ["probe"]:
    add(B["blue2"] - 0.2, "closeWindow", {"id": wid})
add(B["blue2"], "deskWallpaper", {"id": "desk2", "mode": "solid", "hex": DJ_BLUE})
add(B["blue2"], "screenFlash", {"color": WHITE, "durationBeats": 0.4})

# =============================================================================
# Cue 7 (0:39) — and then the desktop is the face.
# `slides` with one image, so it goes through the same controller and is restored the
# same way. hz far below one: the list never advances, so every tick past the first is
# a ~300 ms window-server round-trip for an identical picture.
# =============================================================================
# The face is a prebuilt WALLPAPER written to assets/: a blue field with the face small
# in the middle. The ground is the artwork's OWN field colour, sampled from the file
# (a shade off cue 6's DJ blue), so the face has no visible edge on it.
FACE_GROUND = "#001FFD"
FACE_DESKTOP = "assets/pixelface_desktop.jpg"
FACE_SHARE = 0.20                  # the face's height, as a fraction of the wallpaper's

def build_face_desktop():
    """Write the cue 7 wallpaper. 2560x1600 -- 16:10, the aspect of the Macs this plays
    on. `setDesktopImageURL` is handed it with `scaleAxesIndependently`, so a display of
    a different shape stretches it; at this aspect that is a few percent on a face that
    is mostly flat colour, and invisible."""
    from PIL import Image
    out = os.path.join(ROOT, FACE_DESKTOP)
    src = Image.open(os.path.join(ROOT, "assets/pixelface.jpg")).convert("RGB")
    canvas_w, canvas_h = 2560, 1600
    ground = tuple(int(FACE_GROUND[i:i + 2], 16) for i in (1, 3, 5))
    canvas = Image.new("RGB", (canvas_w, canvas_h), ground)
    # NEAREST: the artwork is pixel art and every other appearance of it in the show is
    # hard-edged. Smoothing it here would make this the one soft one.
    h = round(canvas_h * FACE_SHARE)
    w = round(src.width * h / src.height)
    canvas.paste(src.resize((w, h), Image.NEAREST),
                 ((canvas_w - w) // 2, (canvas_h - h) // 2))
    canvas.save(out, quality=95)
    return w, h

FACE_W, FACE_H = build_face_desktop()
# Applied 2×DESK_LATENCY early so the swap has FINISHED before the drop: fired on the
# beat it landed late, and fired 300 ms early it was still mid-swap while the drop's 21
# window opens hit — the WindowServer paid for both at once and the whole entrance
# stuttered. Landing ~0.3 s early on an already-blue field reads as anticipation.
# (the cue is authored at the phrase line; the event leads it to cover the swap).
add_t(secs(B["face"]) - 2 * DESK_LATENCY, "deskWallpaper",
      {"id": "face", "mode": "slides", "hz": 0.1, "images": [FACE_DESKTOP]})

# =============================================================================
# Cue 8 (0:30.28) — one window travels up and down the screen, dragging a trail.
#
# The trail is a DELAY LINE: TRAIL_LINKS identical copies walk the identical path, each
# 1% of the screen further left and one frame further behind — delayed copies of the
# SAME path, NOT followers, because the show scrubs: a follower has no answer when the
# playhead jumps, while a delayed copy of an eased path is a pure function of show time
# and lands identically every take. `beginMove` reads each window's CURRENT frame as
# the base of its next move, so the chain never snaps. TRAIL_LINKS is the dial if this
# section ever stutters. Closed together at cue 12.
# =============================================================================
tv = B["traveller"]
TRAVEL_W, TRAVEL_H = round(W * 0.20), round(H * 0.22)
y_top, y_bot = round(H * 0.06), round(H - TRAVEL_H - H * 0.06)

LEG = 1.75                                   # beats for one traverse of the screen
TRAIL_LINKS = 20
TRAIL_DX = W * 0.01                          # each link 1% of the screen to the left
TRAIL_LAG = 1.0 / (FPS * BEAT)               # …and one frame at 30 fps behind, in beats

# The chain hangs to the LEFT of the leader; centring the ASSEMBLY puts the leader
# right of centre by half the chain's span.
CHAIN_SPAN = TRAIL_LINKS * TRAIL_DX
tx = round((W - TRAVEL_W + CHAIN_SPAN) / 2)

# It travels for as long as it is on screen: the end is pinned off cue 12 rather than
# a fixed bar count, and the margin is asserted below once the close time is known.
TRAVEL_END = B["words"] - 3
legs, b, leg = [], tv, 0
while b + LEG <= TRAVEL_END:
    legs.append(y_top if leg % 2 == 0 else y_bot)
    leg += 1
    b += LEG

TRAVELLER_CONTENT = {"kind": "code", "text": lyrics.code(0), "chrome": "terminal",
                     "title": "give_it_2_me.js"}

# Windows stack in the order they are PRESENTED and the event format carries no z-order,
# so the opens are staggered — deepest link first, leader last. Not 21 events on one
# beat: Swift's `sorted(by:)` is not guaranteed stable and a tie would bury the leader;
# each open must land before its window's first `moveWindow` (`beginMove` drops moves
# for unopened ids), hence the cluster sits just BEFORE `tv`; and 21 × 0.001 beats is
# 10 ms, still on the beat. The step is one unit of `add`'s 3-decimal rounding —
# anything finer rounds adjacent opens back onto the same beat.
OPEN_STEP = 0.001
trail_ids = [f"tr{k}" for k in range(1, TRAIL_LINKS + 1)]
for k in reversed(range(1, TRAIL_LINKS + 1)):
    add(tv - (k + 1) * OPEN_STEP, "openWindow", {
        "id": f"tr{k}",
        "frame": [round(tx - k * TRAIL_DX), y_bot, TRAVEL_W, TRAVEL_H],
        "content": TRAVELLER_CONTENT,
        "animate": {"kind": "none"}})
add(tv - OPEN_STEP, "openWindow", {"id": "traveller",
    "frame": [tx, y_bot, TRAVEL_W, TRAVEL_H],
    "content": TRAVELLER_CONTENT,
    "animate": {"kind": "springIn"}, "interactive": True})

for i, to_y in enumerate(legs):
    b = tv + i * LEG
    add(b, "moveWindow", {"id": "traveller", "frame": [tx, to_y],
                          "durationBeats": LEG, "easing": "easeInOut"})
    for k in range(1, TRAIL_LINKS + 1):
        add(b + k * TRAIL_LAG, "moveWindow", {
            "id": f"tr{k}", "frame": [round(tx - k * TRAIL_DX), to_y],
            "durationBeats": LEG, "easing": "easeInOut"})
# The deepest link's last leg fires TRAIL_LINKS frames after the leader's, so the chain
# is still catching up after the leader has stopped.
TRAIL_LAST_MOVE = tv + (len(legs) - 1) * LEG + TRAIL_LINKS * TRAIL_LAG

# =============================================================================
# Cue 9 (0:43) — the spiral of lyrics, one card per lyric cue, winding out from the
# middle. Authored from the screen's CENTRE (`anchor: center`) — top-left frames would
# put the origin off-centre on a bigger display. The innermost radius clears the
# middle, because cue 10 parks the video placeholder there.
# =============================================================================
sp = B["spiral"]
zero_1A = lyric_zero("chorus1A")
# Chorus 1A's whole lyric, each card landing ON its sung phrase — INCLUDING the pickup
# ("what I want"), which lands on its sung line a second before the drop. Clamping it
# to the cue used to double-land cards 0 and 1 on the drop's busiest instant (21
# traveller windows + the face swap), which smeared the spiral's opening. ALL CAPS —
# the sung line as a shout (every `lyric` card is already Hack-Bold).
spiral_phrases = [(when, text.upper()) for when, text, _ in phrases]
n_sp = len(spiral_phrases)
CARD_W, CARD_H = round(W * 0.24), round(H * 0.16)
r0, r1 = min(W, H) * 0.16, min(W, H) * 0.46
spiral_ids = []
for i, (when, text) in enumerate(spiral_phrases):
    u = i / max(1, n_sp - 1)
    ang = -math.pi / 2 + 2.4 * math.pi * u          # a bit over one full turn
    r = r0 + (r1 - r0) * u
    wid = f"sp{i}"
    spiral_ids.append(wid)
    lyric_card(wid, lyric_beat(zero_1A, when), text, i,
               frame=[round(r * math.cos(ang) * 1.35), round(r * math.sin(ang)),
                      CARD_W, CARD_H],
               chrome="mac", animate="springIn", anchor="center")

# =============================================================================
# Cue 10 (0:38) — the desktop throws itself into the air: `fileworks`, shells bursting
# into desktop file icons, on a TRANSPARENT full-screen window with no ground of its
# own so the spiral stays visible through it. Up from here to cue 13 — about one shell
# a second keeps each burst legible; cue 12 closes it with the spiral.
add(B["video1"], "openWindow", {
    "id": "video", "frame": fullscreen(),
    "content": {"kind": "fileworks", "seed": 1046, "hz": 1.0, "intensity": 1.0,
                "chrome": "none", "title": "Desktop"},
    "animate": {"kind": "none"}})

# =============================================================================
# Cue 11 (0:48) — TBD. Deliberately empty: the author has not decided, and a filler
# event here would have to be found and removed later. The gap is the note.
# =============================================================================

# =============================================================================
# Cue 12 (0:54) — the lyric on the desktop itself: the spiral, the traveller and the
# fireworks all go, one word per wallpaper card. The window server tops
# out near 3 Hz and the controller drops whole ticks rather than queueing them, so the
# words play slower than authored but never skip and never outlive the event.
# =============================================================================
wd = B["words"]                     # chorus 1B; the run starts on the pickup, one bar before
zero_1B = lyric_zero("chorus1B")

# The cards, one file per word as it is sung (RUNNIN, CANT, 2) in assets/lyrics_desktops.
# A cue whose whole text has a card ("NEED YOUR LOVE.jpg") is one card; otherwise its
# words are spread evenly to the next cue, one card each. A word with no file is skipped
# — the previous word holds — and listed below, so a new cue is never a silent gap.
WORDS_DIR = "assets/lyrics_desktops"
def word_key(word):
    key = word.upper().replace("’", "").replace("'", "").strip(".,!?:;")
    return {"RUNNING": "RUNNIN", "TO": "2"}.get(key, key)
def card_path(key):
    path = f"{WORDS_DIR}/{key}.jpg"
    return path if os.path.exists(os.path.join(ROOT, path)) else None
def cue_cards(text):
    words = text.split()
    if len(words) > 1:
        whole = card_path(" ".join(word_key(w) for w in words))
        if whole:
            return [(text, whole)]
    return [(w, card_path(word_key(w))) for w in words]

# The schedule: the whole lyric (lyrics.CUES, 32 beats) at chorus 1B's position, each
# word applied DESK_LATENCY early so the ~300 ms swap lands ON the word as it is sung.
lyric_end = zero_1B + 32
word_times = [lyric_beat(zero_1B, when) for when, _ in lyrics.CUES] + [lyric_end]
word_slides, words_missing, words_interpolated = [], [], []
for k, (when, text) in enumerate(lyrics.CUES):
    b0, b1 = word_times[k], word_times[k + 1]
    cards = cue_cards(text)
    if len(cards) > 1:
        words_interpolated.append(text)
    for j, (label, img) in enumerate(cards):
        if img is None:
            if word_key(label) not in words_missing:
                words_missing.append(word_key(label))
            continue
        word_slides.append((secs(b0 + (b1 - b0) * j / len(cards)), img))
if not word_slides:
    sys.exit("CHORUS 1B: no desktop word has a card")
words_first = word_slides[0][0]
words_event_at = words_first - DESK_LATENCY
words_event_beat = (words_event_at - OFFSET) / BEAT
# The traveller runs until cue 12 takes it away — so the last leg, INCLUDING the deepest
# link's lag, has to land before the close. Pinned rather than eyeballed: retime cue 12
# and this fails the build instead of silently cutting the chain off mid-leg.
assert TRAIL_LAST_MOVE + LEG <= words_event_beat - 0.2, (
    f"traveller: last trail leg ends at beat {TRAIL_LAST_MOVE + LEG:.2f}, after the "
    f"close at {words_event_beat - 0.2:.2f}")
# The fireworks go too (no embers): a transparent full-screen window with live
# particles keeps the compositor repainting the whole screen every frame, and under
# the ~300 ms wallpaper swaps it dragged the words — and everything after them.
for wid in spiral_ids + trail_ids + ["traveller", "video"]:
    add(words_event_beat - 0.2, "closeWindow", {"id": wid})
add_t(words_event_at, "deskWallpaper", {
    "id": "words", "mode": "slides",
    "images": [img for _, img in word_slides],
    "at": [round(t - words_first, 3) for t, _ in word_slides],
    "durationSeconds": round(secs(B["torus1"]) - words_event_at, 3)})

# =============================================================================
# Cue 13 (1:09) — the magic torus introduces itself in typed text, then actually asks:
# the `oracle` is the only window in the piece allowed to take the keyboard — without
# it the torus makes an offer the show cannot honour. They flank the torus, greeting
# bottom-right, question bottom-left.
# =============================================================================
t1 = B["torus1"]
add(t1, "screenFlash", {"color": WHITE, "durationBeats": 0.5})
TORUS_SIZE = round(min(W, H) * 0.58)
add(t1, "glassTorus", {"id": "torus", "material": "glass", "speed": 0.8,
                       "size": TORUS_SIZE})
GREETING = ("Greetings, I am the magic torus. I rotate infinitely around an axis in "
            "the 3D plane, thus I am all knowing... ask me anything")
GREETING_CPB = 11
# The greeting sits fully to the RIGHT of the torus window, taking what is left of the
# screen past its edge.
GREET_X = round((W + TORUS_SIZE) / 2 + W * 0.02)
add(t1 + 1, "typeText", {"id": "greeting",
    "frame": [GREET_X, round(H * 0.62), W - GREET_X - round(W * 0.02), round(H * 0.26)],
    "text": GREETING, "charsPerBeat": GREETING_CPB, "fontSize": 15,
    "title": "torus.txt — Edited", "interactive": True})

# A beat after the greeting has finished typing — derived from the copy, so rewriting
# the greeting moves the invitation with it.
ORACLE_AT = t1 + 1 + len(GREETING) / GREETING_CPB + 1
# Answered and read before the map cuts in at cue 14. A viewer who won't play cannot
# stall the show: it answers itself.
ORACLE_BEATS = 14
add(ORACLE_AT, "oracle", {"id": "oracle",
    "frame": [round(W * 0.04), round(H * 0.62), 460, 186],
    "title": "hey, i'm the magic torus", "body": "ask me a question",
    "placeholder": "will you give it 2 me?", "answerBeats": ORACLE_BEATS})

# The desktop goes back to blue under the torus. This REPLACES the words event before
# it expires — an expiry restores the viewer's own picture for a ~300 ms flicker — and
# leads the cue by DESK_LATENCY so the blue lands with the flash, not a swap after it.
add_t(secs(t1) - DESK_LATENCY, "deskWallpaper",
      {"id": "desk3", "mode": "solid", "hex": DJ_BLUE})

# =============================================================================
# Cue 14 (1:24) — Apple Maps, falling out of orbit onto the viewer's own location.
# =============================================================================
mp = B["map"]
for wid in ("torus", "greeting", "oracle"):
    add(mp - 0.3, "closeWindow", {"id": wid})
add(mp, "screenFlash", {"color": WHITE, "durationBeats": 0.3})
# The fallback when Location Services gives nothing: downtown Los Angeles. `here=True`
# overrides these whenever there IS a fix.
FALL = dict(lat=34.0522, lon=-118.2437)
DESCENT = dict(FALL, here=True, altitude=2_600_000, toAltitude=260,
               pitch=0, toPitch=62, heading=0, toHeading=30,
               seconds=round((B["black"] - mp) * BEAT - 1.0, 1), style=MAP_STYLE)
add(mp, "openWindow", {"id": "map0",
    "frame": [round(W * 0.10), round(H * 0.07), round(W * 0.80), round(H * 0.78)],
    "content": {"kind": "map", "chrome": "browser", "title": "maps://{ip}", "map": DESCENT},
    "animate": {"kind": "springIn"}, "interactive": True, "respawn": True})

# =============================================================================
# Cue 15 (1:27) — windows start opening and slowly fill the screen. The rate ramps
# from roughly one a bar to four a beat, walking outward from the centre.
# =============================================================================
fl = B["fill"]
fill_rng = random.Random(19)
fill_ids = []
codes = lyrics.CODE

# Three of the flat blue cards carry the piece's own tear — the cue 28 glitch pass run
# once over one of the show's own images — spread across the ramp. WHICH cards is a
# fixed set, not a roll, and the colour draw below still happens for every blue card
# even when its hex goes unused: `fill_rng` seeds the whole act's layout, so a draw
# added or skipped here would reshuffle every window after it.
GLITCH_BLUES = {1, 4, 8}
GLITCH_SOURCES = ["assets/pixelface.jpg", "assets/muybridge_horse.gif",
                  "assets/credits_tile.png"]

# ...and two more RUN a Wolfram elementary cellular automaton, computed by the engine
# (`AutomatonView`): it has to keep going for as long as the window is up, and it sizes
# its own grid to the window. `seed: 0` is a single live cell — the classic light cone.
# Rule 110 looks lopsided from one cell, so it takes a seeded random first row.
CA_CARDS = {
    2: dict(rule=30,  seed=0,   hz=14, title="rule_30"),
    6: dict(rule=110, seed=110, hz=10, title="rule_110"),
}

b, i, blue = fl, 0, 0
while b < B["black"] - 0.5:
    u = (b - fl) / (B["black"] - fl)                 # 0 → 1 across the act
    ring = 0.10 + 0.42 * u
    ang = i * 2.399963                                # golden angle: no two adjacent
    w = round(W * fill_rng.uniform(0.13, 0.24))
    h = round(w * fill_rng.uniform(0.58, 0.82))
    x = round(W / 2 + math.cos(ang) * W * ring - w / 2)
    y = round(H / 2 + math.sin(ang) * H * ring - h / 2)
    x = max(8, min(x, W - w - 8))
    y = max(8, min(y, H - h - 8))
    wid = f"fw{i}"
    fill_ids.append(wid)
    roll = fill_rng.random()
    if roll < 0.45:
        hexc = fill_rng.choice(PALETTE + ["#0B0E16"])   # drawn either way — see above
        if blue in CA_CARDS:
            ca = CA_CARDS[blue]
            add(b, "openWindow", {"id": wid, "frame": [x, y, w, h],
                "content": {"kind": "automaton", "rule": ca["rule"], "seed": ca["seed"],
                            "hz": ca["hz"], "fontSize": 9,
                            "chrome": "mixed", "title": ca["title"]},
                "animate": {"kind": "springIn"}, "interactive": True})
        elif blue in GLITCH_BLUES:
            g = sorted(GLITCH_BLUES).index(blue)
            add(b, "openWindow", {"id": wid, "frame": [x, y, w, h],
                "content": {"kind": "glitch", "path": GLITCH_SOURCES[g],
                            "intensity": round(0.45 + 0.18 * g, 2), "seed": 4100 + 17 * g,
                            "chrome": "mixed", "title": "recovered.jpg"},
                "animate": {"kind": "springIn"}, "interactive": True})
        else:
            add(b, "openWindow", {"id": wid, "frame": [x, y, w, h],
                "content": {"kind": "color", "hex": hexc,
                            "chrome": "mixed", "title": "look://again"},
                "animate": {"kind": "springIn"}, "interactive": True})
        blue += 1
    elif roll < 0.75:
        add(b, "openWindow", {"id": wid, "frame": [x, y, max(w, 300), h],
            "content": {"kind": "code", "text": lyrics.code(i), "chrome": "terminal",
                        "title": "haunt.sh"},
            "animate": {"kind": "none"}, "interactive": True})
    else:
        # No lyric popups in the fill (cut 2026-09-01): these slots are terminals now,
        # so the fill keeps its density without alert dialogs quoting the lyric. No
        # fill_rng draws added or removed — the layout of every other window holds.
        add(b, "openWindow", {"id": wid, "frame": [x, y, max(w, 300), h],
            "content": {"kind": "code", "text": lyrics.code(i), "chrome": "terminal",
                        "title": "haunt.sh"},
            "animate": {"kind": "none"}, "interactive": True})
    # 4 beats apart at the start, 0.25 at the end.
    b += 4 * (1 - u) ** 2 + 0.25
    i += 1

# =============================================================================
# Cue 16 (1:37) — the desktop goes black and the windows close one by one: a hard swap
# dressed as a fade (see cue 2), the closes staggered in the order the windows arrived.
# =============================================================================
bk = B["black"]
add(bk, "deskWallpaper", {"id": "dark", "mode": "solid", "hex": BLACK})
add(bk, "screenFlash", {"color": BLACK, "durationBeats": 0.6})
add(bk + 0.2, "closeWindow", {"id": "map0"})
# The closes cross the section line by a little: the raymarcher opens while the last
# stragglers are still leaving, instead of after a beat of emptied-screen dead air.
close_span = (B["tbd_099"] - bk) + 1.5
for i, wid in enumerate(fill_ids):
    add(bk + 0.2 + close_span * i / max(1, len(fill_ids) - 1), "closeWindow", {"id": wid})

# =============================================================================
# Cue 17 (1:30) — the artist's GLSL raymarcher, alone on the emptied screen until
# Photo Booth. The shader (`assets/shaders/graphic.frag`, second of the three in the
# artist's code.txt) has its feedback line commented out in their own source, so it
# needs only `u_time` and `u_resolution`. `drop` scales its internal time
# (`u_time * mix(1., 4., drop)`); the breakdown runs it at 0.
# =============================================================================
SHADER_W, SHADER_H = round(W * 0.52), round(H * 0.52)
add(B["tbd_099"], "openWindow", {
    "id": "tbd1", "anchor": "center",
    "frame": [0, 0, SHADER_W, SHADER_H],
    "content": {"kind": "shader", "path": "assets/shaders/graphic.frag", "drop": 0.0,
                "chrome": "mixed", "title": "graphic.frag"},
    "animate": {"kind": "springIn"}, "interactive": True})

# Somebody is still using the computer: over the raymarcher, one hydra sketch is set
# up BY HAND, taking its time — the cursor walks over first, the sketch spawns under
# it, gets hauled up by the title bar, pulled bigger by its corner, and run. It lives
# LOW on the LEFT: final frame (0.05W, 0.50H, 0.18W, 0.38H), whose right edge (331px
# at 1440) stops short of both the raymarcher and the booth frame (both start x≈346)
# so nothing overlaps the countdown. The patch is hy1's sketch from the pulled intro
# act (PATCHES[2]). It stays up (running) through the booth, cut with everything at
# cue 21.
hb = B["tbd_099"] + 1.5
h_spawn = (round(W * 0.05), round(H * 0.72), 240, 150)
h_grab = (h_spawn[0] + h_spawn[2] * 0.5, h_spawn[1] + 12)   # its title bar — the cursor is already there
# 1. the cursor walks to where the window is about to appear…
add(hb, "cursorPath", {"path": "linear", "durationBeats": 2.5, "easing": "easeInOut",
    "mode": "warp", "points": [[round(W * 0.34), round(H * 0.92)],
                               [round(h_grab[0]), round(h_grab[1])]]})
# 2. …and the sketch spawns under it, code written but not running
hydra_window("hyb", hb + 3, h_spawn, PATCHES[2], running=False, animate="springIn")
# 3. hauled UP the screen by the title bar
h_up = (round(W * 0.05), round(H * 0.50), h_spawn[2], h_spawn[3])
add(hb + 4, "moveWindow", {"id": "hyb", "frame": [h_up[0], h_up[1]],
    "durationBeats": 2.5, "easing": "easeInOut"})
add(hb + 4, "cursorPath", {"path": "linear", "durationBeats": 2.5, "easing": "easeInOut",
    "mode": "warp", "points": [[round(h_grab[0]), round(h_grab[1])],
                               [round(h_up[0] + h_spawn[2] * 0.5), round(h_up[1] + 12)]]})
# 4. pulled bigger by the LOWER-RIGHT corner (top-left stays put, code stays on its corner)
h_corner = (h_up[0] + h_spawn[2], h_up[1] + h_spawn[3])
h_big = (h_up[0], h_up[1], round(W * 0.18), round(H * 0.38))
h_new_corner = (h_big[0] + h_big[2], h_big[1] + h_big[3])
add(hb + 7, "cursorPath", {"path": "linear", "durationBeats": 1.0, "easing": "easeInOut",
    "mode": "warp", "points": [[round(h_up[0] + h_spawn[2] * 0.5), round(h_up[1] + 12)],
                               [round(h_corner[0]), round(h_corner[1])]]})
add(hb + 8.2, "moveWindow", {"id": "hyb", "frame": list(h_big),
    "durationBeats": 2.0, "easing": "easeOut"})
add(hb + 8.2, "cursorPath", {"path": "linear", "durationBeats": 2.0, "easing": "easeOut",
    "mode": "warp", "points": [[round(h_corner[0]), round(h_corner[1])],
                               [round(h_new_corner[0]), round(h_new_corner[1])]]})
# Re-open clean at the final size once the drag settles. Still not running.
hydra_window("hyb", hb + 10.4, h_big, PATCHES[2], running=False)
# 5. up to the run button — and it starts, just as Photo Booth arrives centre-screen.
h_play = (h_big[0] + h_big[2] - 26, h_big[1] + 34)
add(hb + 10.5, "cursorPath", {"path": "linear", "durationBeats": 1.0, "easing": "easeInOut",
    "mode": "warp", "points": [[round(h_new_corner[0]), round(h_new_corner[1])],
                               [round(h_play[0]), round(h_play[1])]]})
HYB_RUN = hb + 12
hydra_window("hyb", HYB_RUN, h_big, PATCHES[2], running=True)
add(HYB_RUN, "screenFlash", {"color": "#68BDF8", "durationSeconds": 0.06})

# =============================================================================
# Cue 18 (1:47) — Photo Booth opens on the viewer, counts 3 · 2 · 1, and takes the
# picture. The shutter lands exactly where the photo wall starts.
# =============================================================================
bo = B["booth"]
# The window opens a BAR early and the camera runs before any numeral shows: the
# countdown is anchored to the shutter (PhotoBoothController counts numberAt back
# from durationBeats), so opening earlier only buys the camera its warm-up — the 3
# still lands on the cue, a bar apart from 2 and 1, and the shutter on cue 19.
BOOTH_WARMUP = 4
add(bo - BOOTH_WARMUP - 0.3, "closeWindow", {"id": "tbd1"})
BOOTH_W = round(min(W * 0.52, 760))
BOOTH_H = round(BOOTH_W * 0.78)
add(bo - BOOTH_WARMUP, "photoBooth", {"id": "booth",
    "frame": [round((W - BOOTH_W) / 2), round((H - BOOTH_H) * 0.45), BOOTH_W, BOOTH_H],
    "durationBeats": B["wall"] - (bo - BOOTH_WARMUP), "count": 3, "stepBeats": 4})

# =============================================================================
# Cue 19 (1:54) — the shutter, and then the viewer's own photos bury the screen.
# =============================================================================
wl = B["wall"]
add(wl - 0.12, "screenFlash", {"color": "#FFFFFF", "durationBeats": 0.6})
add(wl + 0.25, "photoWall", {"id": "wall", "fillPerBeat": 12, "churnPerBeat": 2.6,
                             "windows": 40, "minFrac": 0.10, "maxFrac": 0.42})

# =============================================================================
# Cue 20 (1:58) — the face strobes over the wall, in a WINDOW centre-screen, not over
# the whole picture. Same 6 Hz as ever — well clear of the 15–20 Hz photosensitivity
# band. ONE window re-opened under the same id, never shown/hidden (show/hide once
# cost this show 195 ms of A/V drift; re-opening swaps the content view in place —
# `WindowManager.open`, the `existing` branch — hence `chrome: "none"` on both frames).
# =============================================================================
fs = B["facestrobe"]
face_hz, face_until = 6.0, B["horse"] - 0.3
FLASH_W = round(W * 0.36)
FLASH_H = round(FLASH_W * 320 / 425)            # pixelface.jpg's own aspect
FACE_FRAME = {"kind": "image", "path": "assets/pixelface.jpg", "chrome": "none"}
BLUE_FRAME = {"kind": "color", "hex": DJ_BLUE, "chrome": "none"}
k, b = 0, fs
while b < face_until:
    add(b, "openWindow", {"id": "faceflash", "anchor": "center",
        "frame": [0, 0, FLASH_W, FLASH_H],
        "content": FACE_FRAME if k % 2 == 0 else BLUE_FRAME,
        "animate": {"kind": "none"}})
    b += 0.5 / face_hz / BEAT          # one swap per half-cycle: face, blue, face, …
    k += 1
add(face_until, "closeWindow", {"id": "faceflash"})

# =============================================================================
# Cue 21 (2:00) — everything cuts out to the bare desktop, and the horse gets out.
# =============================================================================
hs = B["horse"]
add(hs - 0.2, "closeWindow", {"id": "wall"})
add(hs - 0.2, "closeWindow", {"id": "booth"})
add(hs - 0.2, "closeWindow", {"id": "hyb"})
# Blue from here all the way to the end card (nothing repaints the desktop after
# this), expiring two beats after the card is up — the restore's ~300 ms round-trip
# happens invisibly under the opaque card, and the desktop is back before quit.
add(hs, "deskWallpaper", {"id": "desk4", "mode": "solid", "hex": DJ_BLUE,
                          "durationSeconds": round(secs(B["ending"]) + 2 * BEAT - secs(hs), 3)})
frames, gc, gr, max_lit = build_frames(cols=HORSE_COLS)
HORSE_BEATS = B["torus2"] - hs
horse, horse_exit, horse_end = horse_event(
    frames, gc, gr, W, H, span=HORSE_SPAN, start_beat=hs,
    in_beats=4, hold=round(HORSE_BEATS - 7, 1), out_beats=3)
events.append(horse)

# =============================================================================
# Cue 22 (2:05) — the horse is cut mid-stride and the glass torus takes the middle,
# ringed by EIGHT pixelfaces, one flashing in on each beat — the cue-20 strobe's
# rhythm slowed to the beat. They stay up until cue 24 cuts the whole clock.
# =============================================================================
t2 = B["torus2"]
add(t2, "closeWindow", {"id": "horse"})
add(t2, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
add(t2, "glassTorus", {"id": "torus", "material": "crystal", "speed": 1.2,
                       "size": round(min(W, H) * 0.56)})
FACE_RING = 8
RING_W = round(W * 0.15)
RING_H = round(RING_W * 320 / 425)              # pixelface.jpg's own aspect
rx, ry = W * 0.36, H * 0.40
clock_ids = []
for i in range(FACE_RING):
    ang = -math.pi / 2 + 2 * math.pi * i / FACE_RING        # 12 o'clock, clockwise
    wid = f"ck{i}"
    clock_ids.append(wid)
    add(t2 + i, "openWindow", {"id": wid, "anchor": "center",
        "frame": [round(rx * math.cos(ang)), round(ry * math.sin(ang)), RING_W, RING_H],
        "content": {"kind": "image", "path": "assets/pixelface.jpg", "chrome": "none"},
        "animate": {"kind": "none"}})

# =============================================================================
# Cue 23 (2:08) — all of it stays, and the video slot lands on top.
# =============================================================================
placeholder("video", B["video2"], VIDEO_LABEL, [0, 0, VIDEO_W, VIDEO_H],
            title="untitled.mov")

# =============================================================================
# Cue 24 (2:09) — the torus and the ring cut out from under it, leaving the slot alone
# on the blue desktop (no black backdrop any more — cut 2026-09-01), and the pointer
# swarm rises WITH it: transparent, over everything, so it has the whole section to
# build before it is alone with the pointer.
# =============================================================================
v3 = B["video3"]
for wid in clock_ids + ["torus"]:
    add(v3, "closeWindow", {"id": wid})
# A full-screen transparent swarm of Mac pointers chasing `NSEvent.mouseLocation`, so
# it follows the pointer whether the viewer is moving it or the show is (`cursorPath`
# drives the pointer elsewhere in the piece).
add(v3 + 0.2, "openWindow", {
    "id": "tbd2", "frame": fullscreen(),
    "content": {"kind": "cursors", "seed": 3136, "intensity": 1.0,
                "chrome": "none", "title": "pointer"},
    "animate": {"kind": "none"}})

# =============================================================================
# Cue 25 (2:06) — the video cuts and the swarm, up since cue 24, is alone with the
# viewer's pointer.
# =============================================================================
add(B["tbd_136"], "closeWindow", {"id": "video"})

# =============================================================================
# Cue 26 (2:08) — the mouse spinner, taken the other way: nothing in the app sets the
# pointer, so instead of one beach ball ON the cursor, a MANDALA of them — concentric
# rings of the wait cursor over the whole screen. Cue 25's swarm chases; this one is
# fixed and turns.
# =============================================================================
add(B["spinner"] - 0.2, "closeWindow", {"id": "tbd2"})
add(B["spinner"], "openWindow", {
    "id": "tbd3", "frame": fullscreen(),
    "content": {"kind": "mandala", "seed": 3863, "cols": 5, "intensity": 1.0,
                "chrome": "none", "title": "wait"},
    "animate": {"kind": "none"}})

# =============================================================================
# Cue 27 (2:23) — a ton of crazy UI windows. The eruption: windows, terminals, alerts
# and lyric cards bursting out of the middle, dense from the first beat.
# =============================================================================
body_colors = PALETTE + ["#0B0E16"]
chaos_rng = random.Random(7)
chaos = {"w": 0, "d": 0, "l": 0, "ui": 0}

def erupt(b0, b1, cx, cy, rate=0.25, ui_chaos=0.0):
    """~8 events/sec out of (cx, cy) — the explosion, not a ramp.

    `ui_chaos` is the fraction of the flat colour cards that come up packed with real
    macOS interface instead (`uichaos`, drawn by the engine). It is set on BOTH
    eruptions even though cue 29 is what asked for it: both erupt into the same
    fourteen ids, cue 29 alone is only ~2.3 s (about one packed window), and most of
    what is visible then was put up by cue 27 — so "a quarter of the visible empty
    windows" means a quarter on both.
    """
    b = b0
    while b < b1:
        u = 0.75 + 0.25 * (b - b0) / max(1e-6, b1 - b0)
        r = 30 + (u ** 1.6) * 0.65 * W * chaos_rng.uniform(0.5, 1.0)
        ang = chaos_rng.uniform(0, 6.28318)
        w = round((110 + (u ** 1.7) * 380) * chaos_rng.uniform(0.8, 1.25))
        h = round(w * chaos_rng.uniform(0.6, 0.85))
        x = max(10, min(cx + r * math.cos(ang) - w / 2, W - w - 10))
        y = max(10, min(cy + r * math.sin(ang) - h / 2, H - h - 10))
        roll = chaos_rng.random()
        if roll < 0.42:
            # Both draws happen either way — see the note in cue 15. `chaos_rng` seeds
            # the whole eruption's geometry, so a draw taken on one branch and not the
            # other would re-scatter every window after it.
            hexc = chaos_rng.choice(body_colors)
            packed = chaos_rng.random() < ui_chaos
            animate = {"kind": "none" if chaos_rng.random() < 0.8 else "springIn"}
            content = ({"kind": "uichaos", "seed": 900 + chaos["w"], "intensity": 1.15,
                        "chrome": "mixed", "title": "Finder"}
                       if packed else
                       {"kind": "color", "hex": hexc,
                        "chrome": "mixed", "title": "look://again"})
            add(b, "openWindow", {"id": f"w{chaos['w'] % 14}", "frame": [round(x), round(y), w, h],
                "content": content, "animate": animate, "interactive": True})
            chaos["w"] += 1
            if packed:
                chaos["ui"] += 1
        elif roll < 0.58:
            text = phrase_texts[chaos["l"] % n_cue].upper()   # ALL CAPS, like the spiral
            lyric_card(f"w{chaos['w'] % 14}", b, text, chaos["l"],
                       frame=[round(x), round(y), max(w, 260), h], chrome="mac")
            chaos["w"] += 1; chaos["l"] += 1
        elif roll < 0.70:
            add(b, "openWindow", {"id": f"w{chaos['w'] % 14}",
                "frame": [round(x), round(y), max(w, 300), h],
                "content": {"kind": "code", "text": chaos_rng.choice(codes),
                            "chrome": "terminal", "title": "haunt.sh"},
                "animate": {"kind": "none"}, "interactive": True})
            chaos["w"] += 1
        elif roll < 0.86:
            title, body, icon = lyrics.alert(chaos["d"])
            add(b, "fakeDialog", {"id": f"d{chaos['d'] % 4}", "title": title, "body": body,
                "buttons": lyrics.buttons(chaos["d"]), "icon": icon,
                "frame": [round(x), round(y), 460, 190]})
            chaos["d"] += 1
        elif chaos["w"] > 0:
            add(b, "jiggle", {"id": f"w{(chaos['w'] - 1) % 14}", "durationBeats": 1.5,
                "amplitude": 18, "frequency": 9})
        b += max(0.15, rate * chaos_rng.uniform(0.7, 1.3))

sm = B["spam"]
add(sm - 0.2, "closeWindow", {"id": "tbd3"})
add(sm, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
erupt(sm, B["glitch"], W / 2, H / 2, ui_chaos=0.25)

# The ground flashes on every kick underneath it.
flash_colors = ["#FEFEFE", BLUE, "#020202", "#68BDF8"]
n_kick = 0
for i, kt in enumerate(kicks_between(sm, B["glitch"])):
    add_t(kt, "screenFlash", {"color": flash_colors[i % len(flash_colors)],
                              "durationSeconds": 0.09})
    n_kick += 1

# =============================================================================
# Cue 28 (2:28) — the pickup bar of chorus 2B: the eruption again, with the original
# strobe spliced in verbatim over the top, STRAIGHT IN — no four-bar wait. The strobe
# is authored in absolute seconds, which survive the splice with a plain offset;
# everything past the stop is dropped, and the stop closes what it left. The desktop
# stays blue underneath: the old glitch ⇄ lyric alternation is out of the cut — every
# glitch pass was a bitmap render AND a ~300 ms desktop swap every window on screen
# pays for, and the section was extremely laggy live.
# =============================================================================
gl2 = B["glitch"]
erupt(gl2, B["lastwords"], W / 2, H / 2, rate=0.18, ui_chaos=0.25)
with open(os.path.join(ROOT, "examples", "timeline_strobe.json")) as f:
    strobe = json.load(f)
strobe_at = secs(gl2)
strobe_cut = secs(B["lastwords"]) - 0.05
strobe_ids, n_strobe = set(), 0
for ev in strobe["events"]:
    if ev["t"] + strobe_at >= strobe_cut:
        continue
    add_t(ev["t"] + strobe_at, ev["type"], ev["params"])
    n_strobe += 1
    if "id" in ev["params"]:
        strobe_ids.add(ev["params"]["id"])

# =============================================================================
# Cue 29 — PULLED (2026-09-01): the lyric desktop under the strobe is out. The strobe
# starves the swap queue, so each word card stuck for whole seconds, and a lingering
# word right before the end card read as a weird wallpaper flash. The desktop stays
# blue from the horse straight into the card; the slot keeps its number.
# =============================================================================
ag = B["allglitch"]

# =============================================================================
# Cue 30 (2:41) — the stop. The noise closes on the silence and nothing else moves:
# the desktop has been plain blue since the horse, so no swap is in flight — or even
# possible — when the end card fires.
# =============================================================================
lw = B["lastwords"]
add(lw, "screenFlash", {"color": WHITE, "durationBeats": 1.0})
for wid in sorted(strobe_ids) + [f"w{i}" for i in range(14)] + [f"d{i}" for i in range(4)]:
    add(lw + 0.05, "closeWindow", {"id": wid})

# =============================================================================
# Cue 31 (2:41) — the ending, ON the stop: the break IS the end card. The photo the
# booth took, the machine's vitals and the credits typing themselves out, held while
# the track's silent tail runs out underneath.
# =============================================================================
en = B["ending"]
add(en, "screenFlash", {"color": WHITE, "durationBeats": 1.5})
CREDITS = [
    "GiveIt2Me",
    "by DJ_Dave",
    "produced by ninajirachi",
    "2026",
    "",
    "Malware and music video",
    "by Computer Art, LLC",
    "Viola He",
    "Jame Coyne",
    "",
    "Bye",
]
# Typed by the LINE, one per beat — the probe's cadence. The card comes up ON the
# stop, so the hold only has to clear its own typing before the outro plays.
CREDITS_LPS = round(1 / BEAT, 3)
CARD_AT = secs(en)
TYPED_AT = CARD_AT + len(CREDITS) / CREDITS_LPS
OUTRO_DELAY = 4.0
add(en, "credits", {"id": "credits", "lines": CREDITS, "hold": True,
    "linesPerSecond": CREDITS_LPS, "fontSize": 22, "photoTilt": -4,
    "outroDelay": OUTRO_DELAY,
    "backdrop": "#FFFFFF",
    "tile": "assets/credits_tile.png", "tileDriftSeconds": 4})

# --- markers for the scrubber: the analyser's sections plus every cue ---
LABELS = {
    "blue": "blue desktop", "restore": "desktop back", "welcome": "welcome (typed)",
    "probe": "system probe", "hydra": "hydra (pulled)", "blue2": "blue again",
    "face": "pixelface desktop", "traveller": "traveller + trail",
    "spiral": "lyric spiral", "video1": "video slot", "tbd_048": "TBD",
    "words": "lyrics desktop", "torus1": "magic torus + greeting",
    "map": "maps: here", "fill": "windows fill", "black": "to black",
    "tbd_099": "glsl + hydra", "booth": "photo booth", "wall": "photo wall",
    "facestrobe": "pixelface strobe", "horse": "the horse",
    "torus2": "torus + face ring", "video2": "video on top", "video3": "video + swarm",
    "tbd_136": "swarm alone", "spinner": "beach-ball mandala", "spam": "UI spam",
    "glitch": "spam + strobe", "allglitch": "words (pulled)",
    "lastwords": "the stop", "ending": "the end card",
}
KINDS = {"blue": "start", "words": "drop", "torus1": "drop", "horse": "drop",
         "spam": "drop", "allglitch": "drop", "ending": "break", "black": "break"}
markers = list(analysis["markers"])
markers += [{"t": round(secs(B[name]), 2), "bar": int(B[name] // 4) + 1,
             "label": LABELS[name], "kind": KINDS.get(name, "section")}
            for name in CUES]
markers.sort(key=lambda m: m["t"])

def when(e):
    return e["t"] if "t" in e else secs(e["beat"])
events.sort(key=when)

doc = {"meta": {"bpm": BPM, "beatOffset": OFFSET, "audioFile": AUDIO,
                # The canvas every frame and cursor point in this file is authored in.
                # ScreenGeometry maps it onto the real screen, so a different-sized
                # display gets the same composition, centred and scaled.
                "authoredSize": [W, H],
                "analyzedBpm": BPM, "markers": markers,
                # On by default — the desktop is painted in cue 1; false skips and logs
                # every deskWallpaper. WallpaperController snapshots the viewer's own
                # picture before the first swap and restores it on stop, panic and quit.
                # ALLOW_WALLPAPER=0 opts back out.
                "allowWallpaper": os.environ.get("ALLOW_WALLPAPER") != "0",
                "allowDesktopFiles": os.environ.get("ALLOW_DESKTOP_FILES") == "1"},
       "events": events}
for out in (os.path.join(ROOT, "examples", "timeline_show.json"),
            # DPECore: the library target the tests import; the resources live with it.
            os.path.join(ROOT, "Sources", "DPECore", "Resources", "timeline.json")):
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}")

print(f"\n{len(events)} events @ {BPM} BPM, offset {OFFSET}s, track {DURATION:.1f}s "
      f"({frame_at(DURATION)} frames)")
# Reported in FRAMES — the unit docs/CUES.md is written in and the app's transport
# counts in, so a number printed here is findable on the scrubber.
print(f"  {'cue':<11} {'phrase':<14} {'in':>6} {'fires on':>10} {'beat':>5}  {'vs recut−9s':>11}")
for i, (name, (p, bars, beats)) in enumerate(CUES.items(), start=1):
    g = secs(B[name])
    was_beat = 0 if name == "blue" else round((WAS[name] - RECUT_SHIFT - OFFSET) / BEAT)   # the recut, on the track's clock
    print(f"  {i:>2} {name:<11} {p:<14} {bars:>2}.{beats:<4g} {'f ' + str(frame_at(g)):>10} {B[name]:>5g}  "
          f"{frame_at(g) - frame_at(secs(was_beat)):+8d}f"
          + ("   (past the end of the track)" if g > DURATION else ""))
print()
print(f"  face     {FACE_DESKTOP} {FACE_W}x{FACE_H} on 2560x1600 ({FACE_SHARE:.0%} of the height)")
print(f"  welcome  {len(WELCOME_LINES)} lines @{WELCOME_LPB:g}/beat in a {WELCOME_W}x{WELCOME_H} terminal, "
      f"last line lands f {frame_at(secs(B['welcome'] + len(WELCOME_LINES) / WELCOME_LPB))}, "
      f"closed f {frame_at(secs(B['probe']))}")
if HYDRA_ACT:
    print(f"  hydra    {len(hydra_ids)} sketches, dragged one runs at {secs(HYDRA_RUN):.2f}s")
else:
    print("  hydra    pulled from the cut (HYDRA_ACT = False)")
print(f"  trail    {len(trail_ids)} delayed copies over {len(legs)} legs, "
      f"{TRAIL_DX:.0f}px and {TRAIL_LAG:.3f} beats apart "
      f"(tail {TRAIL_LINKS * TRAIL_LAG * BEAT:.2f}s behind the leader, leg {LEG * BEAT:.2f}s)")
print(f"  spiral   {len(spiral_ids)} lyric cards, r {r0:.0f}→{r1:.0f}px")
print(f"  words    {len(word_slides)} desktop words on the sung lyric, {words_first:.2f}s → "
      f"{word_slides[-1][0]:.2f}s, last holds to {secs(B['torus1']):.1f}s "
      f"(applied {DESK_LATENCY * 1000:.0f} ms early; min gap "
      f"{min(b - a for (a, _), (b, _) in zip(word_slides, word_slides[1:])):.2f}s)"
      + (f"\n           no card yet for: {', '.join(words_missing)}" if words_missing else "")
      + (f"\n           inner words spread evenly in: {', '.join(repr(t) for t in words_interpolated)}"
         if words_interpolated else ""))
print(f"  torus    greeting types {secs(t1 + 1):.2f}s → {secs(ORACLE_AT - 1):.2f}s, "
      f"question at f {frame_at(secs(ORACLE_AT))} "
      f"({secs(ORACLE_AT):.2f}s), answers itself after {ORACLE_BEATS:.0f} beats "
      f"(f {frame_at(secs(ORACLE_AT + ORACLE_BEATS))}), cut at f {frame_at(secs(mp)):d}")
print(f"  fill     {len(fill_ids)} windows, 4 beats apart → 0.25")
print(f"  face     {k} strobe frames @{face_hz:.0f} Hz")
print(f"  horse    {gc}x{gr} grid, {max_lit} windows, {HORSE_SPAN:.0%} of the screen, "
      f"exits beat {horse_exit:.0f}")
print(f"  hydra2   breakdown sketch over the raymarcher: cursor walks f {frame_at(secs(hb))}, "
      f"spawns f {frame_at(secs(hb + 3))}, runs f {frame_at(secs(HYB_RUN))}, cut f {frame_at(secs(hs - 0.2))}")
print(f"  booth    window f {frame_at(secs(bo - BOOTH_WARMUP))} (camera warm-up, {BOOTH_WARMUP:g} beats), "
      f"count starts f {frame_at(secs(bo))}, shutter f {frame_at(secs(B['wall']))}")
print(f"  ring     {len(clock_ids)} pixelfaces round the torus, one a beat, "
      f"f {frame_at(secs(t2))} → f {frame_at(secs(t2 + FACE_RING - 1))}")
print(f"  spam     {chaos['w']} windows, {chaos['d']} alerts, {n_kick} kick flashes, "
      f"{chaos['ui']} packed with macOS UI (both eruptions)")
print(f"  strobe   {n_strobe} of {len(strobe['events'])} strobe events over "
      f"{secs(B['lastwords']) - secs(B['glitch']):.1f}s from the 2B pickup; the desktop "
      f"stays blue to the card")
print(f"  outro    copy lands {TYPED_AT:.2f}s, holds {OUTRO_DELAY:.1f}s → quit at "
      f"{TYPED_AT + OUTRO_DELAY:.2f}s ({TYPED_AT + OUTRO_DELAY - DURATION:+.2f}s vs track end)")
print()
print("  lyric phrases (tools/lyrics.py PHRASES, timed off CUES) — spiral cards at chorus 1A:")
print("   #    spiral    text")
for i, (when, text, _) in enumerate(phrases):
    ta = f"{secs(lyric_beat(zero_1A, when)):6.2f}s"
    print(f"  {i:>2}   {ta:>8}   {text}")
