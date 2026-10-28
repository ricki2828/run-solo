"""Glue between the facts layer and the voice: which situation is this run, which touch (if any)
rides along, and what media a channel should attach.

Pure functions. The service persists the usage log and decides when to send.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any, Mapping, Sequence

from ..facts import (FLOOD_SHARE, comparable, fmt_km, fmt_pace, is_hard_run, is_session_run, is_steady_road, is_steady_trail, pace_basis, pace_pair,
                     session_label, verdict_delta)
from ..timeutil import parse_iso
from . import touches as T
from . import voice
from .weather import HEAT_C, RunWeather

BREAK_DAYS = T.BREAK_DAYS  # a gap this long before today's run makes it a "back after a break" run
SLOW_DAY_S = 10         # as in facts.SLOW_DAY_S_PER_KM
FASTER_S = 3            # as in facts.DELTA_MIN_S_PER_KM
HILLS_M = 100           # climb that explains a slow day
# One definition of a "big session" (video-worthy besides a PB and the weekly recap):
#  - a hard-type session (interval, tempo, race) with at least HARD_VIDEO_MIN minutes in Z4 and Z5, or
#  - a long run of at least LONG_VIDEO_MIN_KM that is at least LONG_VIDEO_SHARE of the longest run in
#    the last 28 days (a run that is not your biggest recent one stays a still card).
HARD_VIDEO_MIN = 8
LONG_VIDEO_MIN_KM = 10.0
LONG_VIDEO_SHARE = 0.9
LONG_WINDOW_DAYS = 28


@dataclass(frozen=True)
class MediaPlan:
    card: str   # light | flood | pb | suggestion | weekly_recap | monthly | none
    video: bool   # a big day (the reason below). Since cards v4 every run with splits goes out as a loop; this stays the reason's flag
    reason: str
    touch_card: str | None = None  # milestone | race_countdown: a second card the channel may add
    # What the picture shows, persisted at the moment the coach decides to send the card (the server holds no routes
    # and the text it writes is not re-parseable). `facts` is for the card itself (suggestion, monthly: run and recap
    # cards rebuild theirs from the stored run rows), `touch_facts` for the touch card. Both hold only what the card's
    # own text says; see render/protocol.KIND_FACT_KEYS for the exact keys. Shown to the runner in /v1/me.
    facts: dict[str, Any] | None = None
    touch_facts: dict[str, Any] | None = None

    def to_json(self) -> str:
        d = asdict(self)
        for k in ("facts", "touch_facts"):
            if d[k] is None:
                del d[k]   # cards without a picture keep the shape they always had
        return json.dumps(d, sort_keys=True)


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


PB_EFFORT_M = {"5k": 5000, "10k": 10000, "half": 21097.5}
PB_EFFORT_NAME = {"5k": "5 km", "10k": "10 km", "half": "the half marathon"}


def fmt_duration(seconds: float) -> str:
    t = int(round(seconds))
    return f"{t // 3600}:{t % 3600 // 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60}:{t % 60:02d}"


def _delta(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]]) -> tuple[int | None, str | None]:
    """(the pace gap the card may state, the basis it is on). The app's verdict owns the direction, so a gap that
    contradicts it is not stated at all."""
    prev = comparable(run, hist)
    if prev is None:
        return None, None
    now_p, prev_p = pace_pair(run, prev)
    return verdict_delta(run, round(now_p - prev_p)), pace_basis(run, prev)


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def gap_days(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]]) -> int | None:
    return (_when(run) - _when(hist[0])).days if hist else None


hard_share = T.hard_share


def situation_for(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]],
                  rw: RunWeather | None) -> tuple[str, dict[str, str]]:
    dist, dur = run["distance_m"], run["duration_s"]
    slots: dict[str, str] = {"km": fmt_km(dist), "min": str(round(dur / 60))}
    if run.get("pace_s_per_km"):
        slots["pace"] = fmt_pace(run["pace_s_per_km"])
    delta, basis = _delta(run, hist)
    if delta is not None:
        slots["delta"] = str(abs(delta))
        if basis == "true" and abs(delta) >= FASTER_S:
            slots.pop("pace", None)  # the gap is on true pace: the raw pace never shares a line with it
    hm = T.hard_minutes(run)
    if hm:
        slots["hard_min"] = str(hm)
    if run.get("climb_m"):
        slots["climb"] = str(run["climb_m"])
    if rw and rw.temp_c is not None:
        slots["temp"] = str(rw.temp_c)
    gap = gap_days(run, hist)
    typ = run["type"]
    session = is_session_run(run)
    if session:
        # An interval session speaks in its own terms: the session, its work pace and its reps, never the whole-run pace.
        slots["session_line"] = session_label(run)
        slots["work_pace"] = fmt_pace(run["work_pace_s_per_km"])
        if run.get("reps_done"):
            slots["reps"] = str(run["reps_done"])
        slots.pop("pace", None)
        if delta is not None and abs(delta) >= FASTER_S:
            slots["cmp_dir"] = "faster" if delta < 0 else "slower"
        else:
            slots.pop("delta", None)

    if run.get("pb"):
        slots["pb"] = {"5k": "5 km best", "10k": "10 km best", "half": "half marathon best",
                       "longest": "longest run", "fastest_km": "fastest km"}[run["pb"]]
        if run["pb"] in ("5k", "10k", "half"):
            # A race PB leads with the time, not the pace. The effort's own time when the app sent it: the PB can be a
            # stretch inside a longer run, and then it is the effort that is spoken of, never the run's time or distance.
            slots["time"] = fmt_duration(run.get("pb_s") or dur)
            if run.get("pb_s") and dist > PB_EFFORT_M[run["pb"]] * 1.03:
                slots["pb_dist"] = PB_EFFORT_NAME[run["pb"]]
                return "pb_effort", slots
            return "pb", slots
        return "pb_other", slots
    if gap is not None and gap >= BREAK_DAYS:
        slots["gap_txt"] = T.plural(gap, "day")
        return "back_after_break", slots
    if run.get("verdict") == "baselineSet":
        if session and "reps" in slots:
            return "interval_baseline", slots
        return "baseline", slots
    if session and typ == "interval" and "reps" in slots:
        return "interval_work", slots
    slower = delta is not None and (delta >= SLOW_DAY_S or (run.get("verdict") == "slower" and delta >= FASTER_S))
    if slower and typ != "interval":
        if rw and rw.temp_c is not None and rw.temp_c >= HEAT_C:
            return "slower_heat", slots
        if (run.get("climb_m") or 0) >= HILLS_M:
            return "slower_hills", slots
        if run.get("load_state") in ("high", "very_high"):
            return "slower_load", slots
        return "slower", slots
    if run.get("app_type") == "trail":  # "trail" stays the place; the session the coach knows is named inside it
        if is_steady_trail(run):
            return "trail_steady", slots   # mostly Z3 is not an easy effort, whatever the climbs did to the type
        return {"easy": "trail_easy", "tempo": "trail_tempo", "long": "trail_long"}.get(typ, "trail"), slots
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
    if is_steady_road(run):
        return "road_steady", slots   # mostly Z3 is not an easy effort: the road twin of trail_steady
    share = hard_share(run)
    if typ == "easy" and (share is None or share < 0.15) and "pace" in slots:
        return "easy_right", slots
    if delta is not None or run.get("verdict") in ("holding", "noRealChange"):
        return "holding", slots
    return "steady", slots


def big_session(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]]) -> str | None:
    """The reason this run is a big session, or None."""
    if is_hard_run(run) and T.hard_minutes(run) >= HARD_VIDEO_MIN:
        return "big_session"
    if run["type"] == "long" and run["distance_m"] / 1000 >= LONG_VIDEO_MIN_KM:
        t0 = _when(run)
        recent = [h["distance_m"] for h in hist
                  if h.get("distance_m") and 0 < (t0 - _when(h)).days <= LONG_WINDOW_DAYS]
        if not recent or run["distance_m"] >= LONG_VIDEO_SHARE * max(recent):
            return "long_run"
    return None


# The line under a milestone number. Fixed copy keyed on the number: nothing personal, nothing the text does not say.
MILESTONE_LINE = {
    ("runs", 10): "Double digits.", ("runs", 25): "A habit forming.", ("runs", 50): "Fifty on the board.",
    ("runs", 100): "Triple digits.", ("runs", 150): "Still showing up.", ("runs", 200): "Two hundred and counting.",
    ("runs", 250): "A quarter of a thousand.", ("runs", 300): "Three hundred strong.", ("runs", 400): "Four hundred runs.",
    ("runs", 500): "Five hundred runs.", ("runs", 750): "Seven hundred and fifty.", ("runs", 1000): "One thousand runs.",
    ("distance_km", 100): "The first hundred.", ("distance_km", 250): "A quarter way to a thousand.",
    ("distance_km", 500): "Halfway to a thousand.", ("distance_km", 1000): "A thousand kilometres.",
    ("distance_km", 1500): "Fifteen hundred.", ("distance_km", 2000): "Two thousand kilometres.",
    ("distance_km", 2500): "Twenty-five hundred.", ("distance_km", 3000): "Three thousand kilometres.",
    ("distance_km", 4000): "Four thousand kilometres.", ("distance_km", 5000): "Five thousand kilometres.",
}


# The goal the runner told the coach (memory goal_type), as the card's title. Not a race name: we only know the distance.
GOAL_TITLE = {"5k": "5 km", "10k": "10 km", "half": "Half marathon", "marathon": "Marathon"}


def touch_card_facts(touch: T.Touch | None, memory: Mapping[str, str] | None = None) -> tuple[str | None, dict[str, Any] | None]:
    """-> (touch card kind, the facts it shows). Only what the touch line already says: the milestone number, or the
    whole weeks to the race. race_month ("N months away") stays text: a month is not a countdown."""
    if touch is None:
        return None, None
    try:
        if touch.kind == "milestone_runs":
            n = int(touch.slots["n"])
            return "milestone", {"kind": "runs", "value": n, "line": MILESTONE_LINE.get(("runs", n), "")}
        if touch.kind == "milestone_km":
            n = int(touch.slots["total_km"])
            return "milestone", {"kind": "distance_km", "value": n, "line": MILESTONE_LINE.get(("distance_km", n), "")}
        if touch.kind == "race_countdown":
            facts: dict[str, Any] = {"weeks_to_race": int(touch.key.split(":", 1)[1])}
            title = GOAL_TITLE.get((memory or {}).get("goal_type", ""))
            if title:
                facts["race_name"] = title
            return "race_countdown", facts
    except (KeyError, ValueError, IndexError):
        pass
    return None, None


def media_for_run(run: Mapping[str, Any], situation: str, touch: T.Touch | None,
                  hist: Sequence[Mapping[str, Any]] = (), memory: Mapping[str, str] | None = None) -> MediaPlan:
    hard = is_hard_run(run)
    extra, tfacts = touch_card_facts(touch, memory)
    if run.get("pb"):
        return MediaPlan("pb", True, "pb", extra, None, tfacts)
    reason = big_session(run, hist)
    if reason:
        return MediaPlan("flood" if hard else "light", True, reason, extra, None, tfacts)
    if hard:
        return MediaPlan("flood", False, "hard_run", extra, None, tfacts)
    return MediaPlan("light", False, "easy", extra, None, tfacts)


def enrich_run(run: Mapping[str, Any], hist: Sequence[Mapping[str, Any]], memory: Mapping[str, str],
               now: datetime, usage: T.Usage, rw: RunWeather | None, sunrise_count: int = 0,
               prev_situation: str | None = None, soften: bool = False) -> RunVoice:
    """`hist` is the whole prior record, newest first."""
    seed = str(run.get("run_id") or run.get("start_utc"))
    situation, slots = situation_for(run, hist, rw)
    rendered = voice.render(situation, slots, usage.variants, now, seed)
    if rendered is None and situation in ("interval_baseline", "interval_work"):
        situation = "intervals"
        rendered = voice.render(situation, slots, usage.variants, now, seed)
    if rendered is None and situation != "steady":
        situation = "steady"
        rendered = voice.render(situation, slots, usage.variants, now, seed)
    ctx = T.Ctx(run, hist, memory, now, rw.sunrise_local if rw else None, sunrise_count, prev_situation, frozenset(usage.feel_refs), soften)
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
    return RunVoice(situation, rendered, touch, t_variant, t_line, media_for_run(run, situation, touch, hist, memory),
                    allowed, voice.exemplars(situation, 3, seed), used)
