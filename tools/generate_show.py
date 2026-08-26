"""The show, scored to the actual track.

Reads assets/track_analysis.json (written by tools/analyze_track.py) so the grid,
the section markers and every kick come from the audio itself — the generator owns
the tempo map, nothing is patched in afterwards.

  0:00  bars  1-4    HORSE      the Muybridge window-zoetrope, wall to wall, runs in,
                                gallops, runs out
  0:08  bars  5-8    POINT      the cursor draws one long arrow, ">" in one stroke
  0:13  bars  8-10   HYDRA      a browser opens where the arrow points; the cursor
                                drags it up, pulls it bigger, clicks run
  0:19  bars 11-16   MORE       one more sketch on EVERY downbeat, each bigger
  0:29  bars 17-24   CHORUS A   the screen IS the lyric video: full-screen cards, one
                                phrase each, blue-on-white / white-on-blue, on the beat
  0:45  bars 25-32   CHORUS B   back to the desktop: the glass torus in the middle and
                                the same lyrics as small windows going round it like a
                                clock, the background glitching white and blue
  1:00  bars 33-40   BRIDGE     the system probe types out what the machine knows
  1:15  bars 41-48   FOCUS      the terminal clears and re-reads WHERE YOU ARE,
                                highlighted
  1:30  bars 49-55   REBOOT     the screen goes black; the boot glyph and a bar
  1:43  bars 56-61   VERSE 2    the machine comes back — onto a map falling out of
                                orbit onto the viewer's own location, titled with
                                their IP; then a sweep across town
  1:54  bars 62-67   ORACLE     the torus again, and an alert: ask it a question
  2:05  bars 68-71   BOOTH      Photo Booth opens on the viewer; 3 · 2 · 1 on the bars
  2:13  bar  72      CHORUS C   the shutter: one flash. Then their own photos bury
                                the screen
  2:28  bars 80-86   CHORUS D   the eruption, then the original strobe as the finale
  2:41  bar  87      BREAK      everything goes; the end card comes up and HOLDS —
                                the photo the computer took, the machine's vitals,
                                and the credits

    python3 tools/generate_show.py
    W=1440 H=900 COLS=22 python3 tools/generate_show.py

Seeded, so the show is identical take to take. Every act boundary is one BAR_*
constant below; the lyric-card timings live in tools/lyrics.py (CUES).
"""
import json, math, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_horse import PALETTE, build_frames, horse_event
from spell_path import arrow_scene
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

# --- the tempo map, straight from the analysis ---
with open(os.path.join(ROOT, "assets", "track_analysis.json")) as f:
    analysis = json.load(f)
BPM = analysis["bpm"]                  # 128.5
OFFSET = analysis["firstDownbeat"]     # 0.395 — beat 0 sits on the first downbeat
BEAT = 60.0 / BPM
KICKS = analysis["kicks"]
DURATION = analysis["duration"]

def bar(n, b=0.0):
    """Timeline beat at bar `n` (1-indexed), `b` beats into the bar."""
    return (n - 1) * 4 + b

def secs(beat):
    """Absolute seconds for a timeline beat (matches the loader's beat→time math)."""
    return OFFSET + beat * BEAT

# Structure. The chorus boundaries are 8-bar phrases from the verified drop at bar 17
# (the analyser's section detector put it three bars late — see README); the rest
# follow the artist's timeline, which lands on the same grid.
BAR_POINT    = 5     #   7.87s  the arrow
BAR_HYDRA    = 11    #  19.07s  a sketch on every downbeat from here to the drop
BAR_CHORUS_A = 17    #  30.28s  THE DROP — lyric cards
BAR_CHORUS_B = 25    #  45.22s  torus + lyric clock
BAR_BRIDGE   = 33    #  60.16s  the probe
BAR_FOCUS    = 41    #  75.10s  the probe re-reads where you are
BAR_REBOOT   = 49    #  90.05s  black; the boot bar
BAR_VERSE2   = 56    # 103.12s  the map, onto your location
BAR_SWEEP    = 60    # 110.59s  a second flight, across town
BAR_ORACLE   = 62    # 114.33s  the torus, and the question
BAR_BOOTH    = 68    # 125.55s  Photo Booth; 3·2·1 on the next three bars
BAR_CHORUS_C = 72    # 133.02s  the shutter; the photo wall
BAR_CHORUS_D = 80    # 147.96s  the eruption, then the strobe
BAR_STROBE   = 82    # 151.69s  the original strobe finale, cut by the break
BAR_BREAK    = 87    # 161.01s  everything goes; the end card

