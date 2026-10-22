"""Chat validator profile (eng-review B7). Separate from the card rules in writer.py.

Allowed numbers = tool results + the runner's own messages + earlier coach replies (already checked) + a short list of
skill constants (guardrail percentages, session names, crisis numbers). A bare small count ("2 easy runs") is allowed
without a source; any number with a distance, time or pace unit must be grounded. "doctor" and "physio" are fine here
(safety.md needs them). Links and phone numbers are allowed only when they appear verbatim in a source (a tool result);
anything else fails. A reply that fails gets ONE repair turn with the reason (chat.py), then the template, counted.

The reply the model writes is plain text with a tiny HTML subset (<b>, <i>, <a href> to a grounded link) and an optional
trailing <chips>A|B|C</chips> block. `split_chips` takes the block off, `check` judges the text, `render_html` makes the
Telegram-safe HTML (everything else escaped).
"""
from __future__ import annotations

import html as _html
import re
from typing import Iterable

from ..grounding import NUM_WORDS, UNIT_CANON, numbers_in, units_in
from .redflag import CRISIS_NUMBERS

# Numbers the skill itself states (coach/references/plan-building.md guardrails, coaching-method.md, session names).
SKILL_CONSTANTS = frozenset({
    "4x4", "4", "3", "30/30", "30", "400", "800", "1", "10", "20", "35", "75", "70", "80", "14", "15", "2", "5",
    "3-5", "1-2", "2-3", "4-6", "4-20", "20-30", "80/20",
})
SKILL_NUMBERS = frozenset(n for c in SKILL_CONSTANTS for n in re.findall(r"\d+", c))
PERCENT_CONSTANTS = frozenset({"10", "20", "25", "30", "35", "70", "75", "80"})
BARE_COUNT_MAX = 12           # "2 easy runs", "4x4", "day 3": counts this small need no source when no unit follows
LINK_RE = re.compile(r"https?://|www\.|\b[\w-]+\.(?:com|co|nz|au|io|org|net|app|ly)\b", re.I)
PHONE_RE = re.compile(r"\+?\d[\d\s-]{7,}\d")
MAX_REPLY_CHARS = 2500
MAX_CHIPS = 3
MAX_CHIP_CHARS = 24
MAX_CHIP_BYTES = 48   # Telegram callback_data is 64 bytes: `cc:<job>:<label>`
# Units every runner's data uses, so naming them never needs a source; foreign units (miles, kg, kcal, bpm) do.
COMMON_UNITS = {"km", "m", "min", "s", "h", "day", "week", "month", "%"}
# Units that make a number a measurement ("6 km", "5 min"); "3 days" or "2 weeks" is advice about time, not data.
MEASURE_UNITS = set(UNIT_CANON.values()) - {"day", "week", "month"}
_UNIT_TAIL = re.compile(r"\s*(/?[A-Za-z%]+(?:/[A-Za-z]+)?)")
# A spelled-out number used as a measurement ("twelve kilometres", "ten minutes"): cannot be grounded, so rejected.
NUM_WORD_UNIT = re.compile(NUM_WORDS.pattern + r"[\s-]+(?:km|kms|kilomet\w*|mi|miles?|metres?|meters?|min|mins|minutes?|"
                           r"hours?|hrs?|seconds?|secs?|percent|per\s+cent)\b", re.I)
DATE_RE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_BOLD = re.compile(r"\*\*(.+?)\*\*|__(.+?)__", re.S)
TAG_RE = re.compile(r"</?(?:b|i|a)(?:\s+href=\"[^\"<>]*\")?\s*>", re.I)
HREF_RE = re.compile(r"<a\s+href=\"([^\"<>]*)\"\s*>", re.I)
CHIPS_RE = re.compile(r"<chips>(.*?)</chips>", re.I | re.S)
CHIPS_OPEN_RE = re.compile(r"<chips>.*\Z", re.I | re.S)   # a block the model never closed
FOOTER_RE = re.compile(r"\n\n<i>· [^\n]*</i>\s*\Z")


