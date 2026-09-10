#!/bin/bash
# Builds insta360pan.app with just the Command Line Tools — no Xcode project, no SwiftPM.
# Same shape as ~/segcam/build.sh: swiftc straight to a bundle, Syphon borrowed from an
# app that ships it.
set -euo pipefail
cd "$(dirname "$0")"

APP="insta360pan.app"
BIN="$APP/Contents/MacOS/insta360pan"
# Ad-hoc by default. An ad-hoc signature changes identity whenever the binary changes, so
# macOS re-asks for camera access after a rebuild; point SIGN_IDENTITY at a self-signed
# certificate to keep the grant.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Syphon (BSD 2-clause, bangnoise/vade) is not on macOS by default. We need a Syphon 5
# build that exposes SyphonServerBase and ships SyphonSubclassing.h: the app publishes a
# Metal-rendered IOSurface through those hooks, so it does not need the framework to have
# been built with its own Metal server. TouchDesigner's copy qualifies; OBS's has the class
# but no headers, and Resolume's is built with the pre-5 class names. SYPHON_FRAMEWORK
# overrides the search.
SYPHON="${SYPHON_FRAMEWORK:-}"
if [ -z "$SYPHON" ]; then
    for candidate in \
        /Library/Frameworks/Syphon.framework \
        "$HOME/Library/Frameworks/Syphon.framework" \
        /Applications/TouchDesigner.app/Contents/Frameworks/Syphon.framework \
        /Applications/OBS.app/Contents/Frameworks/Syphon.framework; do
        [ -f "$candidate/Headers/SyphonSubclassing.h" ] || continue
        nm -gU "$candidate/Syphon" 2>/dev/null | grep -qF '_OBJC_CLASS_$_SyphonServerBase' || continue
        SYPHON="$candidate"
        break
    done
fi
if [ -z "$SYPHON" ]; then
    cat >&2 <<'MSG'
error: no usable Syphon.framework found.
       Need a Syphon 5 build with headers (SyphonSubclassing.h) and SyphonServerBase.
       Install TouchDesigner, or download the Syphon SDK from
       https://github.com/Syphon/Syphon-Framework/releases and drop Syphon.framework in
       /Library/Frameworks, or set SYPHON_FRAMEWORK=/path/to/Syphon.framework.
MSG
    exit 1
fi
echo "using $SYPHON"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Info.plist "$APP/Contents/Info.plist"
cp -R "$SYPHON" "$APP/Contents/Frameworks/"

swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos14.0" \
    -F "$APP/Contents/Frameworks" -framework Syphon \
    -import-objc-header Sources/Syphon-Bridging.h \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/*.swift \
    -o "$BIN"

codesign --force --sign "$SIGN_IDENTITY" --identifier com.jamecoyne.insta360pan "$APP"

echo "built $PWD/$APP"
