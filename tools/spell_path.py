"""Cursor handwriting: the real cursor writes TEXT huge on screen in a single-stroke
plotter font, stamping breadcrumb windows as it goes, then draws an actual arrow
pointing down-ish, then glides (trail off) to the spot the arrow points at.

    python3 tools/spell_path.py                       # standalone scene → examples/timeline_look.json
    TEXT=look SCALE=52 python3 tools/spell_path.py    # overrides

Also imported by generate_show.py, which drops the same scene into the full show.
Coordinates are global display points (top-left origin); defaults fit 1440x900.

Pen-up between strokes is just the cursor warping to the next stroke's start —
the stamp trail treats big jumps as pen-up and doesn't smear across them.
"""
import json, math, os

# --- single-stroke font: char -> list of strokes, each a polyline on a 4x6 grid ---
# Capital and lowercase are distinct glyphs; lookup falls back to lowercase.
FONT = {
    "L": [[(0.8, 0), (0.8, 6), (3.2, 6)]],
    "O": [[(2, 0), (3.4, 1), (3.4, 5), (2, 6), (0.6, 5), (0.6, 1), (2, 0)]],
    "K": [[(0.8, 0), (0.8, 6)], [(3.4, 0), (0.8, 3.4)], [(1.7, 2.6), (3.4, 6)]],
    "l": [[(1.2, 0), (1.2, 5.2), (2.0, 6)]],
    "o": [[(2, 2), (3.2, 3), (3.2, 5), (2, 6), (0.8, 5), (0.8, 3), (2, 2)]],
    "k": [[(0.9, 0), (0.9, 6)], [(3.1, 2), (0.9, 4.3)], [(1.8, 3.6), (3.3, 6)]],
    "i": [[(2, 2.6), (2, 6)], [(2, 1.4), (2, 1.7)]],
    "t": [[(1.6, 0.6), (1.6, 5.4), (2.6, 6)], [(0.6, 2), (2.8, 2)]],
    "e": [[(0.7, 4), (3.2, 4), (3.1, 2.8), (2, 2.2), (0.9, 3), (0.7, 4.6), (1.8, 6), (3.2, 5.4)]],
    "h": [[(0.9, 0), (0.9, 6)], [(0.9, 3.4), (2.2, 2.2), (3.2, 3), (3.2, 6)]],
    "n": [[(0.9, 2.2), (0.9, 6)], [(0.9, 3.2), (2.2, 2.2), (3.2, 3.2), (3.2, 6)]],
    "r": [[(1, 2.2), (1, 6)], [(1, 3.4), (2.2, 2.2), (3.2, 2.6)]],
    "s": [[(3.1, 2.6), (1.8, 2.2), (0.8, 3), (1.6, 4), (2.8, 4.4), (3.2, 5.2), (2, 6), (0.7, 5.6)]],
    "a": [[(3.1, 2.6), (1.8, 2.2), (0.8, 3.4), (0.8, 5), (1.8, 6), (3.1, 5.2)], [(3.1, 2.2), (3.1, 6)]],
    "!": [[(2, 0), (2, 4)], [(2, 5.2), (2, 5.6)]],
    " ": [],
}
ADVANCE = 5.0   # grid units per character cell (4 wide + 1 gap)


