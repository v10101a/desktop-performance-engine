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


# The lyric video: the chorus, card by card.
#
# Every line of the song is chorus (it repeats each time), so one pass of these is one
# chorus. Each entry is (when, text). ONE list drives both choruses: chorus A shows
# each cue as a fullscreen card, chorus B opens the same cue as a small window round
# the torus, at the same point of its own chorus. The long lines are split into more
# than one card so each card is a phrase, not a paragraph.
#
# `when` is either of:
#   4.0      beats from the START of the chorus (32 beats = 8 bars long; 0.4685 s/beat)
#   "34.10s" a time in the TRACK, as heard in chorus A — read it off the waveform or a
#            player's clock and the card lands on that instant. Mix the two freely.
#
# To tune by ear:  edit the numbers, then  tools/tune_lyrics.sh  (chorus A) or
# tools/tune_lyrics.sh b  (the clock) — it regenerates the show, prints when every card
# lands, and plays just that chorus. Cards alternate blue-on-white / white-on-blue in
# the order given, so inserting one flips the colours after it.
#
# These beat offsets are a FIRST PASS placed by eye on the bar grid, not by ear.
CUES = [
    (0.0,  "what I want"),
    (2.0,  "I told you that I"),
    (4.0,  "need your love"),
    (6.0,  "so give it to me"),
    (8.0,  "running up"),
    (10.0, "my currents"),
    (11.0, "I can’t"),
    (12.0, "get enough"),
    (14.0, "of this feeling baby"),
    (16.0, "all I got"),
    (18.0, "I’m giving that"),
    (20.0, "so give it up"),
    (22.0, "I told you that I"),
    (24.0, "need your love"),
    (26.0, "so give it to me"),
    (28.0, "need your love"),
    (30.0, "so give it to me"),
]


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
