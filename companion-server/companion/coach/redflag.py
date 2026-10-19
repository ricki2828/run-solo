"""Deterministic red-flag check (eng-review B6). Runs in handle_inbound before any cap, budget or model call.

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

# Physical red flags: stop running, get checked today (safety.md "Red flags").
_URGENT = [
    r"(?:chest|cheat|chets|chset)\s*(?:pain|pian|pains|tight\w*|pressure|hurt\w*|ache\w*|ach|squeez\w*|discomfort)",
    r"(?:chest|cheat|chets|chset)\s+(?:\w+\s+){0,2}(?:tight\w*|hurt\w*|pain\w*|pressure|ach\w*)",
    r"pain\s+(?:in|across|on)\s+(?:my|the)\s+chest",
    r"tight(?:ness)?\s+(?:in|across)\s+(?:my|the)\s+chest",
    r"(?:nearly|almost|about to)\s+(?:faint\w*|pass(?:ed)?\s+out|black(?:ed)?\s+out|collaps\w*)",
    r"faint(?:ed|ing)\b", r"(?:feel|felt|feeling|went|go|going)\s+(?:a\s+bit\s+|really\s+|very\s+)?faint\b", r"pass(?:ed|ing)?\s+out", r"black(?:ed|ing)?\s+out", r"collaps(?:e|ed|ing)\b",
    r"heart\s+(?:was\s+|is\s+|kept\s+)?(?:racing|pounding|fluttering|skipping|irregular|all over the place)",
    r"(?:racing|irregular|fluttering|skipping)\s+heart", r"palpitation\w*", r"heart\s+(?:beat|rate)\s+(?:went\s+)?(?:weird|crazy|irregular)",
    r"(?:couldn'?t|could not|can'?t|cannot|struggl\w+ to)\s+breathe?\b",
    r"(?:severe|worst|splitting|crushing)\s+headache",
    r"(?:felt|got|feeling|went)\s+(?:really\s+|very\s+|totally\s+)?confused\b(?!\s+(?:about|by|with|on)\b)",
    r"stopped\s+sweating", r"heat\s*stroke", r"hot\s+dry\s+skin",
    r"pain\s+(?:down|in)\s+(?:my\s+)?(?:left\s+)?arm\s+and\s+(?:jaw|chest)",
]
# Distress or crisis: drop the coaching, point to support (safety.md "Wellbeing").
_WELLBEING = [
    r"kill(?:ing)?\s+my\s*self", r"suicid\w*", r"self[\s-]*harm\w*", r"hurt(?:ing)?\s+my\s*self", r"end(?:ing)?\s+it\s+all",
    r"end\s+my\s+life", r"(?:want|wanna|wish)\s+(?:to\s+)?(?:be\s+)?dead", r"want\s+to\s+die", r"wanna\s+die",
    r"better\s+off\s+(?:dead|without\s+me)", r"(?:don'?t|do not)\s+want\s+to\s+(?:be\s+here|live|wake\s+up)",
    r"no\s+(?:point|reason)\s+(?:in\s+)?(?:living|going on|to live)", r"(?:everything|life)\s+(?:feels|is|seems)\s+(?:so\s+)?pointless",
    r"hopeless", r"can'?t\s+(?:go on|cope|do this anymore)", r"what'?s\s+the\s+point\s+(?:of|in)\s+(?:anything|living|life)",
]
URGENT_RE = re.compile("|".join(f"(?:{p})" for p in _URGENT), re.I)
WELLBEING_RE = re.compile("|".join(f"(?:{p})" for p in _WELLBEING), re.I)
# A negation right before the phrase ("no chest pain", "without any chest pain", "never fainted"). Deliberately narrow:
# "not sure if it's chest pain" is still a hit.
_NEGATION = re.compile(r"\b(?:no|without|zero|never|nil)\s+(?:\w+\s+)?$", re.I)


def _norm(text: str) -> str:
    t = unicodedata.normalize("NFKC", text or "").replace("’", "'").replace("‘", "'")
    return " ".join(t.split())


def _hit(rx: re.Pattern, text: str) -> bool:
    for m in rx.finditer(text):
        if not _NEGATION.search(text[max(0, m.start() - 24):m.start()]):
            return True
    return False


def detect(text: str) -> str | None:
    """'wellbeing', 'urgent' or None. Wellbeing wins when both appear: it is the reply that must not be missed."""
    t = _norm(text)
    if not t:
        return None
    if _hit(WELLBEING_RE, t):
        return WELLBEING
    if _hit(URGENT_RE, t):
        return URGENT
    return None


# Country from the runner's time zone (the only location the server holds for everyone). NZ and AU crisis lines are
# verified (coach/references/safety.md, ~/ai/state/run-supreme-ai-coach/rollout-checks.md); everywhere else gets only
# the emergency number and "your local crisis line" until the other lines are verified on official pages.
_ZONE_COUNTRY = {
    "Pacific/Auckland": "NZ", "Pacific/Chatham": "NZ", "NZ": "NZ", "NZ-CHAT": "NZ",
    "Europe/London": "UK", "Europe/Belfast": "UK", "GB": "UK",
    "Africa/Johannesburg": "ZA", "Asia/Singapore": "SG", "Singapore": "SG",
    "Pacific/Honolulu": "US", "America/Anchorage": "US", "America/Phoenix": "US", "America/Boise": "US",
    "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US", "America/Los_Angeles": "US",
    "America/Detroit": "US",
}
EMERGENCY = {"NZ": "111", "AU": "000", "UK": "999", "US": "911", "ZA": "10111 or 112", "SG": "995"}


def country(zone_id: str | None) -> str | None:
    z = (zone_id or "").strip()
    if z.startswith("Australia/"):
        return "AU"
    if z.startswith(("America/Indiana/", "America/Kentucky/", "America/North_Dakota/", "US/")):
        return "US"
    return _ZONE_COUNTRY.get(z)


def template(kind: str, zone_id: str | None) -> str:
    """The fixed reply. No model writes any of it; plain text, no links."""
    cc = country(zone_id)
    emergency = EMERGENCY.get(cc or "", "")
    em = f"call {emergency}" if emergency else "call your local emergency number (112 or 911 in most places)"
    if kind == URGENT:
        return ("Please stop running and get checked by a doctor today. If it's happening now or it's bad, "
                f"{em} straight away.\n\n"
                "No training talk from me until you've been checked. Let me know how you get on.")
    if cc == "NZ":
        support = "In NZ you can call or text 1737 any time, free, to talk to a trained counsellor."
    elif cc == "AU":
        support = "In Australia you can call Lifeline on 13 11 14, or text 0477 13 11 14, any time."
    else:
        support = "Please reach out to your local crisis line, or someone you trust, today."
    return ("I'm really sorry you're feeling like this. Running can wait.\n\n"
            f"{support} If you're in danger right now, {em}.\n\n"
            "I'm still here whenever you want to talk, about running or anything else.")


# Numbers the safety reply may hold, so the chat validator lets a model reply that repeats one through (B7).
CRISIS_NUMBERS = ("111", "000", "112", "911", "999", "1737", "13 11 14", "0477 13 11 14", "10111", "995", "988")
