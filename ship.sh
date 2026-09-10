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
#
#   A Developer ID build is signed with the hardened runtime, a secure timestamp and
#   GiveIt2Me.entitlements. All three are required: without the timestamp notarization
#   rejects the upload outright, and without the entitlements the hardened runtime denies
#   the camera and Location Services before TCC is ever asked — so the show installs,
#   runs, prompts, and then has no photo booth and no fix. Nothing says so at run time;
#   those cues just do nothing.

set -euo pipefail
cd "$(dirname "$0")"

# See the note in bundle.sh: PRODUCT is what SwiftPM builds (unchanged, so `swift run`
# still works), APP_NAME is what the bundle is called. The lipo below reads PRODUCT out
# of .build and writes APP_NAME into the bundle.
PRODUCT="GiveIt2Me_DJ_Dave_malware"
APP_NAME="give-it-2-me"
VOL_NAME="give-it-2-me"
IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP="build/$APP_NAME.app"
OUT="build/dist"
ENTITLEMENTS="GiveIt2Me.entitlements"

if [ ! -f "$ENTITLEMENTS" ]; then
  echo "error: $ENTITLEMENTS is missing. Every build here is signed --options runtime," >&2
  echo "       ad-hoc included, and the hardened runtime denies the camera and Location" >&2
  echo "       Services without it — the app launches, prompts, and then does neither." >&2
  exit 1
fi

echo "▸ regenerating the show"
python3 tools/generate_show.py > /dev/null
python3 tools/lint_show.py

echo "▸ building both architectures"
swift build -c release --triple arm64-apple-macosx13.0  > /dev/null
swift build -c release --triple x86_64-apple-macosx13.0 > /dev/null

# bundle.sh lays out the .app (resources, track, icon, Info.plist) from the arm64 build;
# we then replace its binary with a universal one so Intel Macs can run it too.
echo "▸ assembling the .app"
# SKIP_GENERATE: the show was regenerated and linted above, before either build, so the
# SwiftPM resource bundle and the flat copy carry the same timeline.
SKIP_GENERATE=1 SIGN_IDENTITY="$IDENTITY" ./bundle.sh > /dev/null

echo "▸ making the binary universal"
lipo -create \
  ".build/arm64-apple-macosx/release/$PRODUCT" \
  ".build/x86_64-apple-macosx/release/$PRODUCT" \
  -output "$APP/Contents/MacOS/$APP_NAME"
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

# Re-sign: replacing the binary invalidated bundle.sh's signature. Hardened runtime is
# required for notarization and harmless without it.
#
# TWO THINGS NOTARIZATION WILL REJECT, both of which this used to do:
#
#   1. No secure timestamp. `--timestamp=none` was tried FIRST and, with a real
#      Developer ID, it SUCCEEDS — so the fallback never ran and every signed build
#      carried a signature notarization refuses ("The signature does not include a
#      secure timestamp"). It is only correct for ad-hoc, which cannot be timestamped
#      at all, so it is now used only there.
#   2. No entitlements. Under the hardened runtime the camera and Location Services are
#      denied before TCC is consulted — see GiveIt2Me.entitlements. An unentitled
#      notarized build installs, launches, prompts, and then quietly has no photo booth
#      and no fix.
# THE ENTITLEMENTS GO IN BOTH BRANCHES, and the ad-hoc one is not belt-and-braces.
# `--options runtime` is applied here whatever the identity, and the hardened runtime
# denies the camera and Location Services on the *runtime flag*, not on who signed it —
# so an ad-hoc USB build signed without them has no photo booth and no fix either, for
# exactly the same silent reason a notarized one would not. Signing both the same way
# also means the stick you rehearse from is the build you ship, differing only in trust.
echo "▸ signing ($IDENTITY)"
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc signatures cannot carry a secure timestamp at all, so this build can never be
  # notarized. That is fine for a USB stick — see the header.
  codesign --force --deep --options runtime --timestamp=none \
           --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --options runtime --timestamp \
           --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "  signature valid"

# What actually got signed in, read back off the binary rather than assumed.
#
# This is worth the twelve lines because BOTH failure modes are silent. A malformed
# entitlements file does not stop the build — codesign fails, `set -e` catches that one —
# but an entitlement that never made it in produces an app that runs and simply has no
# camera. And a signature without a secure timestamp only announces itself minutes later,
# when notarytool rejects the upload.
echo "  entitlements:"
codesign -d --entitlements - "$APP" 2>/dev/null \
  | grep -o 'com\.apple\.security\.[a-z.-]*' | sed 's/^/    /' \
  || echo "    NONE — the camera and Location Services will be denied at run time" >&2

if [ "$IDENTITY" != "-" ]; then
  if codesign -dvv "$APP" 2>&1 | grep -qi "^Timestamp="; then
    codesign -dvv "$APP" 2>&1 | grep -i "^Timestamp=" | sed 's/^/  /'
  else
    echo "  WARNING: no secure timestamp — notarization will reject this" >&2
  fi
fi

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
