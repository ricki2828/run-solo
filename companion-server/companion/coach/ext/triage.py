"""triage_check: the red / amber / green decision for a niggle, made here in code from structured answers, never by the model.
The model asks the runner, fills the answers, and words what comes back; it cannot lift or lower the level. Red carries no
training advice at all. See coach/references/injury-triage.md and the medical rules in the coach plan (section 4)."""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from ... import db
from .. import redflag

RULES = (
    "- MEDICAL. For any pain, injury, or worrying symptom, ask a couple of short questions, then call triage_check and follow its "
    "level: you never decide it. You never diagnose or guess a cause, not even softly (no \"could be an overuse thing\", no \"sounds like ordinary tightness\"). You never name or "
    "dose a medication, supplement, injection or scan, and never say to run through pain. On RED say to get this seen today, give "
    "its next_step, offer find_care(kind=urgent), name the emergency number when call_emergency is true, and give NO training, "
    "pace or plan advice in that reply. On AMBER say to stop the painful sessions (name the runner's actual next sessions when get_plan shows them), see a physio or GP "
    "if it persists, offer find_care, and end with a check-back about 48 hours out, by day. On GREEN give only the general advice the "
    "result carries in at most 5 sentences, say what would change it, and end with a 48 hour check-back. Cite only a source a tool "
    "returned.")

# Red flags: argument name -> (reason shown to the model, needs the emergency number now). Order is the order reasons come back.
RED: dict[str, tuple[str, bool]] = {
    "chest_breath_or_fainting": ("chest pain or pressure, trouble breathing, or fainting", True),
    "heat_illness_signs": ("possible heat illness: confusion, collapse, or hot skin after running in the heat", True),
    "cannot_bear_weight": ("cannot put weight on the leg", False),
    "deformity": ("the area looks out of shape", False),
    "numbness_tingling_weakness": ("numbness, tingling or weakness", False),
    "calf_swollen_hot_or_red": ("a swollen calf that is hot or red", False),
    "fever_with_joint_pain": ("fever together with joint pain", False),
    "severe_rest_or_night_pain": ("severe pain at rest or at night", False),
    "after_fall_or_impact": ("pain after a fall or a hard knock", False),
    "bone_pain_at_night": ("pain pinpointed on a bone that also wakes them at night (possible stress fracture)", False),
}
AMBER: dict[str, str] = {
    "swelling": "swelling",
    "changes_gait": "it changes how they run or makes them limp",
    "worsening": "it gets worse as they run",
    "sharp_or_stabbing": "the pain is sharp or stabbing",
    "bone_point_pain": "pain pinpointed on a bone (shin, foot or hip)",
}
AMBER_DAYS = 3        # lasting more than this many days is amber
AMBER_PAIN = 5        # pain of this many out of 10 or more is amber

NEXT_STEP = {
    "red": "Stop running. Get this seen by a doctor today, at urgent care or an emergency department. Do not train on it.",
    "amber": "Stop the painful sessions and keep easy movement pain-free. See a physio or GP if it has not settled in a few days.",
    "green": "Keep it easy and cut volume a little. Pain should stay at 3 out of 10 or below while you run and should not be worse the next morning. Check back in 48 hours.",
}
GREEN_CHANGES = "It would move to amber if it gets worse, swells, changes how you run, or hangs around past three days."


def _remember(ctx, level: str) -> None:
    """Amber and green are kept on the job (coach_jobs.niggle) so the proactive coach can check back 48 h later. Level only."""
    job_id = getattr(ctx, "job_id", None)
    if job_id is None or level not in ("amber", "green"):
        return
    try:
        with db.tx(ctx.settings.db_path) as c:
            c.execute("UPDATE coach_jobs SET niggle=? WHERE id=?", (level, job_id))
    except Exception:   # a note for later; never fails the triage
        pass


def call(name: str, args: dict, ctx) -> dict:
    out = _call(name, args)
    _remember(ctx, out.get("level", ""))
    return out


def _call(name: str, args: dict) -> dict:
    if name != "triage_check":
        raise ValueError("unknown tool")
    red = [k for k in RED if args.get(k) is True]
    if red:
        emergency = any(RED[k][1] for k in red)
        out = {"level": "red", "reasons": [RED[k][0] for k in red], "next_step": NEXT_STEP["red"], "training_advice": "none",
               "find_care_kind": "urgent", "call_emergency": emergency}
        if emergency:
            out["next_step"] = ("Stop running now. If it is happening now or severe, call your local emergency number. "
                                "Otherwise get seen by a doctor today.")
        return out
    amber = [AMBER[k] for k in AMBER if args.get(k) is True]
    days, pain = args.get("days_present"), args.get("pain_0_10")
    if days is not None and days > AMBER_DAYS:
        amber.append(f"it has lasted more than {AMBER_DAYS} days")
    if pain is not None and pain >= AMBER_PAIN:
        amber.append(f"pain of {AMBER_PAIN} out of 10 or more")
    if amber:
        return {"level": "amber", "reasons": amber, "next_step": NEXT_STEP["amber"], "training_advice": "easy_pain_free_only",
                "find_care_kind": "physio", "call_emergency": False}
    return {"level": "green", "reasons": ["no warning signs reported"], "next_step": NEXT_STEP["green"],
            "training_advice": "general_load_management", "what_would_change_it": GREEN_CHANGES,
            "find_care_kind": None, "call_emergency": False, "check_back_hours": 48}


