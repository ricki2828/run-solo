"""The evening-before suggestion (about 8 pm local, at most 2 a week, Telegram only).

Every suggestion names the session (type and distance) and when, plus the reason it was made: load,
a hard run just done, how the last run felt, weather, plan, or the gap since the last hard session.
Weather is a reason, never the whole suggestion.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from statistics import median
from typing import Any, Mapping, Sequence

from ..facts import LOAD_ALERT, Suggestion, days_since_hard, fmt_km, is_hard_run
from ..timeutil import parse_iso, to_local
from . import voice
from .touches import WEEKDAYS, hard_share, plural
from .weather import Forecast

EVENING_START_MIN = 20 * 60       # plan from 20:00 local ...
EVENING_END_MIN = 21 * 60         # ... until 21:00, before the default quiet window (21:30)
HEAT_MORNING_C = 29
WET_PCT = 60
GOOD_RAIN_PCT = 20
GOOD_TEMP = (10, 27)
PLAN_WEEKS_MAX = 16
LONG_GAP_DAYS = 9
GAP_DAYS = 5
MIN_RUNS_14D = 3
NEW_RUNNER_DAYS = 14   # a runner's first fortnight gets plan and easy reasons only: no 'add a tempo' push yet
ACTIVE_WITHIN_DAYS = 5
EVENING_MIN_GAP_H = 44  # a suggestion never lands two evenings running
FEEL_WINDOW_H = 40


@dataclass(frozen=True)
class Evening:
    suggestion: Suggestion
    rendered: voice.Rendered
    style: list[str]
    card_facts: dict[str, Any] | None = None   # what the suggestion picture shows (render/protocol KIND_FACT_KEYS)


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def whole_km(metres: float) -> int:
    """Whole km, halves up. Python's round() goes to the even number, which turns a 4.5 km plan into '4 km'."""
    return max(1, int(metres / 1000 + 0.5))


def typical_km(history: Sequence[Mapping[str, Any]], typ: str) -> str | None:
    """Median distance of the last five runs of this type in whole km, e.g. '7'."""
    ds = [h["distance_m"] for h in history[:80] if h["type"] == typ and h.get("distance_m")][:5]
    return str(whole_km(median(ds))) if ds else None  # whole km


def typical_easy_km(history):  # kept for callers that predate typed sessions
    return typical_km(history, "easy")


def start_hint(history: Sequence[Mapping[str, Any]], zone_id: str) -> str | None:
    """'around 6:30', from the median local start time of the last 8 runs."""
    mins = []
    for h in history[:8]:
        loc = to_local(_when(h), h.get("zone_id") or zone_id)
        mins.append(loc.hour * 60 + loc.minute)
    if not mins:
        return None
    m = int(round(median(mins) / 15.0) * 15)
    return f"around {m // 60}:{m % 60:02d}"