# The visuals land AHEAD of the audio drop by this much. The bass really hits at
# bar 17 / 30.28 s, but cutting exactly on it reads as late — the eye needs the
# change to have already started when the ear arrives.
#
# BOTH choruses carry it. The lyric cues are tuned by ear against chorus A, which sits
# this far early, so the same cue only means the same word in chorus B if B sits the
# same distance early too — without it the torus cut and every clock window came a
# second after the words they belonged to.
CHORUS_LEAD = 1.0
DROP_BEAT = bar(BAR_CHORUS_A) - CHORUS_LEAD / BEAT
CHORUS_B_BEAT = bar(BAR_CHORUS_B) - CHORUS_LEAD / BEAT
# The shutter is an instant, not a change of scene: a whisker ahead is enough.
SHUTTER_LEAD = 0.12

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

# =============================================================================
# Act 1: HORSE (bars 1-4) — wall to wall. Run in, a SHORT gallop in place, run out.
# =============================================================================
frames, gc, gr, max_lit = build_frames(cols=HORSE_COLS)
horse, horse_exit, horse_end = horse_event(frames, gc, gr, W, H, span=HORSE_SPAN,
                                           in_beats=6, hold=5, out_beats=5)
events.append(horse)

# =============================================================================
# Act 2: POINT (bars 5-8) — as the horse leaves, the cursor draws the arrow.
# Slower than it used to be: a fast stroke drops breadcrumb stamps on a busy
# machine and the arrow arrives half-drawn.
# =============================================================================
p_events, p_end, focal = arrow_scene(bar(BAR_POINT), W, H, speed=200, lead_beats=3)
events += p_events
fx, fy = focal

# =============================================================================
# Act 3: HYDRA (bars 8-16) — somebody using a computer.
# =============================================================================
PATCHES = [
    ("osc(10, 0.1, 300)\n  .color(0.2, 0.9, 1)\n  .diff(\n    osc(10, 0.1, 1)\n    .color(0.9, 0.1, 1)\n    .rotate(()=>time*0.4)\n    .kaleid()\n  )\n  .scrollY(()=>-time * 0.5)\n  .colorama()\n  .luma()\n  .color(0.7, 0.2, 2)\n  .repeat(4)\n  .modulate(o0, 0.1)\n  .scale(2)\n  .out()", "hydra.ojack.xyz"),
    ("osc(10, 0.01, 1.4)\n    .rotate(0, 0.4)\n    .mult(osc(10, 1).modulate(osc(10).rotate(0, -0.1), 1)).colorama().luma()\n    .color(0.1,0.9,3)\n    .scrollX(()=>time*0.1)\n    .pixelate(100)\n  .out()", "hydra.ojack.xyz"),
    ("osc(4,0.7).color(0,0.8,10)\n  .pixelate(60)\n  .kaleid()\n  .rotate(0, 0.2).modulate(o0,0.9)\n  .out()", "hydra.ojack.xyz"),
    ("shape(6, 0.9, 0.01)\n  .repeat(4, 3)\n  .rotate(0, 0.02).pixelate(100)\n  .modulate(osc(10, 0.08).rotate(0, -0.01), 0.5)\n  .color(0.1, 0.5, 3)\n  .modulate(o0,0.02)\n .out()", "hydra.ojack.xyz"),
    ("shape(3, 0.6, 0.02)\n  .kaleid(8)\n  .rotate(()=>time*0.08)\n  .diff(shape(3, 0.45, 0.02).kaleid(8).rotate(()=>-time*0.05))\n  .color(0.3, 0.7, 2.5)\n  .pixelate(120)\n  .out()", "hydra.ojack.xyz"),
    ("osc(10, 0.1, 0).rotate(0.9).out(o1)\n"
     "osc(30, 0.01, 0).color(0.2, 0.7, 3).rotate(1).modulate(o1, 0.1)\n"
     "  .modulatePixelate(o1,4,10)\n"
     "  .out(o0)\n"
     "render(o0)", "hydra.ojack.xyz"),
    ("shape(4, 0.9, 0.01)\n"
     "  .repeat(2, 4)\n"
     "  .rotate(0, 0.02).pixelate(100)\n"
     "  .modulate(osc(20, 0.01).rotate(0, -0.01), 0.8)\n"
     "  .color(0.1, 0.5, 3)\n"
     "//   .modulate(o0,0.02)\n"
     "  .out()", "hydra.ojack.xyz"),
    ("noise(3, 0.1)\n  .rotate(1, -0.2)\n  .colorama(0.5)\n  .kaleid(3)\n  .out()", "hydra.ojack.xyz"),
]

def hydra_window(wid, beat, frame, patch, running, animate="none", interactive=False):
    src, title = patch
    add(beat, "openWindow", {"id": wid, "frame": [round(v) for v in frame],
        "content": {"kind": "livecode", "text": src, "title": title,
                    "chrome": "browser", "hex": "#68BDF8", "running": running},
        "animate": {"kind": animate},
        "interactive": interactive, "respawn": interactive})

# The scene picks up the instant the arrow's cursor finishes its glide — no gap.
HY = p_end + 0.2

# 1. it appears where the arrow points, small, code written but NOT running
small = (min(fx - 40, W - 340), min(fy - 34, H - 220), 320, 200)
hydra_window("hy0", HY, small, PATCHES[0], running=False,
             animate="springIn", interactive=True)

