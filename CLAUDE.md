# GiveIt2Me_DJ_Dave_malware

A music video that runs as software: a macOS app that plays the track and drives the
desktop — windows, dialogs, the cursor, the wallpaper — in sync with it. Everything is
reversible; the panic hotkey is ⌃⌥⌘Esc. `README.md` is the reference for the timeline
format and every event type.

## The cue sheet and the timeline are one thing

`docs/CUES.md` is the **source document for the cut**. `tools/generate_show.py` mirrors
it as the `CUES` table at the top of the file and derives every event time from those
numbers; `Sources/DPECore/Resources/timeline.json` is generated output, never authored
by hand.

**These must never drift apart. Both directions:**

- **Changed the cut?** Whatever moved — a cue's position, what happens at it, which
  events it fires — update `docs/CUES.md` in the same change. A timeline the sheet does
  not describe is a timeline nobody can read.
- **Changed the sheet?** It is not done until the show plays that way. Update the `CUES`
  table and the act it belongs to in `tools/generate_show.py`, regenerate, and commit
  the regenerated `timeline.json` with it.

Either way, finish with:

```bash
python3 tools/generate_show.py && python3 tools/lint_show.py
```

The generator prints every cue's authored and actual frame; those numbers must match the
table in `docs/CUES.md`. The lint catches closes aimed at ids the show never opens,
windows still on screen when the end card comes up, and asset paths that do not resolve.

Note that `generate_show.py` needs Pillow (for the horse's GIF quantisation) — there is
no committed venv, so create one if the import fails.

### Units

The cue sheet is written in **frames at 30 fps**. That is not a property of the engine —
it runs off the audio clock in seconds and quantises nothing — it is the rate the app's
transport counts in (`MainWindowController.fps`), so a frame number in the sheet is the
number on the scrubber. `frame = floor(seconds × 30)`.

The track is **twelve 8-bar phrases** (`PHRASES` in the generator, "The phrases" in the
sheet), each verified in the audio. Every cue is a position inside one — `(phrase, bars
in, beats in)` — so `(phrase, 0, 0)` is the changeover and the hooks are `(chorus, 5, 0)`.
Keep that: a cue never reaches past its own phrase, and moving a phrase moves its cues.
The lyric visuals (spiral, desktop words) are timed by `tools/lyrics.py`, not by hand.

## Everything else

- `swift run dpe-tests` is the test suite — a plain executable with a real exit code, not
  `swift test` (this toolchain ships no XCTest). It must stay green.
- `./bundle.sh` packages the `.app`; `./ship.sh` builds the distributable.
- `tools/fetch_doom.sh` installs the wasm DooM cue 27 runs (`assets/doom.wasm`,
  gitignored — GPL engine, shareware IWAD baked in; read the script header before
  shipping a build with it). Without it that window comes up saying so, and everything
  else works. `--test-doom` proves it is drawing.
- The show must stay **reversible**: no event may leave the machine changed after stop,
  panic or quit. `fileSwarm` is the only thing that touches disk and is gated off
  (`meta.allowDesktopFiles`); wallpaper swaps are gated on `meta.allowWallpaper` and
  restore from a snapshot taken before the first swap.
- **Photosensitivity is a real constraint, not a style note.** Keep full-screen change
  rates out of the 15–20 Hz band and re-measure from the generated timeline if you
  change the cadence. The current cut is median 2.9 Hz, peak 12.0 Hz.
