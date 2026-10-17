"""The default coach week: the plan a runner gets when they have not built a 4-week plan in the app.

Pure logic, no I/O. It reads only what the runner already told us (usual_days, runs_per_week, goal_type) and what their
runs show (how often, how far, how hard). The output is a `Planned` for `checkins`, so check-ins, the morning card, the
week card and Home's next session all work with no new surface. A real plan on the newest run always wins (the caller
only asks here when `planned_from_run` found nothing). Nothing is stored: it is re-derived on every read.

The rules, all explainable:
- Runs a week: the runner's `runs_per_week` answer, else what the last 4 weeks show (clamped to 2-4), else 3.
- Days: spread evenly across the runner's usual days (weekdays or weekends); with no stated days, the weekdays they
  actually run on, most often first.
- Shape: the last run of the week is the longer one (3+ runs), the middle one is the quality session, the rest are easy.
- Distance: easy is the median of the recent runs, in whole km. Longer is about 1.4x that, never beyond the longest
  recent run plus 20 percent. Quality is the easy distance.
- Quality only when the runner has run at least 4 times in 4 weeks, no hard run in the 48 h before it, and goal is not
  'recovery'. Otherwise that day is easy.
- A week with its runs already done waits for next Monday. Today does not count when a run is already done today.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from statistics import median
from typing import Any, Mapping, Sequence

from .checkins import Planned, at_local, usual_weekdays
from .facts import is_hard_run
from .timeutil import parse_iso, to_local

WINDOW_DAYS = 28
MIN_RUNS = 2            # fewer runs in the window and there is no habit to build a week from
MIN_RUNS_FOR_QUALITY = 4
MIN_EASY_KM, MAX_EASY_KM, DEFAULT_EASY_KM = 3, 12, 4
LONG_FACTOR, LONG_CAP_FACTOR = 1.4, 1.2
HARD_GAP_H = 48
MAX_RUNS_PER_WEEK = 4


@dataclass(frozen=True)
class DaySession:
    day: date
    type: str            # easy | long | quality
    distance_m: int


def _local_day(r: Mapping[str, Any], zone_id: str) -> date:
    return to_local(parse_iso(r["start_utc"]), r.get("zone_id") or zone_id).date()


def runs_per_week(memory_value: str | None, recent: Sequence[Mapping[str, Any]]) -> int:
    if memory_value and memory_value.isdigit():
        return max(2, min(MAX_RUNS_PER_WEEK, int(memory_value)))
    if len(recent) >= MIN_RUNS:
        return max(2, min(MAX_RUNS_PER_WEEK, round(len(recent) / (WINDOW_DAYS / 7))))
    return 3


def _spread(days: list[int], n: int) -> list[int]:
    n = min(n, len(days))
    if n <= 1:
        return days[:1]
    return [days[round(i * (len(days) - 1) / (n - 1))] for i in range(n)]


def _km(m: float) -> int:
    return int(round(m / 1000))


def week_template(recent: Sequence[Mapping[str, Any]], n: int, usual: frozenset[int] | None,
                  allow_quality: bool) -> list[tuple[int, str, int]]:
    """-> [(weekday, type, distance_m)] for one week, oldest weekday first."""
    dists = [r["distance_m"] for r in recent if r.get("distance_m")]
    easy_km = max(MIN_EASY_KM, min(MAX_EASY_KM, _km(median(dists)))) if dists else DEFAULT_EASY_KM
    longest_km = max((d for d in dists), default=easy_km * 1000) / 1000
    long_km = max(easy_km + 1, min(round(easy_km * LONG_FACTOR), int(longest_km * LONG_CAP_FACTOR)))
    if usual:
        wds = _spread(sorted(usual), n)
    else:   # no stated days: the weekdays this runner actually runs on, most often first
        zone = recent[0].get("zone_id") if recent else None
        freq = Counter(to_local(parse_iso(r["start_utc"]), r.get("zone_id") or zone).weekday() for r in recent)
        wds = sorted(sorted(range(7), key=lambda w: (-freq[w], w))[:n])
    out: list[tuple[int, str, int]] = []
    for i, wd in enumerate(wds):
        if len(wds) >= 3 and i == len(wds) - 1:
            typ, km = "long", long_km
        elif allow_quality and len(wds) >= 3 and i == len(wds) // 2 - (1 if len(wds) == 4 else 0):
            typ, km = "quality", easy_km
        else:
            typ, km = "easy", easy_km
        out.append((wd, typ, km * 1000))
    return out


def build_week(history: Sequence[Mapping[str, Any]], *, memory: Mapping[str, str], zone_id: str, today: date,
               now: datetime, horizon_days: int = 14) -> list[DaySession]:
    """The runner's coming sessions, oldest first, from today. [] when there is no habit to build from.
    `history` is the runner's runs, newest first."""
    recent = [r for r in history if 0 <= (now - parse_iso(r["start_utc"])).days <= WINDOW_DAYS]
    if len(recent) < MIN_RUNS:
        return []
    usual = usual_weekdays(memory.get("usual_days"))
    n = runs_per_week(memory.get("runs_per_week"), recent)
    allow_quality = len(recent) >= MIN_RUNS_FOR_QUALITY and memory.get("goal_type") != "recovery"
    tmpl = week_template(recent, n, usual, allow_quality)
    ran_days = {_local_day(r, zone_id) for r in history}
    hards = [parse_iso(r["start_utc"]) for r in history if is_hard_run(r)]
    monday = today - timedelta(days=today.weekday())
    done_this_week = sum(1 for d in ran_days if monday <= d <= monday + timedelta(days=6))
    out: list[DaySession] = []
    for off in range(horizon_days):
        d = today + timedelta(days=off)
        if d in ran_days:
            continue                      # already run that day (only today can be)
        wk_monday = d - timedelta(days=d.weekday())
        if wk_monday == monday and done_this_week >= len(tmpl):
            continue                      # this week's runs are done: wait for Monday
        for wd, typ, dist in tmpl:
            if wd != d.weekday():
                continue
            if typ == "quality":
                start = at_local(d, 0, zone_id)
                if any(abs((start - h).total_seconds()) < HARD_GAP_H * 3600 for h in hards):
                    typ = "easy"
            out.append(DaySession(d, typ, dist))
    return out


def next_planned(history: Sequence[Mapping[str, Any]], *, memory: Mapping[str, str], zone_id: str, today: date,
                 now: datetime) -> Planned | None:
    week = build_week(history, memory=memory, zone_id=zone_id, today=today, now=now)
    if not week:
        return None
    s = week[0]
    return Planned(s.type, s.day, distance_m=s.distance_m, derived=True)


def shape_line(sessions: Sequence[DaySession], monday: date) -> str | None:
    """"Next week: Mon easy 5 km, Wed quality 5 km, Fri long 6 km." from the sessions that fall in the week starting
    `monday`, or None when there are none."""
    mine = [x for x in sessions if monday <= x.day < monday + timedelta(days=7)]
    if not mine:
        return None
    return "Next week: " + ", ".join(f"{x.day:%a} {x.type} {_km(x.distance_m)} km" for x in mine) + "."
