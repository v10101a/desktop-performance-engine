#!/bin/bash
# Assemble give-it-2-me.app from the SwiftPM build and code-sign it.
#
#   ./bundle.sh                 # regenerate the show, lint it, release build, ad-hoc signed
#   CONFIG=debug ./bundle.sh    # debug build
#   SKIP_GENERATE=1 ./bundle.sh # package the committed timeline.json as it is (no Pillow needed)
#   SIGN_IDENTITY="Apple Development: you@example.com" ./bundle.sh
#
# Ad-hoc signing (the default, "-") works but the code identity changes every build,
# so macOS resets Accessibility / Automation grants on each rebuild. For a stable
# identity that keeps TCC grants across rebuilds, create a self-signed code-signing
# certificate once (Keychain Access ▸ Certificate Assistant ▸ Create a Certificate,
# type "Code Signing") and pass its name via SIGN_IDENTITY.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"

# THREE NAMES, and they are not the same name (2026-09-09).
#
#   PRODUCT       what SwiftPM builds. Package.swift's executable target, and therefore
#                 the filename in .build — this is NOT renamed, so `swift run` and every
#                 dev command in the README keep working.
#   APP_NAME      what the bundle is called on disk, and the executable inside it. The
#                 thing you hand someone.
#   DISPLAY_NAME  what macOS shows the room: the menu bar during the show, Force Quit,
#                 the Finder's Get Info. Was "Desktop Performance Engine".
#
# They used to be one variable doing all three jobs, which is why renaming the bundle
# looked like it would mean renaming the SwiftPM target. It does not.
PRODUCT="GiveIt2Me_DJ_Dave_malware"
APP_NAME="give-it-2-me"
DISPLAY_NAME="give-it-2-me"
# NOT renamed, on purpose: TCC keys its grants on the identifier and the code signature,
# never on the filename. Change this and macOS treats the piece as a stranger — camera,
# Location Services and Files-and-Folders are all asked for again, on whatever machine
# was already set up for the show.
BUNDLE_ID="com.computerart.giveit2me"
IDENTITY="${SIGN_IDENTITY:--}"

# The show first. The timeline the .app carries is GENERATED — from docs/CUES.md and the
# words in docs/copy/ — so a bundle built without regenerating ships whatever was
# generated last: stale copy, silently. Regenerate and lint on every build. SKIP_GENERATE=1
# is for a machine without Pillow (the generator's one dependency); it packages the
# committed timeline.json as it is.
if [ "${SKIP_GENERATE:-0}" = "1" ]; then
  echo "▸ SKIP_GENERATE=1 — packaging the committed timeline.json as it is"
else
  echo "▸ python3 tools/generate_show.py && python3 tools/lint_show.py"
  python3 tools/generate_show.py > /dev/null
  python3 tools/lint_show.py
fi

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BINDIR=".build/$CONFIG"
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Built as PRODUCT, installed as APP_NAME — and `CFBundleExecutable` below has to name
# the destination, not the source, or the bundle will not launch at all.
cp "$BINDIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"

# App icon — so it can just be double-clicked from the Finder like anything else.
# (Regenerate with `python3 tools/make_icon.py`.)
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/"
fi

# The show itself, copied FLAT into Contents/Resources.
#
# This is the copy the app actually uses. SwiftPM's Bundle.module only searches the top
# level of the .app and an absolute path into the build machine's .build directory, so
# relying on it makes a bundle that runs here and crashes everywhere else — see
# AppDelegate.bundledTimelineURL, which looks here first.
#
# These read from Sources/DPECore, not Sources/$APP_NAME: the library was split out of
# the executable so it could be tested, and the resources went with it.
cp Sources/DPECore/Resources/timeline.json "$APP/Contents/Resources/"

# Real hydra: the library and the page that hosts it, side by side because the page
# loads the library by relative name. Without these the livecode windows silently fall
# back to the Core Animation impression — the show still runs, it just isn't hydra.
cp Sources/DPECore/Resources/hydra-synth.js "$APP/Contents/Resources/"
cp Sources/DPECore/Resources/hydra.html     "$APP/Contents/Resources/"

# The GLSL host and the shader it runs (cue 17). Flat, for the same reason as the
# above: ShaderCanvasView resolves both through resolveResourcePath, which looks in
# Contents/Resources, and the page is loaded by file URL so it needs a real path.
cp Sources/DPECore/Resources/shader.html   "$APP/Contents/Resources/"

# DooM's host page, and the engine it loads IF it has been fetched (tools/fetch_doom.sh).
# Missing, the window says so on its own — the app still builds and still runs.
cp Sources/DPECore/Resources/doom.html     "$APP/Contents/Resources/"
if [ -f assets/doom.wasm ]; then
  mkdir -p "$APP/Contents/Resources/assets"
  cp assets/doom.wasm "$APP/Contents/Resources/assets/"
else
  echo "note: assets/doom.wasm not fetched — cue 27's DooM window will say so (tools/fetch_doom.sh)" >&2
fi

