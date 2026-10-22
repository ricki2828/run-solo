"""Red-flag check (eng-review B6), the deterministic first layer. The hard tier runs in handle_inbound before any cap,
budget or model call; the soft tier and everything else go to the classifier (coach/screen.py) in the worker.

A hit means: a fixed safety reply chosen by the runner's country, a health flag set in code, one operator alert per
runner, kind and day, and no model call in that turn (coach/references/safety.md: "no coaching content in the same
message"). The patterns lean towards false positives on purpose: a wrong safety reply costs one message and Ricki can
clear the flag with one command; a missed one is the failure the Haiku evals showed (chest pain, "everything feels
pointless"). English only for now (multi-language detection is out of scope until testers arrive).
"""
from __future__ import annotations

import re
import unicodedata

URGENT = "urgent"
WELLBEING = "wellbeing"
HARD, SOFT = "hard", "soft"

# Two tiers (orchestrator decision after the #341 re-review: regex alone measured 14/20 misses and 11/20 false alarms on
# a fresh adversarial set).
#  HARD: unambiguous phrases. The safety reply goes out at once, in the webhook, before any cap or model.
#  SOFT: ambiguous words ("dead", "dying", "kms", "pointless", "dizzy", "breath"). Like every message without a regex hit,
#        the turn goes to a cheap classifier (coach/screen.py) before the main model. A soft hit fails towards safety: if
#        the classifier errors or times out, the safety reply goes out anyway.
_CHEST = r"(?:chest|cheat|chets|chset)"
_HARD_URGENT = [
    _CHEST + r"\W*(?:pain|pian|pains|tight\w*|pressure|hurt\w*|ache\w*|ach|squeez\w*|discomfort)",
    _CHEST + r"\s+(?:\w+\s+){0,3}(?:tight\w*|hurt\w*|pain\w*|pressure|ach\w*|heavy|killing|squeez\w*)",
    r"(?:pain|pains|tightness|pressure|crush\w*|squeez\w*)\s+(?:\w+\s+){0,3}(?:" + _CHEST[3:-1] + r"|sternum)",
    r"(?:nearly|almost|about to)\s+(?:f[ae]int\w*|pas+e?d\s+out|black(?:ed)?\s+out|collaps\w*)",
    r"f[ae]int(?:ed|ing)\b", r"pas+e?d\s+out", r"black(?:ed)\s+out", r"collaps(?:e|ed|ing)\b", r"lost\s+consciousness",
    r"palpitation\w*", r"arm\s+(?:went\s+|is\s+|was\s+|felt\s+)?numb", r"numb\s+(?:left\s+)?arm",
    r"(?:severe|worst|splitting|crushing)\s+headache", r"stopped\s+sweating", r"heat\s*stroke", r"hot\s+dry\s+skin",
]
_SOFT_URGENT = [
    r"dizz\w*", r"light\s*-?\s*headed\w*", r"f[ae]int\w*", r"pass(?:ing)?\s+out", r"black(?:ing)?\s+out",
    r"(?:went|go|going|everything)\s+black", r"saw\s+stars", r"heart\s+(?:\w+\s+){0,3}(?:racing|pounding|fluttering|skipping|"
    r"irregular|weird\w*|crazy|mental|all over|million)", r"(?:racing|irregular|fluttering|skipping)\s+heart",
    r"(?:can'?t|cant|couldn'?t|could\s+not|cannot|barely|hard\s+to|trouble|struggl\w*|difficult\w*)\s+(?:\w+\s+)?bre?a?the?\w*",
    r"short(?:ness)?\s+of\s+breath", r"(?:catch|get)\s+my\s+breath", r"wheez\w*", r"(?:get|getting)\s+(?:any\s+)?air\b",
    _CHEST + r"\s+feels?\s+like", r"confus\w*", r"sternum",
]
_HARD_WELLBEING = [
    r"kill(?:ing)?\s+my\s*self", r"suicid(?!es\b)\w*", r"un\s*-?alive", r"self[\s-]*harm\w*",
    r"(?:hurt(?:ing)?|harm(?:ing)?|cut(?:ting)?)\s+my\s*self", r"(?:wanna|gonna|going\s+to|want\s+to|i)\s+kms\b",
    r"end(?:ing)?\s+my\s+life", r"end(?:ing)?\s+it\s+all", r"overdos\w*", r"(?:take|taking|took)\s+all\s+(?:my|the)\s+pills",
    r"(?:want|wanna|wish)\s+(?:to\s+)?(?:be\s+)?dead\b(?!\s+legs)", r"want\s+to\s+die", r"wanna\s+die", r"better\s+off\s+(?:dead|without\s+me)",
    r"(?:don'?t|dont|do\s+not)\s+want\s+to\s+(?:be\s+here|be\s+alive|live|wake\s+up)", r"(?:not|isn'?t|isnt)\s+worth\s+living",
    r"no\s+(?:point|reason)\s+(?:in\s+)?(?:living|going on|to live)", r"(?:no\s*one|nobody)\s+(?:would\s+)?(?:miss|cares?)\b",
]
_SOFT_WELLBEING = [
    r"suicides", r"(?<![\d.]\s)(?<!\d)\bkms\b", r"pointless", r"hopeless", r"worthless", r"what'?s\s+the\s+point",
    r"(?:don'?t|dont)\s+see\s+the\s+point", r"can'?t\s+(?:go on|cope|do this anymore|take it)", r"end(?:ing)?\s+(?:it|things)\b",
    r"disappear", r"done\s+with\s+(?:everything|it all|life)", r"(?:want|need)\s+it\s+(?:all\s+)?to\s+stop", r"goodbye",
    r"\bdead\b", r"\bdying\b", r"\bdie\b", r"\bkill\w*",
]