# 2. the cursor takes it by the title bar and drags it up the screen — window and
# pointer travel together, so it reads as a drag rather than the window moving itself
grab = (small[0] + small[2] * 0.5, small[1] + 12)
add(HY + 1, "cursorPath", {"path": "linear", "durationBeats": 1.2, "easing": "easeInOut",
    "mode": "warp", "points": [[round(fx), round(fy)], [round(grab[0]), round(grab[1])]]})
lifted = (W * 0.30, H * 0.24, small[2], small[3])
add(HY + 2.5, "moveWindow", {"id": "hy0", "frame": [round(lifted[0]), round(lifted[1])],
    "durationBeats": 1.6, "easing": "easeInOut"})
add(HY + 2.5, "cursorPath", {"path": "linear", "durationBeats": 1.6, "easing": "easeInOut",
    "mode": "warp", "points": [[round(grab[0]), round(grab[1])],
                               [round(lifted[0] + small[2] * 0.5), round(lifted[1] + 12)]]})

# 3. resize by the LOWER-RIGHT CORNER: the top-left stays exactly where it is and the
# window grows down and to the right, so the code never moves off its corner.
corner = (lifted[0] + lifted[2], lifted[1] + lifted[3])
big = (lifted[0], lifted[1], W * 0.46, H * 0.52)
new_corner = (big[0] + big[2], big[1] + big[3])
add(HY + 4.6, "cursorPath", {"path": "linear", "durationBeats": 1.2, "easing": "easeInOut",
    "mode": "warp", "points": [[round(lifted[0] + small[2] * 0.5), round(lifted[1] + 12)],
                               [round(corner[0]), round(corner[1])]]})
add(HY + 6.2, "moveWindow", {"id": "hy0",
    "frame": [round(big[0]), round(big[1]), round(big[2]), round(big[3])],
    "durationBeats": 2, "easing": "easeOut"})
add(HY + 6.2, "cursorPath", {"path": "linear", "durationBeats": 2, "easing": "easeOut",
    "mode": "warp", "points": [[round(corner[0]), round(corner[1])],
                               [round(new_corner[0]), round(new_corner[1])]]})
# Re-open at the final size once the drag settles: the stretched-during-resize layout
# gets rebuilt cleanly at the new dimensions. Still not running.
add(HY + 8.4, "openWindow", {"id": "hy0",
    "frame": [round(big[0]), round(big[1]), round(big[2]), round(big[3])],
    "content": {"kind": "livecode", "text": PATCHES[0][0], "title": PATCHES[0][1],
                "chrome": "browser", "hex": "#68BDF8", "running": False},
    "animate": {"kind": "none"}, "interactive": True, "respawn": True})

# 4. up to hydra's run button, top-right — and the sketch starts. The click lands on
# the downbeat of BAR_HYDRA if the drag has left room for it, else as soon as it can.
play = (big[0] + big[2] - 26, big[1] + 34)
add(HY + 8.6, "cursorPath", {"path": "linear", "durationBeats": 1.4, "easing": "easeInOut",
    "mode": "warp", "points": [[round(new_corner[0]), round(new_corner[1])],
                               [round(play[0]), round(play[1])]]})
RUN_AT = max(HY + 10.2, bar(BAR_HYDRA))
hydra_window("hy0", RUN_AT, big, PATCHES[0], running=True, interactive=True)
add(RUN_AT, "screenFlash", {"color": "#68BDF8", "durationSeconds": 0.06})

# 5. one more on EVERY downbeat until the drop — evenly, on the beat, each bigger
# than the last, scattered so nothing sits on anything else.
rng = random.Random(11)
hydra_ids = ["hy0"]
spots = [(big[0], big[1])]

def place(w, h):
    """A scattered spot that isn't sitting on top of one we already used."""
    for _ in range(60):
        x = rng.uniform(20, W - w - 20)
        y = rng.uniform(20, H - h - 20)
        if all(abs(x - px) > 130 or abs(y - py) > 110 for px, py in spots):
            break
    spots.append((x, y))
    return x, y

