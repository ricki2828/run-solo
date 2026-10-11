"""Facts engine: pure functions, no I/O. Picks what is worth saying (or nothing).

The LLM only phrases what this module returns; every number it may use appears in the
fact texts below, which is what the writer's grounding check enforces.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Mapping, Sequence

from .convo.questions import ENUMS as _EXTENDED_ENUMS
from .timeutil import UTC, parse_iso

HARD_TYPES = frozenset({"tempo", "interval", "race"})

# The app records one of these (RecordMode). The coach's rules speak easy | long | tempo | interval | race.
APP_TYPES = frozenset({"intervals", "cooper", "laps", "free", "trail"})
LONG_MIN_KM = 12.0
LONG_EASY_MULT = 1.5
LONG_MIN_S = 75 * 60
TEMPO_MIN_S, TEMPO_MAX_S = 20 * 60, 60 * 60


def infer_coach_type(app_type: str, *, distance_m: float, duration_s: float, zone_min: Mapping[str, float] | None,
                     pb: str | None, history: Sequence[Mapping[str, Any]], has_reps: bool = False) -> str:
    """The coach's type for a run, from the app's type plus the facts. A type already in the coach's vocabulary
    passes through. `history` is the earlier runs, newest first, carrying the coach types already inferred.

    intervals -> interval; cooper -> race (a test effort); laps -> interval when it has reps or work/recovery splits
    (`has_reps`; the app does not upload them today, so laps is easy for now), else easy. free / trail -> race when
    PB-flagged, else long (distance >= max(1.5 x the typical easy run, 12 km) or 75+ min), else tempo (most time in
    Z3-Z4 over 20-60 min), else easy."""
    if app_type not in APP_TYPES:
        return app_type
    if app_type == "intervals":
        return "interval"
    if app_type == "cooper":
        return "race"
    if app_type == "laps":
        return "interval" if has_reps else "easy"
    if pb:
        return "race"
    easy = [h["distance_m"] for h in history[:80] if h.get("type") == "easy" and h.get("distance_m")][:5]
    typical_km = sorted(easy)[len(easy) // 2] / 1000 if easy else 0.0
    if distance_m / 1000 >= max(LONG_EASY_MULT * typical_km, LONG_MIN_KM) or duration_s >= LONG_MIN_S:
        return "long"
    zm = zone_min or {}
    total = sum(zm.values())
    if total > 0 and (zm.get("z3", 0) + zm.get("z4", 0)) / total > 0.5 and TEMPO_MIN_S <= duration_s <= TEMPO_MAX_S:
        return "tempo"
    return "easy"
TYPE_LABEL = {
    "easy": "easy run", "long": "long run", "tempo": "tempo run",
    "interval": "interval session", "race": "race",
}
VERDICT_TEXT = {  # app wire name (VerdictHeadline.name) -> the verdict copy; noVerdict is silent
    "faster": "faster", "holding": "holding", "slower": "slower", "noRealChange": "no real change",
    "baselineSet": "baseline set", "indoorRun": "indoor run",
}
PB_LABEL = {
    "5k": "5 km best", "10k": "10 km best", "half": "half marathon best",
    "longest": "longest run", "fastest_km": "fastest km",
}
LOAD_ALERT = {"high", "very_high"}
SLOW_DAY_S_PER_KM = 10  # a day at least this much slower is called slow, plainly
DELTA_MIN_S_PER_KM = 3
MIN_DURATION_S = 300
MIN_DISTANCE_M = 1000
QUIET_CARD_GAP_H = 18  # without anything notable, stay silent if we sent a card this recently


@dataclass(frozen=True)
class Fact:
    id: str
    text: str


@dataclass(frozen=True)
class Suggestion:
    kind: str
    reason: str
    text: str


@dataclass(frozen=True)
class FactsResult:
    facts: tuple[Fact, ...]
    suggestion: Suggestion | None
    tone: str  # pb | slow | steady
    say_nothing: bool
    reason: str


def fmt_pace(s: float) -> str:
    total = int(round(s))
    return f"{total // 60}:{total % 60:02d}"


def fmt_km(m: float) -> str:
    return f"{m / 1000:.1f}"


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def _metric(r: Mapping[str, Any], use_true: bool) -> float | None:
    if use_true:
        return r.get("true_pace_s_per_km")
    return r.get("pace_s_per_km")


def comparable(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """Most recent prior run of the same type, 0.8x-1.25x the distance, within 60 days, with a pace."""
    if not run.get("distance_m"):
        return None
    t0 = _when(run)
    for h in history:  # newest first
        if h["type"] != run["type"] or not h.get("distance_m"):
            continue
        ratio = h["distance_m"] / run["distance_m"]
        if not 0.8 <= ratio <= 1.25:
            continue
        if not timedelta(0) < t0 - _when(h) <= timedelta(days=60):
            continue
        if _metric(h, True) is not None and _metric(run, True) is not None:
            return h
        if _metric(h, False) is not None and _metric(run, False) is not None:
            return h
    return None


def days_since_hard(history: Sequence[Mapping[str, Any]], now: datetime) -> int | None:
    for h in history:
        if h["type"] in HARD_TYPES:
            return (now - _when(h)).days
    return None


def _recent_count(history: Sequence[Mapping[str, Any]], now: datetime, days: int) -> int:
    return sum(1 for h in history if timedelta(0) <= now - _when(h) <= timedelta(days=days))


def suggest_after_run(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]]) -> Suggestion | None:
    now = _when(run)
    if run.get("load_state") in LOAD_ALERT:
        return Suggestion("easy_next", "load", "Load is high right now, so an easy day or a rest day next suits you.")
    if run["type"] in HARD_TYPES:
        return Suggestion("recover", "hard_today", "That was a hard session, so an easy day next lets it land.")
    gap = days_since_hard(history, now)
    if gap is not None and gap >= 6 and _recent_count(history, now, 14) >= 3:
        return Suggestion("quality", "gap", f"It has been {gap} days since your last hard session, so one this week fits.")
    return None


def suggest_evening(history: Sequence[Mapping[str, Any]], now: datetime) -> Suggestion | None:
    """The evening-before suggestion (Telegram only). Needs a reason from the rules."""
    if not history:
        return None
    last = history[0]
    if _recent_count(history, now, 14) < 3:
        return None
    if last.get("load_state") in LOAD_ALERT:
        return Suggestion("easy_next", "load", "Load is high right now, so tomorrow is best easy or a rest day.")
    if last["type"] in HARD_TYPES and (now - _when(last)) <= timedelta(hours=40):
        return Suggestion("recover", "hard_recent", "Your last run was a hard one, so keep tomorrow easy.")
    gap = days_since_hard(history, now)
    if gap is not None and gap >= 5:
        return Suggestion("quality", "gap", f"It has been {gap} days since your last hard session, so tomorrow suits one.")
    return None


def build_facts(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]],
                memory: Mapping[str, str], *, last_card_age_h: float | None = None) -> FactsResult:
    """`history` is the user's prior runs, newest first, excluding `run`."""
    dist, dur = run.get("distance_m") or 0, run.get("duration_s") or 0
    if dur < MIN_DURATION_S or dist < MIN_DISTANCE_M:
        return FactsResult((), None, "steady", True, "junk")

    label = "trail run" if run.get("app_type") == "trail" else TYPE_LABEL.get(run["type"], "run")
    pace = run.get("pace_s_per_km")
    base_txt = f"{label.capitalize()}: {fmt_km(dist)} km in {round(dur / 60)} min"
    if pace:
        base_txt += f" at {fmt_pace(pace)}/km"
    base = Fact("base", base_txt)

    worthy: list[Fact] = []
    tone = "steady"

    verdict = VERDICT_TEXT.get(run.get("verdict") or "")
    if verdict:
        worthy.append(Fact("verdict", f"Verdict: {verdict}"))  # the app's own wording, never reworded

    if run.get("pb") in PB_LABEL:
        worthy.append(Fact("pb", f"New personal best: {PB_LABEL[run['pb']]}"))
        tone = "pb"

    prev = comparable(run, history)
    if prev is not None:
        use_true = _metric(prev, True) is not None and _metric(run, True) is not None
        now_p, prev_p = _metric(run, use_true), _metric(prev, use_true)
        delta = round(now_p - prev_p)
        if abs(delta) >= DELTA_MIN_S_PER_KM:
            word = "slower" if delta > 0 else "faster"
            worthy.append(Fact("delta", f"{abs(delta)} s/km {word} than your last similar {label} ({fmt_pace(prev_p)}/km)"))
            if delta >= SLOW_DAY_S_PER_KM and tone != "pb":
                tone = "slow"
        else:
            worthy.append(Fact("delta", f"Level with your last similar {label} ({fmt_pace(prev_p)}/km)"))

    if run.get("load_state") in LOAD_ALERT:
        worthy.append(Fact("load", f"Training load is {run['load_state'].replace('_', ' ')}"))

    pk = run.get("plan_kind")
    if pk:
        txt = f"Plan day: {pk}"
        if run.get("plan_target_m"):
            txt += f", {fmt_km(run['plan_target_m'])} km planned, {fmt_km(dist)} km run"
        if run.get("plan_weeks_to_race") is not None:
            txt += f", {run['plan_weeks_to_race']} weeks to race"
        worthy.append(Fact("plan", txt))

    if not worthy and last_card_age_h is not None and last_card_age_h < QUIET_CARD_GAP_H:
        return FactsResult((), None, tone, True, "nothing_new")

    picked = worthy[:3]
    if len(picked) < 2:
        picked = [base, *picked]
    if run.get("feel") and len(picked) < 3:
        picked.append(Fact("feel", f"You rated it {run['feel']}"))

    return FactsResult(tuple(picked), suggest_after_run(run, history), tone, False, "ok")