# ------------------------------------------------------------------------------------------------ the runner's own words
# The server runs this table on what the runner TYPED, before any model call (chat._claim). The model's triage_check is an
# extra, not the gate. Each pattern has a group `k` marking the symptom words: a negation among the few words before `k` in
# the same clause ("no numbness", "my calf isn't swollen") clears that hit. The patterns lean towards a false red on purpose.
_NEG_WORDS = frozenset(
    "no not never without nothing none zero dont don't doesnt doesn't didnt didn't isnt isn't wasnt wasn't havent haven't hasnt "
    "hasn't arent aren't aint ain't nor neither".split())
_CLAUSE_BREAK = re.compile(r"[,.;:!?\n]|\b(?:but|however|although|though|except)\b", re.I)
_CHEST = r"ch[ea]?[st]{1,2}\w*"
_PAIN_CTX = re.compile(r"\b(?:pain\w*|hurt\w*|sore\w*|ache\w*|aching|niggl\w*|injur\w*|tweak\w*|strain\w*|sprain\w*|pulled|throb\w*)", re.I)

# code -> (reason, needs the emergency number now, [patterns])
TEXT_RED: dict[str, tuple[str, bool, list[str]]] = {
    "chest_breath_or_fainting": ("chest pain or pressure, breathing trouble, or fainting", True, [
        r"(?P<k>" + _CHEST + r"\W+(?:\w+\W+){0,3}?(?:pain|pian|pains|tight\w*|pressure|hurt\w*|ache|aching|squeez\w*|discomfort))",
        r"(?P<k>f[ae]i?nt(?:ed|ing)?\b|pas+e?d\s+out|black(?:ed|ing)\s+out|collaps\w+|lost\s+consciousness)",
        r"(?P<k>(?:can'?t|cant|cannot|couldn'?t)\s+(?:\w+\s+){0,2}breath\w*|short(?:ness)?\s+of\s+breath)"]),
    "heat_illness_signs": ("possible heat illness", True, [
        r"(?P<k>heat\s*-?\s*(?:stroke|exhaustion|illness)|stopped\s+sweating|hot\s+dry\s+skin)",
        r"(?P<k>confus\w*\b(?!\s+(?:about|by|on|with|over|re)\b)|disorient\w*|delirious)"]),
    "head_injury": ("a knock to the head", False, [
        r"(?P<k>(?:hit|bump\w*|bang\w*|knock\w*|smack\w*|crack\w*|slam\w*|whack\w*)\s+(?:\w+\s+){0,2}head|head\s+(?:injur\w*|trauma|knock)|"
        r"concuss\w*|knocked\s+out)"]),
    "calf_swollen_hot_or_red": ("a swollen leg or calf that is hot or red, or a possible clot", False, [
        r"(?:calf|calve|calves|leg)\W+(?:\w+\W+){0,6}?(?P<k>swo\w*|swel\w*|puff\w*|hot\b|warm\b|red\b|throbbing)",
        r"(?P<k>swo\w*|swel\w*|puff\w*|hot|warm|red)\s+(?:and\s+\w+\s+)?(?:\w+\s+){0,2}(?:calf|calve|calves)",
        r"(?P<k>\bdvt\b|blood\s*clot|thrombo\w*)"]),
    "numbness_tingling_weakness": ("numbness, tingling or weakness", False, [
        r"(?P<k>numb\w*|tingl\w*|pins\s+and\s+needles|foot\s+drop|loss\s+of\s+(?:sensation|feeling)|can'?t\s+feel|sudden\w*\s+weak\w*|"
        r"(?:leg|foot|ankle)\s+(?:\w+\s+){0,2}(?:gave|giving)\s+(?:out|way))"]),
    "cannot_bear_weight": ("cannot put weight on the leg", False, [
        r"(?P<k>(?:can'?t|cant|cannot|can\s+not|unable\s+to|couldn'?t|could\s+not)\s+(?:even\s+)?(?:put\s+(?:any\s+)?w[ei]{1,2}ght|bear\s+(?:any\s+)?w[ei]{1,2}ght|"
        r"stand\s+on|walk\b|hobble)|non\s*-?\s*w[ei]{1,2}ght\s*-?\s*bearing|"
        r"(?:can|could)\s+(?:only\s+)?(?:barely|hardly|just\s+about)\s+(?:walk|stand|put\s+weight)|(?:barely|hardly)\s+(?:able\s+to\s+)?(?:walk|stand)|"
        r"(?:hurts?|painful|sore|agony|pain)\s+(?:\w+\s+){0,2}(?:to|when|while|on)\s+(?:i\s+)?(?:walk|walking|stand|standing|put\w*\s+weight)|"
        r"struggl\w+\s+to\s+walk)"]),
    "deformity": ("the area looks out of shape or something snapped", False, [
        r"(?P<k>dislocat\w*|deform\w*|bone\s+(?:is\s+)?(?:sticking|poking)|heard\s+(?:a\s+)?(?:snap|pop|crack)\w*|looks?\s+(?:out\s+of\s+shape|crooked)|"
        r"broke[n]?\s+(?:my\s+)?(?:bone|ankle|leg|foot|toe)|think\s+(?:i\s+)?broke)"]),
    "fever_with_joint_pain": ("fever together with joint pain", False, [
        r"(?P<k>fever\w*|feverish)\W+(?:\w+\W+){0,8}(?:joint|knee|hip|ankle)",
        r"(?:joint|knee|hip|ankle)\W+(?:\w+\W+){0,8}(?P<k>fever\w*|feverish)"]),
    "severe_rest_or_night_pain": ("severe pain, or pain at rest or at night", False, [
        r"(?P<k>(?:severe|agony|excruciating|unbearable|screaming)\s+(?:\w+\s+){0,2}pain|agony)",
        r"(?:pain|ache\w*|sore\w*|hurt\w*|throb\w*)\W+(?:\w+\W+){0,6}?(?P<k>at\s+night|in\s+the\s+night|wak\w+\s+me|keeps?\s+me\s+(?:up|awake)|at\s+rest|in\s+bed)",
        r"(?P<k>wak\w+\s+me|keeps?\s+me\s+(?:up|awake))\W+(?:\w+\W+){0,6}(?:pain|ache|hurt\w*)",
        r"(?P<k>night\s+pain|rest\s+pain)"]),
    "bone_pain_at_night": ("a possible stress fracture", False, [
        r"(?P<k>stress\s+(?:fracture|fractre|fractur\w*|reaction))"]),
    "after_fall_or_impact": ("pain after a fall or a hard knock", False, [
        r"(?P<k>fell|fall|fallen|crash\w*|tripped|came\s+off|hit\s+by\s+a?\s*(?:car|bike|cyclist))\W+(?:\w+\W+){0,10}?(?:pain|hurt\w*|sore|swo\w*|can'?t)"]),
}
TEXT_AMBER: dict[str, tuple[str, list[str], bool]] = {   # code -> (reason, patterns, needs a pain word somewhere in the text)
    "swelling": ("swelling", [r"(?P<k>swo\w*|swel\w*|puffy)"], False),
    "changes_gait": ("it makes them limp or change how they run", [r"(?P<k>limp\w*|hobbl\w*)"], False),
    "worsening": ("it is getting worse", [r"(?P<k>(?:getting|got|gets|is|keeps|keep)\s+(?:\w+\s+)?worse|worsening|worse\s+each|not\s+(?:getting\s+)?better|not\s+going\s+away)"], True),
    "sharp_or_stabbing": ("sharp, stabbing or shooting pain", [r"(?P<k>sharp|stabbing|shooting)"], True),
    "lasting": ("it has lasted days", [r"(?P<k>(?:for|past|over|last)\s+(?:\w+\s+){0,2}(?:\d+|few|couple|several|two|three|four|five|six|seven)\s+(?:days?|weeks?|wks?))"], True),
    "recurring": ("it hurts on every run", [r"(?P<k>(?:every|each)\s+(?:single\s+)?run|every\s+time\s+i\s+run|all\s+(?:week|my\s+runs)|on\s+every\s+(?:\w+\s+)?run)"], True),
    "bone_point_pain": ("pain on a bone (shin, foot, hip)", [r"(?P<k>shin|heel|metatars\w*|foot|hip)\W+(?:\w+\W+){0,3}(?:pain|hurt\w*|sore)"], False),
    "injury_words": ("they describe an injury", [r"(?P<k>injur\w*|sprain\w*|pulled\s+a?|tweak\w*)"], False),
}
_RED_RX = {c: [re.compile(p, re.I) for p in ps] for c, (_r, _e, ps) in TEXT_RED.items()}
_AMBER_RX = {c: [re.compile(p, re.I) for p in ps] for c, (_r, ps, _n) in TEXT_AMBER.items()}


