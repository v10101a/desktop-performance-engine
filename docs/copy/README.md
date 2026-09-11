# The words

Everything the show *says* — what a window types, what a dialog reads, the credits —
lives here, one plain-text file per passage. `tools/generate_show.py` reads these when it
builds the timeline, and both build scripts run it first — so rewriting a passage is: edit
the file, then `./bundle.sh` for the `.app` or `tools/run_show.sh` to play it straight
away. No quotes to escape, no code to touch, no separate generate step to forget. The lyric is not here: the song's words and their
timing are `tools/lyrics.py`, and `docs/LYRICS.md` explains them.

| file | where it is heard | shape |
|---|---|---|
| `welcome.txt` | the welcome terminal (cue 3) | one line per line typed, a beat each; blank lines are kept |
| `torus_greeting.txt` | the torus introducing itself (cue 13) | prose — wrap it anywhere, a blank line is a paragraph break |
| `torus_oracle.txt` | the torus's question card and its answers (cue 13) | fields |
| `locate.txt` | the terminal tracing the viewer's location (cue 14) | one line per line typed |
| `location_found.txt` | the alert once the map has landed (cue 14) | fields |
| `last_words.txt` | the one alert on the blue after the stop (cue 30) | fields |
| `credits.txt` | the end card (cue 31) | one line per line typed, a beat each; blank lines are kept |

**Shapes.** *Lines* are typed exactly as written, including leading spaces, so keep them
short enough for their window — the generator asserts the welcome fits its gap and fails
the build if it does not. *Prose* is joined into paragraphs, so the file can be wrapped at
any width. *Fields* are `key: value` lines; a key with nothing after the colon takes the
`- item` lines under it as a list; lines starting with `#` are comments. The
`answers` list in `torus_oracle.txt` is what the torus can reply — the same question
always gets the same one.

Rewriting anything here changes the cut, so the row in `docs/CUES.md` that points at the
file should still describe what it says.
