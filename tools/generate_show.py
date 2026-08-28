"""The show, cut to docs/CUES.md.

`docs/CUES.md` is the source document — one row per cue, authored in seconds by ear
against the recording. `CUES` below mirrors it, and everything in this file hangs off
those numbers; edit the two together.

    python3 tools/generate_show.py
    W=1440 H=900 COLS=22 python3 tools/generate_show.py

Writes examples/timeline_show.json and Sources/DPECore/Resources/timeline.json.

The cue times do NOT land on bar lines — they were read off a player's clock, not
counted in bars — so `at()` puts each one on the NEAREST BEAT. That moves a cue by at
most half a beat (0.23 s) and keeps every cut tight to the music; authoring them at
their literal second instead would drift each one against the grid by a different
amount, which is audible on the hard cuts.

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
# How the flyover renders: "flyover" is Apple's 3-D mode with no labels at all,
# "hybrid" is the same imagery WITH roads and place names, "standard" is the plain
# vector map. All three are real Apple Maps — it's the same MKMapView either way.
MAP_STYLE = os.environ.get("MAP_STYLE", "hybrid")
AUDIO = "assets/03 - Give it 2 me.mp3"

# The lyric cards' two colours. Cards alternate ground/type between them.
BLUE = "#0078D7"
WHITE = "#F2F4FE"
BLACK = "#000000"

# The signature blue: rgb(2, 10, 245). The desktop and the restart card both take it, so
# the ground under the opening is one colour. It is PALETTE[1] — the blue the horse and
# the strobe are built from — NOT the lighter #0078D7 the lyric cards use.
DJ_BLUE = "#020AF5"

# --- the tempo map, straight from the analysis ---
with open(os.path.join(ROOT, "assets", "track_analysis.json")) as f:
    analysis = json.load(f)
BPM = analysis["bpm"]                  # 128.5
OFFSET = analysis["firstDownbeat"]     # 0.395 — beat 0 sits on the first downbeat
BEAT = 60.0 / BPM
KICKS = analysis["kicks"]
DURATION = analysis["duration"]        # 169.85 — the last two cues are past this

def secs(beat):
    """Absolute seconds for a timeline beat (matches the loader's beat→time math)."""
    return OFFSET + beat * BEAT

def at(t):
    """The beat nearest the authored second `t` — see the module docstring."""
    return round((t - OFFSET) / BEAT)

# =============================================================================
# THE CUE LIST — docs/CUES.md, in seconds. Every act below indexes this by name;
# no act computes a time of its own.
# =============================================================================
CUES = {
    "blue":        0.0,      #  1  intro gate + the desktop goes DJ blue
    "restore":    16.0,      #  2  blue goes, the viewer's own wallpaper is back
    "welcome":    18.0,      #  3  the ASCII welcome window
    "probe":      25.0,      #  4  the system probe
    "hydra":      30.0,      #  5  sketches dragged onto the screen
    "blue2":      38.0,      #  6  blue again
    "face":       39.0,      #  7  the desktop becomes pixelface.jpg
    "traveller":  39.5,      #  8  one window up and down, trailing windows
    "spiral":     43.0,      #  9  the spiral of lyrics
    "video1":     47.0,      # 10  placeholder for a video
    "tbd_048":    48.0,      # 11  TBD — deliberately empty
    "words":      54.0,      # 12  the lyrics on the desktop, dragged trail
    "torus1":     69.0,      # 13  the magic torus, and it introduces itself
    "map":        84.0,      # 14  Apple Maps onto the viewer's location
    "fill":       87.0,      # 15  windows start filling the screen
    "black":      97.0,      # 16  desktop to black, windows close one by one
    "tbd_099":    99.0,      # 17  TBD — cool graphic
    "booth":     107.0,      # 18  Photo Booth, 3·2·1, shutter
    "wall":      114.0,      # 19  the viewer's own photos fill the screen
    "facestrobe":118.0,      # 20  pixelface strobes over the wall
    "horse":     120.0,      # 21  everything cuts; the horse
    "torus2":    125.0,      # 22  glass torus + a circle of lyric windows
    "video2":    128.0,      # 23  the video placeholder on top of all of it
    "video3":    129.0,      # 24  cut to black, video placeholder alone on it
    "tbd_136":   136.0,      # 25  everything cuts; TBD
    "spinner":   138.0,      # 26  TBD + the mouse spinner
    "spam":      143.0,      # 27  a ton of crazy UI windows
    "glitch":    158.0,      # 28  the wallpaper glitches, lyrics glitch with it
    "allglitch": 167.0,      # 29  windows + the whole screen glitching
    "lastwords": 171.0,      # 30  the lyrics desktop
    "ending":    174.0,      # 31  the end card
}
B = {name: at(t) for name, t in CUES.items()}
B["blue"] = 0                            # the first event is beat 0, not a snap

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
    """A labelled stand-in for content that isn't made yet.

    Deliberately legible rather than pretty: these are slots in the cut, and a slot
    that looks finished is a slot nobody fills. Every one of them says what it is
    waiting for — see the Gaps section of docs/CUES.md.
    """
    params = {"id": wid, "frame": frame,
              "content": {"kind": "text", "text": label, "hex": hex, "fg": fg,
                          "fontSize": 26, "chrome": "mac",
                          "title": title or "placeholder"},
              "animate": {"kind": animate}}
    if anchor:
        params["anchor"] = anchor
    add(beat, "openWindow", params)

VIDEO_LABEL = "[ video goes here ]\n\nplaceholder — single video, centre screen"

# =============================================================================
# Cue 1 (0:00) — THE BLUE. The intro gate has already run: it is what armed the
# transport, so it sits before beat 0 rather than on it, and the only thing this cue
# puts on the timeline is the desktop taking the signature blue.
#
# The event carries a duration, and that duration IS cue 2: when a deskWallpaper
# expires, WallpaperController puts the viewer's own picture back. Real wallpaper, so
# `meta.allowWallpaper` gates it; the snapshot is taken here, before the first swap,
# and restored on stop, panic and quit as well.
# =============================================================================
add(0, "deskWallpaper", {"id": "desk", "mode": "solid", "hex": DJ_BLUE,
                         "durationSeconds": round(secs(B["restore"]) - secs(0), 3)})

# =============================================================================
# Cue 2 (0:16) — the blue goes and the viewer's own desktop is underneath it.
#
# The restore above is a hard swap — setDesktopImageURL has no fade and takes ~300 ms —
# so a short white wash covers the change. Without it the cut reads as a dropped frame
# rather than as the piece letting go of the machine for a moment.
# =============================================================================
add(B["restore"], "screenFlash", {"color": WHITE, "durationBeats": 0.5})

# =============================================================================
# Cue 3 (0:18) — the welcome window. PLACEHOLDER: the `ascii` kind renders literal art
# and image→ASCII already, so only the artwork is missing; the copy names itself as a
# stand-in so nobody ships it by accident.
# =============================================================================
WELCOME = r"""
  ____   _   ___   ___    _ _   _ ___
 |  _ \ | | |   \ / _ \  /_\ | | | __|
 | |_| || |_| |) | (_) |/ _ \| |_| _|
 |____/ |___|___/ \___//_/ \_\___|___|

  welcome to the DJ Dave malware blah blah blah
  placeholder for some cool glitchy ascii art thing
"""
add(B["welcome"], "openWindow", {
    "id": "welcome", "anchor": "center",
    "frame": [0, 0, round(W * 0.52), round(H * 0.44)],
    "content": {"kind": "ascii", "text": WELCOME, "hex": "#8CF2A6",
                "chrome": "terminal", "title": "welcome.txt"},
    "animate": {"kind": "springIn"}, "interactive": True})

# =============================================================================
# Cue 4 (0:25) — the welcome window goes and the probe opens, typing out what the
# machine knows about whoever is sitting at it.
#
# Slow enough to read: it has from here to the end of the hydra act, and the report is
# long, so the rate is set from the gap rather than picked.
# =============================================================================
add(B["probe"], "closeWindow", {"id": "welcome"})
PROBE_FRAME = [round(W * 0.18), round(H * 0.08), round(W * 0.64), round(H * 0.84)]
add(B["probe"], "systemProbe", {"id": "probe", "linesPerBeat": 6, "frame": PROBE_FRAME})

# =============================================================================
# Cue 5 (0:30) — somebody using a computer: a hydra sketch is dragged onto the screen,
# pulled bigger by its corner, and run. Then two more arrive on the downbeats.
#
# The window and the pointer travel together on every leg, which is what makes it read
# as a drag rather than as a window moving itself. It plays to the LEFT of the probe's
# terminal, which owns the middle of the screen until 0:38.
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

# …and two more, already running, on the downbeats after it — the machine getting the
# hang of it. Right-hand side, clear of both the probe and the dragged window.
for i, (dx, dy, s) in enumerate([(0.62, 0.10, 0.30), (0.70, 0.52, 0.26)], start=1):
    wid = f"hy{i}"
    hydra_ids.append(wid)
    beat = HYDRA_RUN + 2 + 2 * (i - 1)
    hydra_window(wid, beat, (round(W * dx), round(H * dy),
                             round(W * s), round(H * s * 1.05)),
                 PATCHES[(i + 1) % len(PATCHES)], running=True, animate="springIn")

# =============================================================================
# Cue 6 (0:38) — the desktop goes blue again, and the screen is cleared for it.
#
# No duration on this one: it is replaced a beat later by cue 7 rather than expiring.
# An expiry here would restore the viewer's picture for the two frames before the face
# lands, which is a flicker of the wrong image at the worst moment.
# =============================================================================
for wid in hydra_ids + ["probe"]:
    add(B["blue2"] - 0.2, "closeWindow", {"id": wid})
add(B["blue2"], "deskWallpaper", {"id": "desk2", "mode": "solid", "hex": DJ_BLUE})
add(B["blue2"], "screenFlash", {"color": WHITE, "durationBeats": 0.4})

# =============================================================================
# Cue 7 (0:39) — and then the desktop is the face.
#
# `slides` with one image rather than a `wallpaper` event, so it goes through the same
# controller as everything else and is restored the same way. hz is deliberately far
# below one — the list never advances, so every tick past the first is a ~300 ms window
# server round-trip for an identical picture.
# =============================================================================
add(B["face"], "deskWallpaper", {"id": "face", "mode": "slides", "hz": 0.1,
                                 "images": ["assets/pixelface.jpg"]})

# =============================================================================
# Cue 8 (0:39.5) — one window travels up and down the screen and leaves a trail of
# windows behind it.
#
# The trail is stamped rather than followed: a window is opened at the traveller's
# position on every half-beat and simply left there, so the path is still legible after
# the traveller has moved on. They are closed together at cue 12.
# =============================================================================
tv = B["traveller"]
TRAVEL_END = B["spiral"] - 0.5
TRAVEL_W, TRAVEL_H = round(W * 0.20), round(H * 0.22)
tx = round((W - TRAVEL_W) / 2)
y_top, y_bot = round(H * 0.06), round(H - TRAVEL_H - H * 0.06)

add(tv, "openWindow", {"id": "traveller", "frame": [tx, y_bot, TRAVEL_W, TRAVEL_H],
    "content": {"kind": "code", "text": lyrics.code(0), "chrome": "terminal",
                "title": "give_it_2_me.js"},
    "animate": {"kind": "springIn"}, "interactive": True})

LEG = 1.75                                   # beats for one traverse of the screen
trail_ids, leg, b = [], 0, tv
while b + LEG <= TRAVEL_END:
    to_y = y_top if leg % 2 == 0 else y_bot
    add(b, "moveWindow", {"id": "traveller", "frame": [tx, to_y],
                          "durationBeats": LEG, "easing": "easeInOut"})
    # Three stamps down the leg, at the eased positions the traveller actually passes
    # through — evenly spaced in time would bunch them at the ends of the ease.
    frm = y_bot if leg % 2 == 0 else y_top
    for k in (0.25, 0.5, 0.75):
        e = 4 * k ** 3 if k < 0.5 else 1 - (-2 * k + 2) ** 3 / 2      # easeInOut cubic
        wid = f"tr{len(trail_ids)}"
        trail_ids.append(wid)
        add(b + LEG * k, "openWindow", {
            "id": wid,
            "frame": [tx + round((len(trail_ids) % 3 - 1) * TRAVEL_W * 0.22),
                      round(frm + (to_y - frm) * e), round(TRAVEL_W * 0.62),
                      round(TRAVEL_H * 0.55)],
            "content": {"kind": "color", "hex": PALETTE[len(trail_ids) % len(PALETTE)],
                        "chrome": "mixed", "title": "…"},
            "animate": {"kind": "none"}})
    leg += 1
    b += LEG

# =============================================================================
# Cue 9 (0:43) — the spiral of lyrics. One card per lyric cue, winding out from the
# middle, each a little further round and a little further out.
#
# Authored from the screen's CENTRE (`anchor: center`), like everything else that rings
# the middle: top-left frames put the spiral's origin at (W/2, H/2) of the AUTHORED
# size, which on a bigger display is up and to the left of where the eye expects it.
#
# The innermost radius clears the middle, because cue 10 parks the video placeholder
# there four seconds later.
# =============================================================================
sp = B["spiral"]
SPIRAL_END = B["words"] - 1.5
CARD_W, CARD_H = round(W * 0.15), round(H * 0.11)
n_cue = len(lyrics.CUES)
step = (SPIRAL_END - sp) / n_cue
r0, r1 = min(W, H) * 0.16, min(W, H) * 0.46
spiral_ids = []
for i, (_, text) in enumerate(lyrics.CUES):
    u = i / max(1, n_cue - 1)
    ang = -math.pi / 2 + 2.4 * math.pi * u          # a bit over one full turn
    r = r0 + (r1 - r0) * u
    wid = f"sp{i}"
    spiral_ids.append(wid)
    lyric_card(wid, sp + i * step, text, i,
               frame=[round(r * math.cos(ang) * 1.35), round(r * math.sin(ang)),
                      CARD_W, CARD_H],
               chrome="mac", animate="springIn", anchor="center")

# =============================================================================
# Cue 10 (0:47) — the middle of the spiral fills with the slot the video will take.
# PLACEHOLDER: there is no video content kind yet.
# =============================================================================
VIDEO_W, VIDEO_H = round(W * 0.34), round(H * 0.32)
placeholder("video", B["video1"], VIDEO_LABEL, [0, 0, VIDEO_W, VIDEO_H],
            title="untitled.mov")

# =============================================================================
# Cue 11 (0:48) — TBD. Deliberately empty: the author has not decided, and a filler
# event here would have to be found and removed later. The gap is the note.
# =============================================================================

# =============================================================================
# Cue 12 (0:54) — the lyric on the desktop itself, and a trail of windows dragged
# across it by the mouse.
#
# The wallpaper is swapped for a card carrying one word at a time. 10 Hz is what the
# cut asks for; the window server tops out near 3 Hz and the controller drops whole
# ticks rather than queueing them, so the words play slower than authored but never
# skip and never outlive the event.
#
# The spiral and the traveller's trail go here — the desktop is the picture now.
# =============================================================================
wd = B["words"]
for wid in spiral_ids + trail_ids + ["traveller"]:
    add(wd - 0.4, "closeWindow", {"id": wid})

LYRIC_WORDS = ["I", "TOLD", "YOU", "THAT", "I", "NEED", "YOUR", "LOVE",
               "SO", "GIVE", "IT", "2", "ME",
               "RUNNIN", "UP", "MY", "CURRENTS",
               "I", "CANT", "GET", "ENOUGH", "SO", "GIVE", "IT", "2", "ME"]
WORD_SLIDES = [f"assets/lyrics_desktops/{w}.jpg" for w in LYRIC_WORDS]
add(wd, "deskWallpaper", {"id": "words", "mode": "slides", "hz": 10,
                          "images": WORD_SLIDES,
                          "durationSeconds": round(secs(B["torus1"]) - secs(wd), 3)})

# The cursor hauls a stamped trail across the screen. `stamp` drops a breadcrumb window
# every `spacing` px of travel and leaves it there, so what the pointer draws stays
# drawn — the trail IS the windows, not a fading tail.
add(wd, "cursorTrail", {"id": "drag", "mode": "stamp", "spacing": 92,
                        "count": 40, "size": [round(W * 0.09), round(H * 0.08)],
                        "chrome": "mixed", "colors": PALETTE,
                        "durationBeats": B["torus1"] - wd - 2})
# One path, not a leg per cue: the spline needs at least three points to curve at all,
# and a hand hauling something across a desk does not travel in straight segments.
DRAG_LEGS = [(0.08, 0.78), (0.28, 0.22), (0.52, 0.80), (0.74, 0.26), (0.94, 0.66),
             (0.62, 0.44), (0.20, 0.52), (0.86, 0.16)]
add(wd, "cursorPath", {
    "path": "catmullRom", "durationBeats": B["torus1"] - wd - 2, "easing": "easeInOut",
    "mode": "warp",
    "points": [[round(x * W), round(y * H)] for x, y in DRAG_LEGS]})

# =============================================================================
# Cue 13 (1:09) — the magic torus, and a window that introduces it, typed out a
# character at a time.
#
# The greeting is `typeText` rather than `oracle`: the cut asks for the torus to
# announce itself, not to open a dialog and wait for an answer. The oracle event is
# still in the app for whenever the question comes back.
# =============================================================================
t1 = B["torus1"]
add(t1 - 0.3, "closeWindow", {"id": "video"})
add(t1 - 0.3, "closeWindow", {"id": "drag"})
add(t1, "screenFlash", {"color": WHITE, "durationBeats": 0.5})
add(t1, "glassTorus", {"id": "torus", "material": "glass", "speed": 0.8,
                       "size": round(min(W, H) * 0.58)})
GREETING = ("Greetings, I am the magic torus. I rotate infinitely around an axis in "
            "the 3D plane, thus I am all knowing... ask me anything")
add(t1 + 1, "typeText", {"id": "greeting",
    "frame": [round(W * 0.60), round(H * 0.62), round(W * 0.36), round(H * 0.26)],
    "text": GREETING, "charsPerBeat": 11, "fontSize": 15,
    "title": "torus.txt — Edited", "interactive": True})

# The desktop goes back to blue when the words expire, under the torus.
add(t1 + 0.1, "deskWallpaper", {"id": "desk3", "mode": "solid", "hex": DJ_BLUE})

# =============================================================================
# Cue 14 (1:24) — Apple Maps, falling out of orbit onto the viewer's own location.
# =============================================================================
mp = B["map"]
for wid in ("torus", "greeting"):
    add(mp - 0.3, "closeWindow", {"id": wid})
add(mp, "screenFlash", {"color": WHITE, "durationBeats": 0.3})
# Where the map goes when Location Services gives us nothing (denied, switched off, or
# still pending): downtown Los Angeles. `here=True` overrides these whenever there IS a
# fix, so this is the fallback, not the destination.
FALL = dict(lat=34.0522, lon=-118.2437)
DESCENT = dict(FALL, here=True, altitude=2_600_000, toAltitude=260,
               pitch=0, toPitch=62, heading=0, toHeading=30,
               seconds=round((B["black"] - mp) * BEAT - 1.0, 1), style=MAP_STYLE)
add(mp, "openWindow", {"id": "map0",
    "frame": [round(W * 0.10), round(H * 0.07), round(W * 0.80), round(H * 0.78)],
    "content": {"kind": "map", "chrome": "browser", "title": "maps://{ip}", "map": DESCENT},
    "animate": {"kind": "springIn"}, "interactive": True, "respawn": True})

# =============================================================================
# Cue 15 (1:27) — windows start opening and slowly fill the screen.
#
# "Slowly" is the whole point, so the rate ramps: it starts at roughly one window a bar
# and ends at four a beat. Placed on a coarse lattice that walks outward from the middle,
# so the screen fills from the centre rather than at random.
# =============================================================================
fl = B["fill"]
fill_rng = random.Random(19)
fill_ids = []
codes = lyrics.CODE
b, i = fl, 0
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
        add(b, "openWindow", {"id": wid, "frame": [x, y, w, h],
            "content": {"kind": "color", "hex": fill_rng.choice(PALETTE + ["#0B0E16"]),
                        "chrome": "mixed", "title": "look://again"},
            "animate": {"kind": "springIn"}, "interactive": True})
    elif roll < 0.75:
        add(b, "openWindow", {"id": wid, "frame": [x, y, max(w, 300), h],
            "content": {"kind": "code", "text": lyrics.code(i), "chrome": "terminal",
                        "title": "haunt.sh"},
            "animate": {"kind": "none"}, "interactive": True})
    else:
        title, body, icon = lyrics.alert(i)
        add(b, "fakeDialog", {"id": wid, "title": title, "body": body,
            "buttons": lyrics.buttons(i), "icon": icon,
            "frame": [x, y, 460, 190]})
    # 4 beats apart at the start, 0.25 at the end.
    b += 4 * (1 - u) ** 2 + 0.25
    i += 1

# =============================================================================
# Cue 16 (1:37) — the desktop goes black and the windows close one by one.
#
# Another hard swap dressed as a fade (see cue 2). The closes are staggered across two
# bars in the order the windows arrived, so the screen empties the way it filled.
# =============================================================================
bk = B["black"]
add(bk, "deskWallpaper", {"id": "dark", "mode": "solid", "hex": BLACK})
add(bk, "screenFlash", {"color": BLACK, "durationBeats": 0.6})
add(bk + 0.2, "closeWindow", {"id": "map0"})
close_span = (B["tbd_099"] - bk) - 0.4
for i, wid in enumerate(fill_ids):
    add(bk + 0.2 + close_span * i / max(1, len(fill_ids) - 1), "closeWindow", {"id": wid})

# =============================================================================
# Cue 17 (1:39) — TBD: a cool graphic. PLACEHOLDER holding the slot open.
# =============================================================================
placeholder("tbd1", B["tbd_099"],
            "[ cool graphic ]\n\nTBD — 1:39 → 1:47",
            [0, 0, round(W * 0.44), round(H * 0.38)], title="tbd.graphic")

# =============================================================================
# Cue 18 (1:47) — Photo Booth opens on the viewer, counts 3 · 2 · 1, and takes the
# picture. The shutter lands exactly where the photo wall starts.
# =============================================================================
bo = B["booth"]
add(bo - 0.3, "closeWindow", {"id": "tbd1"})
BOOTH_W = round(min(W * 0.52, 760))
BOOTH_H = round(BOOTH_W * 0.78)
add(bo, "photoBooth", {"id": "booth",
    "frame": [round((W - BOOTH_W) / 2), round((H - BOOTH_H) * 0.45), BOOTH_W, BOOTH_H],
    "durationBeats": B["wall"] - bo, "count": 3, "stepBeats": 4})

# =============================================================================
# Cue 19 (1:54) — the shutter, and then the viewer's own photos bury the screen.
# =============================================================================
wl = B["wall"]
add(wl - 0.12, "screenFlash", {"color": "#FFFFFF", "durationBeats": 0.6})
add(wl + 0.25, "photoWall", {"id": "wall", "fillPerBeat": 12, "churnPerBeat": 2.6,
                             "windows": 40, "minFrac": 0.10, "maxFrac": 0.42})

# =============================================================================
# Cue 20 (1:58) — the spam carries on and the face strobes over the top of it.
#
# 6 Hz, well clear of the 15–20 Hz photosensitivity band the rest of the piece stays out
# of. A window rather than a wallpaper swap: the desktop is buried under the wall by now,
# so a wallpaper change would not be visible at all.
#
# ONE window, re-opened under the same id and alternating face/blue — never shown and
# hidden. Showing or hiding a FULLSCREEN window per flash is the exact thing that cost
# this show 195 ms of A/V drift once before: it makes the window server re-composite the
# whole screen over every window underneath, and there are forty photo windows under this
# one. Re-opening an id swaps the content view on the window that is already there, which
# costs nothing like as much (`WindowManager.open`, the `existing` branch — it needs the
# chrome to stay equally native, hence `chrome: "none"` on both frames).
# =============================================================================
fs = B["facestrobe"]
face_hz, face_until = 6.0, B["horse"] - 0.3
FACE_FRAME = {"kind": "image", "path": "assets/pixelface.jpg", "chrome": "none"}
BLUE_FRAME = {"kind": "color", "hex": DJ_BLUE, "chrome": "none"}
k, b = 0, fs
while b < face_until:
    add(b, "openWindow", {"id": "faceflash", "frame": fullscreen(),
        "content": FACE_FRAME if k % 2 == 0 else BLUE_FRAME,
        "animate": {"kind": "none"}})
    b += 0.5 / face_hz / BEAT          # one swap per half-cycle: face, blue, face, …
    k += 1
add(face_until, "closeWindow", {"id": "faceflash"})

# =============================================================================
# Cue 21 (2:00) — everything cuts out to the bare desktop, and the horse gets out.
#
# It has run in the show since the first cut; here it is the thing that has been in the
# machine all along, wall to wall, and gone again in five seconds.
# =============================================================================
hs = B["horse"]
add(hs - 0.2, "closeWindow", {"id": "wall"})
add(hs - 0.2, "closeWindow", {"id": "booth"})
add(hs, "deskWallpaper", {"id": "desk4", "mode": "solid", "hex": DJ_BLUE})
frames, gc, gr, max_lit = build_frames(cols=HORSE_COLS)
HORSE_BEATS = B["torus2"] - hs
horse, horse_exit, horse_end = horse_event(
    frames, gc, gr, W, H, span=HORSE_SPAN, start_beat=hs,
    in_beats=4, hold=round(HORSE_BEATS - 7, 1), out_beats=3)
events.append(horse)

# =============================================================================
# Cue 22 (2:05) — the horse is cut mid-stride and the glass torus takes the middle,
# ringed by a circle of lyric windows — the clock.
# =============================================================================
t2 = B["torus2"]
add(t2, "closeWindow", {"id": "horse"})
add(t2, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
add(t2, "glassTorus", {"id": "torus", "material": "crystal", "speed": 1.2,
                       "size": round(min(W, H) * 0.56)})
CLOCK_W, CLOCK_H = round(W * 0.16), round(H * 0.12)
rx, ry = W * 0.36, H * 0.40
clock_ids = []
clock_span = (B["video2"] - t2) - 0.5
for i, (_, text) in enumerate(lyrics.CUES):
    ang = -math.pi / 2 + 2 * math.pi * i / n_cue            # 12 o'clock, clockwise
    wid = f"ck{i}"
    clock_ids.append(wid)
    lyric_card(wid, t2 + 0.3 + clock_span * i / n_cue, text, i,
               frame=[round(rx * math.cos(ang)), round(ry * math.sin(ang)),
                      CLOCK_W, CLOCK_H],
               chrome="mac", animate="springIn", anchor="center")

# =============================================================================
# Cue 23 (2:08) — all of it stays, and the video slot lands on top.
# =============================================================================
placeholder("video", B["video2"], VIDEO_LABEL, [0, 0, VIDEO_W, VIDEO_H],
            title="untitled.mov")

# =============================================================================
# Cue 24 (2:09) — the torus and the ring cut out from under it, leaving the slot alone
# on a full black window. Re-opened after the black so it is above it.
# =============================================================================
v3 = B["video3"]
for wid in clock_ids + ["torus"]:
    add(v3, "closeWindow", {"id": wid})
add(v3, "openWindow", {"id": "void", "frame": fullscreen(),
    "content": {"kind": "color", "hex": BLACK, "chrome": "none"},
    "animate": {"kind": "none"}})
placeholder("video", v3 + 0.1, VIDEO_LABEL, [0, 0, VIDEO_W, VIDEO_H],
            title="untitled.mov", animate="none")

# =============================================================================
# Cue 25 (2:16) — everything cuts. TBD content; a placeholder holds the slot.
# =============================================================================
add(B["tbd_136"], "closeWindow", {"id": "void"})
add(B["tbd_136"], "closeWindow", {"id": "video"})
placeholder("tbd2", B["tbd_136"], "[ ??? ]\n\nTBD — 2:16 → 2:18",
            [0, 0, round(W * 0.40), round(H * 0.34)], title="tbd.2")

# =============================================================================
# Cue 26 (2:18) — more TBD content, and the mouse spinner.
#
# NOT BUILT: nothing in the app sets the pointer, so there is no spinner to fire. The
# slot is held by a placeholder that says so; see the Gaps section of docs/CUES.md.
# =============================================================================
add(B["spinner"] - 0.2, "closeWindow", {"id": "tbd2"})
placeholder("tbd3", B["spinner"],
            "[ ??? ]  +  mouse spinner\n\nTBD — 2:18 → 2:23\nthe spinner needs a new event",
            [0, 0, round(W * 0.46), round(H * 0.36)], title="tbd.3")

# =============================================================================
# Cue 27 (2:23) — a ton of crazy UI windows. The eruption: windows, terminals, alerts
# and lyric cards bursting out of the middle, dense from the first beat.
# =============================================================================
body_colors = PALETTE + ["#0B0E16"]
chaos_rng = random.Random(7)
chaos = {"w": 0, "d": 0, "l": 0}

def erupt(b0, b1, cx, cy, rate=0.25):
    """~8 events/sec out of (cx, cy) — the explosion, not a ramp."""
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
            add(b, "openWindow", {"id": f"w{chaos['w'] % 14}", "frame": [round(x), round(y), w, h],
                "content": {"kind": "color", "hex": chaos_rng.choice(body_colors),
                            "chrome": "mixed", "title": "look://again"},
                "animate": {"kind": "none" if chaos_rng.random() < 0.8 else "springIn"},
                "interactive": True})
            chaos["w"] += 1
        elif roll < 0.58:
            _, text = lyrics.CUES[chaos["l"] % n_cue]
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
erupt(sm, B["glitch"], W / 2, H / 2)

# The ground flashes on every kick underneath it.
flash_colors = ["#FEFEFE", BLUE, "#020202", "#68BDF8"]
n_kick = 0
for i, kt in enumerate(kicks_between(sm, B["glitch"])):
    add_t(kt, "screenFlash", {"color": flash_colors[i % len(flash_colors)],
                              "durationSeconds": 0.09})
    n_kick += 1

# =============================================================================
# Cue 28 (2:38) — the wallpaper glitches over and over, and the lyric desktop glitches
# with it: the two alternate, so the tear keeps landing on a different picture.
#
# `glitch` re-corrupts the SNAPSHOT every pass, not the current wallpaper, so it never
# compounds into noise — but it renders a full-size bitmap per frame, hence the low hz.
# =============================================================================
gl = B["glitch"]
seg, b, gi = 1.6 / BEAT, B["glitch"], 0        # ~1.6 s a segment
n_glitch = 0
while b < B["allglitch"]:
    if gi % 2 == 0:
        add(b, "deskWallpaper", {"id": f"gl{gi}", "mode": "glitch", "hz": 2.5,
                                 "intensity": 0.55 + 0.08 * (gi % 3), "seed": 1000 + gi,
                                 "durationSeconds": round(seg * BEAT, 3)})
    else:
        add(b, "deskWallpaper", {"id": f"gl{gi}", "mode": "slides", "hz": 6,
                                 "images": WORD_SLIDES,
                                 "durationSeconds": round(seg * BEAT, 3)})
    n_glitch += 1
    b += seg
    gi += 1

# =============================================================================
# Cue 29 (2:47) — a ton of windows again, and this time the whole screen goes with
# them: the original strobe, spliced in verbatim over the top.
#
# The strobe is authored in absolute seconds, which survive the splice with a plain
# offset. Everything past the ending is dropped, and the ending closes what it left.
# =============================================================================
ag = B["allglitch"]
erupt(ag, B["lastwords"], W / 2, H / 2, rate=0.18)
add(ag, "deskWallpaper", {"id": "glall", "mode": "glitch", "hz": 3, "intensity": 0.85,
                          "seed": 77,
                          "durationSeconds": round((B["lastwords"] - ag) * BEAT, 3)})

with open(os.path.join(ROOT, "examples", "timeline_strobe.json")) as f:
    strobe = json.load(f)
strobe_at = secs(ag)
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
# Cue 30 (2:51) — the noise stops and the desktop is the lyric again. Past the last
# note of the track: from here the piece is playing over silence.
# =============================================================================
lw = B["lastwords"]
add(lw, "screenFlash", {"color": WHITE, "durationBeats": 1.0})
for wid in sorted(strobe_ids) + [f"w{i}" for i in range(14)] + [f"d{i}" for i in range(4)]:
    add(lw + 0.05, "closeWindow", {"id": wid})
add(lw, "deskWallpaper", {"id": "lastwords", "mode": "slides", "hz": 4,
                          "images": WORD_SLIDES,
                          "durationSeconds": round((B["ending"] - lw) * BEAT, 3)})

# =============================================================================
# Cue 31 (2:54) — the ending. The photo the booth took, the machine's vitals and the
# credits typing themselves out, held until the card has been read.
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
# Typed by the LINE, one per beat — the probe's cadence, not a typist's. The card has to
# finish AND then sit there before the machine gives up, so the hold is derived from how
# long the copy takes rather than picked: the old show ended on the last bar of music and
# had to be sized against the track, but this card comes up 4.2 s AFTER the track ends,
# so all it has to clear is its own typing.
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
    "blue": "blue desktop", "restore": "desktop back", "welcome": "welcome (ascii)",
    "probe": "system probe", "hydra": "hydra dragged in", "blue2": "blue again",
    "face": "pixelface desktop", "traveller": "traveller + trail",
    "spiral": "lyric spiral", "video1": "video slot", "tbd_048": "TBD",
    "words": "lyrics desktop + drag", "torus1": "magic torus + greeting",
    "map": "maps: here", "fill": "windows fill", "black": "to black",
    "tbd_099": "TBD graphic", "booth": "photo booth", "wall": "photo wall",
    "facestrobe": "pixelface strobe", "horse": "the horse",
    "torus2": "torus + lyric clock", "video2": "video on top", "video3": "black + video",
    "tbd_136": "TBD", "spinner": "TBD + spinner", "spam": "UI spam",
    "glitch": "wallpaper glitch", "allglitch": "everything glitches",
    "lastwords": "lyrics desktop", "ending": "the end card",
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
                "analyzedBpm": BPM, "markers": markers,
                # The desktop is painted in cue 1, so this is on by default — with it
                # false every deskWallpaper is skipped and logged and the desktop simply
                # never changes. WallpaperController snapshots the viewer's own picture
                # before the first swap and restores it on stop, panic and quit.
                # ALLOW_WALLPAPER=0 opts back out.
                "allowWallpaper": os.environ.get("ALLOW_WALLPAPER") != "0",
                "allowDesktopFiles": os.environ.get("ALLOW_DESKTOP_FILES") == "1"},
       "events": events}
