#!/bin/bash
# Fetch the WebAssembly DooM the show runs in one of its windows (cue 27).
#
#   tools/fetch_doom.sh          # into assets/doom.wasm
#
# WHAT THIS IS, AND WHY IT IS NOT IN THE REPO
#
# `doom.wasm` is Ilya Diekmann's wasm32 port of id Software's linuxdoom-1.10 — the 1997
# sources, GPL-2.0, compiled to a freestanding WebAssembly module with no emscripten
# runtime and no sound (which is exactly what a piece with its own soundtrack wants).
# Source: https://github.com/diekmann/wasm-fizzbuzz  (the `doom/` directory).
#
# The build has an IWAD baked into it — id's SHAREWARE episode. That is why the binary is
# fetched onto your machine instead of committed here: running the shareware episode is
# what it is for, but redistributing it inside a signed .app you hand out is a decision
# for you, not something a build script should make quietly. `ship.sh` will happily put
# it in the .dmg if it is present, so delete it before shipping if you would rather not.
# The GPL applies to the engine either way: distributing the .app with this in it means
# offering the corresponding source, which is at the URL above.
#
# It lands in `assets/` rather than `Sources/DPECore/Resources/`, where the other web
# hosts live, for a build reason: SwiftPM fails the whole build over a DECLARED resource
# that is not there, so a fetched file cannot be one. `assets/` is resolved at run time
# (`resolveResourcePath`), which is exactly the "there if you fetched it" semantics this
# needs. `doom.html` — the host page that drives it — is ours and IS committed.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://diekmann.github.io/wasm-fizzbuzz/doom/doom.wasm"
OUT="assets/doom.wasm"

if [ -f "$OUT" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "✓ $OUT already here ($(du -h "$OUT" | cut -f1)). FORCE=1 to re-fetch."
  exit 0
fi

echo "▸ fetching $URL"
curl -fL --retry 2 -o "$OUT.part" "$URL"

# It has to BE a wasm module: a captive-portal HTML page saved under this name would
# otherwise show up as a window that silently never boots.
if ! head -c 4 "$OUT.part" | grep -q $'\x00asm'; then
  rm -f "$OUT.part"
  echo "✗ what came back is not a WebAssembly module — not installing it" >&2
  exit 1
fi
mv "$OUT.part" "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
echo "  gitignored on purpose — see the header of this script."
echo "  rebuild the app to pick it up:  ./bundle.sh"
