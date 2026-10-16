"""The Sunday recap (7 pm local) and which runs and moments are video-worthy."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Mapping, Sequence

from ..facts import fmt_km, fmt_pace
from ..timeutil import UTC, parse_iso, to_local, zone
from . import touches as T
from . import voice
from .engine import MediaPlan

RECAP_WEEKDAY = 6            # Sunday
RECAP_START_MIN = 19 * 60    # plan from 19:00 local ...
RECAP_END_MIN = 20 * 60      # ... until 20:00
PART_WEEK_FROM_WEEKDAY = 3   # a first run on Thursday (0 = Monday) or later makes that week a part week
FLAT_KM = 1.0                # a swing under this many km is "level"
QUIET_AFTER_DAYS = 60        # nothing to say to someone who has not run for two months
WEEKDAY = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
PB_NAME = {"5k": "5 km best", "10k": "10 km best", "half": "half marathon best",
           "longest": "longest run", "fastest_km": "fastest km"}


@dataclass(frozen=True)
class Recap:
    rendered: voice.Rendered
    media: MediaPlan
    style: list[str]
    empty: bool  # a missed week
    week_run_ids: tuple[str, ...] = ()  # this week's runs, newest first: the service quotes a note from one of them


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def _week_runs(runs: Sequence[Mapping[str, Any]], zone_id: str, monday: datetime) -> list[Mapping[str, Any]]:
    lo, hi = monday, monday + timedelta(days=7)
    out = []
    for r in runs:
        loc = to_local(_when(r), r.get("zone_id") or zone_id).replace(tzinfo=None)
        if lo <= loc < hi:
            out.append(r)
    return out


def _to_utc(naive_local: datetime, zone_id: str) -> datetime:
    return naive_local.replace(tzinfo=zone(zone_id)).astimezone(UTC)


def _part_week_start(runs: Sequence[Mapping[str, Any]], zone_id: str, prev_monday: datetime) -> bool:
    """True when the runner's very first run fell in the week starting `prev_monday` on a Thursday or later, so that
    week is a few days long and "up on last week" would be a comparison against a part week."""
    first = min(runs, key=_when)
    loc = to_local(_when(first), first.get("zone_id") or zone_id).replace(tzinfo=None)
    return prev_monday <= loc < prev_monday + timedelta(days=7) and loc.weekday() >= PART_WEEK_FROM_WEEKDAY


def best_moment(week: Sequence[Mapping[str, Any]], zone_id: str) -> str:
    """A single sentence naming the week's best moment, from the data only. May be empty."""
    def day(r):
        return WEEKDAY[to_local(_when(r), r.get("zone_id") or zone_id).weekday()]
    for r in week:
        if r.get("pb") in PB_NAME:
            return f"Best moment: your {PB_NAME[r['pb']]} on {day(r)}."
    if len(week) >= 2:
        avg = sum(r["distance_m"] for r in week) / len(week)
        longest = max(week, key=lambda r: r["distance_m"])
        if longest["distance_m"] >= 1.3 * avg:
            return f"Best moment: the {fmt_km(longest['distance_m'])} km on {day(longest)}."
    climby = max(week, key=lambda r: r.get("climb_m") or 0)
    if (climby.get("climb_m") or 0) >= 150:
        return f"Best moment: {climby['climb_m']} m of climb on {day(climby)}."
    paced = [r for r in week if r.get("pace_s_per_km")]
    if len(paced) >= 2:
        q = min(paced, key=lambda r: r["pace_s_per_km"])
        return f"Quickest was {fmt_pace(q['pace_s_per_km'])}/km on {day(q)}."
    return ""


MONTHLY_DAY = 1               # the 1st of the month, for the month just ended
MONTHLY_START_MIN = 9 * 60    # plan from 09:00 local ...
MONTHLY_END_MIN = 12 * 60     # ... until noon: room to wait out MONTHLY_MIN_GAP_H after another card
MONTHLY_MIN_GAP_H = 3         # never within this long of another card
MONTH_NAMES = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
               "November", "December")


