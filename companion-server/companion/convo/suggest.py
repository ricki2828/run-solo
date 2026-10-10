"""The evening-before suggestion (about 8 pm local, at most 2 a week, Telegram only).

Every suggestion names its reason (load, a hard run just done, weather, plan, gap since the last
hard day) and carries "Not this week" from the service's button builder.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from statistics import median
from typing import Any, Mapping, Sequence

from ..facts import HARD_TYPES, LOAD_ALERT, Suggestion, days_since_hard, fmt_km
from ..timeutil import parse_iso
from . import voice
from .touches import plural
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


@dataclass(frozen=True)
class Evening:
    suggestion: Suggestion
    rendered: voice.Rendered
    style: list[str]


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def typical_easy_km(history: Sequence[Mapping[str, Any]]) -> str | None:
    easy = [h["distance_m"] for h in history[:12] if h["type"] == "easy" and h.get("distance_m")][:5]
    return fmt_km(median(easy)) if easy else None


def plan_weeks(history: Sequence[Mapping[str, Any]], now: datetime) -> int | None:
    for h in history[:10]:
        w = h.get("plan_weeks_to_race")
        if w is not None and (now - _when(h)).days <= 14:
            return max(w - (now - _when(h)).days // 7, 0)
    return None


def _kind_reason(kind: str) -> str:
    return {"easy_load": "load", "recover": "hard_recent", "heat": "weather", "wet": "weather",
            "plan_long": "plan", "good": "weather", "gap": "gap"}[kind]


def evening(history: Sequence[Mapping[str, Any]], now: datetime, forecast: Forecast | None,
            used: Mapping[str, datetime], seed: str) -> Evening | None:
    """`history` newest first. None when no honest reason exists."""
    if not history:
        return None
    recent = sum(1 for h in history if timedelta(0) <= now - _when(h) <= timedelta(days=14))
    if recent < MIN_RUNS_14D:
        return None
    last = history[0]
    since_last = now - _when(last)
    easy_km = typical_easy_km(history)
    slots: dict[str, str] = {}
    if easy_km:
        slots["km"] = easy_km
    kind: str | None = None

    gap = days_since_hard(history, now)
    long_gap = next(((now - _when(h)).days for h in history if h["type"] == "long"), None)
    weeks = plan_weeks(history, now)

    if last.get("load_state") in LOAD_ALERT:
        kind = "easy_load"
    elif last["type"] in HARD_TYPES and since_last <= timedelta(hours=40):
        kind = "recover"
        hrs = int((since_last + timedelta(seconds=0)).total_seconds() // 3600)
        slots["hours_txt"] = plural(hrs, "hour")
    elif forecast and forecast.morning_temp_c >= HEAT_MORNING_C:
        kind = "heat"
        slots["temp"] = str(forecast.morning_temp_c)
    elif forecast and forecast.rain_pct >= WET_PCT:
        kind = "wet"
        slots["rain"] = str(forecast.rain_pct)
    elif weeks is not None and weeks <= PLAN_WEEKS_MAX and long_gap is not None and long_gap >= LONG_GAP_DAYS:
        kind = "plan_long"
        slots.update(weeks_txt=plural(weeks, "week"), gap_txt=plural(long_gap, "day"))
    elif gap is not None and gap >= GAP_DAYS:
        slots["gap_txt"] = plural(gap, "day")
        if forecast and forecast.rain_pct <= GOOD_RAIN_PCT and GOOD_TEMP[0] <= forecast.morning_temp_c <= GOOD_TEMP[1]:
            kind = "good"
            slots.update(temp=str(forecast.morning_temp_c), rain=str(forecast.rain_pct))
        else:
            kind = "gap"
    if kind is None:
        return None

    situation = {"easy_load": "sugg_easy_load", "recover": "sugg_recover", "heat": "sugg_weather_heat",
                 "wet": "sugg_weather_wet", "plan_long": "sugg_plan_long", "good": "sugg_weather_good",
                 "gap": "sugg_gap"}[kind]
    r = voice.render(situation, slots, used, now, seed)
    if r is None:
        return None
    sk = {"easy_load": "easy_next", "recover": "recover", "heat": "heat", "wet": "wet", "plan_long": "long_run",
          "good": "quality", "gap": "quality"}[kind]
    return Evening(Suggestion(sk, _kind_reason(kind), r.body), r, voice.exemplars(situation, 3, seed))
