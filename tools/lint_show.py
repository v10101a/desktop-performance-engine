"""Static checks over a generated timeline.

`--validate` proves the app can decode a document. This proves the document is a
coherent SHOW: that nothing is closed before it exists, that nothing the cut opened is
still on screen when the end card comes up, and that every file an event names is
actually in the repo.

Every one of these has bitten this timeline at least once — a renamed id that left a
window on screen for the whole second half, a lyric slide whose file was never made, a
close aimed at a window the recut had already removed.

    python3 tools/lint_show.py [path/to/timeline.json]

Exits non-zero on any error, so it can gate a build the way dpe-tests does.
"""
import json, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, "Sources", "DPECore", "Resources", "timeline.json")

with open(path) as f:
    doc = json.load(f)
meta, events = doc["meta"], doc["events"]
BPM, OFFSET = meta["bpm"], meta.get("beatOffset", 0.0)
BEAT = 60.0 / BPM

def when(e):
    return e["t"] if "t" in e else OFFSET + e["beat"] * BEAT

errors, warnings = [], []

# --- ordering ------------------------------------------------------------------
times = [when(e) for e in events]
if times != sorted(times):
    errors.append("events are not in time order — the scheduler advances a cursor and "
                  "never looks back, so an out-of-order event simply never fires")

# --- window lifetimes ----------------------------------------------------------
# Which event types put a window on screen under an id, and which take one away.
OPENS = {"openWindow", "fakeDialog", "typeText", "systemProbe", "glassTorus", "sprite",
         "photoWall", "photoBooth", "oracle", "credits", "reboot", "cursorTrail",
         # brickBreaker puts a whole table of windows up under one id — the bricks, the
         # ball and the paddle all live and die with it.
         "brickBreaker"}
CLOSES = {"closeWindow"}
# These end on their own, so leaving one open is not a leak.
SELF_ENDING = {"photoBooth", "credits", "reboot", "sprite"}

open_at = {}                     # id -> (first open time, type) while it is on screen
ever = set()                     # every id the show ever opens
for e in events:
    p = e.get("params", {})
    wid = p.get("id")
    if not wid:
        continue
    if e["type"] in CLOSES:
        # Closing an id that is already gone is deliberate all over this show — an act
        # sweeps the ids it might have inherited rather than reasoning about which
        # branch left what open — so only a close aimed at an id the timeline NEVER
        # opens is an error.
        if wid not in ever:
            errors.append(f"{when(e):7.2f}s  closeWindow \"{wid}\" — never opened")
        open_at.pop(wid, None)
    elif e["type"] in OPENS:
        ever.add(wid)
        open_at.setdefault(wid, (when(e), e["type"]))

# `moveWindow` and `jiggle` aim at a window that has to already be there.
for e in events:
    if e["type"] in ("moveWindow", "jiggle"):
        wid = e["params"]["id"]
        live = [x for x in events
                if x.get("params", {}).get("id") == wid and x["type"] in OPENS
                and when(x) <= when(e)]
        if not live:
            errors.append(f"{when(e):7.2f}s  {e['type']} \"{wid}\" — no window open there")

ending = max((when(e) for e in events if e["type"] == "credits"), default=None)
for wid, (t0, typ) in sorted(open_at.items(), key=lambda kv: kv[1][0]):
    if typ in SELF_ENDING:
        continue
    if ending is not None and t0 < ending:
        warnings.append(f"{t0:7.2f}s  \"{wid}\" ({typ}) is never closed — still on "
                        f"screen when the end card comes up at {ending:.2f}s")

# --- files ---------------------------------------------------------------------
def check(rel, why):
    if not os.path.exists(os.path.join(ROOT, rel)):
        errors.append(f"missing file: {rel}  ({why})")

seen_files = set()
for e in events:
    p = e.get("params", {})
    for rel in p.get("images", []) or []:
        seen_files.add((rel, "deskWallpaper slide"))
    # `tile` only: a bare `path` on an event is a spline name on cursorPath, not a file.
    if isinstance(p.get("tile"), str):
        seen_files.add((p["tile"], f"{e['type']}.tile"))
    c = p.get("content") or {}
    if isinstance(c.get("path"), str):
        seen_files.add((c["path"], f"{e['type']} content.path"))
if isinstance(meta.get("audioFile"), str):
    seen_files.add((meta["audioFile"], "meta.audioFile"))
for rel, why in sorted(seen_files):
    check(rel, why)

# --- the desktop is left as we found it ----------------------------------------
# Not a leak the engine can't clean up — WallpaperController restores on stop — but a
# `deskWallpaper` still running at the end card means the desktop is mid-effect while
# the credits type, which has never been the intent.
last_desk = max((e for e in events if e["type"] == "deskWallpaper"),
                key=when, default=None)
if last_desk is not None and ending is not None:
    dur = last_desk["params"].get("durationSeconds")
    if dur is None and when(last_desk) < ending:
        warnings.append(f"{when(last_desk):7.2f}s  deskWallpaper "
                        f"\"{last_desk['params']['id']}\" has no duration and is still "
                        f"running under the end card")

# --- report --------------------------------------------------------------------
print(f"{os.path.relpath(path, ROOT)}: {len(events)} events, "
      f"{times[-1]:.1f}s, {len(seen_files)} files referenced")
for w in warnings:
    print(f"  warn  {w}")
for e in errors:
    print(f"  ERROR {e}")
print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)")
sys.exit(1 if errors else 0)
