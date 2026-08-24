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
