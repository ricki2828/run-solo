"""Glue between the facts layer and the voice: which situation is this run, which touch (if any)
rides along, and what media a channel should attach.

Pure functions. The service persists the usage log and decides when to send.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any, Mapping, Sequence

from ..facts import HARD_TYPES, comparable, fmt_km, fmt_pace, _metric
from ..timeutil import parse_iso
from . import touches as T
from . import voice
from .weather import HEAT_C, RunWeather

BREAK_DAYS = T.BREAK_DAYS  # a gap this long before today's run makes it a "back after a break" run
SLOW_DAY_S = 10         # as in facts.SLOW_DAY_S_PER_KM
FASTER_S = 3            # as in facts.DELTA_MIN_S_PER_KM
HILLS_M = 100           # climb that explains a slow day
LONG_VIDEO_KM = 15.0
LONG_VIDEO_MIN = 90
HARD_VIDEO_MIN = 8      # minutes in Z4 and Z5 that make a session worth a video
FLOOD_SHARE = 0.4       # share of zone time in Z4 and Z5 that makes a run a "hard" card


@dataclass(frozen=True)
class MediaPlan:
    card: str   # light | flood | pb | suggestion | weekly_recap | none
    video: bool
    reason: str
    touch_card: str | None = None  # milestone | race_countdown: a second card the channel may add

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)


@dataclass(frozen=True)
class RunVoice:
    situation: str
    rendered: voice.Rendered | None
    touch: T.Touch | None
    touch_variant: str | None
    touch_line: str | None
    media: MediaPlan
    allowed: str            # every number source this card may use besides the fact texts
    style: list[str]        # exemplars for the LLM writer
    used_variants: list[str]


def _delta(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]]) -> int | None:
    prev = comparable(run, hist)
    if prev is None:
        return None
    use_true = _metric(prev, True) is not None and _metric(run, True) is not None
    return round(_metric(run, use_true) - _metric(prev, use_true))


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def gap_days(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]]) -> int | None:
    return (_when(run) - _when(hist[0])).days if hist else None


def hard_share(run: Mapping[str, Any]) -> float | None:
    z = T._zone_minutes(run)
    total = sum(z.values())
    return (z.get(4, 0) + z.get(5, 0)) / total if total else None


def situation_for(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]],
                  rw: RunWeather | None) -> tuple[str, dict[str, str]]:
    dist, dur = run["distance_m"], run["duration_s"]
    slots: dict[str, str] = {"km": fmt_km(dist), "min": str(round(dur / 60))}
    if run.get("pace_s_per_km"):
        slots["pace"] = fmt_pace(run["pace_s_per_km"])
    delta = _delta(run, hist)
    if delta is not None:
        slots["delta"] = str(abs(delta))
    hm = T.hard_minutes(run)
    if hm:
        slots["hard_min"] = str(hm)
    if run.get("climb_m"):
        slots["climb"] = str(run["climb_m"])
    if rw and rw.temp_c is not None:
        slots["temp"] = str(rw.temp_c)
    gap = gap_days(run, hist)
    typ = run["type"]

    if run.get("pb"):
        slots["pb"] = {"5k": "5 km best", "10k": "10 km best", "half": "half marathon best",
                       "longest": "longest run", "fastest_km": "fastest km"}[run["pb"]]
        return "pb", slots
    if gap is not None and gap >= BREAK_DAYS:
        slots["gap_txt"] = T.plural(gap, "day")
        return "back_after_break", slots
    if run.get("verdict") == "baselineSet":
        return "baseline", slots
    slower = delta is not None and (delta >= SLOW_DAY_S or (run.get("verdict") == "slower" and delta >= FASTER_S))
    if slower and typ != "interval":
        if rw and rw.temp_c is not None and rw.temp_c >= HEAT_C:
            return "slower_heat", slots
        if (run.get("climb_m") or 0) >= HILLS_M:
            return "slower_hills", slots
        if run.get("load_state") in ("high", "very_high"):
            return "slower_load", slots
        return "slower", slots
    if typ == "interval" or (typ == "race"):
        return "intervals", slots
    if typ == "tempo":
        return "tempo", slots
    if typ == "long":
        return "long", slots
    if typ == "trail" or ((run.get("climb_m") or 0) >= HILLS_M and dist and run["climb_m"] / (dist / 1000) >= 25):
        return "trail", slots
    if delta is not None and delta <= -FASTER_S:
        return "faster", slots
    share = hard_share(run)
    if typ == "easy" and (share is None or share < 0.15) and "pace" in slots:
        return "easy_right", slots
    if delta is not None or run.get("verdict") in ("holding", "noRealChange"):
        return "holding", slots
    return "steady", slots


def media_for_run(run: Mapping[str, Any], situation: str, touch: T.Touch | None) -> MediaPlan:
    share = hard_share(run)
    hard = run["type"] in HARD_TYPES or (share is not None and share >= FLOOD_SHARE)
    hm = T.hard_minutes(run)
    dist_km, dur_min = run["distance_m"] / 1000, run["duration_s"] / 60
    extra = ("milestone" if touch and touch.kind.startswith("milestone")
             else "race_countdown" if touch and touch.kind in ("race_countdown", "race_month") else None)
    if run.get("pb"):
        return MediaPlan("pb", True, "pb", extra)
    if run["type"] in HARD_TYPES and hm >= HARD_VIDEO_MIN:
        return MediaPlan("flood", True, "big_session", extra)
    if run["type"] == "long" and (dist_km >= LONG_VIDEO_KM or dur_min >= LONG_VIDEO_MIN):
        return MediaPlan("flood" if hard else "light", True, "long_run", extra)
    if hard:
        return MediaPlan("flood", False, "hard_run", extra)
    return MediaPlan("light", False, "easy", extra)


def enrich_run(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]], memory: Mapping[str, str],
               now: datetime, usage: T.Usage, rw: RunWeather | None, sunrise_count: int = 0) -> RunVoice:
    """`hist` is the whole prior record, newest first."""
    seed = str(run.get("run_id") or run.get("start_utc"))
    situation, slots = situation_for(run, hist, rw)
    rendered = voice.render(situation, slots, usage.variants, now, seed)
    if rendered is None and situation != "steady":
        situation = "steady"
        rendered = voice.render(situation, slots, usage.variants, now, seed)
    ctx = T.Ctx(run, hist, memory, now, rw.sunrise_local if rw else None, sunrise_count)
    touch = T.choose(ctx, usage)
    t_variant = t_line = None
    allowed = rendered.allowed if rendered else ""
    used = [rendered.variant_id] if rendered else []
    if touch:
        r = T.render(touch, usage, now, seed)
        if r:
            t_variant, t_line, t_allowed = r
            allowed += " " + t_allowed
            used.append(t_variant)
        else:
            touch = None
    return RunVoice(situation, rendered, touch, t_variant, t_line, media_for_run(run, situation, touch),
                    allowed, voice.exemplars(situation, 3, seed), used)