for out in (os.path.join(ROOT, "examples", "timeline_show.json"),
            # DPECore, not the executable target: the library was split out of the
            # executable so the tests could import it, and the resources went with it.
            os.path.join(ROOT, "Sources", "DPECore", "Resources", "timeline.json")):
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}")

print(f"\n{len(events)} events @ {BPM} BPM, offset {OFFSET}s, track {DURATION:.1f}s")
print(f"  {'cue':<11} {'authored':>9} {'on the grid':>12}  {'drift':>6}")
for i, (name, t) in enumerate(CUES.items(), start=1):
    g = secs(B[name])
    print(f"  {i:>2} {name:<11} {t:8.2f}s {g:11.2f}s  {g - t:+6.2f}"
          + ("   (past the end of the track)" if g > DURATION else ""))
print()
print(f"  hydra    {len(hydra_ids)} sketches, dragged one runs at {secs(HYDRA_RUN):.2f}s")
print(f"  trail    {len(trail_ids)} stamped windows over {leg} legs")
print(f"  spiral   {len(spiral_ids)} lyric cards, r {r0:.0f}→{r1:.0f}px")
print(f"  words    {len(LYRIC_WORDS)} slides @10 Hz authored "
      f"({secs(B['words']):.1f}s → {secs(B['torus1']):.1f}s)")
