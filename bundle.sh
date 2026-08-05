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

# Bundle.module resolves resources from Contents/Resources inside an .app.
RESBUNDLE="$BINDIR/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESBUNDLE" ]; then
  cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
fi

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
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Desktop Performance Engine rearranges your desktop icons during a performance and restores them when it finishes.</string>
</dict>
</plist>
PLIST

echo "▸ codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP" || true

echo "✓ Built $APP"
echo "  open \"$APP\"                        # run the control window"
echo "  open -a \"$PWD/$APP\" --args examples/timeline_cursor.json"
