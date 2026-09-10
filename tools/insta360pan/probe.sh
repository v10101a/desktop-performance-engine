#!/bin/bash
# Builds the Syphon probe against the framework inside insta360pan.app and runs it:
#   ./probe.sh [name-fragment] [frames]
# It connects like any other Syphon client would and prints what it receives.
set -euo pipefail
cd "$(dirname "$0")"
APP="insta360pan.app"
FRAMEWORKS="$PWD/$APP/Contents/Frameworks"
[ -d "$FRAMEWORKS/Syphon.framework" ] || { echo "build the app first: ./build.sh" >&2; exit 1; }
mkdir -p build
if [ ! -x build/syphon-probe ] || [ Probe/main.swift -nt build/syphon-probe ]; then
    swiftc -O -target "$(uname -m)-apple-macos14.0" \
        -F "$FRAMEWORKS" -framework Syphon \
        -import-objc-header Sources/Syphon-Bridging.h \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        Probe/main.swift -o build/syphon-probe
    codesign --force --sign - build/syphon-probe
fi
exec build/syphon-probe "$@"
