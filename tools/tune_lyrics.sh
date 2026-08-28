#!/bin/bash
# Tune the lyric cards by ear.
#
# Regenerates the show from tools/lyrics.py (CUES), prints when every card lands, and
# plays JUST the section that uses them, from a couple of seconds before it, then
# restores and quits. Edit a number, run it again.
#
# The same CUES list is read twice in the cut, and the two look nothing alike:
#
#   tools/tune_lyrics.sh          # the SPIRAL  — cue 9, the drop: every phrase on its sung line from 0:30.28, then the desktop words
#   tools/tune_lyrics.sh b        # the CLOCK   — cue 22, 1:56, ringing the glass torus
#   SECS=10 tools/tune_lyrics.sh  # play only the first 10 s of it
#
# ⌃⌥⌘Esc panics out early. Both start times come from CUES in tools/generate_show.py
# ("spiral" and "torus2"); the lead here is so the cut is seen, not joined.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-a}" in
  a|A) FROM=28.5 ;;      # the drop and the first cards at 30.28 s
  b|B) FROM=114.5 ;;     # clock  at 116.2 s
  *)   echo "usage: $0 [a|b]" >&2; exit 2 ;;
esac

python3 tools/generate_show.py | sed -n '/lyric cues/,$p'
echo
echo "▸ playing ${1:-a} from ${FROM}s for ${SECS:-18}s"
DPE_AUTOPLAY_FROM="$FROM" DPE_AUTOPLAY_SECS="${SECS:-18}" swift run GiveIt2Me_DJ_Dave_malware --autoplay