first_more = int(RUN_AT // 4) + 2                      # the next downbeat strictly after the run
more_bars = list(range(first_more, BAR_CHORUS_A))       # …up to, not including, the drop
for i, bn in enumerate(more_bars, start=1):
    wid = f"hy{i}"
    hydra_ids.append(wid)
    scale = 1.15 + 0.32 * (i - 1)
    w = min(round(240 * scale), round(W * 0.52))
    h = min(round(155 * scale), round(H * 0.52))
    x, y = place(w, h)
    hydra_window(wid, bar(bn), (x, y, w, h), PATCHES[i % len(PATCHES)], running=True,
                 animate="springIn", interactive=True)

# =============================================================================
# Act 4: CHORUS A (bars 17-24) — the lyric video. The stack blows away under the
# first card; from then on the whole screen is one phrase at a time, the ground and
# the type swapping blue/white card to card, on the beat.
# =============================================================================
drop = DROP_BEAT
for wid in hydra_ids:
    add(drop + 0.05, "closeWindow", {"id": wid})
add(drop + 0.05, "closeWindow", {"id": "trace"})     # the arrow goes too

def lyric_card(wid, beat, text, i, frame=None, chrome="none", animate="none", anchor=None):
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

def cue_beats(when):
    """Beats from a chorus's (lead-adjusted) start for one CUES entry.

    A number is already beats from the start of the chorus. A string like "34.10s" is a
    time in the TRACK, as heard in chorus A — read straight off the waveform or a
    player's clock — and the card lands on exactly that instant: the chorus starts
    CHORUS_LEAD early, so that much is folded back in. The same cue puts the clock
    window at the same point of chorus B, which starts the same distance early.
    """
    if isinstance(when, str):
        t = float(when.strip().rstrip("s"))
        return (t - secs(bar(BAR_CHORUS_A)) + CHORUS_LEAD) / BEAT
    return float(when)

# Two fullscreen ids, alternating: the new card opens over the old one, and the old
# one is reused for the card after that. Reopening an id is a content swap, not a
# window create, which is what keeps this on the beat.
n_cards = 0
for i, (when, text) in enumerate(lyrics.CUES):
    lyric_card(f"ly{i % 2}", drop + cue_beats(when), text, i)
    n_cards += 1

# =============================================================================
# Act 5: CHORUS B (bars 25-32) — the desktop again. The glass torus lands in the
# middle and the same lyrics come back as small windows going round it like a
# clock, one per cue, accumulating. The background glitches white and blue.
# =============================================================================
b_start = CHORUS_B_BEAT          # CHORUS_LEAD early, like the drop — see there
add(b_start, "screenFlash", {"color": WHITE, "durationBeats": 0.5})
add(b_start + 0.02, "closeWindow", {"id": "ly0"})
add(b_start + 0.02, "closeWindow", {"id": "ly1"})
TORUS_SIZE = round(min(W, H) * 0.60)
add(b_start, "glassTorus", {"id": "torus", "material": "glass", "speed": 0.8,
                            "size": TORUS_SIZE})

CLOCK_W, CLOCK_H = round(W * 0.16), round(H * 0.12)
rx, ry = W * 0.36, H * 0.40                      # an ellipse hugging the screen
clock_ids = []
for i, (when, text) in enumerate(lyrics.CUES):
    ang = -math.pi / 2 + 2 * math.pi * i / len(lyrics.CUES)     # 12 o'clock, clockwise
    # Authored from the screen's CENTRE (`anchor: center`), like the torus itself, so
    # the ring is round it on any display. Top-left frames put the ring's centre at
    # (W/2, H/2) of the AUTHORED size — on a bigger screen that is left of and above
    # the torus, which is where the whole clock used to lean.
    frame = [round(rx * math.cos(ang)), round(ry * math.sin(ang)), CLOCK_W, CLOCK_H]
    wid = f"ck{i}"
    clock_ids.append(wid)
    lyric_card(wid, b_start + cue_beats(when), text, i, frame=frame, chrome="mac",
               animate="springIn", anchor="center")

# The glitch: a short white or blue wash behind everything on every third kick, and
# now and then two in a row — a background that can't quite hold still.
glitch_rng = random.Random(31)
n_glitch = 0
for i, kt in enumerate(kicks_between(b_start, bar(BAR_BRIDGE))):
    if i % 3 != 0:
        continue
    color = WHITE if (i // 3) % 2 == 0 else BLUE
    add_t(kt, "screenFlash", {"color": color, "durationSeconds": 0.08})
    n_glitch += 1
    if glitch_rng.random() < 0.35:
        add_t(kt + 0.14, "screenFlash", {"color": BLUE if color == WHITE else WHITE,
                                         "durationSeconds": 0.05})
        n_glitch += 1

# =============================================================================
# Act 6: BRIDGE (bars 33-40) — the probe. The clock goes; a terminal opens in the
# middle and types out what the machine knows, slowly enough to be read.
# =============================================================================
br = bar(BAR_BRIDGE)
add(br, "screenFlash", {"color": BLUE, "durationBeats": 0.5})
for wid in clock_ids + ["torus"]:
    add(br + 0.05, "closeWindow", {"id": wid})
PROBE_FRAME = [round(W * 0.18), round(H * 0.08), round(W * 0.64), round(H * 0.84)]
add(br + 0.3, "systemProbe", {"id": "probe", "linesPerBeat": 6, "frame": PROBE_FRAME})

# =============================================================================
# Act 7: FOCUS (bars 41-48) — the terminal clears and reads out just WHERE YOU ARE
# and what you're connected to, every line highlighted. Slower still.
# =============================================================================
fo = bar(BAR_FOCUS)
add(fo, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
add(fo, "systemProbe", {"id": "probe", "linesPerBeat": 3, "frame": PROBE_FRAME,
                        "focus": ["geolocation", "network"]})

# =============================================================================
# Act 8: REBOOT (bars 49-55) — the machine has seen enough. Black; the glyph; the
# bar fills across the phrase; then black again, and the desktop comes back on the
# downbeat of verse 2 — onto the map.
# =============================================================================
rb = bar(BAR_REBOOT)
REBOOT_BEATS = bar(BAR_VERSE2) - rb          # 28 beats black, bar filling most of it
add(rb, "reboot", {"id": "boot", "delayBeats": 3, "durationBeats": REBOOT_BEATS - 6})
add(rb + 0.1, "closeWindow", {"id": "probe"})
# The last beat is black-on-black: the glyph goes, then the desktop is simply there.
add(bar(BAR_VERSE2, -1), "openWindow", {"id": "blackout", "frame": fullscreen(),
    "content": {"kind": "color", "hex": "#000000", "chrome": "none"},
    "animate": {"kind": "none"}})
add(bar(BAR_VERSE2, -0.95), "closeWindow", {"id": "boot"})

# =============================================================================
# Act 9: VERSE 2 (bars 56-61) — the map. It falls out of orbit onto the viewer's own
# location (`here`: the fix the probe got), the window titled with their address.
# Then a second flight sweeps across town at rooftop height.
# =============================================================================
v2 = bar(BAR_VERSE2)
add(v2, "closeWindow", {"id": "blackout"})
add(v2, "screenFlash", {"color": WHITE, "durationBeats": 0.3})
# Fallback coordinates if there's no fix: Shanghai. `here` overrides them when there is.
FALL = dict(lat=31.2304, lon=121.4737)
DESCENT = dict(FALL, here=True, altitude=2_600_000, toAltitude=260,
               pitch=0, toPitch=62, heading=0, toHeading=30,
               seconds=round((bar(BAR_SWEEP) - v2) * BEAT - 0.5, 1), style=MAP_STYLE)
add(v2, "openWindow", {"id": "map0",
    "frame": [round(W * 0.10), round(H * 0.07), round(W * 0.80), round(H * 0.78)],
    "content": {"kind": "map", "chrome": "browser", "title": "maps://{ip}", "map": DESCENT},
    "animate": {"kind": "springIn"}, "interactive": True, "respawn": True})
SWEEP = dict(FALL, here=True, altitude=260, toAltitude=900,
             pitch=62, toPitch=55, heading=30, toHeading=230,
             seconds=round((bar(BAR_ORACLE) - bar(BAR_SWEEP)) * BEAT + 2.0, 1), style=MAP_STYLE)
add(bar(BAR_SWEEP), "openWindow", {"id": "map1",
    "frame": [round(W * 0.30), round(H * 0.22), round(W * 0.66), round(H * 0.72)],
    "content": {"kind": "map", "chrome": "browser", "title": "maps://{city}", "map": SWEEP},
    "animate": {"kind": "springIn"}, "interactive": True})

# =============================================================================
# Act 10: ORACLE (bars 62-67) — the torus again, and this time it talks: an alert
# asks for a question and answers on OK, or on its own two bars later.
# =============================================================================
orc = bar(BAR_ORACLE)
add(orc, "screenFlash", {"color": BLUE, "durationBeats": 0.4})
add(orc + 0.05, "closeWindow", {"id": "map0"})
add(bar(BAR_ORACLE + 1), "closeWindow", {"id": "map1"})
add(orc, "glassTorus", {"id": "torus", "material": "crystal", "speed": 1.2,
                        "size": round(min(W, H) * 0.56)})
add(bar(BAR_ORACLE + 1), "oracle", {"id": "oracle",
    "frame": [round(W * 0.5 + min(W, H) * 0.30), round(H * 0.5 - 93), 460, 186],
    "title": "hey, i'm the magic torus", "body": "ask me a question",
    "placeholder": "will you give it 2 me?", "answerBeats": 10})

# =============================================================================
# Act 11: BOOTH (bars 68-71) — Photo Booth opens on the viewer. 3, 2, 1 land on the
# downbeats of the last three bars; the shutter is the drop.
# =============================================================================
bo = bar(BAR_BOOTH) - SHUTTER_LEAD / BEAT
add(bar(BAR_BOOTH, -0.5), "closeWindow", {"id": "oracle"})
add(bar(BAR_BOOTH, -0.5), "closeWindow", {"id": "torus"})
add(bar(BAR_BOOTH, -0.5), "screenFlash", {"color": WHITE, "durationBeats": 0.3})
BOOTH_W, BOOTH_H = round(min(W * 0.52, 760)), round(min(W * 0.52, 760) * 0.78)
add(bo, "photoBooth", {"id": "booth",
    "frame": [round((W - BOOTH_W) / 2), round((H - BOOTH_H) * 0.45), BOOTH_W, BOOTH_H],
    "durationBeats": bar(BAR_CHORUS_C) - bar(BAR_BOOTH), "count": 3, "stepBeats": 4})

# =============================================================================
# Act 12: CHORUS C (bars 72-79) — the shutter. ONE flash, the booth goes with it, and
# their own photos start burying the screen.
# =============================================================================
shutter = bar(BAR_CHORUS_C) - SHUTTER_LEAD / BEAT
add(shutter, "screenFlash", {"color": "#FFFFFF", "durationBeats": 0.6})
add(bar(BAR_CHORUS_C, 0.25), "photoWall", {"id": "wall", "fillPerBeat": 12, "churnPerBeat": 2.6,
                                            "windows": 40, "minFrac": 0.10, "maxFrac": 0.42})

# =============================================================================
# Act 13: CHORUS D (bars 80-86) — the eruption from the first chorus, two bars of it,
# then the original strobe as the finale until the break cuts it.
# =============================================================================
cd = bar(BAR_CHORUS_D)
add(cd, "screenFlash", {"color": "#FF2D95", "durationBeats": 0.75})
add(cd + 0.05, "closeWindow", {"id": "wall"})

codes = lyrics.CODE
dialogs = lyrics.ALERTS
body_colors = PALETTE + ["#0B0E16"]
chaos_rng = random.Random(7)

def erupt(b0, b1, cx, cy):
    """Windows, terminals, alerts and lyric cards bursting out of (cx, cy), dense
    from the first beat — the explosion, not a ramp. ~8 events/sec."""
    b, wi, di, li = b0, 0, 0, 0
    while b < b1:
        u = 0.75 + 0.25 * (b - b0) / (b1 - b0)
        r = 30 + (u ** 1.6) * 0.65 * W * chaos_rng.uniform(0.5, 1.0)
        ang = chaos_rng.uniform(0, 6.28318)
        w = round((110 + (u ** 1.7) * 380) * chaos_rng.uniform(0.8, 1.25))
        h = round(w * chaos_rng.uniform(0.6, 0.85))
        x = max(10, min(cx + r * math.cos(ang) - w / 2, W - w - 10))
        y = max(10, min(cy + r * math.sin(ang) - h / 2, H - h - 10))
        roll = chaos_rng.random()
        if roll < 0.42:
            add(b, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), w, h],
                "content": {"kind": "color", "hex": chaos_rng.choice(body_colors),
                            "chrome": "mixed", "title": "look://again"},
                "animate": {"kind": "none" if chaos_rng.random() < 0.8 else "springIn"},
                "interactive": True})
            wi += 1
        elif roll < 0.58:
            _, text = lyrics.CUES[li % len(lyrics.CUES)]
            lyric_card(f"w{wi % 14}", b, text, li, frame=[round(x), round(y), max(w, 260), h],
                       chrome="mac")
            wi += 1; li += 1
        elif roll < 0.70:
            add(b, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), max(w, 300), h],
                "content": {"kind": "code", "text": chaos_rng.choice(codes), "chrome": "terminal",
                            "title": "haunt.sh"},
                "animate": {"kind": "none"}, "interactive": True})
            wi += 1
        elif roll < 0.86:
            title, body, icon = dialogs[di % len(dialogs)]
            add(b, "fakeDialog", {"id": f"d{di % 4}", "title": title, "body": body,
                "buttons": lyrics.buttons(di), "icon": icon,
                "frame": [round(x), round(y), 460, 190]})
            di += 1
        elif wi > 0:
            add(b, "jiggle", {"id": f"w{(wi - 1) % 14}", "durationBeats": 1.5,
                "amplitude": 18, "frequency": 9})
        b += max(0.15, 0.25 * chaos_rng.uniform(0.7, 1.3))

