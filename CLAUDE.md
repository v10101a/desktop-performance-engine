# give-it-2-me (GiveIt2Me_DJ_Dave_malware)

A music video that runs as software: a macOS app that plays the track and drives the
desktop — windows, dialogs, the cursor, the wallpaper — in sync with it. Everything is
reversible; the panic hotkey is ⌘Esc. `README.md` is the reference for the timeline
format and every event type.

## The cue sheet, the copy and the timeline are one thing

`docs/CUES.md` is the **source document for the cut**: one row per cue, present tense,
what the show does today. `docs/copy/` holds **every word the show speaks** — the welcome
terminal, the torus's greeting and question, the locate trace and its alert, the credits —
one plain-text file per passage (the README there explains the three shapes).
`tools/generate_show.py` mirrors the sheet as the `CUES` table at the top of the file,
reads the copy files, and derives every event time from those numbers;
`Sources/DPECore/Resources/timeline.json` is generated output, never authored by hand.

**These must never drift apart. All directions:**

- **Changed the cut?** Whatever moved — a cue's position, what happens at it, which
  events it fires — update `docs/CUES.md` in the same change. A timeline the sheet does
  not describe is a timeline nobody can read.
- **Changed the sheet?** It is not done until the show plays that way. Update the `CUES`
  table and the act it belongs to in `tools/generate_show.py`, regenerate, and commit
  the regenerated `timeline.json` with it.