def tidy(text: str) -> str:
    """Telegram-ready text: markdown the model sometimes adds becomes the HTML subset or plain text, bullets become dots,
    line breaks are kept. Em dashes stay (the voice uses them)."""
    t = _BOLD.sub(lambda m: "<b>" + (m.group(1) or m.group(2)) + "</b>", text or "")
    t = re.sub(r"^#{1,6}[ \t]+", "", t, flags=re.M)
    t = re.sub(r"^[ \t]*[-*][ \t]+", "• ", t, flags=re.M)
    lines = [ln.rstrip() for ln in t.strip().splitlines()]
    out, blank = [], 0
    for ln in lines:
        blank = blank + 1 if not ln else 0
        if blank <= 1:
            out.append(ln)
    return "\n".join(out).strip()


def split_chips(text: str) -> tuple[str, list[str]]:
    """(the text without its chips block, the chips). At most 3 chips of 24 characters (48 bytes); empty, repeated and
    tag-bearing ones are dropped. An unclosed block is cut off and ignored."""
    text = text or ""
    found = CHIPS_RE.findall(text)
    body = CHIPS_OPEN_RE.sub("", CHIPS_RE.sub("", text)).rstrip()
    chips: list[str] = []
    for raw in (found[-1].split("|") if found else []):
        label = " ".join(raw.split())
        if (not label or len(label) > MAX_CHIP_CHARS or len(label.encode()) > MAX_CHIP_BYTES or "<" in label
                or ">" in label or label in chips):
            continue
        chips.append(label)
    return body, chips[:MAX_CHIPS]


def with_chips(body: str, chips: Iterable[str]) -> str:
    chips = list(chips)
    return body + ("\n<chips>" + "|".join(chips) + "</chips>" if chips else "")


def strip_footer(text: str) -> str:
    """The operator cost footer is shown, never stored as the coach's words."""
    return FOOTER_RE.sub("", text or "")


def plain(text: str) -> str:
    """The text with the HTML subset removed (and entities undone): what the numbers and words are judged on."""
    return _html.unescape(TAG_RE.sub("", text or ""))


def render_html(text: str) -> str:
    """Telegram parse_mode=HTML for a checked reply. Only <b>, <i> and <a href="http(s)://...">, properly nested, survive;
    every other < > & is escaped, unclosed tags are closed and stray closers dropped."""
    out: list[str] = []
    stack: list[str] = []
    pos = 0
    text = text or ""
    for m in TAG_RE.finditer(text):
        out.append(_html.escape(text[pos:m.start()], quote=False))
        pos = m.end()
        tag = m.group(0)
        name = re.match(r"</?(\w+)", tag).group(1).lower()
        if tag.startswith("</"):
            if name in stack:
                while stack:
                    top = stack.pop()
                    out.append(f"</{top}>")
                    if top == name:
                        break
            continue
        if name == "a":
            href = HREF_RE.match(tag)
            if not href or not re.match(r"https?://", href.group(1), re.I):
                continue
            out.append('<a href="' + _html.escape(_html.unescape(href.group(1)), quote=True) + '">')
        else:
            out.append(f"<{name}>")
        stack.append(name)
    out.append(_html.escape(text[pos:], quote=False))
    out.extend(f"</{t}>" for t in reversed(stack))
    return "".join(out)


def _variants(nums: Iterable[str]) -> set[str]:
    """7.0 also allows 7; 40:00 also allows 40 (and 1:05:00 allows 1:05); a range 5:50-6:30 is split by numbers_in."""
    out = set()
    for n in nums:
        out.add(n)
        if re.fullmatch(r"\d+\.0", n):
            out.add(n[:-2])
        if re.fullmatch(r"\d+:00", n):
            out.add(n[:-3])
        m = re.fullmatch(r"(\d+:\d\d):00", n)
        if m:
            out.add(m.group(1))
    return out


