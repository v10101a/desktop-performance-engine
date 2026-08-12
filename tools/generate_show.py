"""The show, scored to the actual track.

Reads assets/track_analysis.json (written by tools/analyze_track.py) so the grid,
the section markers and every kick come from the audio itself — the generator owns
the tempo map, nothing is patched in afterwards.

  bars  1-4    HORSE    the Muybridge window-zoetrope runs in, gallops, runs out
  bars  5-8    POINT    the cursor draws one long arrow, unhurried, ">" in one stroke
  bars  8-11   HYDRA    somebody using a computer: a little browser opens at exactly
                        the spot the arrow pointed at, the cursor drags it up, pulls it
                        bigger and clicks run — only then does the sketch render
  bars 12-15   MORE     one, two, three, four more, already running when they land
  ~1s          BUILD    the biggest ones slam in
  bar   17     CHORUS   THE DROP, fired CHORUS_LEAD seconds AHEAD of the bass so it
                        doesn't read as late. Everything blows away, the background
                        flashes on every detected kick, chaos erupts from the focal spot
  bar   24     STROBE   the original strobe finale, spliced in verbatim
  after        the rest of the track is not scored yet — a lower-left (kick) window
                        blinks the beat as a placeholder

    python3 tools/generate_show.py
    W=1440 H=900 HUSH=0 python3 tools/generate_show.py

Seeded, so the show is identical take to take.
"""
import json, math, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_horse import PALETTE, build_frames, horse_event
from spell_path import arrow_scene

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
W = int(os.environ.get("W", "1440"))
H = int(os.environ.get("H", "900"))
HUSH = os.environ.get("HUSH", "1") != "0"     # honour the bar where the bass drops out
AUDIO = "assets/03 - Give it 2 me.mp3"

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

# Structure, verified against per-bar RMS energy in the audio (not the section
# detector, which put the chorus 3 bars late at 35.87s):
BAR_POINT   = 5     #  7.87s
BAR_HYDRA   = 9     # 15.34s  windows start stacking
BAR_HUSH    = 15    # 26.54s  sub-bass energy 0.198 -> 0.012: the bass drops out
BAR_BUILD   = 16    # 28.41s  it comes back
BAR_CHORUS  = 17    # 30.28s  THE DROP
BAR_STROBE  = 24    # 43.35s
BAR_LETTER  = 33    # 60.16s  the strobe is over; someone starts typing
BAR_MAP     = 56    # 103.12s the letter is finished; close it and fly

# The run-up: one second of windows slamming in, then the drop. Short on purpose —
# a long visual build reads as the drop having already happened.
BUILD_SECONDS = 1.0
BUILD_WINDOWS = 3

# The visuals land AHEAD of the audio drop by this much. The bass really hits at
# bar 17 / 30.28 s, but cutting exactly on it reads as late — the eye needs the
# change to have already started when the ear arrives.
CHORUS_LEAD = 1.0

DROP_BEAT = bar(BAR_CHORUS) - CHORUS_LEAD / BEAT

events = []
def add(beat, typ, params):
    events.append({"beat": round(beat, 3), "type": typ, "params": params})
def add_t(t, typ, params):
    events.append({"t": round(t, 3), "type": typ, "params": params})

# --- Act 1: HORSE (bars 1-4) — run in, a SHORT gallop in place, run out ---
frames, gc, gr, max_lit = build_frames()
horse, horse_exit, horse_end = horse_event(frames, gc, gr, W, H,
                                           in_beats=6, hold=5, out_beats=5)
events.append(horse)

# --- Act 2: POINT (bars 5-8) — as the horse leaves, the cursor draws the arrow.
# Slower than it used to be: a fast stroke drops breadcrumb stamps on a busy
# machine and the arrow arrives half-drawn. ---
p_events, p_end, focal = arrow_scene(bar(BAR_POINT), W, H, speed=200, lead_beats=3)
events += p_events
fx, fy = focal