def plan_weeks(history: Sequence[Mapping[str, Any]], now: datetime) -> int | None:
    for h in history[:10]:
        w = h.get("plan_weeks_to_race")
        if w is not None and (now - _when(h)).days <= 14:
            return max(w - (now - _when(h)).days // 7, 0)
    return None


PLAN_KIND_WORD = {"easy": "easy", "long": "long run", "quality": "quality session"}
PLAN_SUGG_KIND = {"easy": "easy_next", "long": "long_run", "quality": "quality"}


def planned_for_tomorrow(history: Sequence[Mapping[str, Any]], now: datetime, zone_id: str) -> Mapping[str, Any] | None:
    """The newest run's plan snapshot, when its next planned session falls on tomorrow's local date. Older runs are
    ignored: the app re-sends the plan with every run, so the newest one is the freshest."""
    if not history:
        return None
    h = history[0]
    tomorrow = (to_local(now, zone_id).date() + timedelta(days=1)).isoformat()
    if h.get("plan_next_type") in PLAN_KIND_WORD and h.get("plan_next_day") == tomorrow:
        return h
    return None


def plan_session(h: Mapping[str, Any], history: Sequence[Mapping[str, Any]], now: datetime) -> tuple[str, str] | None:
    """-> (session text, reason clause) from the plan row, or None when no honest number can be named.
    The distance or minutes come from the plan; an easy or long session without one uses the runner's own typical
    distance, exactly as an unplanned suggestion would. A quality session needs no number."""
    typ = h["plan_next_type"]
    word = PLAN_KIND_WORD[typ]
    name = h.get("plan_next_session_name")
    if typ == "quality" and name:   # the coach week names its quality session ("tempo"), the same word its other messages use
        word = "tempo" if name == "Tempo" else name
    text: str | None
    if h.get("plan_next_m"):
        text = f"{word} {whole_km(h['plan_next_m'])} km"
    elif h.get("plan_next_min"):
        text = f"{word} {h['plan_next_min']} min"
    elif typ == "easy":
        km = typical_km(history, "easy")
        text = f"easy {km} km" if km else None
    elif typ == "long":
        km = long_run_km(history, now)
        text = f"long run {km} km" if km else None
    else:
        text = word
    if text is None:
        return None
    return text, plan_week_clause(h.get("plan_next_week"), h.get("plan_weeks"))


def plan_week_clause(wk: int | None, wks: int | None) -> str:
    """'week 3 of 4 of your plan', built only from the week numbers the app sent."""
    if wk and wks and wk <= wks:
        return f"week {wk} of {wks} of your plan"
    if wk:
        return f"week {wk} of your plan"
    return "your plan"


LONG_STEP_KM = 1.5      # build by 1 to 2 km on the last long run ...
LONG_CAP_OVER_MAX = 1.10  # ... but never more than about 10% over the longest run of the last 28 days
LONG_PEAK_KM = 20        # peak for a half marathon
LONG_DROP = 0.8          # after a break or a missed week, step back to this share of the last long run
TAPER_WEEKS = 2          # no long-run build in the last two weeks before the race
MISSED_WEEK_DAYS = 7


def missed_week_recently(history: Sequence[Mapping[str, Any]], now: datetime) -> bool:
    """A gap of 7+ days between runs, with the run after it inside the last 14 days."""
    for newer, older in zip(history, history[1:]):
        if (now - _when(newer)).days > 14:
            return False
        if (_when(newer) - _when(older)).days >= MISSED_WEEK_DAYS:
            return True
    return False


def long_run_km(history: Sequence[Mapping[str, Any]], now: datetime) -> int | None:
    """Next long run in whole km: last long run + 1.5 km, capped 10% over the 4-week max and at the peak.
    Only stepped back after a break or a missed week."""
    last = next((h["distance_m"] / 1000 for h in history if h["type"] == "long" and h.get("distance_m")), None)
    if last is None:
        return None
    if missed_week_recently(history, now):
        return max(1, round(last * LONG_DROP))
    recent = [h["distance_m"] / 1000 for h in history if h.get("distance_m") and (now - _when(h)).days <= 28]
    cap = min(LONG_CAP_OVER_MAX * max(recent + [last]), LONG_PEAK_KM)
    target = min(last + LONG_STEP_KM, cap)
    return max(round(last), min(round(target), int(cap)))


def session_parts(kind: str, history: Sequence[Mapping[str, Any]], now: datetime | None = None) -> tuple[str, str] | None:
    """(word, whole km) of the session a kind of suggestion names, from the runner's own distances."""
    easy, tempo = typical_km(history, "easy"), typical_km(history, "tempo")
    long_ = long_run_km(history, now or _when(history[0])) if history else None
    if kind in ("easy_load", "recover", "heat", "wet", "feel", "soft"):
        return ("easy", easy) if easy else None
    if kind in ("gap", "good"):
        km = tempo or easy
        return ("tempo" if tempo else "steady", km) if km else None
    if kind == "plan_long":
        return ("long run", str(long_)) if long_ else None
    return None


def session_for(kind: str, history: Sequence[Mapping[str, Any]], now: datetime | None = None) -> str | None:
    """The named session for a kind of suggestion, built from the runner's own distances."""
    p = session_parts(kind, history, now)
    return f"{p[0]} {p[1]} km" if p else None


# The suggestion picture: the session word -> (card type, label). The label is the session word the text uses.
_CARD_SESSION = {"easy": ("easy", "Easy run"), "tempo": ("tempo", "Tempo"), "steady": ("easy", "Steady run"),
                 "long run": ("long", "Long run")}
_PLAN_CARD_TYPE = {"easy": "easy", "long": "long", "quality": "tempo"}   # a planned session the table above does not name


def plan_parts(session: str) -> tuple[str, str] | None:
    """(word, whole km) of a planned session's text ("tempo 7 km", "Norwegian 4x4 8 km"); None when it names no km."""
    head, _, unit = session.rpartition(" ")
    word, _, km = head.rpartition(" ")
    return (word, km) if unit == "km" and word else None


def card_reason(kind: str, slots: Mapping[str, str]) -> str:
    """One short sentence for the picture, built only from the slots the text itself was written from (so every number
    on the picture is one the message already says). Never mentions a note: the soft line is generic."""
    s = slots
    return {
        "easy_load": "Your load is high. Easy keeps it from stacking.",
        "recover": f"Your last run was hard, {s.get('hours_txt', '')} ago.",
        "feel": f"You called {s.get('weekday', '')} hard at an easy pace. {s.get('cause', '')}".strip(),
        "heat": f"{s.get('temp', '')} degrees forecast at {s.get('fc_at', '')} tomorrow, so go early.",
        "wet": f"{s.get('rain', '')}% chance of rain tomorrow.",
        "plan_long": f"Race is {s.get('weeks_txt', '')} away and your last long run was {s.get('gap_txt', '')} ago.",
        "good": f"{s.get('temp', '')} degrees, {s.get('rain', '')}% rain, and {s.get('gap_txt', '')} since your last hard run.",
        "gap": f"It has been {s.get('gap_txt', '')} since your last hard session.",
        "plan_session": f"Part of {s.get('why', 'your plan')}.",
        "soft": "Nothing hard for now. Keep it gentle.",
    }[kind]


def _kind_reason(kind: str) -> str:
    return {"easy_load": "load", "recover": "hard_recent", "heat": "weather", "wet": "weather", "feel": "feel",
            "plan_session": "plan", "plan_long": "plan", "good": "weather", "gap": "gap", "soft": "rest"}[kind]


def feel_cause(prev_situation: str | None) -> str:
    return {"slower_heat": "Heat.", "slower_load": "Load is high.", "slower_hills": "Hills."}.get(
        prev_situation or "", "Worth watching.")


def evening(history: Sequence[Mapping[str, Any]], now: datetime, forecast: Forecast | None,
            used: Mapping[str, datetime], seed: str, zone_id: str = "UTC",
            last_situation: str | None = None, soften: bool = False) -> Evening | None:
    """`history` newest first. None when no honest reason exists or no session can be named.

    `soften` (a recent run note carried a niggle/sore/injury/tired/sick word, see companion.notes) turns every push
    (a quality session, the plan's long run) into a gentle easy-or-rest line. Easy-session reasons are unchanged."""
    if not history:
        return None
    recent = sum(1 for h in history if timedelta(0) <= now - _when(h) <= timedelta(days=14))
    if recent < MIN_RUNS_14D:
        return None
    last = history[0]
    since_last = now - _when(last)
    # `history` is the full record (the caller's limit is 2000), so its oldest entry is the runner's first run; the < 60 is a cheap guard
    new_runner = len(history) < 60 and now - _when(history[-1]) < timedelta(days=NEW_RUNNER_DAYS)
    if since_last > timedelta(days=ACTIVE_WITHIN_DAYS):
        return None  # someone who has stopped running gets the recap, not a nudge
    start = start_hint(history, zone_id)
    if start is None:
        return None
    slots: dict[str, str] = {"start": start}
    kind: str | None = None
    use_plan_session = False  # heat naming the planned session (never when a flagged note softens a push)

    gap = days_since_hard(history, now)
    long_gap = next(((now - _when(h)).days for h in history if h["type"] == "long"), None)
    weeks = plan_weeks(history, now)
    planned = planned_for_tomorrow(history, now, zone_id)
    planned_text = plan_session(planned, history, now) if planned else None
    hot = bool(forecast and forecast.morning_temp_c >= HEAT_MORNING_C)
    # The runner's own Hard tap on the last run counts like a flagged note: no push on top of it, whatever the type was.
    tapped_hard = last.get("feel") == "hard" and since_last <= timedelta(hours=FEEL_WINDOW_H)
    soften = soften or tapped_hard
    push_softened = bool(soften and planned and planned["plan_next_type"] != "easy")  # a flagged note vs a planned push
    share = hard_share(last)
    felt_hard = (last.get("feel") == "hard" and last["type"] == "easy" and (share is None or share < 0.15)
                 and since_last <= timedelta(hours=FEEL_WINDOW_H))

    if last.get("load_state") in LOAD_ALERT:
        kind = "easy_load"
    elif is_hard_run(last) and since_last <= timedelta(hours=40):
        kind = "recover"
        slots["hours_txt"] = plural(int(since_last.total_seconds() // 3600), "hour")
    elif felt_hard:
        kind = "feel"
        slots.update(weekday=WEEKDAYS[to_local(_when(last), last.get("zone_id") or zone_id).weekday()],
                     cause=feel_cause(last_situation))
    elif planned_text is not None and hot and not push_softened:
        kind = "heat"  # the heat warning is a safety line: it keeps its place, and names the planned session
        slots.update(temp=str(forecast.morning_temp_c), fc_at="7 am")
        use_plan_session = True
    elif planned_text is not None and not (hot and push_softened):
        kind = "plan_session"  # tomorrow is a planned session: follow the plan, ahead of rain and gap reasons
        slots.update(why=planned_text[1])
    elif forecast and forecast.morning_temp_c >= HEAT_MORNING_C:
        kind = "heat"
        slots.update(temp=str(forecast.morning_temp_c), fc_at="7 am")
    elif forecast and forecast.rain_pct >= WET_PCT:
        kind = "wet"
        slots["rain"] = str(forecast.rain_pct)
    elif weeks is not None and TAPER_WEEKS < weeks <= PLAN_WEEKS_MAX and long_gap is not None and long_gap >= LONG_GAP_DAYS:
        kind = "plan_long"
        slots.update(weeks_txt=plural(weeks, "week"), gap_txt=plural(long_gap, "day"))
    elif gap is not None and gap >= GAP_DAYS and not new_runner:
        slots["gap_txt"] = plural(gap, "day")
        if forecast and forecast.rain_pct <= GOOD_RAIN_PCT and GOOD_TEMP[0] <= forecast.morning_temp_c <= GOOD_TEMP[1]:
            kind = "good"
            slots.update(temp=str(forecast.morning_temp_c), rain=str(forecast.rain_pct), fc_at="7 am")
        else:
            kind = "gap"
    if kind is None:
        return None
    if soften and (kind in ("gap", "good", "plan_long")
                   or (kind == "plan_session" and planned["plan_next_type"] != "easy")):
        kind = "soft"  # a planned push turns into the gentle line too
        slots.pop("why", None)
    session = planned_text[0] if planned_text and (kind == "plan_session" or use_plan_session) else session_for(kind, history, now)
    if session is None:
        return None  # no concrete session to name: say nothing rather than something vague
    slots["session"] = session
    situation = {"easy_load": "sugg_easy_load", "recover": "sugg_recover", "heat": "sugg_weather_heat",
                 "wet": "sugg_weather_wet", "plan_session": "sugg_plan_session", "plan_long": "sugg_plan_long", "good": "sugg_weather_good",
                 "gap": "sugg_gap", "feel": "sugg_feel", "soft": "sugg_soft"}[kind]
    r = voice.render(situation, slots, used, now, seed)
    if r is None:
        return None
    sk = {"easy_load": "easy_next", "recover": "recover", "heat": "heat", "wet": "wet",
          "plan_session": PLAN_SUGG_KIND[planned["plan_next_type"]] if planned else "easy_next", "plan_long": "long_run",
          "good": "quality", "gap": "quality", "feel": "easy_next", "soft": "easy_next"}[kind]
    facts = None
    named = planned_text is not None and (kind == "plan_session" or use_plan_session)
    parts = plan_parts(session) if named else session_parts(kind, history, now)
    if parts and parts[1].isdigit() and (parts[0] in _CARD_SESSION or named):
        ctype, label = _CARD_SESSION.get(parts[0]) or (_PLAN_CARD_TYPE[planned["plan_next_type"]], parts[0][:1].upper() + parts[0][1:])
        tomorrow = to_local(now, zone_id).date() + timedelta(days=1)
        facts = {"type": ctype, "session": label, "distance_km": int(parts[1]), "date_local": tomorrow.isoformat(),
                 "reason": card_reason(kind, slots)}
    return Evening(Suggestion(sk, _kind_reason(kind), r.body), r, voice.exemplars(situation, 3, seed), facts)


def after_run(sug: Suggestion, run: Mapping[str, Any], history: Sequence[Mapping[str, Any]],
              used: Mapping[str, datetime], now: datetime, seed: str) -> voice.Rendered | None:
    """The suggestion that rides on a post-run card, with a named session. None means: no buttons."""
    situation = {"easy_next": "sugg_easy_load", "recover": "sugg_after_hard", "quality": "sugg_gap_week"}.get(sug.kind)
    if situation is None:
        return None
    zone = run.get("zone_id") or "UTC"
    session = session_for("easy_load" if sug.kind != "quality" else "gap", history)
    start = start_hint(history, zone)
    if session is None or start is None:
        return None
    slots = {"session": session, "start": start}
    if situation == "sugg_gap_week":
        gap = days_since_hard(history, _when(run))
        if gap is None:
            return None
        slots["gap_txt"] = plural(gap, "day")
    return voice.render(situation, slots, used, now, seed)