# --- the weekly learning question -------------------------------------------------------

GOAL_OPTIONS = [("5k", "5 km"), ("10k", "10 km"), ("half", "Half marathon"),
                ("marathon", "Marathon"), ("fitness", "Fitness"), ("other", "Something else")]
DAYS_OPTIONS = [("weekdays", "Weekdays"), ("weekends", "Weekends"), ("both", "Both")]
NIGGLE_OPTIONS = [("none", "None"), ("calf", "Calf"), ("knee", "Knee"), ("hip", "Hip"),
                  ("foot", "Foot"), ("other", "Other")]
RACE_GOALS = {"5k", "10k", "half", "marathon"}
NIGGLE_TTL_DAYS = 56  # health-adjacent: expires after 8 weeks (eng-review C6)
MEMORY_ENUMS = {
    "goal_type": {v for v, _ in GOAL_OPTIONS},
    "usual_days": {v for v, _ in DAYS_OPTIONS},
    "niggle_area": {v for v, _ in NIGGLE_OPTIONS},
    **_EXTENDED_ENUMS,  # the rest of the weekly question set (convo/questions.py)
}


def race_month_options(now: datetime) -> list[tuple[str, str]]:
    out, y, m = [], now.year, now.month
    for _ in range(6):
        out.append((f"{y:04d}-{m:02d}", datetime(y, m, 1).strftime("%b %Y")))
        m += 1
        if m == 13:
            y, m = y + 1, 1
    out.append(("none", "No date yet"))
    return out


