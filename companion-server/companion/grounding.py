"""Number and unit grounding shared by the card writer and the coach chat validator (eng-review B7).

Only the extraction lives here. Each caller keeps its own rules about which numbers are allowed and what else is banned:
the card rules (BANNED, PHONE, FILLER) stay in writer.py, the chat profile in coach/validator.py.
"""
from __future__ import annotations

import re

NUM_RE = re.compile(r"\d+(?:[:.]\d+)*")
NUM_WORDS = re.compile(
    r"\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|"
    r"seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|"
    r"dozen|twice|thrice)\b", re.I)
# Units are compared in canonical form, so "kilometres" == "km" but "miles" != "km".
UNIT_CANON = {
    "km": "km", "kms": "km", "kilometre": "km", "kilometres": "km", "kilometer": "km", "kilometers": "km",
    "mi": "mi", "mile": "mi", "miles": "mi",
    "m": "m", "metre": "m", "metres": "m", "meter": "m", "meters": "m",
    "min": "min", "mins": "min", "minute": "min", "minutes": "min",
    "h": "h", "hr": "h", "hrs": "h", "hour": "h", "hours": "h",
    "s": "s", "sec": "s", "secs": "s", "second": "s", "seconds": "s",
    "day": "day", "days": "day", "week": "week", "weeks": "week", "month": "month", "months": "month",
    "kg": "kg", "lb": "lb", "lbs": "lb", "ft": "ft", "feet": "ft", "foot": "ft", "bpm": "bpm", "%": "%",
    "kcal": "kcal", "cal": "kcal",
}
# Distance and mass words are checked even without a number ("fewer miles"); time words are not
# ("second half", "in recent days" are ordinary English).
LONG_UNITS = {"kilometre", "kilometres", "kilometer", "kilometers", "mile", "miles", "metre", "metres", "meter",
              "meters", "feet", "kcal"}
UNIT_AFTER_NUM = re.compile(r"\d[\d:.]*\s*(/?[A-Za-z%]+(?:/[A-Za-z]+)?)")


def numbers_in(text: str) -> set[str]:
    return set(NUM_RE.findall(text))


def units_in(text: str, loose: bool) -> set[str]:
    """Canonical units used next to a number; with loose=True also unambiguous unit words anywhere."""
    out: set[str] = set()
    for m in UNIT_AFTER_NUM.finditer(text):
        for part in m.group(1).lower().split("/"):
            if part in UNIT_CANON:
                out.add(UNIT_CANON[part])
    if loose:
        for w in re.findall(r"[A-Za-z]+", text.lower()):
            if w in LONG_UNITS:
                out.add(UNIT_CANON[w])
    return out