print(f"  fill     {len(fill_ids)} windows, 4 beats apart → 0.25")
print(f"  face     {k} strobe frames @{face_hz:.0f} Hz")
print(f"  horse    {gc}x{gr} grid, {max_lit} windows, {HORSE_SPAN:.0%} of the screen, "
      f"exits beat {horse_exit:.0f}")
print(f"  clock    {len(clock_ids)} windows round the torus")
print(f"  spam     {chaos['w']} windows, {chaos['d']} alerts, {n_kick} kick flashes")
print(f"  glitch   {n_glitch} wallpaper segments, then {n_strobe} of "
      f"{len(strobe['events'])} strobe events")
print(f"  outro    copy lands {TYPED_AT:.2f}s, holds {OUTRO_DELAY:.1f}s → quit at "
      f"{TYPED_AT + OUTRO_DELAY:.2f}s ({TYPED_AT + OUTRO_DELAY - DURATION:+.2f}s vs track end)")
print()
print("  lyric cues (tools/lyrics.py CUES) — when each card lands, in the track:")
print("   #    spiral      clock    text")
for i, (_, text) in enumerate(lyrics.CUES):
    ta = secs(sp + i * step)
    tb = secs(t2 + 0.3 + clock_span * i / n_cue)
    print(f"  {i:>2}   {ta:6.2f}s   {tb:7.2f}s   {text}")