def seg_len(pts):
    return sum(((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
               for a, b in zip(pts, pts[1:]))


def stroke_event(beat, pts, speed, path=None):
    """One pen stroke as a cursorPath event. Returns (event, durationBeats).
    `path` forces the interpolation — the arrowhead needs "linear" so the corner at
    the tip stays sharp instead of getting rounded off by the spline."""
    beats = max(0.4, seg_len(pts) / speed)
    return ({"beat": round(beat, 3), "type": "cursorPath", "params": {
        "path": path or ("catmullRom" if len(pts) >= 3 else "linear"),
        "points": [[round(x, 1), round(y, 1)] for x, y in pts],
        "durationBeats": round(beats, 2),
        "easing": "easeInOut",
        "mode": "warp",
    }}, beats)


def first_point(text, origin, scale, advance=ADVANCE):
    """Where the pen first touches down (start of the first stroke)."""
    ch = text[0]
    stroke = (FONT.get(ch) or FONT[ch.lower()])[0]
    return (origin[0] + stroke[0][0] * scale, origin[1] + stroke[0][1] * scale)


def spell_events(text, origin, scale, speed, start_beat, advance=ADVANCE):
    """Handwrite `text`. Returns (events, end_beat)."""
    events, beat = [], start_beat
    ox, oy = origin
    for ci, ch in enumerate(text):
        strokes = FONT.get(ch, FONT.get(ch.lower()))
        if strokes is None:
            raise SystemExit(f"no stroke glyph for {ch!r} — add it to FONT")
        cx = ox + ci * advance * scale
        for stroke in strokes:
            pts = [(cx + x * scale, oy + y * scale) for x, y in stroke]
            ev, beats = stroke_event(beat, pts, speed)
            events.append(ev)
            beat += beats + 0.25   # pen-up breath between strokes
    return events, beat


def arrow_events(start, angle_deg, length, barb, speed, start_beat, barb_deg=28):
    """Draw an ACTUAL arrow: the shaft, then the ">" head in ONE continuous stroke —
    barb, through the tip, out to the other barb — so the pen never lifts in the
    middle of the arrowhead. (Two separate barb strokes read as two stray marks;
    one stroke reads as a pointer.) Returns (events, end_beat, tip, unit direction)."""
    a = math.radians(angle_deg)
    d = (math.cos(a), math.sin(a))
    tip = (start[0] + d[0] * length, start[1] + d[1] * length)
    events, beat = [], start_beat

    ev, beats = stroke_event(beat, [start, tip], speed)
    events.append(ev); beat += beats + 0.35      # a held moment at the tip

    def barb_point(sign):
        b = math.radians(angle_deg + 180 + sign * barb_deg)   # back from the tip
        return (tip[0] + math.cos(b) * barb, tip[1] + math.sin(b) * barb)

    ev, beats = stroke_event(beat, [barb_point(+1), tip, barb_point(-1)], speed,
                             path="linear")
    events.append(ev); beat += beats + 0.2
    return events, beat, tip, d


def writing_scene(start_beat, W, H, text="LOOK", scale=54, speed=340,
                  stamp_size=(64, 46), spacing=34, advance=4.25,
                  lead_from=None):
    """The full scene: the cursor glides from `lead_from` (default screen center,
    where the previous act held the eye) to the first letter — so the FIRST
    stamped window lands exactly there — then trail on, handwrite text HUGE,
    draw a down-pointing arrow, trail off, glide to the pointed spot (clean).
    Returns (events, end_beat, focal_point). Stamps stay up (id "trace") until
    a later closeWindow.
    """
    ox = max(60, (W - len(text) * advance * scale) / 2 * 0.75)
    oy = H * 0.19
    events = []

    # the hand-off: mouse travels to where the writing begins
    lead_from = lead_from or (W / 2, H / 2)
    pen_down = first_point(text, (ox, oy), scale, advance)
    events.append({"beat": round(start_beat, 3), "type": "cursorPath", "params": {
        "path": "linear",
        "points": [[round(lead_from[0]), round(lead_from[1])],
                   [round(pen_down[0]), round(pen_down[1])]],
        "durationBeats": 2, "easing": "easeInOut", "mode": "warp",
    }})
    trail_start = start_beat + 2.05   # trail arms once the cursor is already there
    s_events, beat = spell_events(text, (ox, oy), scale, speed, start_beat + 2.3,
                                  advance=advance)
    events += s_events

    # arrow: starts under the word's center, points down-and-right "a bit"
    a_start = (ox + len(text) * advance * scale * 0.42, oy + 6 * scale + 70)
    a_events, beat, tip, d = arrow_events(a_start, angle_deg=38, length=0.19 * W,
                                          barb=0.052 * W, speed=speed, start_beat=beat)
    events += a_events

    # trail arms after the hand-off glide, so the first stamp is the first letter;
    # it runs exactly while the pen is down and the stamps persist after
    events.insert(0, {"beat": round(trail_start, 3), "type": "cursorTrail", "params": {
        "id": "trace", "mode": "stamp", "spacing": spacing,
        "size": list(stamp_size), "chrome": "mixed",
        "durationBeats": round(beat - trail_start + 0.1, 2),
    }})

    # the glide: continue past the tip to where the arrow points — NO trail
    focal = (min(W * 0.92, tip[0] + d[0] * 0.13 * W),
             min(H * 0.92, tip[1] + d[1] * 0.13 * W))
    beat += 0.5
    events.append({"beat": round(beat, 3), "type": "cursorPath", "params": {
        "path": "linear", "points": [[round(tip[0]), round(tip[1])],
                                     [round(focal[0]), round(focal[1])]],
        "durationBeats": 2, "easing": "easeInOut", "mode": "warp",
    }})
    beat += 2
    return events, beat, focal


def arrow_scene(start_beat, W, H, angle_deg=35, length=None, speed=200,
                stamp_size=(84, 58), spacing=40, lead_from=None, lead_beats=3):
    """Arrow only, no writing: the cursor glides from `lead_from` (default screen
    center, where the last act held the eye) to the arrow start, draws one LONG
    big arrow pointing down-a-bit — stamped in windows — then glides trail-off to
    the spot it points at. Returns (events, end_beat, focal_point).

    `speed` is px per beat, and it is deliberately unhurried: a fast stroke can
    outrun a loaded machine's pump and drop most of its breadcrumb stamps, so the
    arrow half-draws. Slower = more samples = it always lands."""
    length = length or 0.48 * W
    a_start = (W * 0.18, H * 0.24)
    lead_from = lead_from or (W / 2, H / 2)

    events = [{"beat": round(start_beat, 3), "type": "cursorPath", "params": {
        "path": "linear",
        "points": [[round(lead_from[0]), round(lead_from[1])],
                   [round(a_start[0]), round(a_start[1])]],
        "durationBeats": lead_beats, "easing": "easeInOut", "mode": "warp",
    }}]
    trail_start = start_beat + lead_beats + 0.05
    a_events, beat, tip, d = arrow_events(a_start, angle_deg, length,
                                          barb=0.09 * W, speed=speed,
                                          start_beat=start_beat + lead_beats + 0.3)
    events += a_events
    events.insert(0, {"beat": round(trail_start, 3), "type": "cursorTrail", "params": {
        "id": "trace", "mode": "stamp", "spacing": spacing,
        "size": list(stamp_size), "chrome": "mixed",
        "durationBeats": round(beat - trail_start + 0.1, 2),
    }})

    focal = (min(W * 0.92, tip[0] + d[0] * 0.14 * W),
             min(H * 0.92, tip[1] + d[1] * 0.14 * W))
    beat += 0.5
    events.append({"beat": round(beat, 3), "type": "cursorPath", "params": {
        "path": "linear", "points": [[round(tip[0]), round(tip[1])],
                                     [round(focal[0]), round(focal[1])]],
        "durationBeats": lead_beats, "easing": "easeInOut", "mode": "warp",
    }})
    return events, beat + lead_beats, focal


def main():
    text = os.environ.get("TEXT", "LOOK")
    W = int(os.environ.get("W", "1440"))
    H = int(os.environ.get("H", "900"))
    scale = float(os.environ.get("SCALE", "54"))
    bpm = float(os.environ.get("BPM", "120"))

    events, end, focal = writing_scene(0, W, H, text=text, scale=scale)
    events.append({"beat": round(end + 4, 3), "type": "closeWindow",
                   "params": {"id": "trace"}})
    doc = {"meta": {"bpm": bpm, "beatOffset": 0.0}, "events": events}
    out = os.path.join(os.path.dirname(__file__), "..", "examples", "timeline_look.json")
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}: {len(events)} events, "
          f"~{(end + 4) * 60 / bpm:.1f}s, text={text!r}, arrow → ({focal[0]:.0f},{focal[1]:.0f})")


if __name__ == "__main__":
    main()