- **Changed the words?** Edit the file in `docs/copy/`, regenerate, and check that the
  row in `docs/CUES.md` pointing at it still describes what it says. Never put a line of
  copy back into the generator as a literal — the generator reads copy, it does not hold
  it. (The lyric is the exception: the song's words and their timing are `tools/lyrics.py`.)
- **History goes in the changelog** at the bottom of `docs/CUES.md`, dated — not in the
  rows. A row describes the cut as it plays; "used to be" and "(2026-09-07)" belong below.

**`README.md` is the engine, not the cut.** One section per event or content kind: what
it does, its params, its gotchas, how to test it. It must not narrate the show, name a
cue number, or quote show copy — every one of those went stale within a week of being
written. If a README sentence needs a cue to make sense, the sentence belongs in the cue
sheet.

Either way, finish with:

```bash
python3 tools/generate_show.py && python3 tools/lint_show.py
```

`./bundle.sh` and `tools/run_show.sh` both run exactly that before they build or play, so a
bundle or a rehearsal can never carry stale words; `SKIP_GENERATE=1 ./bundle.sh` is the
escape hatch for a machine without Pillow.

The generator prints every cue's authored and actual frame; those numbers must match the
table in `docs/CUES.md`. The lint catches closes aimed at ids the show never opens, assets that are git-lfs
pointers rather than the file (a warning — that cue plays empty on that machine),
windows still on screen when the end card comes up, and asset paths that do not resolve.

Note that `generate_show.py` needs Pillow (for the horse's GIF quantisation) — there is
no committed venv, so create one if the import fails. Every derived asset it builds
(the face wallpaper, the blink frame, the lyric cards, the broken screens, the photo
fallback) comes from a gitignored source drop; when the drop is not in the checkout the
step skips and the committed copy is kept, so a clean clone regenerates the show.

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

- **Event timing.** Events fire from their own 240 Hz clock, not the display pump — the
  pump is starved to ~13 Hz by compositing in the densest sections and events can only
  fire on a tick. `DPE_PROFILE=1` prints pump rate + per-event cost at stop;
  `DPE_EVENT_CLOCK=0` reverts. See "The event clock" in README.
- `swift run dpe-tests` is the test suite — a plain executable with a real exit code, not
  `swift test` (this toolchain ships no XCTest). It must stay green.
- `./bundle.sh` packages the `.app`; `./ship.sh` builds the distributable.
- `Sources/DPECore/Effects/SegCam/` is imported from `~/segcam` and its engine files are
  meant to stay identical to that repo's — fix there first, then re-import. The `segcam`
  content kind takes the camera or a video file; the Syphon input, the HUD and the keys
  did not come across, and a cue is the only thing that configures it.
- `tools/fetch_doom.sh` installs the wasm DooM the `doom` content kind runs
  (`assets/doom.wasm`, gitignored — GPL engine, shareware IWAD baked in; read the script
  header before shipping a build with it). No cue in the current cut opens one; a cue
  that does comes up saying so without it, and everything else works. `--test-doom`
  proves it is drawing.
- The show must stay **reversible**: no event may leave the machine changed after stop,
  panic or quit. `fileSwarm` is the only thing that touches disk and is gated off
  (`meta.allowDesktopFiles`). Changing the machine's REAL desktop picture is gated on
  `meta.allowWallpaper` and restores from a snapshot taken before the first swap — the
  shipped cut needs neither: `deskWallpaper` defaults to `surface: "layer"`, a window
  pinned under the desktop icons (`DesktopLayer`) that looks the same and dies with the
  process. `TimelineTests` pairs the gate to `usesWallpaper`, so a cue that switches to
  `surface: "wallpaper"` without opening the gate fails the suite.
- **The transport window is hidden.** A normal launch constructs `MainWindowController`
  (it owns the engine callbacks) but does not show it — `AppDelegate.consoleVisibleAtLaunch`
  is the one rule, and only `--console` and `--no-gate` turn it on. ⌃⌥⌘D toggles it at
  run time. Both chords go through `HotKeyCenter`, which installs **one** Carbon handler
  and dispatches on the hotkey id; a second handler would fire for both chords and ⌃⌥⌘D
  would panic. `applicationShouldTerminateAfterLastWindowClosed` is false for the same
  reason the console is hidden — closing it mid-performance must not end the piece.
- **The photo wall always has photographs.** `PhotoSource` decides at scan time, not
  config time: `~/Desktop/giveit2me` if it is there, else the authored roots, else the
  pool bundled in the `.app` (`assets/photo_fallback` + `assets/broken_screens`). The
  resolution runs **off the main thread** — deciding means trying to read `~/Desktop`,
  and on a first run that blocks on the Files and Folders prompt. `PhotoWallController.spawn`
  returns early on an empty index, so without the fallback a refused machine gets a cue
  that opens nothing. `assets/photo_fallback/` is derived-and-committed from the
  gitignored `broken_computer` drop by `generate_show.py`, minus `IMG_0624.PNG` (a real
  person's DM — see the note there); regenerate it whenever the drop changes.
- **The bundle is `give-it-2-me.app`; the SwiftPM target is not renamed.** `bundle.sh`
  keeps `PRODUCT` (what SwiftPM builds, still `GiveIt2Me_DJ_Dave_malware`, so every
  `swift run` command works), `APP_NAME` (the `.app` and its executable) and
  `DISPLAY_NAME` (menu bar, Force Quit) apart — they were one variable, which is why
  renaming the bundle looked like it meant renaming the target. `CFBundleExecutable` must
  name the *destination* of the `cp`, not the product, or the bundle will not launch.
  `CFBundleIdentifier` stays `com.computerart.giveit2me`: TCC keys grants on the
  identifier and signature, never the filename, so the rename costs no permissions and
  changing the identifier would cost all of them. The outro's fake force-quit alert must
  agree with `DISPLAY_NAME` — one string, `OutroController.defaultAppName`, which
  `StillRenderer`'s preview reads too.
- **Every `ship.sh` build needs `GiveIt2Me.entitlements` — ad-hoc included.** `ship.sh`
  signs `--options runtime` whatever the identity, and the hardened runtime denies the
  camera and Location Services on the *runtime flag*, before TCC is consulted, so the
  Info.plist usage strings are not enough. The failure is silent: the app runs, prompts,
  the viewer says yes, and the cues do nothing. (`bundle.sh` does not set the flag, so
  the dev loop is unaffected.) `ProductionTests` pairs the file against
  `Permissions.plan(for:)` in both directions, so a `rearrangeIcons`/`fileSwarm` cue
  fails the suite until `com.apple.security.automation.apple-events` goes in with it.
  **Comments in that file may not contain `--` and must stay ASCII** — XML forbids it,
  `plutil -lint` passes anyway, and `codesign` then dies with `AMFIUnserializeXML:
  syntax error`. Notarization additionally needs `--timestamp` (not `--timestamp=none`,
  which *succeeds* with a real identity and gets the upload rejected later).
- **`--check` is the USB test.** It resolves every asset the timeline names against the
  `.app` alone (`TimelineAssets.audit`), because the ordinary resolver also searches the
  repo — so a bundle missing half its pictures looks perfect until it leaves the machine.
  Run it from a *copy* of the `.app`. A new asset-carrying param must be added to
  `TimelineAssets.paths` or it silently stops travelling.
- **Photosensitivity is a real constraint, not a style note.** Keep full-screen change
  rates out of the 15–20 Hz band and re-measure from the generated timeline if you
  change the cadence. The current cut is median 2.9 Hz, peak 12.0 Hz.
  `deskWallpaper` used to be held under that band by accident — `setDesktopImageURL` is
  a ~3 Hz wall — but the desktop layer sustains 119 Hz, so the limit is now explicit:
  `WallpaperController.layerMaxHz` (12 Hz), clamped with a log line. Raising it means
  re-measuring the show, not editing a number.
- **`tools/insta360pan/` is a separate app, not part of the SwiftPM package.** It pans and
  zooms an Insta360's webcam-mode feed (front lens top half, rear lens bottom half, each a
  fisheye cropped to a band) by rebuilding the sphere through a calibrated lens model with
  a stitch distance for the lens parallax, and publishes the view over Syphon for Resolume.
  It builds with its own `build.sh` the way `~/segcam` does, borrowing `Syphon.framework`
  from TouchDesigner; its `README.md` covers the controls, calibration and the probe.