# The SwiftPM resource bundle too, as a second home for anything else it carries.
# Copy every bundle SwiftPM produced rather than one hardcoded name: the bundle is named
# for the TARGET that declares the resources, so the split renamed it to
# <package>_DPECore.bundle and a hardcoded name copied nothing.
FOUND_RESBUNDLE=0
for RESBUNDLE in "$BINDIR"/*.bundle; do
  [ -d "$RESBUNDLE" ] || continue
  cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
  FOUND_RESBUNDLE=1
done
if [ "$FOUND_RESBUNDLE" -eq 0 ]; then
  echo "note: no SwiftPM resource bundle in $BINDIR (the flat copies above are what the app reads)" >&2
fi

# The GLSL shaders, by the path the timeline names them with.
if [ -d assets/shaders ]; then
  mkdir -p "$APP/Contents/Resources/assets"
  cp -R assets/shaders "$APP/Contents/Resources/assets/"
fi

# Clips the timeline segments (cue 21's segSwarm). By the path the timeline names them
# with, so `resolveResourcePath` finds them in a bundle that has left the repo behind.
for clip in assets/*.mov assets/*.mp4; do
  [ -e "$clip" ] || continue
  mkdir -p "$APP/Contents/Resources/assets"
  cp "$clip" "$APP/Contents/Resources/assets/"
done

# The lyric face (EffectWindow's LyricFont registers it from this path at run time).
if [ -d assets/fonts/hack ]; then
  mkdir -p "$APP/Contents/Resources/assets/fonts"
  cp -R assets/fonts/hack "$APP/Contents/Resources/assets/fonts/"
fi

# Embed the compressed backing track(s) so the .app is self-contained and plays
# anywhere, not just from inside the repo tree. The resolver checks Contents/Resources.
# Only compressed formats — embedding raw .wav would re-bloat the bundle.
for audio in assets/*.mp3 assets/*.m4a; do
  [ -e "$audio" ] && cp "$audio" "$APP/Contents/Resources/"
done

# Image assets the timeline names by path (the end card's tiled backdrop, the drop's
# wallpaper, the gate's face, the plane the torus refracts). Same reason as the audio:
# the resolver checks Contents/Resources, and without this the .app falls back to a plain
# black card while the repo build looks correct.
#
# BOTH PLACES, and the second one is the one that works (2026-09-07). `resolveResourcePath`
# tries `<base>/<name>` and `<base>/assets/<basename>` -- and never `<base>/<basename>` --
# so a file the timeline names `assets/foo.jpg` is NOT found by a flat copy at
# Contents/Resources/foo.jpg. It only ever resolved because the repo root is among the
# bases the resolver walks up to, which is true when you run from the checkout and false
# for an .app that has been moved anywhere else. The flat copy is kept because other
# things (and `--check`) look for it there.
mkdir -p "$APP/Contents/Resources/assets"
for img in assets/credits_tile.png assets/pixelface.jpg assets/pixelface_desktop.jpg \
           assets/pixelface_blink.jpg assets/torus_dimension.jpg; do
  [ -e "$img" ] || continue
  cp "$img" "$APP/Contents/Resources/"
  cp "$img" "$APP/Contents/Resources/assets/"
done

# The intro gate's two sounds — the alert arriving, and the alert being answered. Named
# explicitly rather than swept up by the audio loop above, which deliberately takes only
# compressed formats; these are small .wavs and embedding them is the point.
for snd in assets/bubble_sound.wav assets/click_sound.wav; do
  [ -e "$snd" ] && cp "$snd" "$APP/Contents/Resources/"
done

# The lyric wallpapers, kept in their own folder because the timeline names them by that
# path and the resolver checks Contents/Resources for it.
if [ -d assets/lyrics_desktops ]; then
  mkdir -p "$APP/Contents/Resources/assets/lyrics_desktops"
  cp assets/lyrics_desktops/*.jpg "$APP/Contents/Resources/assets/lyrics_desktops/"
fi

# The broken-screen photographs the bar-72 eruption throws up, same arrangement: the
# timeline names them by folder, so the folder has to exist under Contents/Resources.
if [ -d assets/broken_screens ]; then
  mkdir -p "$APP/Contents/Resources/assets/broken_screens"
  cp assets/broken_screens/*.jpg "$APP/Contents/Resources/assets/broken_screens/"
fi

# The photo wall's fallback pool — what cue 22 shows when the viewer refuses Files and
# Folders, or has nothing to show. NOT named by the timeline: `PhotoSource.bundledRoots`
# resolves this folder at run time, which is why it has to travel inside the .app. On a
# machine that says no to everything this is the only thing the wall has.
# `|| true` is load-bearing: this script runs under `set -euo pipefail`, and with no
# match `ls` exits non-zero, which pipefail promotes to the whole pipeline and `set -e`
# turns into an aborted build. Counting nothing is not an error here.
FALLBACK_N=$(ls assets/photo_fallback/*.jpg 2>/dev/null | wc -l | tr -d ' ' || true)
SCREENS_N=$(ls assets/broken_screens/*.jpg 2>/dev/null | wc -l | tr -d ' ' || true)
if [ "$FALLBACK_N" -gt 0 ]; then
  mkdir -p "$APP/Contents/Resources/assets/photo_fallback"
  cp assets/photo_fallback/*.jpg "$APP/Contents/Resources/assets/photo_fallback/"
else
  echo "note: assets/photo_fallback is empty — build it with tools/generate_show.py (needs the" >&2
  echo "      gitignored assets/broken_computer drop and Pillow)." >&2
fi
echo "  photo fallback: $((FALLBACK_N + SCREENS_N)) photograph(s) for a machine that refuses Files and Folders"
if [ "$((FALLBACK_N + SCREENS_N))" -eq 0 ]; then
  echo "warning: NO fallback photographs — cue 22 will open an empty wall on a refused machine." >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.2</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <false/>
    <key>NSAppleEventsUsageDescription</key>
    <string></string>
    <key>NSDesktopFolderUsageDescription</key>
    <string></string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string></string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string></string>
    <key>NSCameraUsageDescription</key>
    <string></string>
    <key>NSLocationUsageDescription</key>
    <string></string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string></string>
</dict>
</plist>
PLIST

echo "▸ codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP" || true

echo "✓ Built $APP  (\"$DISPLAY_NAME\" to macOS, $BUNDLE_ID)"
echo "  open \"$APP\"                        # the gate; ⌃⌥⌘D for the console"
echo "  open -a \"$PWD/$APP\" --args examples/timeline_cursor.json"
