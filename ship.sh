#!/bin/bash
# Package the piece for someone else's Mac: universal binary, signed, in a .dmg and a
# .zip. `bundle.sh` is the dev loop; this is the one you hand out.
#
#   ./ship.sh                                   # universal, ad-hoc signed  → USB only
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./ship.sh
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=dpe ./ship.sh   # + notarize
#
# WHY THE SIGNING MATTERS
#   Ad-hoc signing is fine on a USB stick: files copied from removable media are not
#   quarantined, so Gatekeeper lets them run. It is NOT fine for a download — anything
#   a browser, Mail or AirDrop delivers gets the com.apple.quarantine attribute, and an
#   app without a Developer ID is refused. On current macOS the recipient has to dig
#   through System Settings ▸ Privacy & Security ▸ Open Anyway to get past it.
#
#   To ship a link people can just click, you need the $99/yr Apple Developer Program:
#   sign with a "Developer ID Application" certificate, notarize, and staple. Set up the
#   notary credentials once with:
#     xcrun notarytool store-credentials dpe --apple-id you@example.com \
#           --team-id TEAMID --password <app-specific-password>

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GiveIt2Me_DJ_Dave_malware"
VOL_NAME="Desktop Performance Engine"
IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP="build/$APP_NAME.app"
OUT="build/dist"

echo "▸ regenerating the show"
python3 tools/generate_show.py > /dev/null

echo "▸ building both architectures"
swift build -c release --triple arm64-apple-macosx13.0  > /dev/null
swift build -c release --triple x86_64-apple-macosx13.0 > /dev/null

# bundle.sh lays out the .app (resources, track, icon, Info.plist) from the arm64 build;
# we then replace its binary with a universal one so Intel Macs can run it too.
echo "▸ assembling the .app"
SIGN_IDENTITY="$IDENTITY" ./bundle.sh > /dev/null

echo "▸ making the binary universal"
lipo -create \
  ".build/arm64-apple-macosx/release/$APP_NAME" \
  ".build/x86_64-apple-macosx/release/$APP_NAME" \
  -output "$APP/Contents/MacOS/$APP_NAME"
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

# Re-sign: replacing the binary invalidated bundle.sh's signature. Hardened runtime is
# required for notarization and harmless without it.
echo "▸ signing ($IDENTITY)"
codesign --force --deep --options runtime --timestamp=none \
         --sign "$IDENTITY" "$APP" 2>/dev/null || \
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature valid"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "▸ zip"
ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"

echo "▸ dmg"
STAGE="build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO \
               "$OUT/$APP_NAME.dmg" > /dev/null
rm -rf "$STAGE"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "▸ notarizing (this takes a few minutes)"
  xcrun notarytool submit "$OUT/$APP_NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/$APP_NAME.dmg"
  xcrun stapler staple "$APP"
  rm -f "$OUT/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"   # re-zip the stapled app
  echo "  notarized and stapled — this will open from a download with no warning"
else
  echo "▸ NOT notarized."
  if [ "$IDENTITY" = "-" ]; then
    echo "  Ad-hoc signed: fine from a USB stick, refused from a download."
  else
    echo "  Signed but not notarized: a download will still be blocked."
  fi
fi

echo
echo "✓ $OUT/"
ls -lh "$OUT" | tail -n +2 | awk '{print "   " $9 "  " $5}'
echo
echo "  Test it like a recipient would (simulates a download):"
echo "    xattr -w com.apple.quarantine '0081;0;Safari;' $OUT/$APP_NAME.zip"