# --- Act 3: HYDRA (bars 9-16) — small browser windows of livecoding source,
# opening on the beat, more and more of them, cascading up-left from the exact
# spot the arrow pointed at. They all stay open until the drop. ---
PATCHES = [
    ("osc(40, 0.1, 0.8)\n  .kaleid(5)\n  .rotate(0.2, 0.1)\n  .out()", "hydra.ojack.xyz"),
    ("noise(6, 0.12)\n  .colorama(0.4)\n  .kaleid(6)\n  .out()", "hydra — sketch 02"),
    ("voronoi(14, 0.3)\n  .diff(osc(30, 0.2))\n  .rotate(0, 0.15)\n  .out()", "hydra — sketch 03"),
    ("shape(4, 0.4)\n  .repeat(3, 3)\n  .scrollX(0.08)\n  .kaleid(4)\n  .out()", "hydra — sketch 04"),
    ("osc(90, 0.05, 1.2)\n  .thresh(0.4)\n  .kaleid(9)\n  .rotate(0, -0.2)\n  .out()", "hydra — sketch 05"),
    ("gradient(0.4)\n  .diff(noise(9, 0.1))\n  .colorama(0.6)\n  .kaleid(7)\n  .out()", "hydra — sketch 06"),
    ("osc(60, 0.2)\n  .mult(voronoi(20, 0.2))\n  .pixelate(24)\n  .out()", "hydra — sketch 07"),
    ("noise(3, 0.1)\n  .rotate(1, -0.2)\n  .colorama(0.5)\n  .kaleid(3)\n  .out()", "hydra — sketch 08"),
]

# --- Act 3: HYDRA. It reads as somebody actually using a computer: a little browser
# opens at exactly the spot the arrow pointed at (that was the whole point of the
# arrow), the cursor drags it up, pulls it bigger, and clicks run — and only THEN does
# the sketch start rendering. Once it's live, more of them arrive already running. ---
HY_SRC, HY_TITLE = PATCHES[0]

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

# 4. up to hydra's run button, top-right — and the sketch starts
play = (big[0] + big[2] - 26, big[1] + 34)
add(HY + 8.6, "cursorPath", {"path": "linear", "durationBeats": 1.4, "easing": "easeInOut",
    "mode": "warp", "points": [[round(new_corner[0]), round(new_corner[1])],
                               [round(play[0]), round(play[1])]]})
RUN_AT = HY + 10.4
hydra_window("hy0", RUN_AT, big, PATCHES[0], running=True, interactive=True)
add(RUN_AT, "screenFlash", {"color": "#68BDF8", "durationSeconds": 0.06})

# 5. FOUR more, spread out and closing in — the long ramp…
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

# Four windows with the gap shrinking, so the stack is already accelerating…
SPREAD_GAPS = [5.0, 4.0, 3.5]        # beats between the four
# …then the whole run-up collapses into ONE SECOND: four more, faster and faster,
# the last one landing right on top of the drop.
RISER_SECONDS = 1.0
RISER_COUNT = 4

schedule = []
b = RUN_AT + 4.5
schedule.append((b, 1.15))
for gap in SPREAD_GAPS:
    b += gap
    schedule.append((b, 1.15 + 0.30 * len(schedule)))

# Riser positions: evenly spaced in TIME would read as a metronome, so they ride a
# curve — each gap SHORTER than the last, bunching up against the drop.
riser_beats = RISER_SECONDS / BEAT
for i in range(RISER_COUNT):
    lead = riser_beats * ((1 - i / RISER_COUNT) ** 1.6)   # 1.00, 0.64, 0.33, 0.11
    schedule.append((DROP_BEAT - lead, 2.6 + 0.22 * i))

for i, (beat, scale) in enumerate(schedule, start=1):
    wid = f"hy{i}"
    hydra_ids.append(wid)
    w = min(round(240 * scale), round(W * 0.52))
    h = min(round(155 * scale), round(H * 0.52))
    x, y = place(w, h)
    riser = i > 1 + len(SPREAD_GAPS)
    hydra_window(wid, beat, (x, y, w, h), PATCHES[i % len(PATCHES)], running=True,
                 animate="springIn" if riser else "none", interactive=True)

# --- Act 4: CHORUS (bar 17) — the drop. Wipe the stack, then chaos erupts from
# the focal point while the background flashes on every real kick. ---
drop = DROP_BEAT
authored_flashes = [secs(drop)]
add(drop, "screenFlash", {"color": "#F2F4FE", "durationBeats": 0.75})
for wid in hydra_ids:
    add(drop + 0.05, "closeWindow", {"id": wid})
add(drop + 0.05, "closeWindow", {"id": "trace"})     # the arrow goes too

texts   = ["you looked", "hi.", "it's here", ":)", "told you", "don't blink",
           "give it 2 me", "again"]
codes   = ["$ open look://deeper\nspawning pages… ok\nvibes at 98%",
           "> trace complete\n> you are the cursor now",
           "while true:\n    window()   # sorry"]
