#!/bin/bash
# Tune the lyric cards by ear.
#
# Regenerates the show from tools/lyrics.py (CUES), prints when every card lands, and
# plays JUST that chorus full-screen, from two seconds before it, then restores and
# quits. Edit a number, run it again.
#
#   tools/tune_lyrics.sh          # chorus A — the fullscreen cards (bar 17 − 1 s lead, 29.28 s)
#   tools/tune_lyrics.sh b        # chorus B — the clock round the torus (bar 25 − 1 s lead, 44.22 s)
#   SECS=10 tools/tune_lyrics.sh  # play only the first 10 s of it
#
# ⌃⌥⌘Esc panics out early. The chorus start times are BAR_CHORUS_A / BAR_CHORUS_B in
# tools/generate_show.py (both start CHORUS_LEAD = 1 s early); the two seconds of
# lead here are so the cut is seen, not joined.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-a}" in
  a|A) FROM=28.3 ;;
  b|B) FROM=42.2 ;;
  *)   echo "usage: $0 [a|b]" >&2; exit 2 ;;
esac

python3 tools/generate_show.py | sed -n '/lyric cues/,$p'
echo
echo "▸ playing chorus ${1:-a} from ${FROM}s for ${SECS:-18}s"
DPE_AUTOPLAY_FROM="$FROM" DPE_AUTOPLAY_SECS="${SECS:-18}" swift run GiveIt2Me_DJ_Dave_malware --autoplay