def valid_answer(key: str, value: str) -> bool:
    if key == "race_month":
        return value == "none" or (len(value) == 7 and value[4] == "-" and value[:4].isdigit()
                                   and value[5:].isdigit() and 1 <= int(value[5:]) <= 12)
    return value in MEMORY_ENUMS.get(key, ())


def next_question(memory: Mapping[str, str], now: datetime) -> dict[str, Any] | None:
    """First unanswered fixed question: goal, race month (race goals only), usual days, niggle area."""
    if "goal_type" not in memory:
        return {"key": "goal_type", "text": "What are you training for?", "options": GOAL_OPTIONS}
    if memory["goal_type"] in RACE_GOALS and "race_month" not in memory:
        return {"key": "race_month", "text": "Which month is the race?", "options": race_month_options(now)}
    if "usual_days" not in memory:
        return {"key": "usual_days", "text": "When do you usually run?", "options": DAYS_OPTIONS}
    if "niggle_area" not in memory:
        return {"key": "niggle_area", "text": "Any niggle at the moment?", "options": NIGGLE_OPTIONS}
    return None


def tomorrow_is_usual_day(usual: str | None, tomorrow_weekday: int) -> bool:
    """weekday(): Mon=0. Unknown preference means any day is fine."""
    if usual == "weekdays":
        return tomorrow_weekday < 5
    if usual == "weekends":
        return tomorrow_weekday >= 5
    return True
