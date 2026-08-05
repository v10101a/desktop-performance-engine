"""The main scene — three acts, one timeline:

  1. HORSE   — the Muybridge window-zoetrope runs in, gallops in place ~5s,
               runs out of frame.
  2. LOOK    — the moment the horse starts to leave, the cursor handwrites
               "look" huge, draws an actual arrow pointing down-ish, then glides
               (no trail) to the spot the arrow points at.
  3. CHAOS   — from exactly that spot, the crazy windows erupt: pages bursting
               outward, absurd dialogs, flings, jiggles, a few flashes.

    python3 tools/generate_show.py                 # → examples/timeline_show.json
    W=1440 H=900 python3 tools/generate_show.py

Seeded, so the show is identical take to take.
"""
import json, math, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_horse import PALETTE, build_frames, horse_event
from spell_path import arrow_scene

W   = int(os.environ.get("W", "1440"))
H   = int(os.environ.get("H", "900"))
BPM = float(os.environ.get("BPM", "120"))

events = []
def add(beat, typ, params):
    events.append({"beat": round(beat, 3), "type": typ, "params": params})

# --- Act 1: horse (2s of galloping in place) ---
frames, gc, gr, max_lit = build_frames()
horse, exit_start, horse_end = horse_event(frames, gc, gr, W, H, hold=4)
events.append(horse)

# --- Act 2: as the horse starts to leave, the mouse glides from center stage
# and draws one LONG arrow pointing down-a-bit, then glides to its target ---
w_events, w_end, focal = arrow_scene(exit_start, W, H)
events += w_events

# --- Act 3: chaos erupts from where the arrow pointed — ELASTIC: starts slow,
# small, and low, then accelerates and swells on a curve until it tips over
# into the full strobe ---
rng = random.Random(7)
CHAOS_BEATS = 16
chaos_start = w_end + 1
fx, fy = focal

texts   = ["you looked", "hi.", "it's here", ":)", "told you", "don't blink"]
codes   = ["$ open look://deeper\nspawning pages… ok\nvibes at 98%",
           "> trace complete\n> you are the cursor now",
           "while true:\n    window()   # sorry"]
dialogs = [("FOUND SOMETHING", "You looked. That was the whole trick."),
           ("NOTHING TO SEE", "Absolutely nothing behind this window."),
           ("CONGRATULATIONS", "You are the 1,000,000th cursor."),
           ("UH OH", "The pages are multiplying.")]
body_colors = PALETTE + ["#0B0E16"]

t = 0.0
wi = di = 0
while t < CHAOS_BEATS:
    u = t / CHAOS_BEATS          # 0 → 1 across the act; every knob rides this curve
    beat = chaos_start + t
    # radius: hugs the focal point at first, then flings wide
    r = 30 + (u ** 1.6) * 0.65 * W * rng.uniform(0.5, 1.0)
    ang = rng.uniform(0, 6.28318)
    # size: starts small, swells hard late
    w = round((110 + (u ** 1.7) * 380) * rng.uniform(0.8, 1.25))
    h = round(w * rng.uniform(0.6, 0.85))
    x = max(10, min(fx + r * math.cos(ang) - w / 2, W - w - 10))
    y = max(10, min(fy + r * math.sin(ang) - h / 2, H - h - 10))
    roll = rng.random()
    flash_p = 0.0 if u < 0.55 else 0.06 + 0.30 * (u - 0.55) / 0.45
    if roll < flash_p:
        add(beat, "screenFlash", {"color": rng.choice(["#FFFFFF", "#FF2D95", "#0078D7"]),
            "durationBeats": 0.3})
    elif roll < flash_p + 0.46:
        add(beat, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), w, h],
            "content": {"kind": "color", "hex": rng.choice(body_colors),
                        "chrome": "mixed", "title": "look://again"},
            # elastic: early windows spring in softly, late ones snap
            "animate": {"kind": "springIn" if u < 0.55 or rng.random() < 0.2 else "none"}})
        wi += 1
    elif roll < flash_p + 0.58:
        add(beat, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), max(w, 240), h],
            "content": {"kind": "text", "text": rng.choice(texts), "chrome": "browser",
                        "title": "look://found"},
            "animate": {"kind": "none"}})
        wi += 1
    elif roll < flash_p + 0.68:
        add(beat, "openWindow", {"id": f"w{wi % 14}", "frame": [round(x), round(y), max(w, 300), h],
            "content": {"kind": "code", "text": rng.choice(codes), "chrome": "terminal",
                        "title": "haunt.sh"},
            "animate": {"kind": "none"}})
        wi += 1
    elif roll < flash_p + 0.80:
        title, body = dialogs[di % len(dialogs)]
        add(beat, "fakeDialog", {"id": f"d{di % 4}", "title": title, "body": body,
            "buttons": ["ok", "OK", "very ok"][di % 2:],
            "frame": [round(x), round(y), 380, 170]})
        di += 1
    elif wi > 0:
        add(beat, "jiggle", {"id": f"w{(wi - 1) % 14}", "durationBeats": 1.5,
            "amplitude": 18, "frequency": 9})
    # tempo: sparse at first, machine-gun by the end
    t += max(0.1, (0.72 - 0.60 * (u ** 1.8)) * rng.uniform(0.8, 1.2))

# --- chaos wipe: one flash, clear the stage for the finale ---
end = chaos_start + CHAOS_BEATS + 1
add(end, "screenFlash", {"color": "#FFFFFF", "durationBeats": 0.6})
for i in range(14):
    add(end + 0.1, "closeWindow", {"id": f"w{i}"})
for i in range(4):
    add(end + 0.1, "closeWindow", {"id": f"d{i}"})
add(end + 0.1, "closeWindow", {"id": "trace"})

# --- Act 4: the ORIGINAL strobe madness, spliced in verbatim as the finale.
# Its events are authored in absolute seconds ("t"), which survive the splice
# with a plain offset ("t" wins over "beat" at load time).
strobe_path = os.path.join(os.path.dirname(__file__), "..", "examples", "timeline_strobe.json")
with open(strobe_path) as f:
    strobe = json.load(f)
offset_s = (end + 1.0) * 60.0 / BPM
strobe_len = 0.0
for ev in strobe["events"]:
    t = ev["t"] + offset_s
    strobe_len = max(strobe_len, ev["t"])
    events.append({"t": round(t, 3), "type": ev["type"], "params": ev["params"]})
end = (offset_s + strobe_len) * BPM / 60.0

def when(e):
    return e["t"] if "t" in e else e["beat"] * 60.0 / BPM
events.sort(key=when)
doc = {"meta": {"bpm": BPM, "beatOffset": 0.0}, "events": events}
root = os.path.join(os.path.dirname(__file__), "..")
# This IS the show now: written to examples/ and as the bundled default the app
# plays when launched with no timeline argument.
for out in (os.path.join(root, "examples", "timeline_show.json"),
            os.path.join(root, "Sources", "DesktopPerformanceEngine", "Resources", "timeline.json")):
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}")
print(f"{len(events)} events, ~{(end + 1) * 60 / BPM:.1f}s — horse exit at beat {exit_start}, "
      f"writing ends {w_end:.1f}, chaos from ({fx:.0f},{fy:.0f})")
