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

**All of it is chorus** — each chorus sings the whole lyric — so the first chorus is a
lyric video: full-screen cards, one phrase per card, and the second chorus puts the same
phrases in small windows round the torus. **One list times both**: the card timings are
`CUES` in `tools/lyrics.py`, `(when, text)`, and each cue is a fullscreen card in chorus A
and a clock window at the same point of chorus B.

`when` is either **beats from the start of the chorus** (`4.0`; 32 beats = 8 bars, 0.4685 s
a beat) or **a time in the track**, as a string (`"34.10s"`) — as heard in chorus A, read
straight off the waveform or a player's clock; the card lands on that instant. The two
forms mix freely.

To tune by ear: edit the numbers, then `tools/tune_lyrics.sh` (chorus A) or
`tools/tune_lyrics.sh b` (the clock). It regenerates the show, prints when every card
lands in the track, and plays just that chorus full-screen from two seconds before it.
The timings are a first pass on the bar grid. When they're right,
`python3 tools/generate_show.py && ./bundle.sh` for the `.app`.

Every `fakeDialog` in the piece draws its title and body from these lines — see
`tools/lyrics.py`, which is the single source both generators import. The lines
alternate short/long, which maps onto an alert's two text styles: the short line
becomes the bold message, the long one the smaller informative text underneath.

Casing and punctuation are kept exactly as written (the lower-case `i`, the curly
apostrophes) — the alerts are meant to read as the song, not as system copy.
