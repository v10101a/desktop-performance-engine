"""Quantize Muybridge's 1878 galloping horse (public domain) into window-zoetrope
frames: each animation frame becomes rows of '.'/'X' cells, each lit cell rendered
live by one micro-window. The first motion picture, replayed as desktop windows.

    python3 tools/generate_horse.py                   # → examples/timeline_horse.json
    SPAN=0.88 HOLD=10 COLS=19 python3 tools/generate_horse.py

Reads assets/muybridge_horse.gif (committed; from Wikimedia Commons, PD-old).
Requires Pillow. Also imported by generate_show.py for the combined show.

Grid size tradeoff: the window pool holds max-lit-cells windows and moves ALL of
them every frame — keep max lit around 60-70 or the window server starts to lag.
"""
import json, os
from PIL import Image

# The pages: white, pink, BSOD blue.
PALETTE = ["#FFFFFF", "#FF2D95", "#0078D7"]


def build_frames(cols=19, thresh=110, fill=0.42):
    """Quantize the GIF. Returns (frames, grid_cols, grid_rows, max_lit)."""
    src = os.path.join(os.path.dirname(__file__), "..", "assets", "muybridge_horse.gif")
    im = Image.open(src)
    frames, max_lit = [], 0
    for fi in range(im.n_frames):
        im.seek(fi)
        g = im.convert("L")
        # Blank the plate's frame-number labels in the bottom corners so they
        # don't quantize into stray cells.
        cw, chh = round(g.width * 0.12), round(g.height * 0.16)
        g.paste(255, (0, g.height - chh, cw, g.height))
        g.paste(255, (g.width - cw, g.height - chh, g.width, g.height))
        rows_n = max(1, round(cols * g.height / g.width * 0.72))  # cells ~1.39:1 wide
        small = g.point(lambda v: 255 if v < thresh else 0).resize((cols, rows_n), Image.BOX)
        px = small.load()
        rows = ["".join("X" if px[c, r] >= fill * 255 else "." for c in range(cols))
                for r in range(rows_n)]
        frames.append(rows)
        max_lit = max(max_lit, sum(row.count("X") for row in rows))

    # Trim rows/cols empty across ALL frames so the sprite origin hugs the horse.
    def lit_rows(fr): return [i for i, row in enumerate(fr) if "X" in row]
    top    = min(min(lit_rows(f)) for f in frames)
    bottom = max(max(lit_rows(f)) for f in frames)
    left   = min(min(row.index("X") for row in f if "X" in row) for f in frames)
    right  = max(max(len(row) - 1 - row[::-1].index("X") for row in f if "X" in row)
                 for f in frames)
    frames = [[row[left:right + 1] for row in f[top:bottom + 1]] for f in frames]
    return frames, right - left + 1, bottom - top + 1, max_lit


def horse_event(frames, grid_cols, grid_rows, W, H, start_beat=0,
                span=0.88, hold=10, in_beats=6, out_beats=5):
    """The act: run into frame (easeOut), gallop in place at center stage for
    `hold` beats, run out of frame right (easeIn). Returns (event, exit_start_beat,
    end_beat)."""
    cell = round(W * span / grid_cols)
    gap = 3
    sprite_w = grid_cols * (cell + gap)
    sprite_h = grid_rows * (round(cell * 0.72) + gap)
    center = [round((W - sprite_w) / 2), round((H - sprite_h) * 0.42)]
    event = {"beat": round(start_beat, 3), "type": "sprite", "params": {
        "id": "horse",
        "frames": frames,
        "cell": cell, "cellAspect": 0.72, "gap": gap,
        "origin": [-sprite_w, center[1]],
        "target": center,
        "travelBeats": in_beats, "travelEasing": "easeOut",
        "exit": [W + round(sprite_w * 0.1), center[1]],
        "exitBeats": out_beats, "exitEasing": "easeIn",
        "beatsPerFrame": 0.25,
        "durationBeats": round(in_beats + hold + out_beats, 1),
        "chrome": "mixed",
        "colors": PALETTE,
    }}
    return event, start_beat + in_beats + hold, start_beat + in_beats + hold + out_beats


def main():
    cols = int(os.environ.get("COLS", "19"))
    W = int(os.environ.get("W", "1440"))
    H = int(os.environ.get("H", "900"))
    bpm = float(os.environ.get("BPM", "120"))
    span = float(os.environ.get("SPAN", "0.88"))
    hold = float(os.environ.get("HOLD", "4"))      # ~2s at 120 BPM
    thresh = int(os.environ.get("THRESH", "110"))
    fill = float(os.environ.get("FILL", "0.42"))

    frames, gc, gr, max_lit = build_frames(cols, thresh, fill)
    event, _, _ = horse_event(frames, gc, gr, W, H, span=span, hold=hold)
    doc = {"meta": {"bpm": bpm, "beatOffset": 0.0}, "events": [event]}
    out = os.path.join(os.path.dirname(__file__), "..", "examples", "timeline_horse.json")
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
    print(f"wrote {os.path.normpath(out)}: {len(frames)} frames, grid {gc}x{gr}, "
          f"max {max_lit} lit cells (window pool size), cell {event['params']['cell']}px")
    if max_lit > 70:
        print(f"WARNING: pool of {max_lit} windows may lag — lower COLS or raise FILL")


if __name__ == "__main__":
    main()
