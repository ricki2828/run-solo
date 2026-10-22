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
URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)
SERVER_TAG_RE = re.compile(r"<\s*(/?)\s*(host_note|chips)\b", re.I)
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
            if not href or not re.match(r"https?://", href.group(1), re.I) or "a" in stack:
                continue   # an unlinkable or nested <a> is dropped; its text stays
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


def defang(text: str) -> str:
    """Runner words with the server's own tags made inert, so typed "<host_note>" is never read as the server."""
    return SERVER_TAG_RE.sub(lambda m: "\u2039" + m.group(1) + m.group(2), text or "")


def _urls(text: str) -> set[str]:
    return {u.rstrip(".,;:!?)]}") for u in URL_RE.findall(text or "")}


# ------------------------------------------------------------------------------------------------ medical safety (coach PR3)
# Always on: no dosing, no diagnosis (coach plan section 4.3). `mode` "amber" / "red72" (an injury was reported in the runner's
# words, or a red one in the last 72 h): also no pace figures and no push-on training advice beyond rest and modify.
# Plan section 4.3: the coach never names a medicine, supplement or injection, with or without a dose.
_DRUGS = (r"ibuprofen|ibuprophen|nurofen|advil|brufen|motrin|paracetamol|paracetemol|acetaminophen|panadol|panadeine|tylenol|naproxen|"
          r"aleve|naprosyn|aspirin|asprin|diclofenac|voltaren|voltarol|celecoxib|celebrex|indomethacin|ketoprofen|meloxicam|codeine|"
          r"tramadol|morphine|opioids?|cortisone|corticosteroids?|prednisone|prednisolone|steroids?|nsaids?|anti-?inflammator\w+|"
          r"analgesics?|painkill\w+|pain\s*killers?|deep\s+heat|tiger\s+balm|ben-?gay|salonpas|biofreeze|arnica|"
          r"(?:take|taking|start|try|add)\s+(?:a\s+|an\s+|some\s+|the\s+)?(?:\w+\s+)?supplements?|"
          r"(?:cortisone|steroid|cortico\w*|hyaluron\w*|prp|botox)\s+(?:shots?|injections?|jabs?)|injections?")
# A scan the coach tells them to get is refused; "a physio can tell you if you need a scan" (the professional's call) is fine.
_IMAGING = re.compile(r"\b(?:get|book|order|arrange|ask\s+for|go\s+for)\s+(?:an?\s+|the\s+)?(?:mri|x-?ray|ultrasound|ct|scan)\b|"
                      r"(?<!if )(?<!whether )\byou\s+(?:need|should\s+have|should\s+get|must\s+get)\s+(?:an?\s+|the\s+)?(?:mri|x-?ray|ultrasound|ct|scan)\b", re.I)
_PILL = re.compile(r"\b(?:tablets?|pills?|capsules?|caplets?)\b", re.I)
_DOSE_RE = re.compile(r"\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|\u00b5g|ug|milligrams?|micrograms?|ml|millilit\w+|iu)\b|"
                      r"\b(?:one|two|three|four|five|six|a\s+couple\s+of|a\s+few|half(?:\s+a)?|\d+)\s+(?:\w+\s+)?"
                      r"(?:tablets?|pills?|capsules?|caplets?|tabs|doses?|sachets?)\b", re.I)
_COND = (r"(?:it\s*band|iliotibial\w*|itbs?|runner'?s\s+knee|patell\w+|plantar\s+fasci\w+|shin\s+splints?|stress\s+(?:fracture|reaction)|"
         r"fractur\w+|tendin\w+|tendon\w*|achilles\s+\w+|dvt|deep\s+vein\s+thrombosis|thrombosis|blood\s+clot|sprain\w*|"
         r"torn\s+\w+|tears?|ruptur\w+|menisc\w+|bursitis|sciatica|compartment\s+syndrome|hernia|osteo\w+|arthritis|gout|"
         r"heat\s*stroke|concussion|infection|strains?|slipped\s+disc|pinched\s+nerve)")
_DIAG_LEAD = (r"(?:you(?:'ve\s+got|'ve|\s+have|\s+got)|it(?:'s|\s+is)|this\s+is|that(?:'s|\s+is)|looks?\s+like|sounds?\s+like|"
              r"(?:is|are)\s+(?:probably|likely|definitely|clearly)|diagnosis\s+(?:is|as)|probably|likely|definitely|clearly|classic|textbook)")