def _negated(text: str, k_start: int) -> bool:
    before = text[:k_start]
    cut = 0
    for m in _CLAUSE_BREAK.finditer(before):
        cut = m.end()
    words = re.findall(r"[\w']+", before[cut:].lower().replace("\u2019", "'"))[-4:]
    return any(w in _NEG_WORDS for w in words)


def _find(rxs: list[re.Pattern], text: str) -> bool:
    for rx in rxs:
        for m in rx.finditer(text):
            if not _negated(text, m.start("k")):
                return True
    return False


@dataclass
class TextTriage:
    level: str                                   # red | amber | green
    codes: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    call_emergency: bool = False


def classify_text(text: str) -> TextTriage:
    """The red / amber / green level for what the runner typed, from the tables above. Deterministic, no model."""
    t = " ".join((text or "").replace("\u2019", "'").split())
    red = [c for c in TEXT_RED if _find(_RED_RX[c], t)]
    if red:
        return TextTriage("red", red, [TEXT_RED[c][0] for c in red], any(TEXT_RED[c][1] for c in red))
    pain = bool(_PAIN_CTX.search(t))
    amber = [c for c, (_r, _p, needs) in TEXT_AMBER.items() if (pain or not needs) and _find(_AMBER_RX[c], t)]
    if amber:
        return TextTriage("amber", amber, [TEXT_AMBER[c][0] for c in amber])
    return TextTriage("green")


