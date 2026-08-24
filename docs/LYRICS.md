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

Every `fakeDialog` in the piece draws its title and body from these lines — see
`tools/lyrics.py`, which is the single source both generators import. The lines
alternate short/long, which maps onto an alert's two text styles: the short line
becomes the bold message, the long one the smaller informative text underneath.

Casing and punctuation are kept exactly as written (the lower-case `i`, the curly
apostrophes) — the alerts are meant to read as the song, not as system copy.