_DIAG_RE = re.compile(_DIAG_LEAD + r"\s+(?:(?:probably|likely|just|a|an|the|some|your|classic|textbook|mild|slight|minor|clear|case\s+of)\s+)*"
                      r"(?:\w+\s+)?" + _COND + r"\b", re.I)
_PACE_FIG = re.compile(r"\b\d{1,2}:\d{2}\b|/\s?km\b|\bper\s+km\b|\bmin/km\b", re.I)
_TRAIN_VERBS = (r"(?:run|do|try|go\s+for|aim\s+for|hit|add|include|schedule|keep|stick\s+(?:to|with)|carry\s+on\s+with|get)")
_INTENSITY = re.compile(r"\b" + _TRAIN_VERBS + r"\b[^.!?\n]{0,25}?\b(?:tempo|intervals?|strides|fartlek|hill\s+(?:repeats|reps|sprints)|"
                        r"threshold|race\s+pace|speed\s*work|4x4|reps|sprints?|long\s+run|workout)s?\b|"
                        r"\b(?:increase|build|ramp|extend|boost|up)\w*\s+[^.!?\n]{0,20}?\b(?:mileage|volume|distance|km|intensity|pace|load)\b|"
                        r"\bpush\s+(?:through|on|it|harder|yourself)\b|\brun\s+(?:through|it\s+off)\b|\brun\s+on\s+it\b", re.I)
_RUN_SUGGEST = re.compile(
    r"\b(?:easy\s+(?:run|jog)s?|jog(?:ging)?|go\s+for\s+an?\s+(?:run|jog)|run\s+(?:today|tomorrow|tonight)|"
    r"(?:keep|continue|carry\s+on|resume|start|begin|restart|go|get\s+back\s+to|return\s+to|ease\s+back\s+into)\s+(?:on\s+)?(?:running|jogging)|"
    r"(?:run|jog)\s+(?:\w+\s+){0,2}(?:easy|easily|slow\w*|gently|lightly|short|shorter|\d+)|"
    r"\d+(?:[.,]\d+)?\s*(?:km|kms|k|miles?|mi|min|mins|minutes?)\s+(?:\w+\s+){0,2}(?:easy|run|jog|slow\w*|steady|gentle)|"
    r"\d+\s*x\s*\d+|\d+\s+(?:reps?|repeats?|intervals?|strides?))\b", re.I)


def medical_check(text: str, mode: str | None = None) -> str | None:
    """-> "dosing" | "diagnosis" | "training_advice" | None."""
    t = " ".join((text or "").replace("\u2019", "'").split())
    if _DOSE_RE.search(t):
        return "dosing"
    drug = re.compile(r"\b(?:" + _DRUGS + r")\b", re.I)
    if drug.search(t) or _IMAGING.search(t) or _PILL.search(t):
        return "dosing"
    if _DIAG_RE.search(t):
        return "diagnosis"
    if mode in ("amber", "red72"):
        if _PACE_FIG.search(t) or _INTENSITY.search(t) or re.search(r"\b\d+\s*x\s*\d+", t) or (mode == "red72" and _RUN_SUGGEST.search(t)):
            return "training_advice"
    return None


def check(reply: str, sources: Iterable[str], link_sources: Iterable[str] | None = None, mode: str | None = None) -> str | None:
    """None when the reply may go out, else the reason it may not. Links are grounded only in `link_sources` (tool results;
    default: all sources), whole URL, scheme to the end of the token. `mode` is the injury mode of the turn (see medical_check)."""
    sources = list(sources)
    link_hay = "\n".join(s or "" for s in (sources if link_sources is None else link_sources))
    link_urls = _urls(link_hay)
    raw = reply or ""
    text = plain(raw)
    if not text.strip():
        return "empty"
    if len(text) > MAX_REPLY_CHARS:
        return "too_long"
    bad = medical_check(text, mode)
    if bad:
        return bad
    haystack = "\n".join(s or "" for s in sources)
    haystack_n = _norm(haystack)
    for href in HREF_RE.findall(raw):   # a link goes out only when a tool handed it over, character for character
        if _html.unescape(href).rstrip(".,;:!?)]}") not in link_urls:
            return "link"
    shown = _urls(text)
    for u in shown:
        if u not in link_urls:
            return "link"
    rest = URL_RE.sub(" ", text)
    for m in LINK_RE.finditer(rest):
        if m.group(0).lower() in ("http://", "https://"):
            return "link"
        if m.group(0) not in link_hay:
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
