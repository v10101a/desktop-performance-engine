# Give it 2 me — lyrics

The words for the backing track (`assets/03 - Give it 2 me.mp3`), as written.

```
what I want
I told you that i need your love so give it to me
running up
my currents i can’t get enough of this feeling baby
all i got
i’m giving that so give it up
i told you that I
need your love
so give it to me
need your love
so give it to me
```

## Where these appear in the show

**All of it is chorus** — each chorus sings the whole lyric, 8 bars — and one list times
everything: `CUES` in `tools/lyrics.py`, `(when, word)`, **one entry per sung word,
tuned by ear**. `when` is beats from the lyric's own zero — *what I want*, the pickup,
which is sung one bar before the chorus's downbeat (`CHORUS_LEAD` in the generator) —
or a time in the track as a string (`"34.10s"`). `PHRASES` is the same lyric in phrases,
and `phrase_cues()` times each phrase off the `CUES` entry its first word starts on, so
tuning a word moves its phrase too.

In the cut (`docs/CUES.md`):

- **cue 9, the spiral** (CHORUS 1A, the drop, 0:30.28) — every phrase of the lyric, one
  card each, landing on its sung line (the first line is the pickup and lands with the
  drop; the last at 0:43.06). Cards are set in Hack Bold (`LyricFont` in
  `EffectWindow.swift` — the one place every lyric card's face comes from).
- **cue 12, the desktop** (CHORUS 1B, 0:45.22) — the whole lyric again, one wallpaper card
  per sung word from `assets/lyrics_desktops/<WORD>.jpg` (named as sung: RUNNIN, CANT, 2;
  a whole-cue card such as `NEED YOUR LOVE.jpg` wins if present; a word with no card is
  skipped and the generator lists it — WHAT, WANT, OF, THIS, FEELING, BABY, ALL, GOT, IM,
  GIVING are still missing).
- **cue 22, the clock** (INSTRUMENTAL A + 6 bars, 1:56) — the phrase texts round the
  torus, spread evenly; nobody is singing there.

To tune by ear: edit the numbers, then `tools/tune_lyrics.sh` (the spiral) or
`tools/tune_lyrics.sh b` (the clock). It regenerates the show, prints when every card
and word lands in the track, and plays just that section from a couple of seconds before
it. When they're right, `python3 tools/generate_show.py && ./bundle.sh` for the `.app`.

Every `fakeDialog` in the piece draws its title and body from these lines — see
`tools/lyrics.py`, which is the single source both generators import. The lines
alternate short/long, which maps onto an alert's two text styles: the short line
becomes the bold message, the long one the smaller informative text underneath.

Casing and punctuation are kept exactly as written (the lower-case `i`, the curly
apostrophes) — the alerts are meant to read as the song, not as system copy.