# …up to the wipe, not the strobe: a nudge aimed past the wipe hits a closed window.
wipe = bar(BAR_STROBE) - 0.3
erupt(cd + 0.1, wipe, W / 2, H / 2)

# The background flashes on every kick under the eruption (behind the windows).
flash_colors = ["#FEFEFE", BLUE, "#020202", "#68BDF8"]
n_kick = 0
for i, kt in enumerate(kicks_between(cd, bar(BAR_STROBE))):
    if abs(kt - secs(cd)) < 0.25:
        continue
    add_t(kt, "screenFlash", {"color": flash_colors[i % len(flash_colors)],
                              "durationSeconds": 0.09})
    n_kick += 1

# Wipe, then the ORIGINAL strobe, spliced in verbatim. Its events are authored in
# absolute seconds, which survive the splice with a plain offset; everything past the
# break is dropped, and the break closes whatever it left open.
add(wipe, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
for i in range(14):
    add(wipe + 0.1, "closeWindow", {"id": f"w{i}"})
for i in range(4):
    add(wipe + 0.1, "closeWindow", {"id": f"d{i}"})

with open(os.path.join(ROOT, "examples", "timeline_strobe.json")) as f:
    strobe = json.load(f)
strobe_at = secs(bar(BAR_STROBE))
strobe_cut = secs(bar(BAR_BREAK)) - 0.05
strobe_ids, n_strobe = set(), 0
for ev in strobe["events"]:
    if ev["t"] + strobe_at >= strobe_cut:
        continue
    add_t(ev["t"] + strobe_at, ev["type"], ev["params"])
    n_strobe += 1
    if "id" in ev["params"]:
        strobe_ids.add(ev["params"]["id"])

# =============================================================================
# Act 14: BREAK (bar 87) — everything goes at once, and the end card comes up and
# stays: the photo the booth took, the machine's vitals, and the credits typing
# themselves out. The engine holds on it past the end of the track.
# =============================================================================
brk = bar(BAR_BREAK)
add(brk, "screenFlash", {"color": WHITE, "durationBeats": 1.5})
for wid in sorted(strobe_ids) + ["wall", "booth", "torus", "oracle", "probe"]:
    add(brk + 0.05, "closeWindow", {"id": wid})
# One entry per line; interior blanks are the stanza breaks and are typed through.
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
# The card has to finish AND then sit there before the machine gives up. Typing is by
# the line, so the copy lands len(CREDITS)/linesPerSecond after the card comes up, and
# the outro waits `outroDelay` on top of that before the force-quit alert.
#
# Sized so the finished card — photo, credits, summary, all of it — is complete and
# still on screen until the track has actually ended, plus a beat of silence to read
# it. At the authored tempo the copy lands at ~166.6s against a 169.9s track, so the
# stock 2s default put the alert up at ~168.6s, over the last bar of music: the machine
# gave up while the song was still playing. Derived rather than hard-coded so it stays
# right if the track, the tempo or the credits copy change.
CREDITS_LPS = round(1 / BEAT, 3)
CARD_AT = secs(bar(BAR_BREAK, 1))
TYPED_AT = CARD_AT + len(CREDITS) / CREDITS_LPS
END_PAD = 3.0                    # silence after the last note before the alert
OUTRO_DELAY = round(max(2.0, DURATION + END_PAD - TYPED_AT), 2)

add(bar(BAR_BREAK, 1), "credits", {"id": "credits", "lines": CREDITS, "hold": True,
    # Typed by the LINE, one per beat — the probe's cadence, not a typist's — and in
    # type big enough to read from across the room. The photo is pinned on at a tilt.
    "linesPerSecond": CREDITS_LPS, "fontSize": 22, "photoTilt": -4,
    # How long the completed card holds before the force-quit alert.
    "outroDelay": OUTRO_DELAY,
    # Tiled behind the card, drifting diagonally one tile per 4 s. Missing file =>
    # plain black backdrop, logged, show unaffected.
    # The card's ground. White, to match the tile artwork's own field — the tile fills
    # its padding with that same colour, so the card reads as one continuous ground.
    "backdrop": "#FFFFFF",
    "tile": "assets/credits_tile.png", "tileDriftSeconds": 4})

# --- markers for the scrubber: the analyser's sections plus the act boundaries ---
markers = list(analysis["markers"])
markers += [
    {"t": round(secs(bar(BAR_HYDRA)), 2),    "bar": BAR_HYDRA,    "label": "hydra stack", "kind": "section"},
    {"t": round(secs(bar(BAR_CHORUS_A)), 2), "bar": BAR_CHORUS_A, "label": "CHORUS A · lyrics", "kind": "drop"},
    {"t": round(secs(bar(BAR_CHORUS_B)), 2), "bar": BAR_CHORUS_B, "label": "CHORUS B · torus clock", "kind": "drop"},
    {"t": round(secs(bar(BAR_BRIDGE)), 2),   "bar": BAR_BRIDGE,   "label": "probe", "kind": "section"},
    {"t": round(secs(bar(BAR_FOCUS)), 2),    "bar": BAR_FOCUS,    "label": "focus: where you are", "kind": "section"},
    {"t": round(secs(bar(BAR_REBOOT)), 2),   "bar": BAR_REBOOT,   "label": "reboot", "kind": "break"},
    {"t": round(secs(bar(BAR_VERSE2)), 2),   "bar": BAR_VERSE2,   "label": "map: here", "kind": "section"},
    {"t": round(secs(bar(BAR_ORACLE)), 2),   "bar": BAR_ORACLE,   "label": "oracle", "kind": "section"},
    {"t": round(secs(bar(BAR_BOOTH)), 2),    "bar": BAR_BOOTH,    "label": "photo booth", "kind": "section"},
    {"t": round(secs(bar(BAR_CHORUS_C)), 2), "bar": BAR_CHORUS_C, "label": "CHORUS C · shutter", "kind": "drop"},
    {"t": round(secs(bar(BAR_CHORUS_D)), 2), "bar": BAR_CHORUS_D, "label": "CHORUS D · eruption", "kind": "drop"},
    {"t": round(secs(bar(BAR_STROBE)), 2),   "bar": BAR_STROBE,   "label": "strobe", "kind": "drop"},
    {"t": round(secs(bar(BAR_BREAK)), 2),    "bar": BAR_BREAK,    "label": "credits", "kind": "break"},
]
markers.sort(key=lambda m: m["t"])

def when(e):
    return e["t"] if "t" in e else secs(e["beat"])
events.sort(key=when)

doc = {"meta": {"bpm": BPM, "beatOffset": OFFSET, "audioFile": AUDIO,
                "analyzedBpm": BPM, "markers": markers,
                # Both default false: nothing in this show writes to disk or touches
                # the wallpaper.
                "allowWallpaper": os.environ.get("ALLOW_WALLPAPER") == "1",
                "allowDesktopFiles": os.environ.get("ALLOW_DESKTOP_FILES") == "1"},
       "events": events}
for out in (os.path.join(ROOT, "examples", "timeline_show.json"),
            # DPECore, not the executable target: the library was split out of the
            # executable so the tests could import it, and the resources went with it.
            os.path.join(ROOT, "Sources", "DPECore", "Resources", "timeline.json")):
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}")