def allowed_numbers(sources: Iterable[str]) -> set[str]:
    """Numbers grounded in the tool results and messages. Skill constants and crisis numbers are not in here: they are
    allowed only in their own form (no measure unit after them, or a whole phone string), see check()."""
    nums: set[str] = set()
    for s in sources:
        nums |= numbers_in(DATE_RE.sub(" ", s or ""))
    return _variants(nums)


def date_numbers(sources: Iterable[str]) -> set[str]:
    """Day, month and year of the dates in the sources ("2026-10-20" -> 2026, 10, 20). They may be said as dates ("the
    20th") but never ground a measurement ("20 km")."""
    out: set[str] = set()
    for s in sources:
        for y, m, d in DATE_RE.findall(s or ""):
            out |= {y, m, d, str(int(m)), str(int(d))}
    return out


def _unit_after(text: str, end: int) -> str | None:
    """The canonical measure unit right after a number ("6 km" -> km), else None. "3 days" is not a measurement."""
    u = _UNIT_TAIL.match(text, end)
    if not u:
        return None
    for p in u.group(1).lower().split("/"):
        canon = UNIT_CANON.get(p)
        if canon in MEASURE_UNITS:
            return canon
    return None


def _scrub_crisis(text: str) -> str:
    """Blank out whole crisis numbers ("call 111", "13 11 14") so their digits never count as data. A crisis number with
    a measure unit after it ("13 km") is not a phone number and stays to be checked."""
    for n in sorted(CRISIS_NUMBERS, key=len, reverse=True):
        # a full stop after it ends the sentence ("Call 111."); only "111.5" makes it part of another number
        rx = re.compile(r"(?<![\d:])(?<!\d\.)" + re.escape(n) + r"(?![\d:]|\.\d)")
        text = rx.sub(lambda m: m.group(0) if _unit_after(text, m.end()) else " " * len(m.group(0)), text)
    return text


def _norm(s: str) -> str:
    return re.sub(r"[\s-]", "", s)


def check(reply: str, sources: Iterable[str]) -> str | None:
    """None when the reply may go out, else the reason it may not."""
    sources = list(sources)
    raw = reply or ""
    text = plain(raw)
    if not text.strip():
        return "empty"
    if len(text) > MAX_REPLY_CHARS:
        return "too_long"
    haystack = "\n".join(s or "" for s in sources)
    haystack_n = _norm(haystack)
    for href in HREF_RE.findall(raw):   # a link goes out only when a tool handed it over, character for character
        if _html.unescape(href) not in haystack:
            return "link"
    for m in LINK_RE.finditer(text):
        if m.group(0) not in haystack:
            return "link"
    scrubbed = _scrub_crisis(text)
    for m in PHONE_RE.finditer(scrubbed):
        if _norm(m.group(0)) not in haystack_n:
            return "phone_like"
    if NUM_WORD_UNIT.search(text):
        return "spelled_measure"
    source_units = set()
    for s in sources:
        source_units |= units_in(s or "", loose=False) | units_in(s or "", loose=True)
    foreign = units_in(text, loose=True) - source_units - COMMON_UNITS
    if foreign:
        return "foreign_unit:" + ",".join(sorted(foreign))
    allowed = allowed_numbers(sources)
    dates = date_numbers(sources)
    for m in re.finditer(r"\d+(?:[:.]\d+)*", scrubbed):
        n = m.group(0)
        if n in allowed:
            continue
        unit = _unit_after(scrubbed, m.end())
        if unit is None and (n in SKILL_NUMBERS or n in dates or (n.isdigit() and int(n) <= BARE_COUNT_MAX)):
            continue   # a count, a session name or a guardrail with no measurement after it ("2 easy runs", "4x4")
        if unit == "%" and n in PERCENT_CONSTANTS:
            continue   # the plan-building guardrails ("10%", "35%", "75%")
        return f"ungrounded:{n}"
    return None
