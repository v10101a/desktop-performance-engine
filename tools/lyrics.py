"""Lyric text for the show's alert windows.

Imported by BOTH generators (generate_show.py and generate_strobe.py) so the alert
copy lives in exactly one place. The words themselves are in docs/LYRICS.md.

A macOS alert has two text styles — a bold message and smaller informative text
below it — and the lyric alternates short line / long line, so each pair maps onto
one alert directly. These are the lines as written, in order, not rearranged:
casing and punctuation are verbatim, because the alerts are meant to read as the
song rather than as system copy.

Each entry is (message, informative, icon), where icon is the system illustration:
"caution" (the yellow triangle), "critical" (the app icon badged with it), or "info".
The show cycles the list, so a dense burst of alerts reads as the verse repeating.
"""

ALERTS = [
    ("what I want",
     "I told you that i need your love so give it to me", "critical"),
    ("running up",
     "my currents i can’t get enough of this feeling baby", "caution"),
    ("all i got",
     "i’m giving that so give it up", "info"),
    ("i told you that I",
     "need your love so give it to me", "critical"),
    ("need your love",
     "so give it to me", "caution"),
]

# Ordinary alert buttons. Deliberately plain — the lyric carries the message text,
# and a real alert's buttons are short verbs, which is also what keeps them legible
# at the sizes these spawn at.
BUTTONS = [["ok"], ["ok", "more"], ["not now", "ok"], ["ok"], ["more", "ok"]]


def alert(i):
    """(message, informative, icon) for the i-th alert, cycling the list."""
    return ALERTS[i % len(ALERTS)]


def buttons(i):
    return BUTTONS[i % len(BUTTONS)]


# The lyric video: the cues, word by word.
#
# Every line of the song is chorus (it repeats each time), so one pass of these is one
# chorus. Each entry is (when, text). This is the lyric WORD BY WORD, which is what the
# chorus 1A spiral wants — one small window per word, accumulating round the spiral.
#
# The chorus 1B desktop cards are drawn a phrase at a time, so they read this through
# `DESKTOP` below rather than directly. Tune a word here and both follow it.
#
# `when` is either of:
#   4.0      beats from the START of the chorus (32 beats = 8 bars long; 0.4669 s/beat)
#   "34.10s" a time in the TRACK, as heard in chorus A — read it off the waveform or a
#            player's clock and the card lands on that instant. Mix the two freely.
#
# To tune by ear:  edit the numbers, then  tools/tune_lyrics.sh  — it regenerates the
# show, prints when every card lands, and plays just that chorus.
#
# Chorus A (the clock round the torus) and chorus D (the alerts over the eruption) do
# NOT use these directly: they read PHRASES below, which are timed off the word that
# starts each phrase here, so tuning a word here moves its phrase there too.
CUES = [
    (0.0,  "WHAT I WANT"),
    (1.5,  "I"),
    (2.0,  "TOLD"),
    (2.5,  "YOU"),
    (3.0,  "THAT"),
    (3.5,  "I"),
    (4.0,  "NEED YOUR LOVE"),
    (5.5,  "SO"),
    (6.0,  "GIVE"),
    (6.5,  "IT"),
    (7.0,  "2"),
    (7.5,  "ME"),
    (8.0,  "RUNNING UP"),
    (10.0, "MY"),
    (10.5, "CURRENTS"),
    (11.0, "I"),
    (11.5, "CAN'T"),
    (12.0, "GET"),
    (12.5, "ENOUGH"),
    (13.5, "OF THIS"),
    (14.0, "FEELING"),
    (15.0, "BABY"),
    (16.0, "ALL I GOT"),
    (17.5, "I’M"),
    (18.0, "GIVING"),
    (19.0, "THAT"),
    (19.5, "SO"),
    (20.0, "GIVE IT UP"),
    (21.5, "I"),
    (22.0, "TOLD"),
    (22.5, "YOU"),
    (23.0, "THAT"),
    (23.5, "I"),
    (24.0, "NEED YOUR"),
    (24.8, "LOVE"),
    (25.5, "SO"),
    (26.0, "GIVE"),
    (26.5, "IT"),
    (27.0, "2"),
    (27.5, "ME"),
    (28.0, "NEED YOUR"),
    (28.8, "LOVE"),
    (29.5, "SO"),
    (30.0, "GIVE"),
    (30.5, "IT"),
    (31.0, "2"),
    (31.5, "ME"),
]


# The DESKTOP cards, as grouped by the artwork.
#
# `CUES` above is the lyric word by word — that is what the chorus 1A spiral wants, one
# small window per word. The desktop cards are drawn a phrase at a time ("NEED YOUR LOVE"
# is one picture, edge to edge), so this is the SAME lyric regrouped into the units the
# cards come in. One entry per card, in order, and the concatenation of these must be the
# concatenation of CUES exactly — `generate_show.py` asserts it, so a word retimed or
# reworded in CUES that is not reflected here fails the build rather than silently
# landing the wrong picture on the wrong beat.
#
# NO TIMES HERE. Each card lands on its FIRST word, at whatever time that word has in
# CUES — tune a word up there and its card follows. That is the whole reason this is a
# grouping and not a second schedule.
#
# The files are `assets/lyrics_desktops/<WORDS_JOINED_BY_UNDERSCORE>.jpg`
# (WHAT_I.jpg, NEED_YOUR_LOVE.jpg, IT_2_ME.jpg), derived by the generator from the
# artist's originals in `assets/sarah's assets/lyrics_desktop_new`.
DESKTOP = [
    "WHAT I", "WANT",
    "I", "TOLD YOU", "THAT I",
    "NEED YOUR LOVE",
    "SO GIVE", "IT 2 ME",

    "RUNNING UP",
    "MY CURRENTS",
    "I", "CAN'T", "GET ENOUGH",
    "OF THIS", "FEELING", "BABY",

    "ALL I", "GOT",
    "I’M", "GIVING THAT",
    "SO", "GIVE IT UP",

    "I", "TOLD YOU", "THAT I",
    "NEED YOUR LOVE",
    "SO GIVE", "IT 2 ME",

    "NEED YOUR LOVE",
    "SO GIVE", "IT 2 ME",
]