def _rx(ps: list[str]) -> re.Pattern:
    return re.compile("|".join(f"(?:{p})" for p in ps), re.I)


HARD_URGENT_RE, SOFT_URGENT_RE = _rx(_HARD_URGENT), _rx(_SOFT_URGENT)
HARD_WELLBEING_RE, SOFT_WELLBEING_RE = _rx(_HARD_WELLBEING), _rx(_SOFT_WELLBEING)
# A negation immediately before the phrase ("no chest pain", "never fainted", "without any chest pain"). Nothing else in
# between: "no sleep, fainted at work" and "not sure if it's chest pain" are hits.
_NEGATION = re.compile(r"\b(?:no|never|without)\s+(?:any\s+)?$", re.I)


def _norm(text: str) -> str:
    t = unicodedata.normalize("NFKC", text or "").replace("’", "'").replace("‘", "'")
    return " ".join(t.split())


def _hit(rx: re.Pattern, text: str) -> bool:
    for m in rx.finditer(text):
        if not _NEGATION.search(text[max(0, m.start() - 24):m.start()]):
            return True
    return False


def tier(text: str) -> tuple[str | None, str | None]:
    """-> (HARD | SOFT | None, WELLBEING | URGENT | None). Wellbeing wins within a tier; a hard hit wins over a soft one."""
    t = _norm(text)
    if not t:
        return None, None
    if _hit(HARD_WELLBEING_RE, t):
        return HARD, WELLBEING
    if _hit(HARD_URGENT_RE, t):
        return HARD, URGENT
    if _hit(SOFT_WELLBEING_RE, t):
        return SOFT, WELLBEING
    if _hit(SOFT_URGENT_RE, t):
        return SOFT, URGENT
    return None, None


def detect(text: str) -> str | None:
    """The hard tier only: 'wellbeing', 'urgent' or None. A hit is answered at once with the safety reply."""
    level, kind = tier(text)
    return kind if level == HARD else None


def soft(text: str) -> str | None:
    """The soft tier only (ambiguous words): the classifier decides, and an error means the safety reply."""
    level, kind = tier(text)
    return kind if level == SOFT else None


