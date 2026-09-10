#!/bin/bash
# Regenerate the show and play it.
#
# The score is tools/generate_show.py (and tools/lyrics.py for the cues); the JSON it
# writes is what the app loads. `swift run` on its own plays whatever was generated
# LAST — this makes sure what plays is what's written.
#
#   tools/run_show.sh               # the whole piece, gate and all — as a viewer sees it
#   tools/run_show.sh 146           # rehearse from 146 s: no gate, restores + quits at the end
#   SECS=30 tools/run_show.sh 146   # …and quit after 30 s
#
# ⌘Esc panics out early. Cue times are the CUES table in generate_show.py (the source
# is docs/CUES.md); the generator prints every cue's frame. For the .app:
# python3 tools/generate_show.py && ./bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 tools/generate_show.py
python3 tools/lint_show.py
echo

if [ $# -eq 0 ]; then
  echo "▸ playing the whole show"
  swift run GiveIt2Me_DJ_Dave_malware
else
  echo "▸ rehearsing from ${1}s${SECS:+ for ${SECS}s}"
  DPE_AUTOPLAY_FROM="$1" DPE_AUTOPLAY_SECS="${SECS:-}" swift run GiveIt2Me_DJ_Dave_malware --autoplay
fi