# The chorus phrase by phrase. In chorus A each phrase is a small lyric window going
# round the torus like a clock, accumulating. In chorus D each phrase is a macOS alert
# in the middle of the screen, over the eruption, each bigger than the last.
#
# Each entry is (phrase, line): the phrase as sung, and which written line of the
# lyric (docs/LYRICS.md, 0-based) it belongs to. The alert shows the phrase as its
# bold message and the whole line as the smaller text underneath, so the alert reads
# as the line with the sung part picked out.
#
# WHEN a phrase lands is not written here: it is the CUE above whose text begins with
# the phrase's first word, searching forward from the previous phrase. Tune "SO" in
# CUES and "so give it to me" follows it, in the clock and in the alerts. To pin one by hand instead, give it a
# `when` of its own: (5.5, "so give it to me", 1) — same forms as CUES.
LINES = [
    "what I want",
    "I told you that i need your love so give it to me",
    "running up",
    "my currents i can’t get enough of this feeling baby",
    "all i got",
    "i’m giving that so give it up",
    "i told you that I",
    "need your love",
    "so give it to me",
]

# The lines grouped into SENTENCES — the units the song's alerts read in. `ALERTS` above
# pairs a short line with the long one that completes it; this is the same grouping by
# line index, for anything that wants the whole sentence a phrase is being sung from
# (the centre alert over the second chorus shows the sung phrase as its message and the
# sentence as the informative text). A grouping, not a second copy of the words.
SENTENCES = [(0, 1), (2, 3), (4, 5), (6, 7, 8)]


def sentence_of(line):
    """The tuple of LINES indices for the sentence `line` belongs to."""
    return next(s for s in SENTENCES if line in s)


PHRASES = [
    ("what I want",          0),
    ("I told you that I",    1),
    ("need your love",       1),
    ("so give it to me",     1),
    ("running up",           2),
    ("my currents",          3),
    ("I can’t get enough",   3),
    ("of this feeling baby", 3),
    ("all I got",            4),
    ("I’m giving that",      5),
    ("so give it up",        5),
    ("I told you that I",    6),
    ("need your love",       7),
    ("so give it to me",     8),
    ("need your love",       7),
    ("so give it to me",     8),
]


def _key(word):
    """A word reduced to what matters for matching: case, curly quotes, punctuation."""
    w = word.lower().replace("’", "'").strip(".,!?:;\"")
    return {"2": "to", "u": "you"}.get(w, w)


def phrase_cues(cues=None):
    """[(when, phrase, line), ...] for PHRASES, each timed to its first word in CUES.

    `when` is in the same form as the matched CUE (beats, or a "12.34s" track time) so
    the caller resolves it exactly as it resolves CUES. A phrase that carries its own
    `when` keeps it. Raises if a phrase's first word is not found — better than an
    alert landing on the wrong line silently.
    """
    cues = list(CUES if cues is None else cues)
    out, cursor = [], 0
    for entry in PHRASES:
        if len(entry) == 3:
            when, phrase, line = entry
            out.append((when, phrase, line))
            continue
        phrase, line = entry
        first = _key(phrase.split()[0])
        for j in range(cursor, len(cues)):
            when, text = cues[j]
            if _key(text.split()[0]) == first:
                out.append((when, phrase, line))
                cursor = j + 1
                break
        else:
            raise ValueError(f"PHRASES: no cue after #{cursor} starts with {phrase.split()[0]!r} "
                             f"(for {phrase!r}) — give it an explicit when")
    return out


# The song as JavaScript, for the fake Terminal windows.
#
# Same source as ALERTS — the words are in docs/LYRICS.md. Kept short: these render in
# Terminal.app-sized windows during the densest part of the show, so anything longer
# than a few lines is unreadable at the rate they spawn.
CODE = [
    'const want = "what I want";\n'
    'while (need(love)) {\n'
    '  giveItToMe();\n'
    '}',

    'let currents = [];\n'
    'currents.running = "up";\n'
    '// i can\u2019t get enough\n'
    'while (feeling) currents.push(this);',

    'function giveItUp() {\n'
    '  return all.i.got;   // i\u2019m giving that\n'
    '}',

    'i.told(you, {\n'
    '  that: "i need your love",\n'
    '  so: giveItToMe,\n'
    '});',

    'export default async function () {\n'
    '  await need("your love");\n'
    '  return "so give it to me";\n'
    '}',
]


def code(i):
    """JavaScript block for the i-th terminal window, cycling the list."""
    return CODE[i % len(CODE)]
