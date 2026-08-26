#!/bin/bash
# Assemble GiveIt2Me_DJ_Dave_malware.app from the SwiftPM build and code-sign it.
#
#   ./bundle.sh                 # release build, ad-hoc signed
#   CONFIG=debug ./bundle.sh    # debug build
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
BUNDLE_ID="com.computerart.giveit2me"
APP_NAME="GiveIt2Me_DJ_Dave_malware"
IDENTITY="${SIGN_IDENTITY:--}"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BINDIR=".build/$CONFIG"
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINDIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

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

# Embed the compressed backing track(s) so the .app is self-contained and plays
# anywhere, not just from inside the repo tree. The resolver checks Contents/Resources.
# Only compressed formats — embedding raw .wav would re-bloat the bundle.
for audio in assets/*.mp3 assets/*.m4a; do
  [ -e "$audio" ] && cp "$audio" "$APP/Contents/Resources/"
done

# Image assets the timeline names by path (the end card's tiled backdrop). Same reason
# as the audio: the resolver checks Contents/Resources, and without this the .app falls
# back to a plain black card while the repo build looks correct.
for img in assets/credits_tile.png; do
  [ -e "$img" ] && cp "$img" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>Desktop Performance Engine</string>
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
    <string>Desktop Performance Engine rearranges your desktop icons during a performance and restores them when it finishes.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>The photo wall reads image files from your Desktop to show them during a performance. Nothing is copied, moved or modified.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>The photo wall reads image files from your Documents folder to show them during a performance. Nothing is copied, moved or modified.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>The photo wall reads image files from your Downloads folder to show them during a performance. Nothing is copied, moved or modified.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>The photo wall reads image files to show them during a performance. Nothing is copied, moved or modified.</string>
    <key>NSCameraUsageDescription</key>
    <string>The photo booth shows your camera during a performance and takes one photo for the end card. It is kept in memory only and discarded when the show ends.</string>
    <key>NSContactsUsageDescription</key>
    <string>The system probe reads your own "me" card to show you what this machine knows about you. Nothing leaves this computer.</string>
    <key>NSLocationUsageDescription</key>
    <string>The system probe and the map show where this machine is. Nothing leaves this computer.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>The system probe and the map show where this machine is. Nothing leaves this computer.</string>
</dict>
</plist>
PLIST

echo "▸ codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP" || true

echo "✓ Built $APP"
echo "  open \"$APP\"                        # run the control window"
echo "  open -a \"$PWD/$APP\" --args examples/timeline_cursor.json"