dialogs = [("FOUND SOMETHING", "You looked. That was the whole trick."),
           ("NOTHING TO SEE", "Absolutely nothing behind this window."),
           ("CONGRATULATIONS", "You are the 1,000,000th cursor."),
           ("UH OH", "The pages are multiplying.")]
body_colors = PALETTE + ["#0B0E16"]

# No flashes in this loop — the kick pass below owns the flashing, so the two can't
# fight over the same overlay.
rng = random.Random(7)
b, wi, di = drop, 0, 0
chorus_end = bar(BAR_STROBE)
while b < chorus_end:
    u = 0.75 + 0.25 * (b - drop) / (chorus_end - drop)   # already near full tilt
    r = 30 + (u ** 1.6) * 0.65 * W * rng.uniform(0.5, 1.0)
    ang = rng.uniform(0, 6.28318)
    w = round((110 + (u ** 1.7) * 380) * rng.uniform(0.8, 1.25))
    h = round(w * rng.uniform(0.6, 0.85))
    x = max(10, min(fx + r * math.cos(ang) - w / 2, W - w - 10))
    y = max(10, min(fy + r * math.sin(ang) - h / 2, H - h - 10))
    roll = rng.random()
    if roll < 0.50:
        add(b, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), w, h],
            "content": {"kind": "color", "hex": rng.choice(body_colors),
                        "chrome": "mixed", "title": "look://again"},
            "animate": {"kind": "none" if rng.random() < 0.8 else "springIn"},
            "interactive": True})
        wi += 1
    elif roll < 0.64:
        add(b, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), max(w, 240), h],
            "content": {"kind": "text", "text": rng.choice(texts), "chrome": "browser",
                        "title": "look://found"},
            "animate": {"kind": "none"}, "interactive": True})
        wi += 1
    elif roll < 0.74:
        add(b, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), max(w, 300), h],
            "content": {"kind": "code", "text": rng.choice(codes), "chrome": "terminal",
                        "title": "haunt.sh"},
            "animate": {"kind": "none"}, "interactive": True})
        wi += 1
    elif roll < 0.86:
        title, body = dialogs[di % len(dialogs)]
        add(b, "fakeDialog", {"id": f"d{di % 4}", "title": title, "body": body,
            "buttons": ["ok", "OK", "very ok"][di % 2:],
            "frame": [round(x), round(y), 380, 170]})
        di += 1
    elif wi > 0:
        add(b, "jiggle", {"id": f"w{(wi - 1) % 14}", "durationBeats": 1.5,
            "amplitude": 18, "frequency": 9})
    # Dense from the first beat — this is the explosion, not a ramp. ~8 events/sec
    # on top of the kick flashes.
    b += max(0.15, 0.25 * rng.uniform(0.7, 1.3))

# The kick pass: the background flashes on every kick the analyser found between the
# drop and the strobe. Absolute seconds, so these land on the real audio transients
# rather than on the nominal grid. ~2.4 flashes/sec — nowhere near the 15-20 Hz band.
flash_colors = ["#F2F4FE", "#020AF5", "#FF2D95", "#68BDF8"]
kick_flashes = 0
wipe = chorus_end - 0.5
authored_flashes.append(secs(wipe))
for i, kt in enumerate(KICKS):
    if not (secs(drop) <= kt < secs(chorus_end)):
        continue
    # There is one flash overlay for the whole screen, so a kick landing on top of
    # an authored flash just cuts it short. Let the authored one have the moment.
    if any(abs(kt - a) < 0.25 for a in authored_flashes):
        continue
    add_t(kt, "screenFlash", {"color": flash_colors[i % len(flash_colors)],
                              "durationSeconds": 0.09})
    kick_flashes += 1

# --- chorus wipe: clear the stage for the finale ---
add(wipe, "screenFlash", {"color": "#F2F4FE", "durationBeats": 0.6})
for i in range(14):
    add(wipe + 0.1, "closeWindow", {"id": f"w{i}"})
for i in range(4):
    add(wipe + 0.1, "closeWindow", {"id": f"d{i}"})
add(wipe + 0.1, "closeWindow", {"id": "trace"})

# --- Act 5: the ORIGINAL strobe, spliced in verbatim at bar 24. Its events are
# authored in absolute seconds, which survive the splice with a plain offset. ---
with open(os.path.join(ROOT, "examples", "timeline_strobe.json")) as f:
    strobe = json.load(f)
strobe_at = secs(bar(BAR_STROBE))
strobe_len = max(ev["t"] for ev in strobe["events"])
for ev in strobe["events"]:
    add_t(ev["t"] + strobe_at, ev["type"], ev["params"])
