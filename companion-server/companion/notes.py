"""Run notes: text the runner typed after tapping "Add a note".

A note is used in exactly two deterministic ways, and in no others:
  1. the weekly recap quotes it back ("You said: ...");
  2. a few plain keywords soften the next suggestion and the touches (see `soften`).
It is NEVER put in a prompt, a render request, a log line or a card the writer sees. The text lives in its own table
(`run_notes`) rather than a `runs` column, so no `SELECT * FROM runs` can carry it anywhere by accident.
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta

NOTE_MAX_CHARS = 500
NOTE_MODE_MIN = 10          # "Add a note" waits this long for the text
SOFTEN_DAYS = 7             # a flagged note softens suggestions for this long after it was written
QUOTE_MAX_CHARS = 200       # the recap shows at most this much of a note

# Stems, matched at the start of a word: niggle(s), sore(ness), injury/injured, tired, sick(ness), and the conditions
# that make a slow run expected: flight, jet lag, haze, smoke (not "smoked it"), heat, hills that hurt, travel. "not sore
# today" still softens. A gentler suggestion is the safe error.
FLAG_RE = re.compile(
    r"\b(?:niggl|sore|injur|tired|sick|flight|jet\s?lag|travel|haz[ey]|smok(?:e|y|ing)\b|heat\b|steep hills?|"
    r"hills? (?:killed|destroyed|hurt|wrecked|ruined|cooked|were (?:brutal|tough|hard)|was (?:brutal|tough|hard)))", re.I)


def clean(text: str) -> str:
    """One line, printable characters only. The caller checks the length."""
    printable = "".join(ch if ch.isprintable() or ch.isspace() else " " for ch in text)
    return " ".join(printable.split())


def flagged(note: str) -> bool:
    return bool(FLAG_RE.search(note))


def soften(notes: list[tuple[str, datetime]], now: datetime) -> bool:
    """True when a note written in the last SOFTEN_DAYS (and not in the future) carries a flag keyword."""
    lo = now - timedelta(days=SOFTEN_DAYS)
    return any(lo <= at <= now and flagged(n) for n, at in notes)


def quote(note: str) -> str:
    n = note if len(note) <= QUOTE_MAX_CHARS else note[:QUOTE_MAX_CHARS - 1].rstrip() + "..."
    return f"You said: “{n}”"