def previous_month(now: datetime, zone_id: str) -> str:
    """'YYYY-MM' of the month before the local month containing `now`."""
    loc = to_local(now, zone_id)
    y, m = (loc.year - 1, 12) if loc.month == 1 else (loc.year, loc.month - 1)
    return f"{y}-{m:02d}"


def month_runs(runs: Sequence[Mapping[str, Any]], zone_id: str, month_ref: str) -> list[Mapping[str, Any]]:
    """The runs whose local start falls in 'YYYY-MM'."""
    return [r for r in runs if to_local(_when(r), r.get("zone_id") or zone_id).strftime("%Y-%m") == month_ref]


def build_monthly(runs: Sequence[Mapping[str, Any]], month_ref: str, zone_id: str, used: Mapping[str, datetime],
                  now: datetime, seed: str) -> Recap | None:
    """The poster text for a finished month. None when the month had no runs (nothing to say, never a nag)."""
    mine = month_runs(runs, zone_id, month_ref)
    if not mine:
        return None
    km = sum(r["distance_m"] for r in mine) / 1000
    hours = max(1, round(sum(r["duration_s"] for r in mine) / 3600))
    slots = {"month": MONTH_NAMES[int(month_ref[5:]) - 1], "runs_txt": T.plural(len(mine), "run"), "km": f"{km:.1f}",
             "hours_txt": T.plural(hours, "hour")}
    r = voice.render("recap_month", slots, used, now, seed)
    if r is None:
        return None
    return Recap(r, MediaPlan("monthly", False, "monthly"), voice.exemplars("recap_month", 3, seed), False,
                 tuple(str(x["run_id"]) for x in mine if x.get("run_id")))


def build(runs: Sequence[Mapping[str, Any]], now: datetime, zone_id: str, used: Mapping[str, datetime],
          seed: str) -> Recap | None:
    """`runs`: the whole record, newest first. The week is the local Mon-Sun week containing `now`."""
    if not runs:
        return None
    local = to_local(now, zone_id)
    monday = (local - timedelta(days=local.weekday())).replace(hour=0, minute=0, second=0, microsecond=0, tzinfo=None)
    week = _week_runs(runs, zone_id, monday)
    prev = _week_runs(runs, zone_id, monday - timedelta(days=7))
    if not week:
        gap = (now - _when(runs[0])).days
        if gap > QUIET_AFTER_DAYS:
            return None
        slots = {"gap_txt": T.plural(max(gap, 1), "day")}
        r = voice.render("missed_week", slots, used, now, seed)
        return Recap(r, MediaPlan("none", False, "missed_week"), voice.exemplars("missed_week", 3, seed), True) if r else None
    km = sum(r["distance_m"] for r in week) / 1000
    prev_km = sum(r["distance_m"] for r in prev) / 1000
    minutes = round(sum(r["duration_s"] for r in week) / 60)
    moment = best_moment(week, zone_id)
    slots = {"runs_txt": T.plural(len(week), "run"), "km": f"{km:.1f}", "min": str(minutes), "moment": moment}
    if not prev:
        situation = "recap_return" if any(_when(r) < _to_utc(monday, zone_id) for r in runs) else "recap_first"
    elif _part_week_start(runs, zone_id, monday - timedelta(days=7)):
        situation = "recap_first_full"   # last week was the runner's first and only a few days long: not a baseline
    else:
        diff = km - prev_km
        slots["delta_km"] = f"{abs(diff):.1f}"
        situation = "recap_flat" if abs(diff) < FLAT_KM else "recap_up" if diff > 0 else "recap_down"
    r = voice.render(situation, slots, used, now, seed)
    if r is None:
        return None
    r = voice.Rendered(r.situation, r.variant_id, r.headline, r.body.strip(), r.allowed)
    video = True  # the weekly recap is always a video moment
    return Recap(r, MediaPlan("weekly_recap", video, "weekly_recap"), voice.exemplars(situation, 3, seed), False,
                 tuple(str(r["run_id"]) for r in week if r.get("run_id")))