strobe_end = strobe_at + strobe_len

# --- Act 6: THE LETTER (bar 33) — after all that noise, a plain text editor opens
# and writes itself out in tempo. The copy lives in assets/letter.txt so it can be
# rewritten without touching the generator. ---
with open(os.path.join(ROOT, "assets", "letter.txt")) as f:
    letter = f.read().strip()
CHARS_PER_BEAT = float(os.environ.get("CHARS_PER_BEAT", "16"))
lw, lh = round(W * 0.58), round(H * 0.66)
add(bar(BAR_LETTER), "typeText", {
    "id": "letter", "frame": [round((W - lw) / 2), round((H - lh) * 0.42), lw, lh],
    "text": letter, "charsPerBeat": CHARS_PER_BEAT, "fontSize": 14,
    "title": "resignation.txt — Edited", "interactive": True})
letter_beats = len(letter) / CHARS_PER_BEAT
# It finishes typing, sits there a while, then the energy comes back and takes it.
letter_out = bar(BAR_MAP)                # 103.12s — typing finished at ~98s
add(letter_out, "screenFlash", {"color": "#F2F4FE", "durationBeats": 0.5})
add(letter_out + 0.1, "closeWindow", {"id": "letter"})

# Behind the letter: the show doesn't go quiet, it just gets out of the way. A short
# WHITE pulse on every fourth kick (a downbeat-ish rate) and the odd small window
# blinking in a corner — enough to keep the screen alive without eating the text.
letter_rng = random.Random(23)
corners = [(40, 60), (W - 320, 60), (40, H - 240), (W - 320, H - 240)]
letter_flashes = 0
for i, kt in enumerate(KICKS):
    if not (secs(bar(BAR_LETTER)) <= kt < secs(letter_out)):
        continue
    if i % 4 != 0:
        continue
    add_t(kt, "screenFlash", {"color": "#FFFFFF", "durationSeconds": 0.07})
    letter_flashes += 1
    if (i // 4) % 6 == 0:                       # …and now and then, a window blinks
        cx, cy = letter_rng.choice(corners)
        wid = f"lb{(i // 4) % 4}"
        add_t(kt, "openWindow", {"id": wid,
            "frame": [round(cx), round(cy), 280, 180],
            "content": {"kind": "color", "hex": letter_rng.choice(PALETTE),
                        "chrome": "mixed", "title": "still here"},
            "animate": {"kind": "fadeIn"}})
        add_t(kt + 0.9, "closeWindow", {"id": wid})

# --- Act 7: THE FLYOVER (bar 76) — the letter gets flashed away and the screen
# opens onto real Apple Maps, flying over the two cities the letter is about. Uses the
# native `map` kind rather than a `web` Google window on purpose: google.com is blocked
# from mainland China, and this has to work where it's being performed. ---
FLIGHTS = [
    # Lujiazui, over the river from the Bund
    dict(lat=31.2397, lon=121.4998, altitude=1600, toAltitude=420,
         pitch=72, heading=250, toHeading=40, seconds=17),
    # Washington Square, New York
    dict(lat=40.7308, lon=-73.9973, altitude=1200, toAltitude=300,
         pitch=76, heading=20, toHeading=210, seconds=17),
    # out over the water, climbing away
    dict(lat=31.2210, lon=121.5400, altitude=700, toAltitude=5200,
         pitch=68, toPitch=40, heading=140, toHeading=330, seconds=22),
]
map_at = letter_out + 1.5
map_frames = [(W * 0.06, H * 0.10, W * 0.52, H * 0.50),
              (W * 0.44, H * 0.34, W * 0.50, H * 0.48),
              (W * 0.20, H * 0.16, W * 0.60, H * 0.62)]
map_titles = ["maps://shanghai", "maps://new-york", "maps://leaving"]
for i, (flight, frame, title) in enumerate(zip(FLIGHTS, map_frames, map_titles)):
    add(map_at + i * 38, "openWindow", {"id": f"map{i}",
        "frame": [round(v) for v in frame],
        "content": {"kind": "map", "chrome": "browser", "title": title, "map": flight},
        "animate": {"kind": "springIn" if i == 0 else "fadeIn"},
        "interactive": True, "respawn": i == 0})

# the final section is high-energy again, so the kicks light the room back up
final_flashes = 0
for i, kt in enumerate(KICKS):
    if secs(map_at) <= kt < secs(bar(87)):          # bar 87 = 161.01s, the break
        add_t(kt, "screenFlash", {"color": flash_colors[i % len(flash_colors)],
                                  "durationSeconds": 0.07})
        final_flashes += 1

# the break at 161s: everything goes
add(bar(87), "screenFlash", {"color": "#F2F4FE", "durationBeats": 1.0})
for i in range(len(FLIGHTS)):
    add(bar(87, 0.5), "closeWindow", {"id": f"map{i}"})

# --- placeholder: the rest of the track isn't scored yet, so keep a heartbeat —
# a small (kick) window blinking in the lower-left on every remaining kick. ---
heartbeats = 0
for kt in KICKS:
    if strobe_end + 1.0 < kt < secs(map_at):
        add_t(kt, "openWindow", {"id": "kick", "frame": [36, -140, 176, 64],
            "content": {"kind": "text", "text": "(kick)", "chrome": "mac",
                        "title": "kick"},
            "animate": {"kind": "none"}})
        add_t(kt + 0.09, "closeWindow", {"id": "kick"})
        heartbeats += 1

# --- markers for the scrubber: the analyser's sections plus the act boundaries we
# verified by hand (the detector missed the drop by three bars) ---
markers = list(analysis["markers"])
markers += [
    {"t": round(secs(bar(BAR_HYDRA)), 2), "bar": BAR_HYDRA, "label": "hydra stack", "kind": "section"},
    {"t": round(secs(bar(BAR_HUSH)), 2),  "bar": BAR_HUSH,  "label": "hush (bass out)", "kind": "break"},
    {"t": round(secs(bar(BAR_BUILD)), 2), "bar": BAR_BUILD, "label": "build", "kind": "section"},
    {"t": round(secs(bar(BAR_CHORUS)), 2), "bar": BAR_CHORUS, "label": "CHORUS", "kind": "drop"},
    {"t": round(secs(bar(BAR_STROBE)), 2), "bar": BAR_STROBE, "label": "strobe", "kind": "drop"},
]
markers.sort(key=lambda m: m["t"])

def when(e):
    return e["t"] if "t" in e else secs(e["beat"])
events.sort(key=when)

doc = {"meta": {"bpm": BPM, "beatOffset": OFFSET, "audioFile": AUDIO,
                "analyzedBpm": BPM, "markers": markers},
       "events": events}
for out in (os.path.join(ROOT, "examples", "timeline_show.json"),
            os.path.join(ROOT, "Sources", "DesktopPerformanceEngine", "Resources", "timeline.json")):
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}")