_ASK_CLAUSE = (
    (re.compile(r"long\s+run", re.I), "That means no long run."),
    (re.compile(r"race|half|marathon|parkrun|10k|5k", re.I), "That means no racing until you have been cleared."),
    (re.compile(r"tempo|interval|speed|session|workout|train|plan|thursday|tomorrow|tonight|today|run\b", re.I), "That means no running for now."),
)
_REASON_LEAD = {   # how each trigger reads at the start of "With ..., please stop running"
    "chest_breath_or_fainting": "chest pain, trouble breathing or fainting", "heat_illness_signs": "possible heat illness",
    "cannot_bear_weight": "not being able to put weight on it", "calf_swollen_hot_or_red": "a swollen, hot or red calf",
    "numbness_tingling_weakness": "numbness, tingling or weakness", "deformity": "the area looking out of shape",
    "fever_with_joint_pain": "fever with joint pain", "severe_rest_or_night_pain": "severe pain at rest or at night",
    "after_fall_or_impact": "pain after a fall or knock", "bone_pain_at_night": "bone pain that wakes you at night",
}


_GENERIC_NET = "If it's getting worse fast, you feel faint, short of breath or confused, or you can't move it, {call}."
_SAFETY_NET = {   # first matching trigger wins; one sentence each, so the reply stays at 5 sentences
    "chest_breath_or_fainting": "If the chest pain or breathlessness is happening now, {call} straight away.",
    "heat_illness_signs": "Get out of the heat, cool down and sip water if you can, and if you're confused or it's getting worse, {call} now.",
    "calf_swollen_hot_or_red": "If you get chest pain or you're short of breath, {call} straight away.",
    "cannot_bear_weight": "Don't walk on it if you can avoid it, and if it's getting worse fast or you feel faint, {call}.",
    "numbness_tingling_weakness": "If the weakness spreads, or you notice any change in bladder or bowel control, {call} straight away.",
}


def red_reply(zone_id: str | None, place_known: bool, codes: list[str] | None = None, message: str = "") -> str:
    """The fixed reply for a red text hit: no model, no training, at most 5 sentences. Names what triggered it, answers the
    runner's ask in one clause, gives the safety net for that trigger and their own country's emergency number. Plain text."""
    call = redflag.call_emergency(zone_id)
    codes = codes or []
    named = [_REASON_LEAD[c] for c in codes if c in _REASON_LEAD][:2]
    lead = f"With {' and '.join(named)}, please" if named else "Please"
    action = "keep weight off it" if "cannot_bear_weight" in codes else "stop running"
    ask = next((clause for rx, clause in _ASK_CLAUSE if rx.search(message or "")), "")
    net = _SAFETY_NET.get(next((c for c in codes if c in _SAFETY_NET), ""), _GENERIC_NET).format(call=call)
    find = ("Say \"find urgent care\" and I'll look near where you usually run." if place_known
            else "Tell me your suburb or town and I'll find the nearest urgent care.")
    return (f"{lead} {action} and get this seen by a doctor today, at urgent care or an emergency department. "
            + (ask + " " if ask else "") + f"{net}\n\n"
            f"I won't suggest any training until you've been checked. {find}")