print(f"{len(events)} events @ {BPM} BPM, offset {OFFSET}s, track {DURATION:.1f}s")
print(f"  horse    bar  1     {secs(0):6.2f}s  {gc}x{gr} grid, {max_lit} windows, "
      f"{HORSE_SPAN:.0%} of the screen, exits beat {horse_exit:.0f}")
print(f"  point    bar {BAR_POINT:>2}     {secs(bar(BAR_POINT)):6.2f}s  ends beat {p_end:.1f} "
      f"→ focal ({fx:.0f},{fy:.0f})")
print(f"  hydra              {secs(HY):6.2f}s  opens at the arrow's tip, runs at "
      f"{secs(RUN_AT):.2f}s (bar {RUN_AT / 4 + 1:.2f})")
print(f"  more     bars {more_bars[0]}-{more_bars[-1]}  one per downbeat → {len(hydra_ids)} sketches")
print(f"  CHORUS A bar {BAR_CHORUS_A:>2}     {secs(drop):6.2f}s  {n_cards} lyric cards "
      f"(lead {CHORUS_LEAD:.1f}s)")
print(f"  CHORUS B bar {BAR_CHORUS_B:>2}     {secs(b_start):6.2f}s  torus + {len(clock_ids)} clock windows, "
      f"{n_glitch} glitch flashes")