print(f"{len(events)} events @ {BPM} BPM, offset {OFFSET}s, track {DURATION:.1f}s")
print(f"  horse   bar  1     {secs(0):6.2f}s  exits beat {horse_exit:.0f}")
print(f"  point   bar {BAR_POINT:>2}     {secs(bar(BAR_POINT)):6.2f}s  ends beat {p_end:.1f} "
      f"→ focal ({fx:.0f},{fy:.0f})")
print(f"  hydra             {secs(HY):6.2f}s  opens at the arrow's tip, runs at "
      f"{secs(RUN_AT):.2f}s, {len(hydra_ids)} windows total")
print(f"  riser             {secs(DROP_BEAT - RISER_SECONDS / BEAT):6.2f}s  {RISER_COUNT} windows "
      f"in {RISER_SECONDS:.0f}s, accelerating into the drop")
print(f"  CHORUS  bar {BAR_CHORUS:>2}     {secs(drop):6.2f}s  {kick_flashes} kick flashes")
print(f"  strobe  bar {BAR_STROBE:>2}     {strobe_at:6.2f}s  ends {strobe_end:.2f}s")
print(f"  letter  bar {BAR_LETTER:>2}     {secs(bar(BAR_LETTER)):6.2f}s  {len(letter)} chars @ "
      f"{CHARS_PER_BEAT:.0f}/beat → done {secs(bar(BAR_LETTER) + letter_beats):.1f}s, "
      f"closes {secs(letter_out):.1f}s")
print(f"  letter bg         {'':6s}  {letter_flashes} white pulses behind the typing")
print(f"  flyover bar {BAR_MAP:>2}    {secs(map_at):6.2f}s  {len(FLIGHTS)} Apple Maps flights, "
      f"{final_flashes} kick flashes → break at {secs(bar(87)):.1f}s")
print(f"  heartbeat         {strobe_end:6.2f}s → {secs(map_at):.1f}s  ({heartbeats} blinks)")
