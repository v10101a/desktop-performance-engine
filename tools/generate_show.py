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

Everything the show SAYS — the welcome terminal, the torus, the locate trace and its
alert, the credits — is read from docs/copy/ (see the README there), not held here.

Seeded, so the show is identical take to take.
"""
import json, math, os, random, sys
import zlib

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

# The images the piece tears, with the same displacement/chroma-split pass the desktop
# gets. Up here rather than inside one act because four different parts of the show put
# torn cards up now: both eruptions, the cue-16 wipe, and every seam.
#
# THE HORSE IS OUT (2026-09-06). `assets/muybridge_horse.gif` was the second source, so
# a third of the torn cards were a smeared Muybridge frame — the last place the horse was
# still on screen after its own act was cut (`HORSE_ACT = False`, cue 21). The asset and
# `tools/generate_horse.py` stay: the act is kept behind that flag for when it comes back,
# and this list is about what the show SHOWS, not what the repo carries.
GLITCH_SOURCES = ["assets/pixelface.jpg", "assets/credits_tile.png"]

# --- the tempo map, straight from the analysis ---
with open(os.path.join(ROOT, "assets", "track_analysis.json")) as f:
    analysis = json.load(f)
BPM = analysis["bpm"]                  # 128.5
OFFSET = analysis["firstDownbeat"]     # 0.395 — beat 0 sits on the first downbeat
BEAT = 60.0 / BPM
KICKS = analysis["kicks"]
DURATION = analysis["duration"]        # 169.85 — the last two cues are past this

# How early a desktop change has to be issued to be SEEN on its beat.
#
# It was 0.30 when `deskWallpaper` drove the real wallpaper: `setDesktopImageURL` takes
# ~270–330 ms to land, so a word fired on its beat was heard before it was seen. The
# default surface is now the desktop LAYER, where a change is a `CALayer` assignment that
# lands on the next vsync — 0.03 covers the ~12 ms a full-screen card costs plus a frame
# at 60 Hz. Leaving it at 0.30 would not be conservative: on the layer it puts every word
# on the desktop two thirds of a beat BEFORE it is sung.
#
# Raise it back toward 0.30 for any cue moved to `surface: "wallpaper"`.
#
# 0.08 since 2026-09-11: at 0.03 the artist heard every desktop word land "a hair" after
# it was sung. The layer's assignment is a frame, but the commit that carries it waits on
# whatever the main thread is doing on that frame, and in the passages the words play in
# that is a window opening. Two more frames of lead cover it; it is still a quarter of
# what the real wallpaper needed.
DESK_LATENCY = 0.08

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
# THE COPY — everything the show SAYS lives in docs/copy/, one plain-text file per
# passage (docs/copy/README.md lists them). The generator reads them here; nothing
# below holds a line of copy as a literal, so the words can be rewritten without
# touching this file. The lyric is the exception: the song's words and their timing are
# `tools/lyrics.py`.
# =============================================================================
COPY_DIR = os.path.join(ROOT, "docs", "copy")

def copy_lines(name):
    """docs/copy/<name>.txt as the list of lines it contains — for anything typed a
    line at a time (a terminal, the credits). Blank lines are kept; leading spaces are
    kept; the file's trailing newline is not a line."""
    with open(os.path.join(COPY_DIR, name + ".txt"), encoding="utf-8") as f:
        return f.read().rstrip("\n").split("\n")

def copy_prose(name):
    """docs/copy/<name>.txt as running text: lines inside a paragraph are joined with a
    space and a blank line is a paragraph break, so the file can be wrapped at any
    width in any editor."""
    paras, cur = [], []
    for line in copy_lines(name) + [""]:
        if line.strip():
            cur.append(line.strip())
        elif cur:
            paras.append(" ".join(cur)); cur = []
    return "\n\n".join(paras)

def copy_fields(name):
    """docs/copy/<name>.txt as `key: value` fields — a dialog's title, body and buttons.
    A key with nothing after the colon takes the `- item` lines under it as a list.
    Lines starting with # are comments."""
    fields, key = {}, None
    for line in copy_lines(name):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("- ") and isinstance(fields.get(key), list):
            fields[key].append(line[2:].strip())
            continue
        k, _, v = line.partition(":")
        key = k.strip()
        fields[key] = v.strip() if v.strip() else []
    return fields

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
    "ending":     ("break",         0, 3),   # 31  the end card, on the release of the last note (162.42 s, measured)
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
# `erupt(mute_from=…)` flips this for the cards past its mute point: every draw and every
# counter still happens, so the eruption after it is byte-identical, but nothing lands.
MUTE = False
def add(beat, typ, params):
    if MUTE:
        if typ in ("openWindow", "fakeDialog"):
            chaos["muted"] += 1
        return
    events.append({"beat": round(beat, 3), "type": typ, "params": params})
def add_t(t, typ, params):
    events.append({"t": round(t, 3), "type": typ, "params": params})

def kicks_between(b0, b1):
    """Kick times (absolute seconds) inside [beat b0, beat b1)."""
    return [kt for kt in KICKS if secs(b0) <= kt < secs(b1)]

def fullscreen():
    return [0, 0, 0, 0]          # w/h of 0 stretch to the far edge on any display

# --- the seam between two acts ---------------------------------------------------
# Every changeover in the piece used to be a hard cut: one act's windows close, the
# next act's open, and on the frames in between there is a bare desktop. This is the
# stitch — a handful of small windows thrown across the boundary, opening in the bar
# before it and dissolving out in the bar after, so the seam is covered by something
# moving rather than being a hole.
#
# Kept SUBTLE on purpose: eight small cards, none bigger than a sixth of the screen,
# each up for under a second. It is a transition, not an act — the moment it reads as
# an event of its own it is competing with the cue it exists to hide.
#
# Each seam gets its own RNG, seeded by name, so adding or moving one leaves the layout
# of every other seam exactly where it was.
SEAM_N = 8
SEAM_FADE = 0.18                 # seconds of dissolve per card
SEAM_LEAD = 0.75                 # beats: the cards are all up before the downbeat
SEAM_TAIL = 1.25                 # beats: and all gone this long after it

def seam(beat, tag, n=SEAM_N, torn_every=4):
    """Throw `n` small windows across the changeover at `beat`. Returns their ids."""
    # crc32, NOT hash(): Python salts string hashing per process, so `hash(tag)` handed
    # this a different seed on every run and every seam in the piece was laid out afresh
    # each time the generator was invoked — the one act in the show that was not the same
    # twice. Found by regenerating and diffing against a previously generated file
    # (2026-09-03): same ids, same beats, different geometry everywhere.
    rng = random.Random(zlib.crc32(tag.encode()))
    ids = []
    for i in range(n):
        w = round(W * rng.uniform(0.09, 0.17))
        h = round(w * rng.uniform(0.60, 0.85))
        # Round the edges of the screen rather than the middle: the middle is where the
        # act that is arriving puts its own picture, and the seam must not sit on it.
        edge = rng.random()
        x = round(rng.uniform(0.02, 0.30) * W) if edge < 0.5 else round(rng.uniform(0.68, 0.96) * W - w)
        y = round(rng.uniform(0.04, 0.90) * (H - h))
        x = max(8, min(x, W - w - 8))
        wid = f"sm{tag}{i}"
        ids.append(wid)
        torn = i % torn_every == 2
        body = ({"kind": "glitch", "path": GLITCH_SOURCES[i % len(GLITCH_SOURCES)],
                 "intensity": round(0.40 + 0.10 * (i % 3), 2), "seed": 7000 + 13 * i,
                 "chrome": "mixed", "title": "recovered.jpg"}
                if torn else
                {"kind": "color", "hex": rng.choice(PALETTE),
                 "chrome": "mixed", "title": "look://again"})
        add(beat - SEAM_LEAD + i * (SEAM_LEAD / n), "openWindow", {
            "id": wid, "frame": [x, y, w, h], "content": body,
            "animate": {"kind": "none"}})
        add(beat + i * (SEAM_TAIL / n), "closeWindow", {"id": wid, "fadeSeconds": SEAM_FADE})
    return ids

def lyric_card(wid, beat, text, i, frame=None, chrome="none", animate="none", anchor=None,
               font_cycle_hz=None):
    """One lyric-video frame. `i` alternates the ground/type between blue and white.

    `font_cycle_hz` re-picks the FACE that many times a second from whatever fonts the
    viewer has installed — see the eruption, which is the only place it is used."""
    blue_ground = (i % 2 == 0)
    content = {"kind": "lyric", "text": text,
               "hex": BLUE if blue_ground else WHITE,
               "fg": WHITE if blue_ground else BLUE,
               "chrome": chrome, "title": "give it 2 me — lyrics"}
    if font_cycle_hz:
        content["fontCycleHz"] = font_cycle_hz
        # Fixes the sequence of faces per card, so a take is reproducible on one machine.
        # Across machines it cannot be: the pool IS the viewer's own library.
        content["seed"] = 7700 + i
    params = {"id": wid, "frame": frame or fullscreen(),
              "content": content,
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
# when the deskWallpaper expires, the layer closes and the viewer's own picture is
# simply there again — it was never covered by anything but a window.
# =============================================================================
# Clear the stage: other apps are hidden, not minimised — `unhide` puts each window
# back exactly where it was, on stop/panic too.
add(0, "hideOtherApps", {"id": "apps"})
add(0, "deskWallpaper", {"id": "desk", "mode": "solid", "hex": DJ_BLUE,
                         "durationSeconds": round(secs(B["restore"]) - secs(0), 3)})

# =============================================================================
# Cue 2 (beat 8) — the blue goes and the viewer's own desktop is underneath it.
# The wash is no longer hiding a ~300 ms setDesktopImageURL stall (the layer closes in a
# frame), but it stays: the cut is written around a flash on this beat.
# =============================================================================
add(B["restore"], "screenFlash", {"color": WHITE, "durationBeats": 0.5})

# =============================================================================
# Cue 3 (beat 10) — the welcome. A Terminal window that types itself out, one line a
# beat — the same surface and cadence as the end card's credits. `⌘Esc` stays the
# last line the viewer reads before anything starts moving.
# =============================================================================
WELCOME_LINES = copy_lines("welcome")            # docs/copy/welcome.txt
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
    # Not Terminal's own black-on-white: the piece's blue, typed in white. It is the
    # first window of the show and it should look like the show, not like a shell that
    # happens to be open (`hex` is the ground, `fg` the type).
    "hex": DJ_BLUE, "fg": WHITE,
    "fontSize": WELCOME_PT, "interactive": True})

# =============================================================================
# Cue 4 (0:25) — the welcome window goes and the probe opens, typing out what the
# machine knows about whoever is sitting at it. The report is long, so the rate is set
# from the gap to the end of the hydra act rather than picked.
# =============================================================================
add(B["probe"], "closeWindow", {"id": "welcome"})
# ONE WINDOW PER SECTION, scattered (2026-09-03). The probe used to be a single tall
# report in the middle of the screen reading itself out top to bottom. It is five
# windows now, each running one section of the same scan, thrown around the desktop the
# way a machine that is interrogating itself would leave them — and all five typing at
# once, so the report arrives as a machine talking over itself rather than as a document.
#
# `focus` is the probe's own mechanism for this and it already existed: a window opened
# with it reads out only the sections named. Each gets its own id, so `SystemProbeController`
# keeps five reports rather than replacing one (it used to hold exactly one and tear the
# previous down — see the `reports` dictionary).
#
# Blue ground, white type, same as the welcome terminal: this is the show talking.
PROBE_SECTIONS = [
    ("identity",    "./scan_identity",   0.03, 0.06, 0.40, 0.40),
    ("machine",     "./scan_machine",    0.55, 0.04, 0.41, 0.34),
    ("network",     "./scan_network",    0.30, 0.36, 0.38, 0.30),
    ("geolocation", "./scan_where",      0.02, 0.52, 0.36, 0.32),
    ("hardware",    "./scan_hardware",   0.60, 0.46, 0.37, 0.36),
]
probe_ids = []
for i, (section, title, fx, fy, fw, fh) in enumerate(PROBE_SECTIONS):
    wid = f"probe{i}"
    probe_ids.append(wid)
    # A beat apart, so they land one after another rather than as a wall of windows.
    add(B["probe"] + i * 0.75, "systemProbe", {
        "id": wid, "linesPerBeat": 6, "focus": [section], "title": title,
        "hex": DJ_BLUE, "fg": WHITE,
        "frame": [round(W * fx), round(H * fy), round(W * fw), round(H * fh)]})
# The probe's session is HALF what it was (2026-09-02): it used to type all the way to
# cue 6, three bars from the drop, and the report had said what it had to say long
# before that — the machine knows who you are, and reading it twice adds nothing. It
# stops talking on cue 5 and the game takes the rest of INTRO B.
#
# But only TWO of the five windows actually leave (2026-09-07). All five used to close
# here, so the brick breaker racked up on a screen with literally nothing else on it —
# measured, zero events between 20.94 s and 28.78 s — and the game read as a different
# program starting rather than as something taking over the desktop that was already
# there. `probe0`, `probe2` and `probe4` stay standing, on a diagonal under the rack, and
# die with the bricks when cue 6 clears the screen for the drop. The scan is over either
# way: a probe window that has finished typing is a report lying where it fell, which is
# exactly what should be behind the game.
PROBE_STAY = ["probe0", "probe2", "probe4"]
for wid in probe_ids:
    if wid not in PROBE_STAY:
        add(B["hydra"] - 0.3, "closeWindow", {"id": wid})

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