print(f"  probe    bar {BAR_BRIDGE:>2}     {secs(br):6.2f}s  full report @ 6 lines/beat")
print(f"  focus    bar {BAR_FOCUS:>2}     {secs(fo):6.2f}s  geolocation + network, highlighted")
print(f"  reboot   bar {BAR_REBOOT:>2}     {secs(rb):6.2f}s  black for {REBOOT_BEATS * BEAT:.1f}s")
print(f"  map      bar {BAR_VERSE2:>2}    {secs(v2):6.2f}s  descent {DESCENT['seconds']}s → "
      f"sweep at {secs(bar(BAR_SWEEP)):.2f}s ({MAP_STYLE})")
print(f"  oracle   bar {BAR_ORACLE:>2}    {secs(orc):6.2f}s  torus + question")
print(f"  booth    bar {BAR_BOOTH:>2}    {secs(bo):6.2f}s  3·2·1 on bars {BAR_BOOTH + 1}-{BAR_BOOTH + 3}, "
      f"shutter {secs(shutter):.2f}s")
print(f"  CHORUS C bar {BAR_CHORUS_C:>2}    {secs(bar(BAR_CHORUS_C)):6.2f}s  photo wall")
print(f"  CHORUS D bar {BAR_CHORUS_D:>2}    {secs(cd):6.2f}s  eruption, {n_kick} kick flashes")
print(f"  strobe   bar {BAR_STROBE:>2}    {strobe_at:6.2f}s  {n_strobe} of {len(strobe['events'])} events "
      f"before the break")
print(f"  break    bar {BAR_BREAK:>2}    {secs(brk):6.2f}s  credits hold past the end ({DURATION:.1f}s)")
print(f"  outro              {TYPED_AT:6.2f}s  copy lands; card holds {OUTRO_DELAY:.2f}s → "
      f"force-quit at {TYPED_AT + OUTRO_DELAY:.2f}s ({TYPED_AT + OUTRO_DELAY - DURATION:+.2f}s vs track end)")
print()
print("  lyric cues (tools/lyrics.py CUES) — when each card lands, in the track:")
print("   #   chorus A   chorus B   text")
for i, (when, text) in enumerate(lyrics.CUES):
    ta = secs(drop + cue_beats(when))
    tb = secs(b_start + cue_beats(when))
    print(f"  {i:>2}   {ta:6.2f}s    {tb:6.2f}s   {text}")
