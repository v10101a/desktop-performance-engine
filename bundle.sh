#!/bin/bash
# Assemble DesktopPerformanceEngine.app from the SwiftPM build and code-sign it.
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
BUNDLE_ID="com.computerart.desktopperformanceengine"
APP_NAME="DesktopPerformanceEngine"
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

# Bundle.module resolves resources from Contents/Resources inside an .app.
#
# Copy every resource bundle SwiftPM produced rather than one hardcoded name. The
# bundle is named for the *target* that declares the resources, so when the library was
# split out of the executable this became DesktopPerformanceEngine_DPECore.bundle — and
# a hardcoded name silently shipped an .app with no timeline.json in it, which only
# shows up as a blank show at runtime.
FOUND_RESBUNDLE=0
for RESBUNDLE in "$BINDIR"/*.bundle; do
  [ -d "$RESBUNDLE" ] || continue
  cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
  FOUND_RESBUNDLE=1
done
if [ "$FOUND_RESBUNDLE" -eq 0 ]; then
  echo "!! no resource bundle in $BINDIR — the app will have no bundled timeline" >&2
  exit 1
fi

# Embed the compressed backing track(s) so the .app is self-contained and plays
# anywhere, not just from inside the repo tree. The resolver checks Contents/Resources.
# Only compressed formats — embedding raw .wav would re-bloat the bundle.
for audio in assets/*.mp3 assets/*.m4a; do
  [ -e "$audio" ] && cp "$audio" "$APP/Contents/Resources/"
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
</dict>
</plist>
PLIST

echo "▸ codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP" || true

echo "✓ Built $APP"
echo "  open \"$APP\"                        # run the control window"
echo "  open -a \"$PWD/$APP\" --args examples/timeline_cursor.json"