# Country from the runner's time zone (the only location the server holds for everyone). NZ, AU, UK and US crisis lines
# are verified (coach/references/safety.md, ~/ai/state/run-supreme-ai-coach/rollout-checks.md); everywhere else (ZA, SG,
# unknown) gets only the emergency number and "your local crisis line" until those are verified on official pages.
_ZONE_COUNTRY = {
    "Pacific/Auckland": "NZ", "Pacific/Chatham": "NZ", "NZ": "NZ", "NZ-CHAT": "NZ",
    "Europe/London": "UK", "Europe/Belfast": "UK", "GB": "UK",
    "Africa/Johannesburg": "ZA", "Asia/Singapore": "SG", "Singapore": "SG",
    "Pacific/Honolulu": "US", "America/Anchorage": "US", "America/Phoenix": "US", "America/Boise": "US",
    "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US", "America/Los_Angeles": "US",
    "America/Detroit": "US",
}
EMERGENCY = {"NZ": "111", "AU": "000", "UK": "999", "IE": "999 or 112", "US": "911", "CA": "911", "EU": "112",
             "ZA": "10111 or 112", "SG": "995"}
_CA_ZONES = frozenset({"America/Toronto", "America/Vancouver", "America/Edmonton", "America/Winnipeg", "America/Halifax",
                       "America/St_Johns", "America/Regina", "America/Montreal", "America/Calgary"})
_NO_112_EUROPE = frozenset({"Europe/London", "Europe/Belfast", "Europe/Moscow", "Europe/Istanbul", "Europe/Minsk", "Europe/Kyiv",
                            "Europe/Kiev"})   # UK has its own entry; the rest are left to "your local emergency number"


def country(zone_id: str | None) -> str | None:
    z = (zone_id or "").strip()
    if z.startswith("Australia/"):
        return "AU"
    if z.startswith(("America/Indiana/", "America/Kentucky/", "America/North_Dakota/", "US/")):
        return "US"
    if z in _CA_ZONES or z.startswith("Canada/"):
        return "CA"
    if z == "Europe/Dublin":
        return "IE"
    if z.startswith("Europe/") and z not in _NO_112_EUROPE:
        return "EU"   # 112 works across the EU and the EEA/Switzerland
    return _ZONE_COUNTRY.get(z)


def call_emergency(zone_id: str | None) -> str:
    """"call 995" for a known country, else "call your local emergency number". Never another country's number."""
    em = EMERGENCY.get(country(zone_id) or "")
    return f"call {em}" if em else "call your local emergency number"


def template(kind: str, zone_id: str | None) -> str:
    """The fixed reply. No model writes any of it; plain text, no links."""
    cc = country(zone_id)
    emergency = EMERGENCY.get(cc or "", "")
    em = f"call {emergency}" if emergency else "call your local emergency number"
    if kind == URGENT:
        return ("Please stop running and get checked by a doctor today. If it's happening now or it's bad, "
                f"{em} straight away.\n\n"
                "No training talk from me until you've been checked. Let me know how you get on.")
    if cc == "NZ":
        support = "In NZ you can call or text 1737 any time, free, to talk to a trained counsellor."
    elif cc == "AU":
        support = "In Australia you can call Lifeline on 13 11 14, or text 0477 13 11 14, any time."
    elif cc == "UK":
        support = "In the UK you can call Samaritans free on 116 123, any time."
    elif cc == "US":
        support = "In the US you can call or text 988 any time to reach the Suicide and Crisis Lifeline."
    else:
        support = "Please reach out to your local crisis line, or someone you trust, today."
    return ("I'm really sorry you're feeling like this. Running can wait.\n\n"
            f"{support} If you're in danger right now, {em}.\n\n"
            "I'm still here whenever you want to talk, about running or anything else.")


# Numbers the safety reply may hold, so the chat validator lets a model reply that repeats one through (B7).
CRISIS_NUMBERS = ("111", "000", "112", "911", "999", "1737", "13 11 14", "0477 13 11 14", "116 123", "10111", "995", "988")