# =============================================================================
# Cue 5 (0:30) — BRICK BREAKER, played on the machine's own furniture. The probe has
# just closed; 32 windows rack up where the report was, the system's beach ball is the
# ball, and the paddle is the viewer's pointer — moving the mouse plays it, and moving
# it is the only thing anyone can do here, so anyone at the machine is playing whether
# they meant to be or not.
#
# It starts moving on the frame it opens: the ball serves itself, a missed ball is
# served again rather than ending anything, and when the last brick goes the rack comes
# back. Nothing in it can stall — the track does not wait, so neither can the game. It
# has INTRO B to itself until cue 6 clears the screen for the drop.
#
# The slot is the hydra act's; that act is still pulled, and this is what is in its
# place. See `BrickBreakerController` for the physics.
#
# IT ARRIVES ON A DESKTOP, NOT ON A BLANK (2026-09-07). Three of the probe's windows are
# left standing (see cue 4) and the bar before the game fills in behind them: eight small
# windows, one every half beat, thrown round the edges of the play area. Then the rack
# comes up ON them. It used to cut from an empty screen straight to 32 bricks, which read
# as a different program launching; now the game is something that takes over a desktop
# that was already busy, which is what it is.
#
# NOTHING here sets a level, and nothing should. Brick-breaker windows are built directly
# by `BrickBreakerController` rather than through `WindowManager`, so they keep
# `BaseEffectWindow`'s default `.screenSaver` (1000), while everything the timeline opens
# is explicitly demoted to `.normal` (0). The rack is on top for free; a `level` here
# would only be a way to break that.
#
# Its own RNG, seeded by name through `zlib.crc32` — NOT `hash()`, which Python salts per
# process and which made every seam in the piece lay out differently on every run (see
# `seam`). Adding or moving a window in here leaves every other act's geometry alone.
BRICK_RAMP_N = 8
ramp_rng = random.Random(zlib.crc32(b"bricksramp"))
ramp_ids = []
# The play area, so the ramp can sit round it rather than under the middle of the rack
# where it would never be seen through the bricks.
BRICK_AREA = [round(W * 0.08), round(H * 0.10), round(W * 0.84), round(H * 0.78)]
for i in range(BRICK_RAMP_N):
    wid = f"br{i}"
    ramp_ids.append(wid)
    w = round(W * ramp_rng.uniform(0.11, 0.19))
    h = round(w * ramp_rng.uniform(0.55, 0.80))
    # Round the edges, like `seam` does and for the same reason: the middle is where the
    # act is, and a card parked in it is in the way rather than behind.
    if ramp_rng.random() < 0.5:
        x = round(ramp_rng.choice([ramp_rng.uniform(0.0, 0.10), ramp_rng.uniform(0.72, 0.94)]) * W)
        y = round(ramp_rng.uniform(0.04, 0.80) * H)
    else:
        x = round(ramp_rng.uniform(0.02, 0.80) * W)
        y = round(ramp_rng.choice([ramp_rng.uniform(0.01, 0.10), ramp_rng.uniform(0.74, 0.90)]) * H)
    x = max(6, min(x, W - w - 6))
    y = max(6, min(y, H - h - 6))
    # Half of them are terminals with the show's own source in them, half flat cards in
    # the palette — the same two things `seam` throws, so the ramp reads as more of the
    # machine rather than as a new idea arriving four seconds before the game.
    if i % 2 == 0:
        content = {"kind": "code", "text": lyrics.code(i // 2), "chrome": "terminal",
                   "title": ["give_it_2_me.js", "haunt.sh", "swarm.js"][(i // 2) % 3],
                   "hex": DJ_BLUE, "fg": WHITE}
    else:
        content = {"kind": "color", "hex": ramp_rng.choice(PALETTE), "chrome": "mixed",
                   "title": f"untitled {i}"}
    add(B["hydra"] - 4 + i * 0.5, "openWindow", {
        "id": wid, "frame": [x, y, w, h], "content": content,
        "animate": {"kind": "springIn" if i % 3 == 0 else "fadeIn"}})

# The rack lands on one frame, on purpose: racking it up across the bar before was tried
# (2026-09-12) and measured far worse — see `BrickBreakerController.rack`.
add(B["hydra"], "brickBreaker", {
    "id": "bricks", "frame": BRICK_AREA,
    "rows": 4, "cols": 8, "speed": 560, "ball": 46, "paddle": [200, 26], "seed": 44})

# =============================================================================
# Cue 11 (0:48) — THE HYDRA ACT, moved here (2026-09-03). Somebody sets a sketch up by
# hand in the middle of the drop: it appears small with its code written but not
# running, the cursor takes it by the title bar and hauls it down the screen, pulls it
# bigger by its lower-right corner, and hits run — and then two more arrive already
# running. It was written for cue 5 (INTRO B + 3.0) and pulled; the brick breaker has
# that slot now, and this is the empty one the author left in chorus 1A.
#
# Scaled to fit. The act is 13 beats as written and there are 13 between here and cue
# 12, which would put the last sketch on screen for no time at all — so every offset
# AND every move duration is multiplied by HY_S, and it lands with about four beats to
# spare. Scaling the offsets alone would leave a 1.8-beat drag running under the step
# that follows it.
# =============================================================================
HY_S = 0.70
hy = B["tbd_048"]
def hs(x):
    return hy + x * HY_S

HYDRA_ACT = True
hydra_ids = []
if HYDRA_ACT:
    DRAG_ID = "hy0"
    hydra_ids = [DRAG_ID]

    # 1. it appears, small, code written but NOT running
    d_small = (round(W * 0.04), round(H * 0.18), 320, 200)
    hydra_window(DRAG_ID, hy, d_small, PATCHES[1], running=False, animate="springIn")

    # 2. the cursor takes it by the title bar and hauls it down the screen
    d_grab = (d_small[0] + d_small[2] * 0.5, d_small[1] + 12)
    add(hs(1), "cursorPath", {"path": "linear", "durationBeats": round(1.2 * HY_S, 3), "easing": "easeInOut",
        "mode": "warp", "points": [[round(W * 0.02), round(H * 0.08)],
                                   [round(d_grab[0]), round(d_grab[1])]]})
    d_lift = (round(W * 0.05), round(H * 0.48), d_small[2], d_small[3])
    add(hs(2.4), "moveWindow", {"id": DRAG_ID, "frame": [d_lift[0], d_lift[1]],
        "durationBeats": round(1.6 * HY_S, 3), "easing": "easeInOut"})
    add(hs(2.4), "cursorPath", {"path": "linear", "durationBeats": round(1.6 * HY_S, 3), "easing": "easeInOut",
        "mode": "warp", "points": [[round(d_grab[0]), round(d_grab[1])],
                                   [round(d_lift[0] + d_small[2] * 0.5), round(d_lift[1] + 12)]]})

    # 3. resize by the LOWER-RIGHT CORNER: the top-left stays put and the window grows down
    # and to the right, so the code never moves off its corner.
    d_corner = (d_lift[0] + d_lift[2], d_lift[1] + d_lift[3])
    d_big = (d_lift[0], d_lift[1], round(W * 0.28), round(H * 0.32))
    d_new_corner = (d_big[0] + d_big[2], d_big[1] + d_big[3])
    add(hs(4.2), "cursorPath", {"path": "linear", "durationBeats": round(1.0 * HY_S, 3), "easing": "easeInOut",
        "mode": "warp", "points": [[round(d_lift[0] + d_small[2] * 0.5), round(d_lift[1] + 12)],
                                   [round(d_corner[0]), round(d_corner[1])]]})
    add(hs(5.4), "moveWindow", {"id": DRAG_ID,
        "frame": [d_big[0], d_big[1], d_big[2], d_big[3]],
        "durationBeats": round(1.8 * HY_S, 3), "easing": "easeOut"})
    add(hs(5.4), "cursorPath", {"path": "linear", "durationBeats": round(1.8 * HY_S, 3), "easing": "easeOut",
        "mode": "warp", "points": [[round(d_corner[0]), round(d_corner[1])],
                                   [round(d_new_corner[0]), round(d_new_corner[1])]]})
    # Re-open at the final size once the drag settles: the layout stretched during the
    # resize gets rebuilt cleanly at the new dimensions. Still not running.
    hydra_window(DRAG_ID, hs(7.4), d_big, PATCHES[1], running=False)

    # 4. up to hydra's run button, top-right — and the sketch starts.
    d_play = (d_big[0] + d_big[2] - 26, d_big[1] + 34)
    add(hs(7.6), "cursorPath", {"path": "linear", "durationBeats": round(1.2 * HY_S, 3), "easing": "easeInOut",
        "mode": "warp", "points": [[round(d_new_corner[0]), round(d_new_corner[1])],
                                   [round(d_play[0]), round(d_play[1])]]})
    HYDRA_RUN = hs(9.0)
    hydra_window(DRAG_ID, HYDRA_RUN, d_big, PATCHES[1], running=True)
    add(HYDRA_RUN, "screenFlash", {"color": "#68BDF8", "durationSeconds": 0.06})

    # …and two more, already running, on the downbeats — right-hand side, clear of
    # both the probe and the dragged window.
    for i, (dx, dy, s) in enumerate([(0.62, 0.10, 0.30), (0.70, 0.52, 0.26)], start=1):
        wid = f"hy{i}"
        hydra_ids.append(wid)
        beat = HYDRA_RUN + (2 + 2 * (i - 1)) * HY_S
        hydra_window(wid, beat, (round(W * dx), round(H * dy),
                                 round(W * s), round(H * s * 1.05)),
                     PATCHES[(i + 1) % len(PATCHES)], running=True, animate="springIn")

# =============================================================================
# Cue 6 (0:38) — the desktop goes blue again, and the screen is cleared for it.
# No duration: cue 7 replaces it a beat later. An expiry would restore the viewer's
# picture for the two frames before the face lands — a flicker of the wrong image.
# =============================================================================
# The game, the ramp that came up under it, and the three probe windows still standing
# from cue 4 — the whole of INTRO B leaves together on one beat. Cue 7 is the drop and it
# wants a bare desktop to land the face on.
for wid in ["bricks"] + ramp_ids + PROBE_STAY:
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

# The lyric desktop cards, cue 12. The artist draws them 1920x1080, full bleed: condensed
# type edge to edge on her blue, one picture per phrase.
#
# They cannot go on the desktop as drawn. A desktop picture is shown FILLED — the engine's
# layer uses `resizeAspectFill`, the real wallpaper `scaleAxesIndependently` — and 16:9 on
# the 1.54:1 screen these play on crops ~8% off each side, straight through the first and
# last letter. So each card is composited onto a 4:3 field of its OWN blue, sampled from
# the source's corner rather than assumed. Because the field is the card's own colour
# there is no edge where it sits.
#
# The padding buys a BAND, not immunity. Filled, the visible slice of a 4:3 canvas is the
# full width by 1920/aspect: the type (1080 tall, centred) survives while that is ≥ 1080,
# i.e. for any display from 4:3 up to 16:9. Narrower than 4:3 clips the letters left and
# right, wider than 16:9 clips them top and bottom — and 16:9 is where the artwork is
# drawn, so nothing can extend the band upward without shrinking the type off the edges
# it is meant to touch. Every display Apple ships is inside it (MacBooks 16:10, every
# desktop panel 16:9); a third-party ultrawide is not.
LYRIC_SRC = "assets/sarah's assets/lyrics_desktop_new"
LYRIC_DIR = "assets/lyrics_desktops"
LYRIC_ASPECT = 4 / 3

def build_lyric_desktops():
    """Composite every source card onto a 4:3 field of its own colour. Returns the
    (name, size) list, or [] when the artist's originals are not in this checkout —
    they are gitignored, so a fresh clone regenerates everything else and leaves the
    committed cards alone."""
    from PIL import Image
    src_dir = os.path.join(ROOT, LYRIC_SRC)
    if not os.path.isdir(src_dir):
        return []
    out_dir = os.path.join(ROOT, LYRIC_DIR)
    os.makedirs(out_dir, exist_ok=True)
    built = []
    for name in sorted(os.listdir(src_dir)):
        if not name.lower().endswith((".jpg", ".jpeg", ".png")):
            continue
        src = Image.open(os.path.join(src_dir, name)).convert("RGB")
        field = src.getpixel((1, 1))
        canvas_w = src.width
        canvas_h = max(src.height, round(canvas_w / LYRIC_ASPECT))
        canvas = Image.new("RGB", (canvas_w, canvas_h), field)
        canvas.paste(src, (0, (canvas_h - src.height) // 2))
        stem = os.path.splitext(name)[0]
        canvas.save(os.path.join(out_dir, f"{stem}.jpg"), quality=92)
        built.append((stem, (canvas_w, canvas_h), field))
    return built

LYRIC_CARDS = build_lyric_desktops()

# Photographs of REAL broken screens, for the eruption at bar 72 (cue 27).
#
# Everything the eruption throws up is synthetic — windows the app draws, `uichaos`
# interface the engine renders, the show's own images torn by its own glitch pass. These
# are the one thing in it that is not: somebody's actual smashed monitor, on an actual
# desk, in an actual room. That is the whole reason they are in there, so the pick is
# HARDWARE — a screen you can see the object of — rather than the pure datamosh grabs in
# the same drop, which are already what `glitch` and `uichaos` do.
#
# Source → derived, the same arrangement as the lyric cards and pixelface_blink: the drop
# is the artist's, gitignored and whole; what the show loads is a downsized copy under a
# name that says what it is, committed. The originals run to 18 MB and 2796 px for windows
# that are never wider than ~500 pt, and `decodeThumbnail` throws most of that away at
# load anyway — so the copy is capped on the long edge and the repo carries megabytes
# instead of tens of them.
#
# NOT included, deliberately: `IMG_0624.PNG` is a screenshot of an Instagram DM — a real
# handle, a real message, a real person who did not agree to be in a piece that gets
# distributed. It is also not a broken computer. The datamosh-only grabs are left out for
# the reason above; they are all still in the drop if the cut ever wants them.
BROKEN_SRC = "assets/broken_computer"
BROKEN_DIR = "assets/broken_screens"
BROKEN_MAX_EDGE = 1200
# LIST ORDER IS SCREEN ORDER — the cards index this by the photo counter, so the first
# photograph of the cue is the first entry. Alternated by subject so two shots of the
# same object never come up back to back.
#
# Six, not eight: the cue lands ~6 photographs (see the note at the branch), and a
# seventh and eighth entry would be built, committed and never seen. `laptop-desk` and
# `curved-monitor` are the two that went — both are dim, cluttered rooms that read as
# nothing at the size these windows open at. They are still in the drop.
BROKEN_PICK = [
    ("3B6850A9-BADE-4181-A13E-6A4D6E9E35B2.JPG", "smashed-monitor.jpg"),
    ("7BE0DF70-F135-49FF-84CE-BD00EDF3C5F7.JPG", "laptop-cracked.jpg"),
    ("DF9CBBDF-5F81-41CD-BBAD-307A75624B44.JPG", "imac-spiral.jpg"),
    ("74856DB5-D8B1-49E9-AD28-6B757DF768F2.JPG", "smashed-monitor-2.jpg"),
    ("C02954EB-855A-4599-9C6B-2378D4542ADC.JPG", "laptop-magenta.jpg"),
    ("View recent photos 2.png",                 "phone-cracked.jpg"),
]

def build_broken_screens():
    """Downsize the picked photos into the committed folder. Returns the paths the
    timeline names, in order. Silent no-op when the drop is not in this checkout — it is
    gitignored, so a fresh clone regenerates everything else and leaves these alone."""
    from PIL import Image
    src_dir = os.path.join(ROOT, BROKEN_SRC)
    out_dir = os.path.join(ROOT, BROKEN_DIR)
    paths = [f"{BROKEN_DIR}/{out}" for _, out in BROKEN_PICK]
    if not os.path.isdir(src_dir):
        # Still name them: the copies are committed, so the show loads either way. The
        # lint is what catches a name with no file behind it.
        return paths
    os.makedirs(out_dir, exist_ok=True)
    for name, out in BROKEN_PICK:
        src_path = os.path.join(src_dir, name)
        if not os.path.exists(src_path):
            sys.exit(f"broken_computer: {name} is missing from the drop")
        im = Image.open(src_path).convert("RGB")
        im.thumbnail((BROKEN_MAX_EDGE, BROKEN_MAX_EDGE), Image.LANCZOS)
        im.save(os.path.join(out_dir, out), quality=88)
    return paths

BROKEN_SCREENS = build_broken_screens()

# The photo wall's fallback pool — what cue 22 shows on a machine whose owner said no to
# Files and Folders. Same source → derived arrangement as `broken_screens` above: the
# drop is gitignored and whole, and what ships is a downsized copy under a name that says
# what it is, committed.
#
# DISJOINT from broken_screens on purpose. Those six are already committed at the same
# cap from the same source, and `PhotoSource.bundledFolders` scans both folders — putting
# them in here as well would mean the fallback wall showed six of its photographs twice
# as often as the rest.
#
# IMG_0624.PNG IS NOT IN HERE, and this is the one exclusion that is not about the cut.
# It is a screenshot of an Instagram DM: a real handle, a real message, a real person who
# did not agree to be in a piece that gets handed around on a USB stick. It was already
# kept out of the timeline for that reason; a fallback pool that swept up "everything
# else in the folder" would have quietly put it back in, and into every copy of the app.
FALLBACK_DIR = "assets/photo_fallback"
FALLBACK_MAX_EDGE = 1200
FALLBACK_EXCLUDE = {"IMG_0624.PNG"}
FALLBACK_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff"}


def build_photo_fallback():
    """Downsize the rest of the drop into the committed fallback folder.

    Returns the paths in the order they were built. Silent no-op when the drop is not in
    this checkout — it is gitignored, so a fresh clone keeps the committed copies."""
    from PIL import Image
    src_dir = os.path.join(ROOT, BROKEN_SRC)
    out_dir = os.path.join(ROOT, FALLBACK_DIR)
    already = {name for name, _ in BROKEN_PICK}
    if not os.path.isdir(src_dir):
        if not os.path.isdir(out_dir):
            return []
        return sorted(f"{FALLBACK_DIR}/{n}" for n in os.listdir(out_dir)
                      if n.lower().endswith(".jpg"))
    os.makedirs(out_dir, exist_ok=True)
    picked = sorted(n for n in os.listdir(src_dir)
                    if os.path.splitext(n)[1].lower() in FALLBACK_EXTS
                    and n not in already and n not in FALLBACK_EXCLUDE)
    paths = []
    for i, name in enumerate(picked, 1):
        out = f"fallback-{i:02d}.jpg"
        im = Image.open(os.path.join(src_dir, name)).convert("RGB")
        im.thumbnail((FALLBACK_MAX_EDGE, FALLBACK_MAX_EDGE), Image.LANCZOS)
        im.save(os.path.join(out_dir, out), quality=88)
        paths.append(f"{FALLBACK_DIR}/{out}")
    # A rename or a deletion in the drop would otherwise leave a stale committed copy
    # behind, and the pool would carry a photograph the drop no longer has.
    keep = {os.path.basename(p) for p in paths}
    for stale in os.listdir(out_dir):
        if stale.endswith(".jpg") and stale not in keep:
            os.remove(os.path.join(out_dir, stale))
    return paths


PHOTO_FALLBACK = build_photo_fallback()

# The face with its eyes SHUT — the second frame of the gate's blink (cue 1). The artist
# drew it as a full screen grab (`sarah's assets/blink.jpg`, 3024x1964, loading bar and
# all), so it has to be cut down to exactly the framing of pixelface.jpg or the face
# would jump between frames instead of blinking.
#
# The two frames are matched on the MOUTH, not on the ink as a whole: the mouth bar is
# identical in both and the eyes are not — that is the whole point of the frame — so
# aligning bounding boxes would slide the mouth up and down on every blink.
FACE_BLINK_SRC = "assets/sarah's assets/blink.jpg"
FACE_BLINK = "assets/pixelface_blink.jpg"

def mouth_box(im):
    """The mouth graphic's bounding box, (x0, y0, x1, y1).

    Found in two steps because neither alone is reliable. First the widest run of white
    in the top three quarters locates the BAR — three quarters because the source grab
    has a loading bar under the face that is wider than the mouth. Then every white pixel
    within a fifth of the height of that row is collected, which picks up the teeth and
    the far end of a bar the run missed: a row interrupted by a tooth gives a short run,
    and matching frames on a short run is what silently zooms one of them."""
    px = im.load()
    def white(x, y):
        r, g, b = px[x, y][:3]
        return r > 170 and g > 170 and b > 170
    best_len, bar_y = 0, 0
    for y in range(int(im.height * 0.75)):
        run = 0
        for x in range(im.width):
            run = run + 1 if white(x, y) else 0
            if run > best_len:
                best_len, bar_y = run, y
    # The band is measured in BAR LENGTHS, not in image heights: the face fills
    # pixelface.jpg and is a fifth of the height of the screen grab, so a band that is a
    # fraction of the image is two different things in the two frames — it took in the
    # eyes on one side and not the other, and the "mouth" it matched was the eye dashes.
    # A bar length is the same face-relative unit in both.
    lo = max(0, bar_y - int(best_len * 0.08))
    hi = min(im.height, bar_y + int(best_len * 0.32))
    xs, ys = [], []
    for y in range(lo, hi):
        for x in range(im.width):
            if white(x, y):
                xs.append(x); ys.append(y)
    return min(xs), min(ys), max(xs), max(ys)

def build_face_blink():
    """Cut the shut frame down to pixelface.jpg's framing; returns its size. When the
    artist's grab is not in this checkout (it is gitignored) the committed frame is left
    alone and measured instead — the same source → derived arrangement as the lyric
    cards and the broken screens, so a fresh clone can regenerate the show."""
    from PIL import Image
    open_im = Image.open(os.path.join(ROOT, "assets/pixelface.jpg")).convert("RGB")
    src, out = os.path.join(ROOT, FACE_BLINK_SRC), os.path.join(ROOT, FACE_BLINK)
    if not os.path.exists(src):
        if not os.path.exists(out):
            sys.exit(f"{FACE_BLINK} is missing and {FACE_BLINK_SRC} is not here to build it from")
        return Image.open(out).size
    shut = Image.open(src).convert("RGB")
    ox0, oy0, ox1, _ = mouth_box(open_im)
    sx0, sy0, sx1, _ = mouth_box(shut)
    k = (sx1 - sx0) / max(1, ox1 - ox0)          # source pixels per open-frame pixel
    oy, sy = oy0, sy0
    # Put the crop where the mouth lands in the same place it does in the open frame.
    left = sx0 - ox0 * k
    top = sy - oy * k
    crop = shut.crop((round(left), round(top),
                      round(left + open_im.width * k), round(top + open_im.height * k)))
    small = crop.resize(open_im.size, Image.BOX)
    # Two colours, hard edges: BOX leaves grey fringes on what is pixel art, and every
    # other appearance of this face in the show is hard-edged.
    ground = tuple(int(FACE_GROUND[i:i + 2], 16) for i in (1, 3, 5))
    px = small.load()
    for y in range(small.height):
        for x in range(small.width):
            r, g, b = px[x, y]
            px[x, y] = (255, 255, 255) if (r + g + b) / 3 > 140 else ground
    small.save(os.path.join(ROOT, FACE_BLINK), quality=95)
    return small.size

FACE_BLINK_W, FACE_BLINK_H = build_face_blink()

# The end card's tiling face. The card's backdrop is the signature blue and this drifts
# across it, so the face is inked WHITE on that blue — the app icon's own two colours,
# the same way round as the icon, the desktop and the ring. (The card's terminals and
# the polaroid are white windows, so the ground under them is the blue the whole piece
# has been sitting on since the instrumental, not a white sheet arriving at the end.)
# `CREDITS_TILE_FIELD` is the field, `DJ_BLUE`; the card's `backdrop` is set from the
# same name below, and the engine fills the tile's padding from the artwork's own corner
# pixel, so the three cannot disagree.
#
# Built from `pixelface.jpg` rather than drawn, so it is the same face as the icon, the
# desktop and the ring, pixel for pixel: the old tile was a soft rounded rendition of it
# and read as a different drawing. NEAREST and a hard threshold keep the edges square —
# every other appearance of this face in the piece is hard-edged.
CREDITS_TILE = "assets/credits_tile.png"
CREDITS_TILE_SIZE = (432, 331)      # unchanged: the drift is written around this size
CREDITS_TILE_SHARE = 0.82           # margin enough that the repeats read as separate
CREDITS_TILE_FIELD = DJ_BLUE        # the ground: the tile's field AND the card's backdrop
CREDITS_TILE_INK = WHITE            # the face

def build_credits_tile():
    from PIL import Image
    src_im = Image.open(os.path.join(ROOT, "assets/pixelface.jpg")).convert("RGB")
    tw, th = CREDITS_TILE_SIZE
    ink = tuple(int(CREDITS_TILE_INK[i:i + 2], 16) for i in (1, 3, 5))
    field = tuple(int(CREDITS_TILE_FIELD[i:i + 2], 16) for i in (1, 3, 5))
    tile = Image.new("RGB", (tw, th), field)
    w = round(tw * CREDITS_TILE_SHARE)
    h = round(src_im.height * w / src_im.width)
    face = src_im.resize((w, h), Image.NEAREST)
    px = face.load()
    for y in range(face.height):
        for x in range(face.width):
            r, g, b = px[x, y]
            # The artwork is white ink on its own blue field: bright is the face.
            px[x, y] = ink if (r + g + b) / 3 > 140 else field
    tile.paste(face, ((tw - w) // 2, (th - h) // 2))
    tile.save(os.path.join(ROOT, CREDITS_TILE))
    return w, h

CREDITS_TILE_W, CREDITS_TILE_H = build_credits_tile()
# Applied 2×DESK_LATENCY early so the change has FINISHED before the drop: fired on the
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

# HALF the run it used to have (2026-09-02). It travelled from the drop all the way to
# cue 12's close — 16 legs, the whole of chorus 1A — and the wave had made its point
# long before the end of that. Now it takes half the span and LEAVES on the last leg
# rather than parking: a chain that stops and sits is the thing the full-length version
# was written to avoid, so the fix for "half as long" is a shorter life, not a shorter
# journey followed by a wait.
TRAVEL_END = tv + (B["words"] - 3 - tv) / 2
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

# …and it goes when it arrives, leader first, the chain following it off the screen in
# the order the delay line already puts them in. Cue 12 used to close this; leaving it
# there would have the wave standing still for the second half of chorus 1A, which is
# the thing the halving was for.
TRAVEL_CLOSE = TRAIL_LAST_MOVE + LEG + 0.15
add(TRAVEL_CLOSE, "closeWindow", {"id": "traveller"})
for k in range(1, TRAIL_LINKS + 1):
    add(TRAVEL_CLOSE + k * TRAIL_LAG, "closeWindow", {"id": f"tr{k}"})

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
# Cue 10 — MOVED (2026-09-02). The bursting file icons used to go up here, over the
# spiral and the traveller, and chorus 1A was carrying three moving pictures at once
# with the drop's own wallpaper under them. The act is intact and it is not gone: it
# opens at cue 25 instead, where the screen has just been cut back to the swarm and
# there is room to watch a shell rise.
#
# THE SLOT IS THE KICK NOW (2026-09-07). Chorus 1A is the half of the first chorus that
# does not move to the beat: the traveller sweeps on its own 1.75-beat legs, the spiral
# lands on sung lines, and the desktop under both is a still picture. Everything in it is
# on the LYRIC's clock, and nothing is on the drum's. So a layer of pointers goes over the
# whole phrase and is CUT ON EVERY KICK — the real onsets out of
# `assets/track_analysis.json`, the same 333 the eruption's ground flashes use, not a beat
# grid. Nothing in the app is audio-reactive (`AudioClock` is a position clock, no tap, no
# FFT), so a pulse has to be authored; `kicks_between` is how cue 28 already does it.
#
# THIS IS DELIBERATELY THE OPPOSITE OF CUE 12, and the difference is the point. Cue 12
# holds each scene half a beat to three beats precisely so the flock has time to gather
# into a body — Reynolds flocking needs a second or two, and below that all you see is
# the spawn shape. Cut on every kick (about one a beat) you only ever see spawn shapes,
# and that IS the rhythm: 1A pulses, 1B breathes. The same particles, read two ways.
#
# 0.45 × 90 = ~40 arrows, well under cue 12's 63: this plays UNDER a 21-window traveller
# and over a wallpaper that is the drop's picture, and it is the beat, not the act.
#
# No `screenFlash` on the kick here, though the machinery is right there. Cue 28 owns
# flashing on the kick (and cue 21 flashes on the strobe's grid, a bar at a time); giving
# the drop the same gesture flattens the difference between the loudest passages in the
# piece, and the face on the desktop is what this is meant to be seen over rather than
# through.
#
# The run ends on the LYRIC's zero for chorus 1B, not on the phrase downbeat: cue 12
# hands over one bar early (the desktop cards start on the pickup, and cue 12's own sweep
# takes this window at `words_event_beat - 0.2`). Bounded at the downbeat instead, the
# last few kicks would re-open the window AFTER that close and leave it standing through
# the whole of chorus 1B on top of the shoal — which is exactly what `lint_show.py`
# caught. Same expression cue 12 times itself from, so the two cannot drift.
SWARM_PATTERNS = ["spiral", "ring", "grid", "burst", "stream"]
kick_cuts = 0
KICK_LAST = None
# Half a beat of air before the bar the handover sits in: without it the last kick landed
# a single frame before cue 12's sweep, so the flock was rebuilt on a new spawn shape and
# taken away on the next frame — one frame of a scatter nobody can read, right on the
# changeover. The pulse would rather stop a beat early than flicker into 1B.
for i, kt in enumerate(kicks_between(B["face"], lyric_zero("chorus1B") - 0.5)):
    KICK_LAST = kt
    add_t(kt, "openWindow", {
        "id": "kickswarm", "frame": fullscreen(),
        # Over the traveller and the spiral, both `.normal`. It stays click-through
        # whatever the level — `hitTest` returns nil — so the cards underneath are still
        # the viewer's.
        "level": "floating",
        "content": {"kind": "cursors", "mode": "school",
                    "pattern": SWARM_PATTERNS[i % len(SWARM_PATTERNS)],
                    "intensity": 0.45, "seed": 6000 + i * 13,
                    "chrome": "none", "title": "pointer"},
        "animate": {"kind": "none"}})
    kick_cuts += 1
# …and it closes with the spiral on cue 12, where the shoal that DOES gather takes over.

# =============================================================================
# Cue 11 (0:48) — TBD. Deliberately empty again: the drain that was put here was one of
# the three particle behaviours being explored, and a behaviour on trial is not a cue.
# All three are still in the engine and `--test-particles` shows them side by side; when
# one of them earns a place in the piece it can have this slot. The gap is the note.
# =============================================================================

# =============================================================================
# Cue 12 (0:54) — the lyric on the desktop itself: the spiral, the traveller and the
# fireworks all go, one word per wallpaper card. The window server tops
# out near 3 Hz and the controller drops whole ticks rather than queueing them, so the
# words play slower than authored but never skip and never outlive the event.
# =============================================================================
wd = B["words"]                     # chorus 1B; the run starts on the pickup, one bar before
zero_1B = lyric_zero("chorus1B")

# The cards. The artist draws a PHRASE at a time, edge to edge — "NEED YOUR LOVE" is one
# picture, not three — so the file for a card is its words joined by underscores
# (NEED_YOUR_LOVE.jpg) and the grouping lives in `lyrics.DESKTOP`. A card with no file is
# skipped (the previous one holds) and listed below, so a new card is never a silent gap.
WORDS_DIR = "assets/lyrics_desktops"
def word_key(word):
    """A word as the filenames spell it: upper case, apostrophes dropped (CANT, IM),
    and TO written the way it is sung."""
    key = word.upper().replace("’", "").replace("'", "").strip(".,!?:;")
    return {"TO": "2"}.get(key, key)
def card_path(text):
    path = f"{WORDS_DIR}/{'_'.join(word_key(w) for w in text.split())}.jpg"
    return path if os.path.exists(os.path.join(ROOT, path)) else None

# The schedule: the whole lyric (lyrics.CUES, 32 beats) at chorus 1B's position, each
# card applied DESK_LATENCY early so the change lands ON the word as it is sung.
#
# CUES is word by word (that is what the chorus 1A spiral wants); the cards come in
# phrases. So the words are flattened to a stream first — a multi-word cue spreads evenly
# to the next one, exactly as the spiral reads it — and then `lyrics.DESKTOP` groups that
# stream back up into cards, each landing on the time of its FIRST word. One source of
# timing: retune a word in CUES and its card moves with it.
lyric_end = zero_1B + 32
word_times = [lyric_beat(zero_1B, when) for when, _ in lyrics.CUES] + [lyric_end]
word_stream = []                      # [(seconds, WORD), ...] — the lyric, word by word
for k, (when, text) in enumerate(lyrics.CUES):
    b0, b1 = word_times[k], word_times[k + 1]
    words = text.split()
    for j, w in enumerate(words):
        word_stream.append((secs(b0 + (b1 - b0) * j / len(words)), w))

# Group it into cards. The assert is the guard that keeps `lyrics.DESKTOP` honest: it is a
# regrouping of CUES, not a second copy of the lyric, and a word added, cut or reworded up
# there has to be reflected down here or the build stops.
word_slides, words_missing = [], []
cursor = 0
for card in lyrics.DESKTOP:
    words = card.split()
    got = word_stream[cursor:cursor + len(words)]
    assert len(got) == len(words) and all(
        lyrics._key(a) == lyrics._key(b) for (_, a), b in zip(got, words)), (
        f"lyrics.DESKTOP: card {card!r} at word {cursor} does not match CUES "
        f"({[w for _, w in got]!r}) — DESKTOP must regroup CUES exactly")
    cursor += len(words)
    img = card_path(card)
    if img is None:
        words_missing.append(card)
        continue
    word_slides.append((got[0][0], img))
assert cursor == len(word_stream), (
    f"lyrics.DESKTOP covers {cursor} of {len(word_stream)} words in CUES — "
    f"{[w for _, w in word_stream[cursor:]]!r} has no card")
if not word_slides:
    sys.exit("CHORUS 1B: no desktop card has a picture")
words_first = word_slides[0][0]
words_event_at = words_first - DESK_LATENCY
words_event_beat = (words_event_at - OFFSET) / BEAT
# The traveller runs until cue 12 takes it away — so the last leg, INCLUDING the deepest
# link's lag, has to land before the close. Pinned rather than eyeballed: retime cue 12
# and this fails the build instead of silently cutting the chain off mid-leg.
assert TRAIL_LAST_MOVE + LEG <= words_event_beat - 0.2, (
    f"traveller: last trail leg ends at beat {TRAIL_LAST_MOVE + LEG:.2f}, after the "
    f"close at {words_event_beat - 0.2:.2f}")
# Same for cue 10's kick layer, and it matters more: that window is RE-OPENED on every
# kick, so a kick landing after this close puts it back up and leaves it standing over
# the whole of chorus 1B on top of the shoal. It is bounded by `lyric_zero("chorus1B")`,
# which is a bar before the phrase and normally well clear — but the close is derived from
# where the artist's first CARD actually falls, not from the bar line, so retuning a word
# in `lyrics.CUES` could walk it back past the last kick. This is the guard for that.
assert KICK_LAST is None or (KICK_LAST - OFFSET) / BEAT <= words_event_beat - 0.2, (
    f"kickswarm: last kick cut at beat {(KICK_LAST - OFFSET) / BEAT:.2f}, after the "
    f"close at {words_event_beat - 0.2:.2f} — it would re-open and never be swept")
# The fireworks go too (no embers): a transparent full-screen window with live
# particles keeps the compositor repainting the whole screen every frame, and under
# the ~300 ms wallpaper swaps it dragged the words — and everything after them.
# No "video" here any more: cue 10's fireworks owned that id and they have moved to
# cue 25 (as "works"), and the video slot itself is the DooM window ("doomvid").
for wid in spiral_ids + hydra_ids + ["kickswarm"]:
    add(words_event_beat - 0.2, "closeWindow", {"id": wid})
add_t(words_event_at, "deskWallpaper", {
    "id": "words", "mode": "slides",
    "images": [img for _, img in word_slides],
    "at": [round(t - words_first, 3) for t, _ in word_slides],
    "durationSeconds": round(secs(B["torus1"]) - words_event_at, 3)})

# A SHOAL OVER THE WORDS. Cursors flocking above the lyric desktop, cutting between
# scenes on the beat.
#
# `mode: "school"` is the whole point and not a detail: `.chase` reads
# `NSEvent.mouseLocation` and hunts the viewer's own pointer, and this must not. School
# never touches the pointer at all — it is the same particles with the mouse taken away.
#
# THE CUTS ARE RE-OPENS. One window id, re-opened with a different `pattern`, which
# swaps the content view in place (`WindowManager.open`, the `existing` branch) — the
# same trick the pulled face-strobe used, and the reason it is a CUT rather than a
# transition: the flock is rebuilt on its new spawn shape on that frame, with no
# crossfade and nothing carried over. Cutting on `seed` alone would be the same picture
# shuffled; `pattern` changes where they start AND the weights that then hold them, so
# each one is a different picture.
#
# The order is seeded rather than a rotation — five patterns cycled in order reads as a
# loop by the third pass — and no scene ever follows itself.
#
# THE CUT LENGTHS ARE NOT UNIFORM, and that is the whole difficulty of this cue. A cut
# every beat is properly rapid, but Reynolds flocking needs a second or two to pull a
# spawn shape into a BODY — so on a flat one-beat grid you only ever see the spawn, and
# forty arrows scattered on a lattice read as specks rather than as a school. Measured on
# the first pass: legible cuts, no schooling.
#
# So: mostly one beat, some half-beat stutters, and a 2–3 beat hold often enough that the
# flock visibly gathers before it is cut again. Rapid, with somewhere to arrive.
# `SWARM_PATTERNS` is shared with cue 10's kick layer, and is defined up there — the two
# cues are the same five scenes read at two rates.
SWARM_HOLDS = [0.5, 1.0, 1.0, 1.0, 2.0, 3.0]
swarm_rng = random.Random(1206)
sw_b, sw_end = words_event_beat, B["torus1"] - 0.3
sw_cuts, sw_prev = 0, None
while sw_b < sw_end:
    choices = [p for p in SWARM_PATTERNS if p != sw_prev]
    pat = swarm_rng.choice(choices)
    sw_prev = pat
    add(sw_b, "openWindow", {
        "id": "wordswarm", "frame": fullscreen(),
        "content": {"kind": "cursors", "mode": "school", "pattern": pat,
                    # 0.7 × 90 = ~63 cursors. A school is a density before it is a
                    # count — at forty they stayed a scatter of arrows however they were
                    # flocked. Still under cue 21's shoal, because the words underneath
                    # are the act and the lyric has to be readable through this.
                    "intensity": 0.7, "seed": 5100 + sw_cuts * 7,
                    "chrome": "none", "title": "pointer"},
        "animate": {"kind": "none"}})
    sw_cuts += 1
    sw_b += swarm_rng.choice(SWARM_HOLDS)
# Gone before the torus: cue 13 is vocals-out and a single window typing to itself.
add(sw_end, "closeWindow", {"id": "wordswarm"})

# The plane the GLASS refracts in cue 13.
#
# The torus reflects a picture, not a capture — by default the viewer's own desktop
# wallpaper, read from the snapshot `WallpaperController` takes before the show swaps
# anything. That is right while the torus is a thing sitting on their desktop and wrong
# the moment cue 13 puts a tunnel underneath it: the glass would be bending a stranger's
# Big Sur photograph inside a cloud tunnel, and belong to neither picture.
#
# So the cue authors its own plane (`environment` on the `glassTorus` event) and this
# bakes it: the same cloud in the same three colours as `assets/shaders/tunnel.frag`,
# with the same bright throat in the middle. It is a STILL, and it does not have to
# match the tunnel frame for frame — it is a plane 2.0 units behind a tumbling torus,
# read through per-channel refraction. What it has to be is the same weather.
#
# Built with successive `Image.blend` rather than a Python loop over pixels: the blend
# weight `amp / (total + amp)` makes each pass the exact running weighted average of the
# octaves so far, so the fbm falls out of five C-speed resizes instead of a million
# interpreted iterations.
TORUS_ENV = "assets/torus_dimension.jpg"

def build_torus_dimension():
    """Write the cue 13 refraction plane. 512x320 is deliberate: `ScreenEnvironment`
    caps the decode at 1024 px on the long edge anyway, and this is a soft cloud field
    with no detail a reflection could show."""
    from PIL import Image, ImageOps
    rng = random.Random(13)
    w, h = 512, 320

    acc, total, amp = None, 0.0, 1.0
    for octave in range(5):
        cells_x = 4 << octave
        cells_y = max(2, round(cells_x * h / w))
        cells = Image.new("L", (cells_x, cells_y))
        cells.putdata([rng.randrange(256) for _ in range(cells_x * cells_y)])
        layer = cells.resize((w, h), Image.BICUBIC)
        acc = layer if acc is None else Image.blend(acc, layer, amp / (total + amp))
        total += amp
        amp *= 0.5

    # Deep blue in the troughs, sky through the middle, near-white on the cloud tops —
    # the shader's own ramp, done in one call.
    cloud = ImageOps.colorize(ImageOps.autocontrast(acc),
                              black=(2, 10, 245), white=(242, 244, 254),
                              mid=(104, 189, 248))

    # …and the throat. A radial ramp computed small and resized up: it is a gradient, so
    # the interpolation IS the picture rather than a loss of one.
    mw, mh = 96, 60
    mask = Image.new("L", (mw, mh))
    cx, cy = (mw - 1) / 2.0, (mh - 1) / 2.0
    rmax = math.hypot(cx, cy)
    mask.putdata([
        round(255 * max(0.0, 1.0 - (math.hypot(x - cx, y - cy) / rmax) / 0.55) ** 1.6)
        for y in range(mh) for x in range(mw)])
    out = Image.composite(Image.new("RGB", (w, h), (242, 244, 254)), cloud,
                          mask.resize((w, h), Image.BICUBIC))

    out.save(os.path.join(ROOT, TORUS_ENV), quality=92)
    return w, h

TORUS_ENV_W, TORUS_ENV_H = build_torus_dimension()

# =============================================================================
# Cue 13 (1:09) — the magic torus introduces itself in typed text, then actually asks:
# the `oracle` is the only window in the piece allowed to take the keyboard — without
# it the torus makes an offer the show cannot honour. They flank the torus, the
# greeting down the whole right of it, the question bottom-left.
# =============================================================================
t1 = B["torus1"]
add(t1, "screenFlash", {"color": WHITE, "durationBeats": 0.5})

# THE TORUS DIMENSION (2026-09-07). The torus used to hang transparently over the blue
# desktop, which made it an ornament on the viewer's own machine; it is supposed to take
# them somewhere. So the phrase opens a room: a full-screen cloud tunnel, flying, in the
# show's own three colours, with the far throat washed out to white exactly where the
# torus sits.
#
# NOTHING has to be said about z-order here, and nothing should be. Every window the
# timeline opens is `.normal`; the torus is `.screenSaver` by default, so it floats
# INSIDE the tunnel for free, and the greeting and the oracle open after this one so
# they land on it. Giving the tunnel a level would only be a way to get that wrong.
#
# `drop: 0` runs the flight at its base rate — the same knob cue 17 turns, and the
# breakdown runs that one at 0 too. This is the still passage before the map.
add(t1, "openWindow", {"id": "tunnel", "frame": fullscreen(),
    "content": {"kind": "shader", "path": "assets/shaders/tunnel.frag", "drop": 0.0,
                "chrome": "none", "title": "tunnel"},
    "animate": {"kind": "none"}})

TORUS_SIZE = round(min(W, H) * 0.58)
add(t1, "glassTorus", {"id": "torus", "material": "glass", "speed": 0.8,
                       "size": TORUS_SIZE,
                       # …and the glass bends the tunnel's own weather rather than the
                       # viewer's wallpaper. See `build_torus_dimension` above.
                       "environment": TORUS_ENV})
GREETING = copy_prose("torus_greeting")          # docs/copy/torus_greeting.txt
# 12 chars a beat, down from 28 (2026-09-09). The 28 was set for a monologue three times
# this length, and reading it straight onto copy this short would have typed the whole
# thing in six beats and then left the oracle sitting answered for half the phrase. This
# is the rate that keeps the phrase's SHAPE: the greeting still lands around beat 15 of
# 32, the invitation a beat after it, the answer inside the phrase. Everything downstream
# is derived from the copy and this number, so the copy can be rewritten again and the
# dialog moves with it — only the phrase is fixed.
GREETING_CPB = 12
# CLIPPY'S BALLOON (2026-09-09), where this used to be a TextEdit document in real macOS
# chrome. The torus is the one thing in the piece that addresses the viewer directly and
# asks them for something, and the Office Assistant is the register that belongs to: a
# computer interrupting you to be helpful, in the same voice as "It looks like you're
# writing a letter". A titled document window says the machine is working; a yellow
# balloon says it is talking to YOU.
#
# It sits to the RIGHT of the torus and the spike points back at it, so the balloon is
# something the torus is saying rather than a window that happens to be next to it. The
# box is a third of the height it was, because the copy is a third of the length — a
# balloon has to hug its words or it reads as an empty label.
GREET_X = round((W + TORUS_SIZE) / 2 + W * 0.02)
# Measured off `--snapshot-chrome`, not guessed: the copy sets in four lines at 15pt, so
# it needs ~113pt including the balloon's padding. 144 hugs that with enough slack for
# the face actually resolving differently on another machine (Tahoma ships with Office;
# without it this falls back through Verdana to Geneva, which sets slightly wider).
GREET_H = round(H * 0.16)
# Centred on the torus, so the spike leaves the balloon's left edge pointing straight at
# the middle of it.
GREET_Y = round(H * 0.5 - GREET_H / 2)
add(t1 + 1, "typeText", {"id": "greeting",
    "frame": [GREET_X, GREET_Y, W - GREET_X - round(W * 0.02), GREET_H],
    "text": GREETING, "charsPerBeat": GREETING_CPB, "fontSize": 15,
    "chrome": "bubble", "tail": "left", "interactive": True})

# ON the beat the greeting finishes typing — derived from the copy, so rewriting the
# greeting moves the invitation with it. It used to wait a beat more; the artist wanted
# the torus to have more time (2026-09-11), and the question arriving as the last word
# lands, balloon still up, is the first half of that.
ORACLE_AT = t1 + 1 + len(GREETING) / GREETING_CPB
# Answered and read before the map cuts in at cue 14. A viewer who won't play cannot
# stall the show: it answers itself. 13.5 beats (2026-09-11), from 10: with the question a
# beat earlier that is 1.6 s more to type in, and the answer lands 2.5 beats later than it
# did — just over a second — with two seconds left to read it before the cut. The beat the
# question moved buys only half a second, so most of the time has to come from here.
ORACLE_BEATS = 13.5
ORACLE = copy_fields("torus_oracle")             # docs/copy/torus_oracle.txt
add(ORACLE_AT, "oracle", {"id": "oracle",
    "frame": [round(W * 0.04), round(H * 0.62), 460, 186],
    "title": ORACLE["title"], "body": ORACLE["body"],
    "placeholder": ORACLE["placeholder"], "answers": ORACLE["answers"],
    "answerBeats": ORACLE_BEATS})

# The desktop goes WHITE under the torus. This REPLACES the words event before it
# expires — an expiry restores the viewer's own picture for a ~300 ms flicker — and leads
# the cue by DESK_LATENCY so the ground lands with the flash, not a frame after it.
#
# White, not the signature blue (2026-09-07). The tunnel covers the screen, so this is
# only ever seen at its edges and for the frame between the flash and the shader's first
# paint — and blue there is the SHOW's colour, which is the one thing this phrase is
# trying to leave behind. White reads as the tunnel's own light instead of as the desktop
# coming back.
add_t(secs(t1) - DESK_LATENCY, "deskWallpaper",
      {"id": "desk3", "mode": "solid", "hex": WHITE})

# =============================================================================
# Cue 14 (1:24) — Apple Maps, falling out of orbit onto the viewer's own location, and
# the only thing on the screen for the whole of bridge B: nothing else opens over it
# until cue 16 closes it (cue 15's fill is pulled — see below). The descent is derived
# from that: it runs the full phrase and lands a second before the black.
# =============================================================================
mp = B["map"]
for wid in ("torus", "greeting", "oracle", "tunnel"):
    add(mp - 0.3, "closeWindow", {"id": wid})
add(mp, "screenFlash", {"color": WHITE, "durationBeats": 0.3})
# …and the desktop comes back to the show's blue as the tunnel goes. The torus dimension
# is one phrase long: cue 13 leaves the piece for it and cue 14 comes back, and the map
# is framed by the same blue as everything either side of it. Led by DESK_LATENCY like
# every other swap, so it lands with the flash rather than a frame after.
add_t(secs(mp) - DESK_LATENCY, "deskWallpaper",
      {"id": "desk3b", "mode": "solid", "hex": DJ_BLUE})
# The fallback when Location Services gives nothing: downtown Los Angeles. `here=True`
# overrides these whenever there IS a fix.
FALL = dict(lat=34.0522, lon=-118.2437)
# The shot runs for exactly as long as the window is on the screen — up to the frame
# cue 16's tiles bury it — and it is flown in two legs. The FALL is 3 s: 2,600 km down
# to 260 m in under a quarter of the shot, so the plummet is over almost before it
# registers. Everything after it ORBITS, and the orbit is eased in and then held at
# rate (`easeInThenSteady`), never eased out: the camera is still going round the
# viewer's own roof at the moment it is covered up.
MAP_CLOSE = 190.2                       # set by the wipe below; the map dies covered
MAP_SECONDS = round((MAP_CLOSE - mp) * BEAT, 1)
MAP_FALL = 3.0
MAP_ORBIT = 180
DESCENT = dict(FALL, here=True, altitude=2_600_000, toAltitude=260,
               pitch=0, toPitch=62, heading=0, toHeading=30,
               seconds=MAP_SECONDS, zoomSeconds=MAP_FALL, orbitDegrees=MAP_ORBIT,
               style=MAP_STYLE)
# …AND THE MAP IS RUN THROUGH THE SEGMENTER (2026-09-03). Once the fall has landed, the
# map window itself becomes the segmenter's source: every part of the orbiting picture
# that MOVES is cut out and pinned to the desktop as its own titled window, so the act
# is processed rather than accompanied. It reads the map window in-process — the window
# draws itself into a bitmap, which costs no Screen Recording and no permission.
#
# It starts on the LANDING, not on the open: the descent from 2,600 km is the shot, and
# burying it under its own fragments would be covering the thing being segmented. And it
# ends a beat before cue 16's wipe, because these panels sit above everything and would
# otherwise be on top of the transition as well.
# PULLED in the timeline (2026-09-03): the map is left to fall and orbit on its own.
MAPSEG_ACT = False
SEG_MAP_FROM = mp + MAP_FALL / BEAT
if MAPSEG_ACT:
    add(SEG_MAP_FROM, "segSwarm", {
        "id": "mapseg", "window": "map0", "mode": "motion",
    # Lower than the clip's: an orbiting camera moves the WHOLE frame, so a twitchy
    # setting boxes everything and the pile stops meaning anything.
        "intensity": 0.35, "maxWindows": 48, "windowHz": 15,
        "mirror": False, "border": "none"})
    add(B["black"] - 0.1, "closeWindow", {"id": "mapseg"})

add(mp, "openWindow", {"id": "map0",
    "frame": [round(W * 0.10), round(H * 0.07), round(W * 0.80), round(H * 0.78)],
    "content": {"kind": "map", "chrome": "browser", "title": "maps://{ip}", "map": DESCENT},
    "animate": {"kind": "springIn"}, "interactive": True, "respawn": True})

# …AND THE MACHINE SAYS WHAT IT IS DOING (2026-09-07). The map used to fall in silence,
# which read as a shot rather than as an act: something is finding you, and nothing on
# the screen said so. Two windows, timed to the two legs of the flight.
#
# This is the first time anything has addressed the viewer since the probe read their
# machine back to them in INTRO B, and it is deliberately in the probe's voice — a
# terminal typing a trace out, not a caption on a picture.
#
# The terminal runs THROUGH the fall and the dialog lands ON the landing, so the copy
# arrives at the rate the camera does. Both sit low and left, clear of the map's own
# title bar and inside the frame rather than beside it: the map is 80% of the width, so
# there is no margin to stand a window in, and a popup over the picture is what Sarah
# asked for anyway.
#
# `{city}` and `{ip}` are substituted by `LocationStore.fill` in window TITLES only —
# not in a body — so the placeholders go in the title and the copy stays generic. A
# machine that cannot get a fix still types the same lines and the map still flies to
# the fallback, which is the whole arrangement `here: true` is built on.
TRACE = "\n".join(copy_lines("locate"))         # docs/copy/locate.txt
# Sized to land its last line as the fall bottoms out: the fall is MAP_FALL seconds, the
# terminal opens half a beat in, and the copy is paced to fill what is left.
TRACE_BEATS = MAP_FALL / BEAT - 0.5
add(mp + 0.5, "typeText", {"id": "maptrace",
    "frame": [round(W * 0.06), round(H * 0.62), round(W * 0.34), round(H * 0.30)],
    "text": TRACE, "charsPerBeat": round(len(TRACE) / TRACE_BEATS, 1),
    "fontSize": 13, "chrome": "terminal", "title": "locate://{city}",
    "hex": DJ_BLUE, "fg": WHITE})
# The dialog lands a beat after the camera does, so the alert is the answer to the
# descent rather than something racing it down.
FOUND = copy_fields("location_found")            # docs/copy/location_found.txt
add(mp + MAP_FALL / BEAT + 1, "fakeDialog", {"id": "mapfound",
    "frame": [round(W * 0.30), round(H * 0.64), 460, 190],
    "title": FOUND["title"], "body": FOUND["body"],
    "buttons": FOUND["buttons"], "icon": "info"})
# Both gone before cue 16's tiles come over the top — the wipe is the way out of the map
# and nothing may still be standing on it when that starts.
for wid in ("maptrace", "mapfound"):
    add(B["black"] - 0.4, "closeWindow", {"id": wid, "fadeSeconds": 0.2})

# =============================================================================
# Cue 15 — PULLED (2026-08-31): the windows that filled the screen are out of the cut.
# Every one of them opened ON TOP of the map, which is 80% × 78% of the screen, so the
# descent from orbit played out under a thickening pile of them. Bridge B is the map's
# alone now — cue 14 lands it and nothing else opens until cue 16 takes it away. The
# act is kept behind FILL_ACT for when it returns: the ramp from roughly one window a
# bar to four a beat, walking outward from the centre. The slot keeps its number.
# =============================================================================
# Drawn on by the eruption's terminals too (cue 27), so it stays outside the gate.
codes = lyrics.CODE
FILL_ACT = False
fill_ids = []
if FILL_ACT:
    fl = B["fill"]
    fill_rng = random.Random(19)

    # Three of the flat blue cards carry the piece's own tear — the cue 28 glitch pass run
    # once over one of the show's own images — spread across the ramp. WHICH cards is a
    # fixed set, not a roll, and the colour draw below still happens for every blue card
    # even when its hex goes unused: `fill_rng` seeds the whole act's layout, so a draw
    # added or skipped here would reshuffle every window after it.
    GLITCH_BLUES = {1, 4, 8}

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
# Cue 16 (1:37) — the way out of the map. The desktop goes black and the screen FILLS
# WITH WINDOWS: 30 tiles on a 6×5 grid, one a transport frame, in scattered order,
# until there is nothing of the map left to see. The map closes behind that cover, so
# the orbit is never seen to stop — it is buried mid-turn. Then the tiles DISSOLVE,
# three a frame, a quarter-second of alpha each, timed so the last of them is still
# going transparent as cue 17's raymarcher springs in: the shader is uncovered rather
# than cut to.
#
# The build is an accumulation and the dissolve is a fade — neither reverses the
# screen, so a one-a-frame cadence is not a flash rate. The only full-screen change
# here is the single black `screenFlash` this cue always had.
# =============================================================================
bk = B["black"]
FRAME = 1.0 / FPS / BEAT                 # one transport frame, in beats
add(bk, "deskWallpaper", {"id": "dark", "mode": "solid", "hex": BLACK})
add(bk, "screenFlash", {"color": BLACK, "durationBeats": 0.6})

TX_COLS, TX_ROWS = 6, 5
TX_BLEED = 10                            # tiles overlap, so the cover has no seams
TX_FADE = 0.25                           # seconds of alpha per tile on the way out
tx_rng = random.Random(53)
cells = [(c, r) for r in range(TX_ROWS) for c in range(TX_COLS)]
tx_rng.shuffle(cells)                    # scattered, not raster — it reads as a wipe
tx_ids = []
tw = round(W / TX_COLS) + 2 * TX_BLEED
th = round(H / TX_ROWS) + 2 * TX_BLEED
for n, (c, r) in enumerate(cells):
    x = max(0, min(round(c * W / TX_COLS) - TX_BLEED, W - tw))
    y = max(0, min(round(r * H / TX_ROWS) - TX_BLEED, H - th))
    wid = f"tx{n}"
    tx_ids.append(wid)
    # Two of the thirty are torn rather than flat — the wipe is the one place in the
    # piece where a card is on screen for a whole second with nothing else asking for
    # attention. By index, not by a draw: `tx_rng` seeds the tile order above.
    body = ({"kind": "glitch", "path": GLITCH_SOURCES[n % len(GLITCH_SOURCES)],
             "intensity": 0.63, "seed": 2645 + n, "chrome": "mixed", "title": "recovered.jpg"}
            if n in (11, 23) else
            {"kind": "color", "hex": tx_rng.choice(PALETTE),
             "chrome": "mixed", "title": "look://again"})
    add(bk + n * FRAME, "openWindow", {"id": wid, "frame": [x, y, tw, th],
        "content": body,
        "animate": {"kind": "none"}})    # a springIn would open gaps in the cover

# Covered at TX_COVERED; the map goes a couple of frames after that, unseen. MAP_CLOSE
# up at cue 14 is this number — the flight is sized to end on it.
TX_COVERED = bk + (len(cells) - 1) * FRAME
add(MAP_CLOSE, "closeWindow", {"id": "map0"})
assert MAP_CLOSE > TX_COVERED, "the map would still be visible when it closes"

# The dissolve is timed BACKWARD from cue 17 so the last tile is a quarter-second into
# its fade as the shader arrives: the two cross rather than one following the other.
TX_PER_FRAME = 3
tx_out = list(tx_ids)
tx_rng.shuffle(tx_out)
tx_last = B["tbd_099"] + 0.1 - TX_FADE / BEAT
tx_first = tx_last - ((len(tx_out) - 1) // TX_PER_FRAME) * FRAME
assert tx_first > MAP_CLOSE, "the dissolve would start before the map is gone"
for n, wid in enumerate(tx_out):
    add(tx_first + (n // TX_PER_FRAME) * FRAME,
        "closeWindow", {"id": wid, "fadeSeconds": TX_FADE})

# With FILL_ACT back on, its windows leave in the order they arrived and the stagger
# crosses the section line: the raymarcher opens while the last stragglers are still
# leaving, instead of after a beat of emptied-screen dead air.
if fill_ids:
    close_span = (B["tbd_099"] - bk) + 1.5
    for i, wid in enumerate(fill_ids):
        add(bk + 0.2 + close_span * i / max(1, len(fill_ids) - 1), "closeWindow", {"id": wid})

# =============================================================================
# Cue 17 (1:30) — a desktop animation, alone on the emptied screen until Photo Booth,
# with three smaller ones scattered around its corners. This slot used to hold the
# artist's GLSL raymarcher (`assets/shaders/graphic.frag`); the centre is now
# `assets/desktop_animation3.mp4` and the corners loop 1, 2 and 3 — each a muted clip on
# its own seamless loop. The breakdown is the one still passage in the piece, so nothing
# here is cut on the beat: the clips simply play until Photo Booth takes the screen.
# =============================================================================
VID_W, VID_H = round(W * 0.52), round(H * 0.52)
add(B["tbd_099"], "openWindow", {
    "id": "tbd1", "anchor": "center",
    "frame": [0, 0, VID_W, VID_H],
    "content": {"kind": "video", "path": "assets/desktop_animation3.mp4",
                "chrome": "mixed", "title": "desktop_animation3.mp4"},
    "animate": {"kind": "springIn"}})

# Three of its four corners, one clip each. The lower-left is left empty on purpose:
# the hydra sketch below is set up and dragged around exactly there. They open with the
# centre, a breath apart, and are cut with it just before Photo Booth (cue 18).
SAT_W = round(W * 0.22)
SAT_H = round(SAT_W * 9 / 16)                     # the clips are 1280x720
satellites = [
    ("anim_tl", "assets/desktop_animation1.mp4", [round(W * 0.11), round(H * 0.11), SAT_W, SAT_H]),
    ("anim_tr", "assets/desktop_animation2.mp4", [round(W * 0.67), round(H * 0.13), SAT_W, SAT_H]),
    ("anim_br", "assets/desktop_animation3.mp4", [round(W * 0.66), round(H * 0.66), SAT_W, SAT_H]),
]
sat_ids = [sid for sid, _, _ in satellites]
for i, (sid, clip, frame) in enumerate(satellites):
    add(B["tbd_099"] + 0.4 * i, "openWindow", {
        "id": sid, "frame": frame,
        "content": {"kind": "video", "path": clip, "chrome": "mixed",
                    "title": clip.split("/")[-1]},
        "animate": {"kind": "springIn"}})

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
# The corner clips go with the centre.
for sid in sat_ids:
    add(bo - BOOTH_WARMUP - 0.3, "closeWindow", {"id": sid})
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
# Cue 20 — PULLED (2026-09-02): the window that alternated the face with a flat blue
# card at 6 Hz, right on the heels of the photo wall. It was the only thing in the piece
# that flashed a window's whole ground on and off, it landed immediately after the
# spam — the busiest picture in the show — and it read as a fault rather than a beat.
# The wall now runs to the horse unaccompanied. Kept behind FACESTROBE_ACT; the slot
# keeps its number. What it used to be:
#
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
# THE SEGMENTER SWARM IS NOT HERE ANY MORE (2026-09-05). It traded places with the
# eruption + strobe splice that used to close the piece: the noise runs in this slot now.
# The segmenter went to the chorus 2B pickup then, and to the chorus 2A pickup in the
# 2026-09-07 swap, where it opens the second chorus and is buried by the eruption a bar
# and a half in. Its code is up at cue 27, where it plays; this comment is the signpost.
#
# What it is, wherever it runs: `assets/giveit2meclip.mp4` segmented for MOTION, every
# region that moves becoming its own titled window holding the piece of frame it was cut
# from, pinned where it was found, up to 60 before the oldest is recycled. Nothing is
# tracked between frames, so a thing that keeps moving mints a new window every frame and
# the screen fills.

FACESTROBE_ACT = False
k, b = 0, fs
while FACESTROBE_ACT and b < face_until:
    add(b, "openWindow", {"id": "faceflash", "anchor": "center",
        "frame": [0, 0, FLASH_W, FLASH_H],
        "content": FACE_FRAME if k % 2 == 0 else BLUE_FRAME,
        "animate": {"kind": "none"}})
    b += 0.5 / face_hz / BEAT          # one swap per half-cycle: face, blue, face, …
    k += 1
if FACESTROBE_ACT:
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
# THE HORSE IS CUT (2026-09-03) and this is what is in its place: the imported
# segmenter with the DESKTOP as its canvas. A clip is segmented for motion and every
# region that moves becomes its own titled window holding the piece of frame it was cut
# from, pinned where it was found — and since nothing is tracked between frames, a thing
# that simply keeps moving mints a new window every frame. The screen fills with
# everything the clip has done.
#
# It reads as the same sentence the horse did — the desktop taken over by one moving
# thing — in the show's own furniture rather than in a sprite. The blue desktop above is
# unchanged and still runs to the end card; this sits on it.
#
# The horse act is kept behind HORSE_ACT for when it comes back.
HORSE_ACT = False
gc = gr = max_lit = 0
horse_exit = horse_end = hs
HORSE_BEATS = B["torus2"] - hs
if HORSE_ACT:
    frames, gc, gr, max_lit = build_frames(cols=HORSE_COLS)
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
if HORSE_ACT:
    add(t2, "closeWindow", {"id": "horse"})
add(t2, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
# PULLED in the timeline (2026-09-03): the torus and its ring of faces and sketches are
# out, and instrumental B is the segmenter's swarm and the pointer swarm alone. The
# screen flash on the cue stays — it is the cut, not the act.
TORUS2_ACT = False
if TORUS2_ACT:
    add(t2, "glassTorus", {"id": "torus", "material": "crystal", "speed": 1.2,
                           "size": round(min(W, H) * 0.56)})
# THE POINTER SWARM STARTS HERE, under the torus, and arrives ONE AT A TIME.
#
# It used to open on cue 24 with all ninety pointers on a single frame, which put a hard
# edge on the section: the screen went from no cursors to a wall of them between two
# frames. Now the window opens a section early and `spawnSeconds` trickles them in —
# roughly one every eighth of a second — so the swarm bleeds through the torus act and
# is at full strength exactly when cue 25 cuts everything else and leaves it alone with
# the viewer's pointer. Transparent and click-through, so it costs the acts it overlaps
# nothing but the sight of it.
SWARM_RAMP = round((B["tbd_136"] - B["torus2"]) * BEAT, 1)
# FLOATING (2026-09-11). It opened at the normal level, and the eruption — a window every
# fifth of a beat — had it buried within a bar: ninety pointers chasing the mouse and the
# artist could not see them do it. Over the cards and the flashes now, like the shoal;
# still click-through.
add(t2 + 0.5, "openWindow", {
    "id": "tbd2", "frame": fullscreen(), "level": "floating",
    "content": {"kind": "cursors", "seed": 3136, "intensity": 1.0,
                "spawnSeconds": SWARM_RAMP,
                "chrome": "none", "title": "pointer"},
    "animate": {"kind": "none"}})

FACE_RING = 8
RING_W = round(W * 0.15)
RING_H = round(RING_W * 320 / 425)              # pixelface.jpg's own aspect
rx, ry = W * 0.36, H * 0.40
clock_ids = []
# Three of the eight are HYDRA SKETCHES rather than faces — the patches from the pulled
# intro act, running. Three and not four: `HydraWeb` pre-warms three canvases, and a
# fourth would be compiled mid-show, which is a visible drop. They sit at 1, 4 and 6 so
# no two are adjacent on the ring.
HYDRA_SLOTS = {1, 4, 6}
for i in range(FACE_RING if TORUS2_ACT else 0):
    ang = -math.pi / 2 + 2 * math.pi * i / FACE_RING        # 12 o'clock, clockwise
    wid = f"ck{i}"
    clock_ids.append(wid)
    if i in HYDRA_SLOTS:
        src_code, title = PATCHES[sorted(HYDRA_SLOTS).index(i) % len(PATCHES)]
        body = {"kind": "livecode", "text": src_code, "title": title,
                "chrome": "browser", "hex": "#68BDF8", "running": True}
    else:
        body = {"kind": "image", "path": "assets/pixelface.jpg", "chrome": "none"}
    add(t2 + i, "openWindow", {"id": wid, "anchor": "center",
        "frame": [round(rx * math.cos(ang)), round(ry * math.sin(ang)), RING_W, RING_H],
        "content": body,
        "animate": {"kind": "none"}})

# =============================================================================
# Cue 23 (2:08) — all of it stays, and the video slot lands on top.
# =============================================================================
# The video slot is not a placeholder any more: it RUNS DOOM. Same window, same
# geometry, same `untitled.mov` title bar — the slot that always said "video goes here"
# is filled by the 1997 sources playing E1M1 (`tools/fetch_doom.sh` installs the engine;
# without it the window says so).
#
# It skips its own title card and menu and comes up already in the level — see
# doom.html: the canvas is hidden while the menu is walked, so the ~1.2 s of getting
# there is black, which on a window dressed as a video slot reads as buffering. The
# level is played by the page, since nothing here is clickable.
# Its OWN id, not the `video` the fireworks already borrow at cue 10: re-opening an id
# rebuilds the window's content view, which for this one means the game starts again
# from its title card. An id shared between a transparent overlay and a running game is
# a restart waiting for someone to move a cue.
# PULLED in the timeline (2026-09-03): the video slot is empty again. The `doom` content
# kind and its engine are untouched — one line here brings it back.
DOOMVID_ACT = False
if DOOMVID_ACT:
    add(B["video2"], "openWindow", {
        "id": "doomvid", "anchor": "center", "frame": [0, 0, VIDEO_W, VIDEO_H],
        "content": {"kind": "doom", "chrome": "mac", "title": "untitled.mov"},
        "animate": {"kind": "springIn"}})

# =============================================================================
# Cue 24 (2:09) — the torus and the ring cut out from under it, leaving the slot alone
# on the blue desktop (no black backdrop any more — cut 2026-09-01), and the pointer
# swarm rises WITH it: transparent, over everything, so it has the whole section to
# build before it is alone with the pointer.
# =============================================================================
v3 = B["video3"]
for wid in clock_ids + (["torus"] if TORUS2_ACT else []):
    add(v3, "closeWindow", {"id": wid})
# The swarm is opened back at cue 22, not here — see there. It has been filling under
# the torus and the video slot for the whole of this section.

# =============================================================================
# Cue 25 (2:06) — the video cuts and the swarm, up since cue 24, is alone with the
# viewer's pointer.
# =============================================================================
if DOOMVID_ACT:
    add(B["tbd_136"], "closeWindow", {"id": "doomvid"})

# THE SHOAL HANDS OVER (2026-09-11). Cue 21's school (opened below, with its act) has
# flocked over the eruption since the cut; on the beat the chase swarm is at full
# strength it leaves, so instrumental B has ONE body of pointers and it is the one that
# follows the mouse — two flocks over each other and neither reads. Instrumental A is
# the shoal, the ramp between them is both, B is the chase.
add(B["tbd_136"], "closeWindow", {"id": "school"})

# …AND THE SHOW MOVES THE POINTER, so the chain is seen trailing whether or not the
# viewer touches the mouse (2026-09-11). Three legs, one a bar from bar 69 — the bar
# after the swarm fills — each 3½ beats corner to corner with half a beat still on the
# bar line, so the swarm piles onto the pointer and is stretched off it again: the
# pile-up and the stretch are what "following" looks like. Nothing else drives the
# pointer here — the strobe's warps stop at bar 66. `warp` needs no permission.
DRIVE_FROM = phrase_beat("instrumentalB") + 16                # bar 69
DRIVE_LEG = 3.5                                                # beats moving, per bar
DRIVE_LEGS = [((0.12, 0.15), (0.88, 0.80)),
              ((0.88, 0.80), (0.12, 0.82)),
              ((0.12, 0.82), (0.85, 0.18))]
assert DRIVE_FROM + 4 * len(DRIVE_LEGS) <= B["spam"], "the pointer drive runs into the segmenter"
for i, (p0, p1) in enumerate(DRIVE_LEGS):
    add(DRIVE_FROM + 4 * i, "cursorPath", {
        "path": "linear", "durationBeats": DRIVE_LEG, "easing": "easeInOut", "mode": "warp",
        "points": [[round(W * p0[0]), round(H * p0[1])], [round(W * p1[0]), round(H * p1[1])]]})

# THE ICON EXPLOSIONS, moved here from cue 10. The video slot has just cut and the only
# thing left is the pointer swarm, so a shell going up is legible in a way it never was
# over the spiral. Transparent and full-screen, like it always was; it burns from here
# to the eruption, which is about the seven seconds it had in chorus 1A.
# PULLED in the timeline (2026-09-03). They were moved here from cue 10 and are now out
# of the cut altogether; the act is intact behind the flag.
WORKS_ACT = False
if WORKS_ACT:
    add(B["tbd_136"] + 0.2, "openWindow", {
        "id": "works", "frame": fullscreen(),
        "content": {"kind": "fileworks", "seed": 1046, "hz": 1.0, "intensity": 1.0,
                    "chrome": "none", "title": "Desktop"},
        "animate": {"kind": "none"}})
    add(B["spam"] - 0.2, "closeWindow", {"id": "works"})

# =============================================================================
# Cue 26 (2:08) — the mouse spinner, taken the other way: nothing in the app sets the
# pointer, so instead of one beach ball ON the cursor, a MANDALA of them — concentric
# rings of the wait cursor over the whole screen. Cue 25's swarm chases; this one is
# fixed and turns.
# =============================================================================
# The chase swarm no longer closes here (2026-09-11): with the mandala pulled this was a
# swarm vanishing on a beat with nothing behind it, three bars before the pickup — and
# most of the chasing it ever got to do. It runs to the 2A pickup and goes with cue 21's
# act, below.
# PULLED in the timeline (2026-09-03).
MANDALA_ACT = False
if MANDALA_ACT:
    add(B["spinner"], "openWindow", {
        "id": "tbd3", "frame": fullscreen(),
        "content": {"kind": "mandala", "seed": 3863, "cols": 5, "intensity": 1.0,
                    "chrome": "none", "title": "wait"},
        "animate": {"kind": "none"}})

# =============================================================================
# Cues 27 and 28 — THE SECOND CHORUS, SWAPPED (2026-09-07).
#
# It used to be the eruption on the 2A pickup and the segmenter on the 2B pickup: a wall
# of popups for fifteen seconds, then a hard cut to the video. The order is the other way
# round now — **the clip first, the popups second** — and the join between them is a
# dissolve rather than a cut. Two reasons, and the second is the interesting one:
#
#   - The eruption is the loudest picture in the piece and it was arriving on the FIRST
#     bar of the last chorus, so the chorus had nowhere left to go. Now it lands on 2B and
#     the piece gets louder into the stop instead of starting there.
#   - The popups do not replace the video on a frame. They BURY it. The swarm opens at
#     `level: "normal"` (it used to take the shielding level, since it had the screen to
#     itself) so it shares the eruption's z-order, and z-order there is simply the order
#     things opened in — every card the eruption raises after the pickup lands ON a video
#     panel. Over about a bar and a half the picture is taken over rather than cut away
#     from, and the close at the end sweeps what is left.
#
# The two acts keep their cue KEYS (`spam` on the 2A pickup, `glitch` on the 2B pickup) —
# renaming them would ripple through `WAS`, `LABELS`, `KINDS` and every `B[...]` in the
# file for no gain, and the piece already does this in two other places (cue 5's key is
# `hydra` and it holds the brick breaker; cue 21's is `horse`). Only what runs at each
# beat has moved.
#
# ONE KNOCK-ON, and it is expected rather than a regression: `chaos_rng` is a single
# stream feeding BOTH eruptions in file order, so shortening this one's span from 32 beats
# to 27 changes how many draws it takes and cue 21's eruption re-scatters. It is still
# seeded, still byte-identical run to run, and still the same act — the windows land in
# different places, which is what "the eruption" means.
# =============================================================================
body_colors = PALETTE + ["#0B0E16"]
chaos_rng = random.Random(7)
chaos = {"w": 0, "d": 0, "l": 0, "ui": 0, "p": 0, "a": 0, "gone": 0, "muted": 0}

def erupt(b0, b1, cx, cy, rate=0.25, ui_chaos=0.0, photos=False, keep_out=None, alerts=True,
          rate_to=None, spread=0.65, evanesce=None, vanish_to=0.0, at=None, rng=None,
          mute_from=None, until=None, rate_before=None, ui_chaos_before=None):
    """~8 events/sec out of (cx, cy) — the explosion, not a ramp.

    …unless `rate_to` is given: then the beats between cards slide from `rate` at `b0`
    to `rate_to` at `b1`. Same draws per card either way.

    `spread` is how far out the cards go, as a fraction of the screen width at full
    size; 0.65 is the eruption, smaller keeps them close round the centre.

    `evanesce=(life0, life1)` is how chorus 2A BUILDS (2026-09-11): every card it opens
    is taken away again after a lifetime that grows from `life0` beats at `b0` to
    `life1` at `b1`, and the SHARE of cards that go at all falls from all of them to
    none — so at first the screen is a few cards popping round the middle and vanishing,
    and by the end they all stay, which is the eruption proper arriving. The decision is
    drawn from its own RNG, not `chaos_rng`, so the geometry is exactly what it would be
    without it. A lifetime must stay under the pool's recycle period (fourteen ids), or a
    close would take a NEWER card under the same id; and no close is scheduled past `b1`,
    where the next act owns the pool.

    `keep_out` is `(w, h)`: a hole that size, centred on (cx, cy), that no card may
    land in — the centre alert's ground at cue 28 (2026-09-11). It is enforced by
    PUSHING a card outward along the angle it already drew, never by re-rolling: a
    rejected draw would shift every window after it in BOTH eruptions, whereas a push
    is a pure function of the values already in hand, so with `keep_out=None` the
    geometry is byte-identical to before it existed. A card is pushed along whichever
    axis it is nearer (the sign of its angle), and its size on that axis is capped to
    the room beside the hole, so the screen-edge clamp below can never slide it back
    in: `room = (W - hole) / 2 - 20`, and the clamp leaves a near edge of at least `hole / 2`
    from the centre exactly when the card is no wider than that room.

    `alerts=False` leaves the dialog slot EMPTY rather than opening one of the
    scattered lyric alerts: when the centre is a warning box carrying the sung line,
    a second warning box in the ring with a different line is the one thing that
    would undo it. The slot stays in the roll (no draw is added or removed) so this,
    too, leaves the other eruption's scatter alone.

    `ui_chaos` is the fraction of the flat colour cards that come up packed with real
    macOS interface instead (`uichaos`, drawn by the engine). It is set on BOTH
    eruptions even though cue 29 is what asked for it: both erupt into the same
    fourteen ids, cue 29 alone is only ~2.3 s (about one packed window), and most of
    what is visible then was put up by cue 27 — so "a quarter of the visible empty
    windows" means a quarter on both.

    `photos` turns on the broken-screen photographs, and unlike `ui_chaos` it is set on
    ONE eruption: the one that closes the piece (cue 28). They are the one un-synthetic
    thing in the piece and they read as that because they are rare and because they
    arrive once — spread over every eruption they would be another texture. The gate
    costs no `chaos_rng` draw, so the others scatter exactly as they would; they simply
    show a colour card where cue 28 shows a photograph.

    `at` (2026-09-11) is a GRID: a list of beats, and a card lands on each of them
    instead of the walk above — chorus 2A's build is cards on the beat, subdividing.
    On a grid every slot opens something: the alert slot (empty with `alerts=False`)
    and the jiggle would be a missed beat, and a missed beat in a build of two cards a
    bar is a bar where nothing happens. The walk keeps its rests. `vanish_to` is the
    share of cards `evanesce` still takes away at `b1` (0 = by then they all stay; 0.5
    leaves the act half-empty for the next one to fill). `rng` is the stream the
    geometry is drawn from; the default is `chaos_rng`, and a build with its OWN stream
    leaves every eruption after it byte-identical, which is why 2A's has one.

    `until` / `rate_before` / `ui_chaos_before` (2026-09-12): before the beat `until`
    the walk steps `rate_before` and packs `ui_chaos_before` of its flat cards instead —
    the eruption doing a little less while something else still has the screen. The
    draws per card are the same either way; fewer cards before `until` means the walk
    after it takes different draws, so the scatter there moves. It is the same act.

    `mute_from` (2026-09-12) is a beat past which the walk goes on — every draw, every
    counter, so the next eruption's scatter does not move — but nothing is emitted: the
    act stops putting windows up while the rng stream stays exactly as long as it was.
    Cue 21 uses it to fall silent a bar before the pickup so that bar can empty.
    """
    rng = chaos_rng if rng is None else rng
    slots = iter(sorted(at)) if at is not None else None
    fade_rng = random.Random(zlib.crc32(b"evanesce"))
    def evanesce_close(wid, b, prog):
        if evanesce is None:
            return
        life0, life1 = evanesce
        life = life0 + (life1 - life0) * prog
        if fade_rng.random() < 1.0 - prog * (1.0 - vanish_to) and b + life < b1 - 0.1:
            add(b + life, "closeWindow", {"id": wid})
            chaos["gone"] += 1
    global MUTE
    b = b0 if slots is None else next(slots, b1)
    while b < b1:
        MUTE = mute_from is not None and b >= mute_from
        prog = (b - b0) / max(1e-6, b1 - b0)
        u = 0.75 + 0.25 * prog
        r = 30 + (u ** 1.6) * spread * W * rng.uniform(0.5, 1.0)
        ang = rng.uniform(0, 6.28318)
        w = round((110 + (u ** 1.7) * 380) * rng.uniform(0.8, 1.25))
        h = round(w * rng.uniform(0.6, 0.85))
        if keep_out:
            # Out of the hole, along the ray it drew — no new draws (see the docstring).
            kw, kh = keep_out
            if abs(math.cos(ang)) >= abs(math.sin(ang)):
                w = min(w, round((W - kw) / 2 - 20))
                r = max(r, (kw + w) / 2 / abs(math.cos(ang)))
            else:
                h = min(h, round((H - kh) / 2 - 20))
                r = max(r, (kh + h) / 2 / abs(math.sin(ang)))
        x = max(10, min(cx + r * math.cos(ang) - w / 2, W - w - 10))
        y = max(10, min(cy + r * math.sin(ang) - h / 2, H - h - 10))
        before = until is not None and b < until
        ui_here = ui_chaos_before if before and ui_chaos_before is not None else ui_chaos
        roll = rng.random() * (0.70 if slots is not None else 1.0)   # a grid has no rests
        if roll < 0.42:
            # Both draws happen either way — see the note in cue 15. `chaos_rng` seeds
            # the whole eruption's geometry, so a draw taken on one branch and not the
            # other would re-scatter every window after it.
            hexc = rng.choice(body_colors)
            packed = rng.random() < ui_here
            animate = {"kind": "none" if rng.random() < 0.8 else "springIn"}
            # Every ninth flat card comes up TORN instead of blank — the same
            # displacement/chroma-split pass the piece uses at the end, run once over one
            # of the show's own images. Chosen off the window counter, never off
            # `chaos_rng`: a draw taken here and not there would re-scatter every window
            # in both eruptions. This is also where the tear went when cue 15 was pulled
            # — that act was the only thing using the `glitch` kind.
            torn = chaos["w"] % 9 == 4
            g = (chaos["w"] // 9) % len(GLITCH_SOURCES)
            # ...and every so often a PHOTOGRAPH of a real broken screen, on the eruption
            # that asked for it. Off the counter for the same reason `torn` is: a
            # `chaos_rng` draw here would re-scatter every window in both eruptions.
            # `photos` gates the branch WITHOUT touching the rng, so cue 21 draws exactly
            # the same geometry and just renders a colour card where cue 27 shows a photo.
            # 10 against `torn`'s 9 so the two never fall into step: consecutive integers
            # are coprime.
            #
            # HOW MANY land is NOT one in ten, and cannot be tuned to a target by moving
            # the modulus. `chaos["w"]` counts every window the eruption opens, but only
            # the ~42% that take this branch can BE a photograph — the lyric cards and the
            # terminals advance the counter too. A photo needs the residue and the branch
            # to coincide, which is ~6% of events; measured, 11 gave seven and 10 gave six.
            # Do not chase a number here.
            #
            # WHICH picture is therefore indexed off the PHOTO counter, not off `w`.
            # `w // 10` skips and repeats as the two rates beat against each other, which
            # is how the eighth picture came to be built, shipped and never shown; `p`
            # advances exactly once per photograph, so they come up in order.
            #
            # Tested FIRST, ahead of `packed` and `torn`. `ui_chaos` is a texture and it
            # is on a quarter of the cards; the photographs are the rare deliberate thing,
            # and letting a 25% roll eat a quarter of them would thin them out and make
            # the count depend on the rng as well as the branch.
            shot = photos and chaos["w"] % 10 == 7
            ph = BROKEN_SCREENS[chaos["p"] % len(BROKEN_SCREENS)]
            content = ({"kind": "image", "path": ph,
                        # Named the way a camera roll names things — the drop's own
                        # filenames are UUIDs that truncate to nothing in a title bar.
                        # Same licence the show already takes with "recovered.jpg".
                        "chrome": "mixed", "title": f"IMG_{4000 + chaos['w']:04d}.JPG"}
                       if shot else
                       {"kind": "uichaos", "seed": 900 + chaos["w"], "intensity": 1.15,
                        "chrome": "mixed", "title": "Finder"}
                       if packed else
                       {"kind": "glitch", "path": GLITCH_SOURCES[g],
                        "intensity": round(0.45 + 0.18 * g, 2), "seed": 4100 + 17 * chaos["w"],
                        "chrome": "mixed", "title": "recovered.jpg"}
                       if torn else
                       {"kind": "color", "hex": hexc,
                        "chrome": "mixed", "title": "look://again"})
            if shot:
                chaos["p"] += 1
            add(b, "openWindow", {"id": f"w{chaos['w'] % 14}", "frame": [round(x), round(y), w, h],
                "content": content, "animate": animate, "interactive": True})
            evanesce_close(f"w{chaos['w'] % 14}", b, prog)
            chaos["w"] += 1
            # `packed` is still drawn on a photo card (the rng must not diverge), but it
            # did not render, so it does not count.
            if packed and not shot:
                chaos["ui"] += 1
        elif roll < 0.58:
            text = phrase_texts[chaos["l"] % n_cue].upper()   # ALL CAPS, like the spiral
            # THE FACE CHANGES THREE TIMES A SECOND, at random, out of the viewer's own
            # font library — the machine rifling through their fonts while it sings at
            # them. Only here: the chorus 1A spiral is the lyric being READ and stays in
            # the show's Hack Bold, and cutting the face under it would make a legibility
            # act into a texture one.
            lyric_card(f"w{chaos['w'] % 14}", b, text, chaos["l"],
                       frame=[round(x), round(y), max(w, 260), h], chrome="mac",
                       font_cycle_hz=3.0)
            evanesce_close(f"w{chaos['w'] % 14}", b, prog)
            chaos["w"] += 1; chaos["l"] += 1
        elif roll < 0.70:
            add(b, "openWindow", {"id": f"w{chaos['w'] % 14}",
                "frame": [round(x), round(y), max(w, 300), h],
                "content": {"kind": "code", "text": rng.choice(codes),
                            "chrome": "terminal", "title": "haunt.sh"},
                "animate": {"kind": "none"}, "interactive": True})
            evanesce_close(f"w{chaos['w'] % 14}", b, prog)
            chaos["w"] += 1
        elif roll < 0.86:
            # The slot is taken either way; with `alerts=False` nothing opens in it.
            if alerts:
                title, body, icon = lyrics.alert(chaos["d"])
                add(b, "fakeDialog", {"id": f"d{chaos['d'] % 4}", "title": title, "body": body,
                    "buttons": lyrics.buttons(chaos["d"]), "icon": icon,
                    "frame": [round(x), round(y), 460, 190]})
                chaos["a"] += 1
            # ...and the counter advances either way. It is the only state this branch
            # owns, and the other eruption reads its copy and its ids off it: skipping
            # it here re-lettered every alert in cue 21 (measured: 32 events).
            chaos["d"] += 1
        elif chaos["w"] > 0:
            add(b, "jiggle", {"id": f"w{(chaos['w'] - 1) % 14}", "durationBeats": 1.5,
                "amplitude": 18, "frequency": 9})
        if slots is not None:
            b = next(slots, b1)
            continue
        step = rate if rate_to is None else rate + (rate_to - rate) * prog
        if before and rate_before is not None:
            step = rate_before
        b += max(0.15, step * rng.uniform(0.7, 1.3))
    MUTE = False

sm = B["spam"]                  # the 2A pickup (bar 72) — the CLIP
gl = B["glitch"]                # the 2B pickup (bar 80) — the ERUPTION
lw = B["lastwords"]             # the stop
if MANDALA_ACT:
    add(sm - 0.2, "closeWindow", {"id": "tbd3"})
add(sm, "screenFlash", {"color": WHITE, "durationBeats": 0.4})

# --- cue 27, the 2A pickup: THE SEGMENTER SWARM ---------------------------------
# `assets/giveit2meclip.mp4` segmented for MOTION: every region that moves becomes its
# own titled window holding the piece of frame it was cut from, pinned where it was
# found. Nothing is tracked between frames, so a thing that keeps moving mints a new
# window every frame and the screen fills — up to 60, then the oldest panel is recycled.
#
# `level: "normal"` is the change that makes the crossfade possible, and it is the
# opposite of what this act asked for when it closed the piece: it took the shielding
# level then, because it WAS the screen and nothing else was open. Here it has to be
# something the eruption can climb on top of.
# THE PILE LEAVES OVER A SECOND (2026-09-12): `clearSeconds` takes it down oldest-first
# on the close, so the video goes panel by panel under the box rather than on a frame.
# It does NOT ramp in: growing the pile's cap over 1, 2 or 3 s was measured and made the
# pickup worse — a window's first appearance is paid per run-loop commit, and spreading
# the sixty only multiplied it (see README, "Closing many windows at once"). What made
# the pickup cheap was the engine releasing finished windows; the sixty births now cost
# a beat at ~25 Hz instead of a second at 2.
SEG_CLEAR = 1.0
add(sm, "segSwarm", {
    "id": "segswarm", "path": "assets/giveit2meclip.mp4", "mode": "motion",
    "intensity": 0.62, "maxWindows": 60, "mirror": False,
    "clearSeconds": SEG_CLEAR,
    "level": "normal",
    # No keyline. Upstream rings every panel green to mark it as a detection; here the
    # panels ARE the picture, and sixty green rectangles read as a debug overlay laid
    # over the show rather than as the show.
    "border": "none"})

# …AND CUE 21'S ERUPTION IS SWEPT OFF THE SCREEN BEHIND IT.
#
# `w0…w13` and `d0…d3` are a POOL shared by both eruptions, and cue 21 deliberately does
# not close them: the next eruption used to open on this very frame and re-open the same
# ids, so closing them here would have been a flicker between two acts using the same
# fourteen windows. The 2026-09-07 swap put fifteen seconds of segmenter between the two,
# and that turned "recycled on the next frame" into eighteen orphaned cards standing over
# the whole of chorus 2A — measured on the generated timeline: all eighteen still up at
# f 4437, the frame before the eruption finally reclaims them.
#
# A QUARTER BEAT AFTER the boundary, not before it, and this is the same trap cue 30's
# sweep is written around: `erupt` walks its own cadence and can land a final `openWindow`
# ON its end beat, so a close placed at −0.1 misses it and that card stands for the rest
# of the act. A quarter beat is ~90 ms into a swarm that takes a second to build up, so
# nothing is seen going.
#
# A BACKSTOP since 2026-09-12: cue 21's eruption is muted from bar 71 and its pool leaves
# one card at a time through that bar (see `leaving` there), so by the pickup every one
# of these is already shut, and a close aimed at a shut window is free.
for wid in [f"w{i}" for i in range(14)] + [f"d{i}" for i in range(4)]:
    add(sm + 0.25, "closeWindow", {"id": wid})

# --- THE CENTRE (2026-09-11): one warning box, the sung line, over both halves ---
# The second chorus had no middle. The segmenter pins its panels wherever the clip
# moves and the eruption throws cards out of the centre in every direction, so the
# only lyric on screen was whichever scattered alert happened to be up, carrying
# whichever line the counter had reached — never the one being sung. So: ONE alert,
# dead centre, floating over all of it, whose message is the phrase being sung right
# now and whose informative text is the sentence it comes from (`lyrics.SENTENCES`).
# It comes up on each sung line and is taken away a hair before the next one lands,
# so every line POPS rather than swapping in place — the same `lyrics.phrase_cues()`
# the chorus 1A spiral is timed from, transposed onto each chorus's own zero, so a
# word retuned in `lyrics.CUES` moves here as well.
#
# The eruption is kept OUT of a hole round it (`keep_out`, below), so the clutter is a
# ring with the words in the middle, and its scattered lyric alerts are off
# (`alerts=False`): a second warning box in the ring with a different line would be
# the one thing that undid the centre. Over the segmenter nothing can be kept out —
# panels land where the motion is — so there the box simply floats over them.
#
# FLOATING, for the reason the ASCII planes are: at the normal level it would be under
# the eruption by the second bar. The planes are floating too and open later, but each
# re-open of the box brings it back to the front of that level, so it is above them
# from its next line on; the flashes are normal windows and never wash it out.
LYRIC_BOX = "lyricbox"
LYRIC_BOX_W, LYRIC_BOX_H = 540, 200               # a size up from the ring's 460x190
LYRIC_HOLE = (LYRIC_BOX_W + 60, LYRIC_BOX_H + 60) # the box plus a 30 pt moat
# EACH LINE IS ITS OWN POP-UP (2026-09-11). The first pass took each box away a hair
# before the next landed, and the artist read that as one window scaling up and down,
# not a series of alerts. So a box stays up HOLD beats and is cut, and there is at least
# GAP beats of nothing before the next one lands — up on its frame with no spring
# (`animate: none`), the way a real alert arrives. Lines are 1–2.5 beats apart, so a box
# is up for half a beat to a beat and a quarter, and the middle is empty between them.
LYRIC_BOX_HOLD = 1.25
LYRIC_BOX_GAP = 0.5
# A HAIR EARLY (2026-09-11). Even parked and swapped rather than rebuilt, an alert is
# a content view laid out and a window ordered front on a main thread that is opening
# other windows; the artist heard every box land a hair after its line. Two frames of
# lead, in seconds because it is latency, not music. Open and close move together.
LYRIC_BOX_LEAD = 0.07
# THE SECOND CHORUS COMES IN TWO BEATS EARLY (2026-09-11, measured). `lyrics.CUES` is
# tuned by ear against chorus 1, where the vocal band steps up two beats into the pickup
# bar (bar 16.5, and again 24.5); in the second chorus it steps up ON the downbeat of
# bars 72 and 80. Timed off chorus 1's zero the boxes ran a line behind the singing —
# the artist's "one late" — so both halves' zeros sit this much earlier.
CHORUS2_PICKUP_LEAD = 2                           # beats
LYRIC_ICONS = ["critical", "caution", "info", "critical"]   # ALERTS' icons, by sentence
lyric_box_at = []                                 # (beat, text), for the printout

def lyric_box_run(zero, until, start=None):
    """The centre alert on every sung phrase from `zero`, each replaced by the next.

    Phrases landing at or after `until` are dropped: chorus 2B's lyric is cut off by
    the stop, and its last sung words are "need your love" — cue 30 is `lastwords`.
    Phrases before `start` are dropped too: 2B's box begins where the segmenter hands
    the centre over, not on the pickup."""
    beats_here = [lyric_beat(zero, when) for when, _, _ in phrases]
    for i, (when, text, line) in enumerate(phrases):
        b = beats_here[i]
        if start is not None and b < start - 1e-6:
            continue
        if b >= until - 0.5:
            break
        k = len(lyric_box_at)
        sentence = lyrics.sentence_of(line)
        add_t(secs(b) - LYRIC_BOX_LEAD, "fakeDialog", {
            "id": LYRIC_BOX, "anchor": "center", "level": "floating", "animate": "none",
            "frame": [0, 0, LYRIC_BOX_W, LYRIC_BOX_H],
            "title": text, "body": "\n".join(lyrics.LINES[i] for i in sentence),
            "buttons": lyrics.buttons(k), "icon": LYRIC_ICONS[lyrics.SENTENCES.index(sentence)]})
        # Cut after HOLD, or GAP before the next line if that comes first. The last line
        # of a half measures its gap against the next half's zero, or the stop.
        nxt = beats_here[i + 1] if i + 1 < len(beats_here) else until
        add_t(secs(min(b + LYRIC_BOX_HOLD, min(nxt, until) - LYRIC_BOX_GAP)) - LYRIC_BOX_LEAD,
              "closeWindow", {"id": LYRIC_BOX})
        lyric_box_at.append((b, text))

zero_2A = lyric_zero("chorus2A") - CHORUS2_PICKUP_LEAD
zero_2B = lyric_zero("chorus2B") - CHORUS2_PICKUP_LEAD
# CHORUS 2A IS THE SEGMENTER'S. The box — and a build under it, twice over on
# 2026-09-11 — was put over this half and pulled both times: with the clip on the
# machine the artist wants the video alone there, nothing breaking it up. Kept behind
# CENTRE_2A_ACT, one line to bring back.
CENTRE_2A_ACT = False
if CENTRE_2A_ACT:
    lyric_box_run(zero_2A, zero_2B)  # over the segmenter; the last line holds into 2B
# …AND 2B'S CENTRE STARTS WHEN THE CLIP RUNS OUT (2026-09-12). The box used to land
# dead centre on the pickup, on top of the video's busiest region, and the video read as
# ending there when it was in fact still minting panels under the box for a bar and a
# half. The clip is 18.4 s and opens on the 2A pickup, so it runs out two bars into 2B,
# on "running up" — the start of a sentence, a hair before a bar line — and that is the
# handover: the eruption rings the video for those two bars (`keep_out` holds the middle
# clear for it), the panels are swept on the line, and the box takes the centre on the
# same frame. Nothing here is timed to the clip's length by number: move the segmenter
# and the handover stays on its line, and the clip loops under it if it has to.
SEG_HANDOVER_LINE = "running up"
SEG_HANDOVER = next(lyric_beat(zero_2B, when) for when, text, _ in phrases
                    if text == SEG_HANDOVER_LINE and lyric_beat(zero_2B, when) > gl)
lyric_box_run(zero_2B, lw, start=SEG_HANDOVER)   # over the eruption; the last line holds to the stop

# --- chorus 2A's BUILD (2026-09-11, evening) — PULLED the same night, behind CENTRE_2A_ACT:
# the artist heard it breaking the video up, and the video is the point of the half.
# Kept as it was tuned, for a cut that wants a build here: cards ON THE BEAT, subdividing to the hook.
# The earlier build walked the eruption's own jittered cadence, thickening from a card
# every half beat to one every third, and the half read as the eruption arriving early
# rather than as something of its own. This one is a RHYTHM: every card lands on the
# grid, and the grid subdivides — a card every two beats through bars 72–73, every beat
# from bar 74, every half beat from the hook in bar 78 (`BUILD_BARS`, one entry per bar
# of the eight). So 2A pulses with the track where 2B sprays over it, and the doubling
# lands where the ear expects it. The cards still VANISH — half a beat after landing at
# first, two beats by the end — and the share that goes falls from all of them to half,
# so the half stays airy round the words and the segmenter shows through: 2B is what
# arrives when nothing goes any more. Same pool, same hole, no alerts (the centre is the
# alert). Its own RNG, so cue 28's scatter is byte-identical to before the build existed;
# it starts on beat 2 of the pickup bar, behind the quarter-beat sweep of cue 21's cards.
BUILD_BARS = [2, 2, 1, 1, 1, 1, 0.5, 0.5]   # beats between cards, bar 72 → bar 79
BUILD_FROM = sm + 1                        # beat 2 of the pickup bar
BUILD_SPREAD = 0.45                        # closer in than the eruption's 0.65: round the box
BUILD_LIFE = (0.5, 2.0)                    # beats a vanishing card stays, at the pickup → at 2B
BUILD_VANISH_TO = 0.5                      # the share still taken away again at the 2B pickup
assert len(BUILD_BARS) * 4 == gl - sm, "one BUILD_BARS entry per bar of chorus 2A"
build_at = []
for k, gap in enumerate(BUILD_BARS):
    b = max(sm + 4 * k, BUILD_FROM)
    while b < sm + 4 * (k + 1) - 1e-6:
        build_at.append(round(b, 3))
        b += gap
build_rng = random.Random(zlib.crc32(b"chorus 2A build"))
w_before, gone_before = chaos["w"], chaos["gone"]
if CENTRE_2A_ACT:
    erupt(sm, gl, W / 2, H / 2, ui_chaos=0.25, keep_out=LYRIC_HOLE, alerts=False,
          spread=BUILD_SPREAD, evanesce=BUILD_LIFE, vanish_to=BUILD_VANISH_TO,
          at=build_at, rng=build_rng)
n_build, n_gone = chaos["w"] - w_before, chaos["gone"] - gone_before

# --- cue 28, the 2B pickup: THE ERUPTION, over it and then instead of it ---------
# WHILE THE VIDEO IS STILL UP (the pickup to `SEG_HANDOVER`, two bars) the eruption does
# a little less: a card every `OVERLAP_RATE` beats instead of every quarter. Sixty video
# panels, the ring, the kick flashes and the hex plane share the compositor here, and it
# was the one stretch still well under the display rate once everything else was fixed.
# Measured (2026-09-12, three alternated pairs of runs): halving the cards over those two
# bars lifts the stretch's worst second from ~60 Hz to ~85 and its mean from 87 to 94;
# dropping the packed-UI cards, halving the hex plane's rate or muting the kick flashes
# over the video did not measure better than the baseline, so they stay as they were.
# The ring reaches the same density by the handover; the flashes, the video and the box
# are untouched.
OVERLAP_RATE = 0.5
add(gl, "screenFlash", {"color": WHITE, "durationBeats": 0.4})
erupt(gl, lw, W / 2, H / 2, ui_chaos=0.25, photos=True, keep_out=LYRIC_HOLE, alerts=False,
      until=SEG_HANDOVER, rate_before=OVERLAP_RATE)

# The swarm is not closed on the boundary. It is left running INTO the eruption — ringed
# by its cards, the middle kept clear, buried a panel at a time at the edges — and swept
# on `SEG_HANDOVER`, the line the clip runs out on, where the centre box takes over (see
# the centre, above). That overlap is the whole difference between the popups replacing
# the video and the popups cutting to it. The sweep lands a hair before the box's own
# lead, so the box comes up on a clean centre. (It was a fixed bar and a half, `SEG_BURY`,
# until 2026-09-12.)
#
# It cannot be ramped down instead: `SegSwarmController.begin` calls `closeAll()` first,
# so a second `segSwarm` on the same id would tear every panel down AND restart the clip
# from the top. Burial is the mechanism available, and it is the better-looking one.
SEG_SWEEP_T = secs(SEG_HANDOVER) - LYRIC_BOX_LEAD - 0.02
add_t(SEG_SWEEP_T, "closeWindow", {"id": "segswarm"})

# The ground flashes on every kick underneath the eruption.
flash_colors = ["#FEFEFE", BLUE, "#020202", "#68BDF8"]
n_kick = 0
for i, kt in enumerate(kicks_between(gl, lw)):
    add_t(kt, "screenFlash", {"color": flash_colors[i % len(flash_colors)],
                              "durationSeconds": 0.09})
    n_kick += 1

# =============================================================================
# THE MACHINE'S OWN VOICE — four ASCII planes over the eruption, running out exactly on
# the stop.
#
# They went WITH the eruption in the 2026-09-07 swap. They were written as its voice —
# the machine talking over the noise it is making — so they belong to the act rather than
# to the bar it used to start on. The phrase is shorter here (27 beats from the 2B pickup
# to the stop, against the 32 they had), so the four slots are 6.75 beats each instead of
# 8: the escalation is the same four steps, taken slightly faster into a stop rather than
# into a changeover. `ASCII_SPAN` is derived, so nothing here needed retiming by hand.
#
# All four are the same object: `asciilog`, a full-screen monospaced plane set in Monaco,
# TRANSPARENT unless it is given a ground, so the eruption goes on underneath and the
# text is laid over it rather than replacing it. They are `floating` for the reason the
# shoal was — the eruption raises a window every fifth of a beat and anything at the
# normal level is buried by the second bar. The shoal itself has closed by now (it went
# with cue 21), so the level is free.
#
# The order is an escalation: unreadable machine state, then the machine saying the words,
# then the words coming apart, then the machine drawing the screen it is on. Then it stops
# — and this time the thing it stops into is the silence, not the segmenter.
# The planes are set in the show's SKY blue, not the signature `DJ_BLUE`.
#
# That is forced, not a preference: the window map's ground IS `DJ_BLUE` (the act is
# "covering up everything" with it), so type in the same blue is type you cannot see.
# `#68BDF8` is the show's own light blue — already the fourth kick flash and in the
# palette — and it reads both on that ground and on the bare eruption underneath the
# three transparent planes.
# ASCII_BLUE = "#68BDF8"
ASCII_BLUE = "#FFFFFF"
al = gl
ASCII_SPAN = (lw - al) / 4                   # 6.75 beats each, the last landing on the stop
ascii_ids = []

def ascii_plane(i, params, seconds_early=0.0):
    """One plane in the run, opened on its slot and closed on the next one's."""
    wid = f"asciilog{i}"
    ascii_ids.append(wid)
    b0 = al + ASCII_SPAN * i
    content = {"kind": "asciilog", "chrome": "none", "hex": ASCII_BLUE}
    content.update(params)
    add(b0 - seconds_early / BEAT, "openWindow", {
        "id": wid, "frame": fullscreen(), "level": "floating",
        "content": content, "animate": {"kind": "none"}})
    add(al + ASCII_SPAN * (i + 1) - 0.05, "closeWindow", {"id": wid})
    return b0

# 1. THE DUMP. Hex spam, filling the screen top to bottom — the machine's memory going
#    past faster than anyone reads it. 26 lines a second fills a ~60-row screen in about
#    two seconds, which is the point: it is a wall before it is a list.
HEX_HZ = 26
ascii_plane(0, {"source": "hex", "hz": HEX_HZ, "seed": 4472, "fontSize": 12,
                "title": "kernel: memory"})

# 2. THE LOG. The same lyric that has been sung all the way through, coming out of the
#    machine as log records — timestamp, level, `giveit2me[1337]`. The words are the
#    written lines from `lyrics.LINES`, so this stays in step with the rest of the show's
#    copy rather than being a second transcription of the song.
ascii_plane(1, {"source": "lines", "lines": [l.upper() for l in lyrics.LINES],
                "hz": 7, "seed": 4473, "fontSize": 14, "title": "syslog"})

# 3. THE CORRUPTION. The same words again, this time coming apart: combining marks
#    stacked over, under and through every glyph so the lines bleed into each other.
#    Bigger type and a static frame, because this one is meant to be read as it fails —
#    a scrolling zalgo is just noise.
ascii_plane(2, {"source": "text", "text": "\n".join(l.upper() for l in lyrics.LINES[:6]),
                "zalgo": 0.85, "seed": 4474, "fontSize": 30, "title": "stdout"})

# 4. THE MACHINE LOOKING AT ITSELF. Every window the show has open, drawn as ASCII box
#    art on the show's own blue — and STROBING, so the screen alternates between the real
#    windows and the machine's rendering of them.
#
#    `bg` is what makes this one cover everything instead of overlaying it, and the strobe
#    takes the whole plane away rather than dimming it, so the off phase is the real
#    screen. 3 Hz — six full-screen changes a second, and the flash-rate measure over the
#    whole cut is what says whether that is affordable, not this comment.
#
#    The boxes are synthesised from the rectangles the engine already owns. Nothing is
#    captured: Screen Recording is the one grant macOS will not settle with an inline
#    prompt, and `TimelineTests` fails a cut that needs it.
ascii_plane(3, {"source": "windows", "bg": DJ_BLUE, "strobe": 3.0, "hz": 12,
                "seed": 4475, "fontSize": 13, "title": "wm: dump"})

# =============================================================================
# Cue 21 (2:00) — the eruption again, with the original strobe spliced in over the top,
# STRAIGHT IN — no four-bar wait — and its flashing PHRASED, a bar on and a bar off.
#
# MOVED HERE (2026-09-05), trading places with the segmenter swarm that used to hold this
# stretch: the noise now lands on the instrumental, where the screen has just been cut
# back to the bare blue desktop, and the segmenter closes the piece instead. The act is
# the same eruption, the same splice, the same shoal, the same current — it is 47 beats
# long here instead of 27, so the whole of the strobe fits before the cut.
#
# The strobe is authored in absolute seconds, which survive the splice with a plain
# offset; everything past the end of the window is dropped, and the vocal pickup closes
# what it left. The desktop stays blue underneath: the old glitch ⇄ lyric alternation is
# out of the cut — every glitch pass was a bitmap render AND a ~300 ms desktop swap every
# window on screen pays for, and the section was extremely laggy live.
#
# THE FLASHING IS A RHYTHM NOW (2026-09-11). The strobe used to run from the cut for its
# whole 15.4 s — a full-screen colour every 0.15 s, over an eruption that already raises
# a window every fifth of a beat — and the section read as one flat wall of flicker. So
# the act is phrased: FOUR two-bar phrases from bar 60, the bar the cut lands in, to bar
# 68, and in each the first bar is windows popping up and the second bar is the strobe.
# Only the strobe's full-screen `screenFlash` events are gated. Its furniture — the
# colour cards, the four movers, the alerts — runs through all eight bars as it always
# did, so a window bar is not an empty one, and every open the strobe makes still meets
# its close (`lint_show.py` checks that pairing).
#
# THE PHRASE STARTS ON THE CUT'S BAR, not on the next bar line. The first pass put the
# grid on bar 61 so the strobe file would cover four whole flash bars, and the artist
# heard every phrase the other way round — flash first, windows second — because the
# ear groups this passage in twos from where the eruption starts, bar 60, not from bar
# 61. So the grid is bars 60/62/64/66 windows, 61/63/65/67 the strobe, and the splice
# starts on the cue again: 15.4 s from a beat into bar 60 reaches bar 68.4, past the last
# flash bar. The three beats between the cut and bar 61 are the first window half.
#
# THE CURSOR TAKES THE OTHER HALF. The strobe warps the pointer along a path every
# 0.14 s; that now happens only in the window bars, and the pointer holds still through a
# flash bar — so the two halves are opposites in every way that moves: windows pop and
# the cursor runs, then the screen flashes and nothing travels. A path is kept only if
# the whole of it fits inside its bar, so none spills into the flash.
# =============================================================================
gl2 = B["horse"]
ERUPT_END = B["spam"]              # the vocal pickup takes the screen back for cue 27
# THE LAST BAR EMPTIES (2026-09-12). The eruption's last card lands before bar 71 — the
# walk goes on muted, so cue 28's scatter is untouched — and through that bar its windows
# LEAVE one at a time (below), so the screen drains into the pickup instead of cutting.
LEAVE_FROM = ERUPT_END - 4         # bar 71, the last before the vocal pickup
# ITS FIRST BAR DOES A LITTLE LESS (2026-09-12): a card every `CUT_RATE` beats and no
# packed-UI cards until `CUT_UNTIL`, because that bar is already the strobe's twenty
# windows being born on the cut and the photo wall's forty coming down — measured as the
# worst second in the show, 5 Hz. From the second bar on it is the eruption as before.
CUT_UNTIL = gl2 + 4
CUT_RATE = 0.36
erupt(gl2, ERUPT_END, W / 2, H / 2, rate=0.18, ui_chaos=0.25, mute_from=LEAVE_FROM,
      until=CUT_UNTIL, rate_before=CUT_RATE, ui_chaos_before=0.0)
ERUPT_P0 = phrase_beat("instrumentalA") + 12       # bar 60: INSTRUMENTAL A + 3.0, the cut's bar
ERUPT_PHRASE = 8                                    # two bars
ERUPT_PHRASES = 4                                   # to bar 68
WINDOW_BARS = [(ERUPT_P0 + k * ERUPT_PHRASE, ERUPT_P0 + k * ERUPT_PHRASE + ERUPT_PHRASE // 2)
               for k in range(ERUPT_PHRASES)]      # the first bar of each phrase
FLASH_BARS = [(ERUPT_P0 + k * ERUPT_PHRASE + ERUPT_PHRASE // 2, ERUPT_P0 + (k + 1) * ERUPT_PHRASE)
              for k in range(ERUPT_PHRASES)]       # the second bar of each phrase
assert WINDOW_BARS[0][0] <= gl2 < WINDOW_BARS[0][1], "the cut must land in the first window half"
assert ERUPT_P0 + ERUPT_PHRASES * ERUPT_PHRASE <= ERUPT_END, "the phrasing reaches outside the act"
def in_flash_bar(t):
    return any(secs(b0) <= t < secs(b1) for b0, b1 in FLASH_BARS)
def in_window_bar(t0, t1):
    """True when [t0, t1) sits wholly inside one window bar."""
    return any(secs(b0) <= t0 and t1 <= secs(b1) for b0, b1 in WINDOW_BARS)
with open(os.path.join(ROOT, "examples", "timeline_strobe.json")) as f:
    strobe = json.load(f)
strobe_at = secs(gl2)
strobe_cut = secs(ERUPT_END) - 0.05
assert strobe_at + max(ev["t"] for ev in strobe["events"] if ev["type"] == "screenFlash") >= secs(FLASH_BARS[-1][1]) - 0.2, \
    "the strobe file runs out before the last flash bar"
# Two passes, because a splice can inherit a close with nothing behind it. The strobe
# file carries `closeWindow im0…im2` with no `openWindow` anywhere — harmless in the
# strobe itself, which is played whole, but spliced in here it is a close aimed at a
# window this show never opens, which is exactly what `lint_show.py` fails on. The old
# 27-beat window cut them off before they landed; this one is 47 beats and does not.
# So: collect what the splice actually OPENS, then drop any close that has no opener.
spliced = [ev for ev in strobe["events"] if ev["t"] + strobe_at < strobe_cut]
strobe_opens = {ev["params"]["id"] for ev in spliced
                if ev["type"] == "openWindow" and "id" in ev["params"]}
strobe_ids, n_strobe, n_orphan, n_muted, n_flash = set(), 0, 0, 0, 0
n_cursor, n_cursor_muted = 0, 0
for ev in spliced:
    if ev["type"] == "closeWindow" and ev["params"].get("id") not in strobe_opens:
        n_orphan += 1
        continue
    # A flash in a window bar is dropped, not moved: the strobe's grid is its own
    # (0.15 s, authored at 150 BPM) and sliding a flash onto the next bar would put it
    # off that grid and on top of another.
    if ev["type"] == "screenFlash":
        if not in_flash_bar(ev["t"] + strobe_at):
            n_muted += 1
            continue
        n_flash += 1
    # …and the pointer only travels in the window bars — the whole path, so the last one
    # before a flash bar has finished before the flash.
    if ev["type"] == "cursorPath":
        t0 = ev["t"] + strobe_at
        if not in_window_bar(t0, t0 + ev["params"].get("durationSeconds", 0)):
            n_cursor_muted += 1
            continue
        n_cursor += 1
    add_t(ev["t"] + strobe_at, ev["type"], ev["params"])
    n_strobe += 1
    if "id" in ev["params"]:
        strobe_ids.add(ev["params"]["id"])

# ...and under all of it, a SHOAL. 54 Mac pointers laid out on a 2½-turn spiral from the
# centre and then flocked — separation, alignment, cohesion over a vortex that keeps the
# whole body turning (`CursorSwarmView.Mode.school`). Nothing here reads the viewer's own
# pointer: cues 24–25 were the swarm that wanted it, and this is the same particles with
# the mouse taken away, which is why it goes in under the noise rather than beside it.
#
# It runs at the FLOATING level, so it stays over everything: the show's z-order is
# otherwise just the order things opened in, and the eruption raises a window every
# fifth of a beat from here to the stop — at the normal level the shoal is buried by
# the second bar and only glimpsed between the cards. Floating also puts it over the
# `screenFlash` overlays, which are normal windows, so the strobe no longer whites the
# fish out. It stays click-through either way (`hitTest` returns nil), so the eruption's
# interactive cards underneath are still the viewer's.
# THE SECOND HALF RUNS. From the midpoint of this cue the screen picks up a horizontal
# CURRENT: twelve windows crossing it, half going left and half going right, each at its
# own speed, each looping — off one edge and straight back on from the other.
#
# They are their own windows, deliberately NOT the eruption's `w0…w13` pool. That pool is
# re-opened every fifth of a beat at a fresh random position, and a window being moved
# and re-placed at the same time snaps back and forth instead of travelling; these slide
# over the top of that while it carries on underneath.
#
# A lap is a full traverse plus the window's own width, so it is completely off the
# screen before it comes back on and the wrap is never seen. The return leg is a move
# with a millisecond on it rather than a duration of zero: the mover divides by its
# duration.
SLIDE_FROM = gl2 + (ERUPT_END - gl2) / 2
SLIDE_N = 12
slide_rng = random.Random(316)
slide_ids = []
for i in range(SLIDE_N):
    wid = f"sl{i}"
    slide_ids.append(wid)
    w = round(W * slide_rng.uniform(0.11, 0.17))
    h = round(w * slide_rng.uniform(0.58, 0.80))
    y = round((H - h) * (i + 0.5) / SLIDE_N)
    rightward = i % 2 == 0
    x_in, x_out = (-w, W) if rightward else (W, -w)
    # 2.4-3.6 beats to cross: about a second and a half at this tempo, which reads as a
    # current rather than as drifting. No two the same, so the band never locks into step.
    lap = round(2.4 + 1.2 * (i / max(1, SLIDE_N - 1)) + slide_rng.uniform(-0.12, 0.12), 3)
    body = {"kind": "color", "hex": slide_rng.choice(PALETTE),
            "chrome": "mixed", "title": "look://again"}
    # Staggered entry, so they do not all arrive on one frame.
    b = SLIDE_FROM + lap * (i / SLIDE_N)
    # The open lands BEFORE the first move, not on the same beat as it. Ties are not
    # ordered — `sorted(by:)` is not stable — and `beginMove` drops a move aimed at a
    # window that is not open yet, which would leave that slider parked off screen for
    # the whole cue. Same reason the traveller staggers its opens by OPEN_STEP.
    add(b - 0.02, "openWindow", {"id": wid, "frame": [x_in, y, w, h], "content": body,
                                 "animate": {"kind": "none"}})
    while b < ERUPT_END - 0.1:
        add(b, "moveWindow", {"id": wid, "frame": [x_out, y],
                              "durationBeats": lap, "easing": "linear"})
        b += lap
        if b >= ERUPT_END - 0.1:
            break
        add(b, "moveWindow", {"id": wid, "frame": [x_in, y], "durationSeconds": 0.001})
        b += 0.02

add(gl2, "openWindow", {
    "id": "school", "frame": fullscreen(), "level": "floating",
    "content": {"kind": "cursors", "mode": "school", "seed": 4438, "intensity": 0.6,
                "chrome": "none", "title": "school"},
    "animate": {"kind": "none"}})

# THE LAST BAR EMPTIES ONE WINDOW AT A TIME (2026-09-12). Fifty windows used to close
# on one frame at the pickup — the strobe's furniture, the crossing windows, the pool —
# and then the segmenter opened: fifty window-server round trips on the beat the video
# is meant to land on, and a cut where the artist wanted a build. So the eruption falls
# silent at `LEAVE_FROM` (its walk is muted, above) and through bar 71 the windows go in
# a seeded order, about three frames apart at first and two a frame by the end — the
# gaps shrink geometrically, sparse then dense, so the screen drains faster and faster
# into the pickup without ever collapsing into a single-frame cut at the end. The
# strobe's furniture has been still since bar 68 (its file ran out), so any order is
# safe; a slider closed mid-lap simply stops, since a move aimed at a closed window is
# dropped. The chase swarm is the LAST thing to go, a tenth of a beat before the pickup:
# the pointer's last leg runs to half a beat before it, and the chain crossing an
# emptying screen is the picture this bar is for. (The shoal went at cue 25; its close
# here is a backstop.) The pool ids are cue 27's to re-open, which is why they used to be
# swept there; now nothing opens them after `LEAVE_FROM`, and cue 27's sweep is a backstop.
LEAVE_UNTIL = ERUPT_END - 0.1
LEAVE_GAPS = (3.0, 0.5)            # frames between departures: the first gap → the last
leaving = sorted(strobe_ids) + slide_ids + [f"w{i}" for i in range(14)] + [f"d{i}" for i in range(4)]
random.Random(zlib.crc32(b"leaving")).shuffle(leaving)
n_leave = len(leaving)
ratio = (LEAVE_GAPS[1] / LEAVE_GAPS[0]) ** (1 / (n_leave - 2))
gaps = [LEAVE_GAPS[0] * ratio ** i for i in range(n_leave - 1)]
gaps = [g * (LEAVE_UNTIL - LEAVE_FROM) / sum(gaps) for g in gaps]   # scaled to fill the bar
leave_at, b = [], LEAVE_FROM
for i, wid in enumerate(leaving):
    add(b, "closeWindow", {"id": wid})
    leave_at.append(b)
    if i < n_leave - 1:
        b += gaps[i]
for wid in ["school", "tbd2"]:
    add(LEAVE_UNTIL, "closeWindow", {"id": wid})

# =============================================================================
# Cue 28 (2:28) — the eruption, and it closes the piece. Both halves of the second chorus
# are authored together up at cue 27; see the swap note there for why, and for how the
# popups bury the clip rather than cutting to it.
#
# Nothing to emit here. What used to be in this slot — the segmenter opening on the 2B
# pickup and the eruption's pool closing a quarter-beat after it — has moved: the swarm
# now opens on the 2A pickup and is swept on `SEG_HANDOVER`, two bars into the eruption, and the
# pool (`w0…w13`, `d0…d3`) runs all the way to the stop, where cue 30 closes it with
# everything else.
#
# The old note about the close landing a quarter-beat AFTER the boundary rather than
# before it still applies, and is why cue 30's sweep sits at `lw + 0.05`: `erupt` walks
# its own cadence and can land a final `openWindow` ON its end beat — measured, `w8`
# opened 42 ms past a close placed at -0.1 and stood there for the whole act.
# =============================================================================

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
add(lw, "screenFlash", {"color": WHITE, "durationBeats": 1.0})
# THE ERUPTION is what is on screen now, since the 2026-09-07 swap — its pool (`w0…w13`,
# `d0…d3`) and the four ASCII planes run right up to this beat, so this is where they are
# actually taken away rather than a backstop for it. Everything else here IS a backstop —
# the segmenter, the strobe's windows, the shoal and the sliders were closed on their own
# cues, and a close aimed at a window that is already shut is free, while a card left
# standing over the end card is not.
#
# A QUARTER BEAT LATE, not early. `erupt` walks its own cadence and can land a final
# `openWindow` ON its end beat: measured, `w8` opened 42 ms past a close placed at −0.1
# and stood there through the whole ending.
for wid in (["segswarm", LYRIC_BOX] + sorted(strobe_ids) + [f"w{i}" for i in range(14)]
            + [f"d{i}" for i in range(4)] + ascii_ids + ["school", "tbd2"] + slide_ids):
    add(lw + 0.05, "closeWindow", {"id": wid})

# THE LAST WORDS (2026-09-12). The four beats of blue used to carry nothing; the artist
# wants one thing on them — a single warning box with the line the song stops on. It
# lands a beat after the sweep, as the stop's flash finishes, dead centre at the centre
# box's size with no spring, and is taken away a hair before the card so nothing is
# standing when the ending comes up (`lint_show.py` checks that). Its words are
# docs/copy/last_words.txt — a title and buttons; a `body:` line there adds small text.
LAST = copy_fields("last_words")
LAST_AT = lw + 1
LAST_W, LAST_H = 460, 190          # a real alert's size, the one cue 14's uses — not the centre box's
add(LAST_AT, "fakeDialog", {"id": "lastwords", "anchor": "center", "animate": "none",
    "frame": [0, 0, LAST_W, LAST_H],
    "title": LAST["title"], "body": LAST.get("body") or "",
    "buttons": LAST["buttons"], "icon": "caution"})
add(B["ending"] - 0.05, "closeWindow", {"id": "lastwords"})

# =============================================================================
# Cue 31 (2:49) — the ending, once the song has actually finished. The photo the booth
# took, the machine's vitals and the credits typing themselves out.
#
# IT LANDS ON THE END OF THE SONG — the release of the last held note, not the end of
# the file. Measured on the track (mono RMS, 20 ms windows): the note holds at about
# -16 dB from the stop until 162.40 s and drops 13 dB in the next 40 ms, right on beat 347
# (162.418 s); everything after that is reverb tail, already under -28 dB and gone under
# -40 dB by 165 s. So the card comes up on beat 347, `(break, 0, 3)`, four beats after
# cue 30's stop, and the blue those four beats hold is the beat before the ending. The
# credits then type out over the tail (15 lines, one a beat, done ~7 s later) and the
# outro runs on wall-clock from there — the printout at the bottom says where the quit
# lands against the end of the file.
#
# IT CANNOT GO PAST THE FILE, and this is a hard edge rather than a taste call.
# `PerformanceEngine.step` tests `now >= duration` BEFORE it ticks the scheduler, and
# `duration` is `max(timeline.duration, audioDuration)` — 169.85 s, the file. A `credits`
# event has no intrinsic duration, so placing it AT the end of the file would make
# `timeline.duration` equal its own fire time and the end-of-piece branch would trip on
# the tick before it ever fired: the card would simply never come up. Beat 362 is the
# latest that leaves a margin (0.43 s). Earlier is always safe.
#
# The card is `hold: true`, so when the track does run out the engine pauses on it rather
# than restoring, and the typing and the outro run on wall-clock timers from there.
#
# THE CARD IS BLUE. Its ground is the signature blue with the face tiled white on it —
# the icon's own colours — and the terminals and the polaroid sit on it as white windows.
# The desktop under it has been that blue since cue 21, so the card's fade-in is a
# surface arriving on its own colour rather than a white sheet. The polaroid's photo is
# a `dither`: a coarse ordered dither and nothing else (see `DitherLook` in the engine) —
# the booth-print texture without the film pass's vignette and cast.
# =============================================================================
en = B["ending"]
add(en, "screenFlash", {"color": WHITE, "durationBeats": 1.5})
CREDITS = copy_lines("credits")                  # docs/copy/credits.txt
# Typed by the LINE, one per beat — the probe's cadence.
CREDITS_LPS = round(1 / BEAT, 3)
CARD_AT = secs(en)
TYPED_AT = CARD_AT + len(CREDITS) / CREDITS_LPS
# The typing runs over the reverb tail and the outro past the end of the file, with the
# engine paused on the held card; the printout below reports where the quit lands
# against the end of the file, but nothing here is trying to land on the last sample.
OUTRO_DELAY = 2.0
# NO BOOT BAR (2026-09-07). The outro was force-quit alert -> memory dump -> a five-second
# Apple-logo progress bar -> quit, and that bar is geometry-matched to the gate's stalled
# restart card on purpose. The piece already OPENS on a machine restarting; doing it again
# to close reads as the same beat played twice rather than as an ending. `bootSeconds: 0`
# makes `OutroController.runBoot` skip straight to the quit, so the dump is the last
# picture and then the app is simply gone — which is the viewer's own desktop back, since
# quitting routes through `applicationWillTerminate` -> `stopAndRestore()`.
add(en, "credits", {"id": "credits", "lines": CREDITS, "hold": True,
    "linesPerSecond": CREDITS_LPS, "fontSize": 22, "photoTilt": -4,
    "outroDelay": OUTRO_DELAY, "bootSeconds": 0,
    "filter": "dither",
    "backdrop": CREDITS_TILE_FIELD,
    "tile": CREDITS_TILE, "tileDriftSeconds": 4})

# =============================================================================
# THE SEAMS — every phrase changeover in the piece, stitched (see `seam`). Two are
# deliberately not in this list: BREAKDOWN, where cue 16's 30-tile wipe is already the
# transition and a second one would be noise on top of it, and BREAK, where the end
# card is the point and anything thrown across it is litter on the ending.
# =============================================================================
# instrumentalB is not stitched: that changeover was taken out in the timeline
# (2026-09-03) — the swarm is already carrying the section and a seam on top of it is
# one more thing arriving where nothing should.
for _phrase in ["introB", "chorus1A", "chorus1B", "bridgeA", "bridgeB",
                "instrumentalA", "chorus2A", "chorus2B"]:
    seam(phrase_beat(_phrase), _phrase)

# --- markers for the scrubber: the analyser's sections plus every cue ---
LABELS = {
    "blue": "blue desktop", "restore": "desktop back", "welcome": "welcome (typed)",
    "probe": "system probe", "hydra": "hydra (pulled)", "blue2": "blue again",
    "face": "pixelface desktop", "traveller": "traveller + trail",
    "spiral": "lyric spiral", "video1": "kick swarm", "tbd_048": "TBD",
    "words": "lyrics desktop", "torus1": "magic torus + greeting",
    "map": "maps: here", "fill": "fill (pulled)", "black": "to black",
    "tbd_099": "glsl + hydra", "booth": "photo booth", "wall": "photo wall",
    # The slot KEYS are historical — a pulled cue keeps its key so the numbering holds,
    # and a cue that swaps acts keeps its key too — but these LABELS are what the viewer
    # reads on the scrubber, so they name what actually plays there. "horse" has run the
    # eruption + strobe since the 2026-09-05 swap, and the horse itself is out of the
    # piece entirely (2026-09-06); "spam" and "glitch" traded acts on 2026-09-07, so the
    # names read backwards against the keys and the labels are what to trust.
    "facestrobe": "pixelface strobe", "horse": "eruption + strobe",
    "torus2": "torus + face ring", "video2": "video on top", "video3": "video + swarm",
    "tbd_136": "swarm alone", "spinner": "beach-ball mandala",
    "spam": "segmenter swarm", "glitch": "UI spam + ascii", "allglitch": "words (pulled)",
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
                # Gates the machine's REAL desktop picture — `wallpaper` events and
                # `deskWallpaper` with `surface: "wallpaper"`. The show does not use
                # either: every deskWallpaper here draws on the desktop LAYER, a window
                # pinned under the desktop icons that looks the same, changes at display
                # rate instead of ~3 Hz, and cannot outlive the process. So the gate is
                # off, and it must stay off unless a cue genuinely needs the wallpaper
                # itself swapped — the timeline test pairs the two.
                # ALLOW_WALLPAPER=1 opens it for a cut that does.
                "allowWallpaper": os.environ.get("ALLOW_WALLPAPER") == "1",
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
print(f"  bricks   4x8 windows, f {frame_at(secs(B['hydra']))} → f {frame_at(secs(B['blue2'] - 0.2))} "
      f"({secs(B['blue2']) - secs(B['hydra']):.0f}s), on top of {len(ramp_ids)} ramp windows "
      f"(f {frame_at(secs(B['hydra'] - 4))} → f {frame_at(secs(B['hydra'] - 0.5))}) "
      f"and {len(PROBE_STAY)} probes still standing; the other "
      f"{len(probe_ids) - len(PROBE_STAY)} close f {frame_at(secs(B['hydra'] - 0.3))}")
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
print(f"  kickswarm {kick_cuts} cuts on the KICK over chorus 1A, f {frame_at(secs(B['face']))} → "
      f"f {frame_at(KICK_LAST)}, swept f {frame_at(secs(words_event_beat - 0.2))}, "
      f"~40 arrows, floating (spawn shapes only — cue 12 is the one that gathers)")
print(f"  wordswarm {sw_cuts} cuts over the lyric desktop in "
      f"{(sw_end - words_event_beat) * BEAT:.1f}s (~{(sw_end - words_event_beat) / sw_cuts:.1f} beats "
      f"apart, holds {'/'.join(str(h) for h in sorted(set(SWARM_HOLDS)))}), "
      f"{len(SWARM_PATTERNS)} patterns, school (never reads the pointer)")
print(f"  words    {len(word_slides)} desktop cards over {len(word_stream)} sung words, "
      f"{words_first:.2f}s → {word_slides[-1][0]:.2f}s, last holds to {secs(B['torus1']):.1f}s "
      f"(applied {DESK_LATENCY * 1000:.0f} ms early; min gap "
      f"{min(b - a for (a, _), (b, _) in zip(word_slides, word_slides[1:])):.2f}s)"
      + (f"\n           no card yet for: {', '.join(words_missing)}" if words_missing else ""))
print(f"  torus    greeting types {secs(t1 + 1):.2f}s → {secs(ORACLE_AT - 1):.2f}s, "
      f"question at f {frame_at(secs(ORACLE_AT))} "
      f"({secs(ORACLE_AT):.2f}s), answers itself after {ORACLE_BEATS:g} beats "
      f"(f {frame_at(secs(ORACLE_AT + ORACLE_BEATS))}), cut at f {frame_at(secs(mp)):d}")
print(f"  tunnel   assets/shaders/tunnel.frag full screen under the torus, "
      f"f {frame_at(secs(t1))} → f {frame_at(secs(mp - 0.3))}; glass refracts "
      f"{TORUS_ENV} ({TORUS_ENV_W}x{TORUS_ENV_H}), ground white for the phrase")
if FILL_ACT:
    print(f"  fill     {len(fill_ids)} windows, 4 beats apart → 0.25")
else:
    print(f"  fill     pulled from the cut (FILL_ACT = False) — the map is alone under its "
          f"own two popups, f {frame_at(secs(mp))} until cue 16's wipe covers it f {frame_at(secs(bk))}")
print(f"  maptrace terminal f {frame_at(secs(mp + 0.5))} typing {len(TRACE)} chars over "
      f"{TRACE_BEATS * BEAT:.1f}s, dialog lands f {frame_at(secs(mp + MAP_FALL / BEAT + 1))}, "
      f"both gone f {frame_at(secs(bk - 0.4))}")
print(f"  map      f {frame_at(secs(mp))} → f {frame_at(secs(MAP_CLOSE))}: falls "
      f"{2_600_000:,}m → 260m in {MAP_FALL:g}s (f {frame_at(secs(mp) + MAP_FALL)}), then "
      f"{MAP_ORBIT:g}° round the fix over {MAP_SECONDS - MAP_FALL:g}s "
      f"({MAP_ORBIT / (MAP_SECONDS - MAP_FALL):.1f}°/s), still turning when it is covered")
if MAPSEG_ACT:
    print(f"  mapseg   the map window segmented for motion, f {frame_at(secs(SEG_MAP_FROM))} → "
          f"f {frame_at(secs(B['black'] - 0.1))} (starts on the landing, ends before the wipe)")
else:
    print("  mapseg   pulled (MAPSEG_ACT = False) — the map falls and orbits alone")
print(f"  wipe     {len(tx_ids)} tiles {tw}x{th} on a {TX_COLS}x{TX_ROWS} grid, one a frame "
      f"f {frame_at(secs(bk))} → f {frame_at(secs(TX_COVERED))}, dissolve {TX_PER_FRAME}/frame "
      f"f {frame_at(secs(tx_first))} → f {frame_at(secs(tx_last) + TX_FADE)} "
      f"({TX_FADE:g}s each), the picture lands f {frame_at(secs(B['tbd_099']))}")
if FACESTROBE_ACT:
    print(f"  face     {k} strobe frames @{face_hz:.0f} Hz")
else:
    print("  face     cue 20 pulled (FACESTROBE_ACT = False) — no blue strobe after the wall")
if HORSE_ACT:
    print(f"  horse    {gc}x{gr} grid, {max_lit} windows, {HORSE_SPAN:.0%} of the screen, "
          f"exits beat {horse_exit:.0f}")
else:
    print(f"  segswarm assets/giveit2meclip.mp4, motion, up to 60 windows, normal level, "
          f"f {frame_at(secs(sm))} → f {frame_at(SEG_SWEEP_T)} "
          f"(alone f {frame_at(secs(sm + 0.25))} to f {frame_at(secs(gl))}, then ringed by "
          f"the eruption for {SEG_HANDOVER - gl:.2f} beats and swept on \"{SEG_HANDOVER_LINE}\", "
          f"where the box begins; no keyline; the horse is cut — HORSE_ACT = False)")
print(f"  deskanim {1 + len(sat_ids)} clips: the centre f {frame_at(secs(B['tbd_099']))}, corners f "
      + ", ".join(str(frame_at(secs(B['tbd_099'] + 0.4 * i))) for i in range(len(sat_ids)))
      + f", all gone for the camera at f {frame_at(secs(bo - BOOTH_WARMUP - 0.3))}")
print(f"  hydra2   breakdown sketch over the picture: cursor walks f {frame_at(secs(hb))}, "
      f"spawns f {frame_at(secs(hb + 3))}, runs f {frame_at(secs(HYB_RUN))}, cut f {frame_at(secs(hs - 0.2))}")
print(f"  booth    window f {frame_at(secs(bo - BOOTH_WARMUP))} (camera warm-up, {BOOTH_WARMUP:g} beats), "
      f"count starts f {frame_at(secs(bo))}, shutter f {frame_at(secs(B['wall']))}")
print(f"  swarm    90 pointers, one every {SWARM_RAMP / 90:.2f}s over {SWARM_RAMP:g}s, floating, "
      f"f {frame_at(secs(t2 + 0.5))} → full at f {frame_at(secs(t2 + 0.5) + SWARM_RAMP)}, "
      f"chasing to f {frame_at(secs(B['spam'] - 0.1))}; the pointer is driven {len(DRIVE_LEGS)} legs "
      f"of {DRIVE_LEG:g} beats, one a bar from bar 69: f {frame_at(secs(DRIVE_FROM))} → "
      f"f {frame_at(secs(DRIVE_FROM + 4 * (len(DRIVE_LEGS) - 1) + DRIVE_LEG))}")
if TORUS2_ACT:
    print(f"  ring     {len(clock_ids)} windows round the torus ({FACE_RING - len(HYDRA_SLOTS)} faces, "
          f"{len(HYDRA_SLOTS)} live hydra), one a beat, "
          f"f {frame_at(secs(t2))} → f {frame_at(secs(t2 + FACE_RING - 1))}")
else:
    print("  ring     pulled (TORUS2_ACT = False) — no torus, no ring at cue 22")
print(f"  spam     {chaos['w']} windows, {chaos['a']} alerts, {n_kick} kick flashes, "
      f"{chaos['ui']} packed with macOS UI (both eruptions)")
print(f"  lyricbox {len(lyric_box_at)} centre alerts, {LYRIC_BOX_W}x{LYRIC_BOX_H} floating, "
      f"f {frame_at(secs(lyric_box_at[0][0]))} → f {frame_at(secs(lw + 0.05))}, each up {LYRIC_BOX_HOLD:g} beats "
      f"or to {LYRIC_BOX_GAP:g} before the next, no spring; zeros {CHORUS2_PICKUP_LEAD:g} beats ahead of chorus 1's "
      f"tuning; cue 28's ring keeps a {LYRIC_HOLE[0]}x{LYRIC_HOLE[1]} hole round it, no scattered alerts")
if CENTRE_2A_ACT:
    print(f"  buildup  {n_build} cards on the grid over chorus 2A, f {frame_at(secs(build_at[0]))} → "
          f"f {frame_at(secs(build_at[-1]))}, {'/'.join(f'{g:g}' for g in BUILD_BARS)} beats apart bar by bar "
          f"(eighths from the hook, bar 78), within {BUILD_SPREAD:.0%} of the width; {n_gone} vanish again "
          f"after {BUILD_LIFE[0]:g} → {BUILD_LIFE[1]:g} beats (all of them at first, {BUILD_VANISH_TO:.0%} by 2B), "
          f"the rest stay")
else:
    print("  buildup  pulled (CENTRE_2A_ACT = False) — chorus 2A is the segmenter alone; the centre starts where the clip runs out")
print(f"  lastword one alert on the blue, \"{LAST['title']}\" / \"{LAST.get('body', '')}\", f {frame_at(secs(LAST_AT))} → "
      f"f {frame_at(secs(B['ending'] - 0.05))}, {LAST_W}x{LAST_H} centred, no spring")
print(f"  photos   {chaos['p']} broken-screen photographs, bar 72 only, "
      f"{min(chaos['p'], len(BROKEN_SCREENS))} of {len(BROKEN_SCREENS)} pictures seen "
      f"(every 10th card; {BROKEN_SRC} → {BROKEN_DIR})")
if DOOMVID_ACT:
    print(f"  doom     the video slot ({VIDEO_W}x{VIDEO_H}) runs DooM, f {frame_at(secs(B['video2']))} → "
          f"f {frame_at(secs(B['tbd_136']))} ({secs(B['tbd_136']) - secs(B['video2']):.1f}s; "
          f"~1.2s of that is the menu, hidden)")
else:
    print("  doom     pulled (DOOMVID_ACT = False) — the video slot is empty again")
print(f"  slide    {SLIDE_N} windows crossing f {frame_at(secs(SLIDE_FROM))} → "
      f"the last bar, laps 2.4-3.6 beats, both directions, looping")
print(f"  leaving  {len(leaving)} windows leave one at a time through bar 71, f {frame_at(secs(leave_at[0]))} → "
      f"f {frame_at(secs(leave_at[-1]))} (gaps shrinking from {(leave_at[1] - leave_at[0]) * BEAT * 30:.1f} frames "
      f"to {(leave_at[-1] - leave_at[-2]) * BEAT * 30:.2f}); the chase swarm last, f {frame_at(secs(LEAVE_UNTIL))}; "
      f"the eruption is muted from f {frame_at(secs(LEAVE_FROM))} ({chaos['muted']} cards drawn but not opened)")
print(f"  school   54 pointers on a {2.5:g}-turn spiral, flocking behind the eruption "
      f"f {frame_at(secs(gl2))} → f {frame_at(secs(B['tbd_136']))}, where it hands over to the chase")
print(f"  strobe   {n_strobe} of {len(strobe['events'])} strobe events from the cut (f {frame_at(strobe_at)}), "
      f"{ERUPT_PHRASES} two-bar phrases from bar 60: windows + {n_cursor} cursor paths in the first bars, "
      f"{n_flash} flashes in the second bars "
      + " ".join(f"f {frame_at(secs(b0))}→{frame_at(secs(b1))}" for b0, b1 in FLASH_BARS)
      + f" ({n_muted} flashes and {n_cursor_muted} cursor paths muted in the other half"
      + (f", {n_orphan} orphan close(s) dropped" if n_orphan else "")
      + "); the desktop stays blue to the card")
print(f"  outro    copy lands {TYPED_AT:.2f}s, holds {OUTRO_DELAY:.1f}s → quit at "
      f"{TYPED_AT + OUTRO_DELAY:.2f}s ({TYPED_AT + OUTRO_DELAY - DURATION:+.2f}s vs track end)")
print()
print("  lyric phrases (tools/lyrics.py PHRASES, timed off CUES) — spiral cards at chorus 1A:")
print("   #    spiral    text")
for i, (when, text, _) in enumerate(phrases):
    ta = f"{secs(lyric_beat(zero_1A, when)):6.2f}s"
    print(f"  {i:>2}   {ta:>8}   {text}")
