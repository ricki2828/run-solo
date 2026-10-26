"""The Sunday recap (7 pm local) and which runs and moments are video-worthy."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
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
LOAD_COVERAGE = 0.8          # the recap speaks in load only when this share of the last 5 weeks' runs carry the app's own load
LOAD_USUAL_WEEKS = 4         # the usual week is the mean of this many weeks before the recap week
LOAD_SHOWN_WEEKS = 6         # the card draws the recap week and the 5 before it
LOAD_MIN_USUAL = 60          # a usual week lighter than this is too small to compare against (the app's minChronicWeekly)
LOAD_LIGHTER, LOAD_USUAL, LOAD_JUMP = 0.80, 1.10, 1.30   # ratio edges: lighter < 0.80 <= usual <= 1.10 < step up <= 1.30 < big jump
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


def run_load(r: Mapping[str, Any]) -> tuple[float, str]:
    """(load, basis) for one run. The app's own number when it sent one. Otherwise an estimate from the zone minutes
    (sum of minutes x zone, 1-5), or 2.5 x the minutes when there are no zones: basis 'server_estimate'."""
    v = r.get("load")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v), str(r.get("load_basis") or "assumed")
    zm = T._zone_minutes(r)
    if sum(zm.values()) > 0:
        return sum(min(z, 5) * m for z, m in zm.items()), "server_estimate"
    return r["duration_s"] / 60 * 2.5, "server_estimate"


def _run_zone_shares(r: Mapping[str, Any]) -> list[float] | None:
    """The run's share of time in each of Z1-Z5, or None when it has no heart-rate zones."""
    zm = T._zone_minutes(r)
    tot = sum(zm.values())
    if tot <= 0:
        return None
    out = [0.0] * 5
    for z, m in zm.items():
        out[min(z, 5) - 1] += m / tot
    return out


def load_band(ratio: float) -> str:
    return "lighter" if ratio < LOAD_LIGHTER else "usual" if ratio <= LOAD_USUAL else "stepUp" if ratio <= LOAD_JUMP else "bigJump"


def load_words(band: str, pct: int, ratio: float) -> str:
    """The card's one line under the hero, the same words as the app's weekly story."""
    if band == "usual":
        return "About your usual week"
    if band == "lighter":
        return f"{pct}% less than your usual week"
    return "About double your usual week" if ratio >= 1.9 else f"{pct}% more than your usual week"


def load_facts(runs: Sequence[Mapping[str, Any]], zone_id: str, monday: datetime,
               paused: Sequence[date] = ()) -> dict[str, Any] | None:
    """This Mon-Sun week's load against the runner's usual week, or None when the recap should stay on km: fewer than
    80% of the runs in this week and the 4 before carry the app's own load; the week has no runs; the runner is
    returning (the 2 weeks before were empty and not paused); fewer than 2 usual weeks with runs; or a usual week
    under 60. `paused` are the Mondays of weeks the coach was in care of: they count for nothing either way."""
    mondays = [monday - timedelta(days=7 * i) for i in range(LOAD_SHOWN_WEEKS - 1, -1, -1)]
    by_week: list[list[Mapping[str, Any]]] = [_week_runs(runs, zone_id, m) for m in mondays]
    if not by_week[-1]:
        return None
    window = [r for w in by_week[1:] for r in w]   # this week and the 4 before
    if sum(1 for r in window if r.get("load") is not None) < LOAD_COVERAGE * len(window):
        return None
    pausedset = set(paused)
    is_paused = [m.date() in pausedset for m in mondays]
    if all(not by_week[i] and not is_paused[i] for i in (-2, -3)):
        return None   # a returner: nothing to compare against
    first = min(_week_start(r, zone_id) for r in runs)
    weeks = []
    for m, wr, p in zip(mondays, by_week, is_paused):
        total, zone, nohr = 0.0, [0.0] * 5, 0.0
        for r in wr:
            ld = run_load(r)[0]
            total += ld
            sh = _run_zone_shares(r)
            if sh is None:
                nohr += ld
            else:
                zone = [a + ld * b for a, b in zip(zone, sh)]
        weeks.append({"monday": m.date().isoformat(), "load": round(total), "paused": p,
                      "zone_share": [round(z / total, 3) if total else 0.0 for z in zone],
                      "nohr_share": round(nohr / total, 3) if total else 0.0, "_runs": len(wr), "_raw": total})
    counted = [w for w, m in zip(weeks[1:5], mondays[1:5]) if not w["paused"] and m >= first]
    if sum(1 for w in counted if w["_runs"]) < 2:
        return None
    usual = sum(w["_raw"] for w in counted) / len(counted)
    if usual < LOAD_MIN_USUAL:
        return None
    this = weeks[-1]["_raw"]
    ratio = this / usual
    band = load_band(ratio)
    pct = round(abs(ratio - 1) * 100)
    for w in weeks:
        w.pop("_runs"), w.pop("_raw")
    return {"load": round(this), "usual_load": round(usual), "band": band, "pct": pct, "weeks": weeks}


def _week_start(r: Mapping[str, Any], zone_id: str) -> datetime:
    loc = to_local(_when(r), r.get("zone_id") or zone_id).replace(tzinfo=None)
    return (loc - timedelta(days=loc.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)


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
        # One basis, said out loud: the coach's session paces are True Pace, so when every run this week has one the
        # quickest is judged on it and labelled (a mix of the two bases is never compared)
        if all(r.get("true_pace_s_per_km") for r in paced):
            q = min(paced, key=lambda r: r["true_pace_s_per_km"])
            return f"Quickest was {fmt_pace(q['true_pace_s_per_km'])}/km true pace on {day(q)}."
        q = min(paced, key=lambda r: r["pace_s_per_km"])
        return f"Quickest was {fmt_pace(q['pace_s_per_km'])}/km on {day(q)}."
    return ""


MONTHLY_DAY = 1               # the 1st of the month, for the month just ended
MONTHLY_DAYS = 3              # ... which may wait until the 2nd or 3rd when the 1st is the recap's day or already full
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


LOAD_SITUATION = {"usual": "recap_load_usual", "stepUp": "recap_load_step", "bigJump": "recap_load_jump", "lighter": "recap_load_light"}


def build(runs: Sequence[Mapping[str, Any]], now: datetime, zone_id: str, used: Mapping[str, datetime],
          seed: str, paused_weeks: Sequence[date] = ()) -> Recap | None:
    """`runs`: the whole record, newest first. The week is the local Mon-Sun week containing `now`. `paused_weeks`:
    Mondays of the weeks the coach held back (care weeks); the load comparison leaves them out."""
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
    lf = None
    slots = {"runs_txt": T.plural(len(week), "run"), "km": f"{km:.1f}", "min": str(minutes), "moment": moment}
    if not prev:
        situation = "recap_return" if any(_when(r) < _to_utc(monday, zone_id) for r in runs) else "recap_first"
    elif _part_week_start(runs, zone_id, monday - timedelta(days=7)):
        situation = "recap_first_full"   # last week was the runner's first and only a few days long: not a baseline
    else:
        diff = km - prev_km
        slots["delta_km"] = f"{abs(diff):.1f}"
        situation = "recap_flat" if abs(diff) < FLAT_KM else "recap_up" if diff > 0 else "recap_down"
        lf = load_facts(runs, zone_id, monday, paused_weeks)
        if lf:   # speak in load, against the runner's own usual week
            situation = LOAD_SITUATION[lf["band"]]
            slots.update(load=str(lf["load"]), usual=str(lf["usual_load"]), pct=str(lf["pct"]),
                         cap=str(int(round(lf["usual_load"] * 1.1 / 10)) * 10))
    r = voice.render(situation, slots, used, now, seed)
    if r is None:
        return None
    r = voice.Rendered(r.situation, r.variant_id, r.headline, r.body.strip(), r.allowed)
    video = True  # the weekly recap is always a video moment
    return Recap(r, MediaPlan("weekly_recap", video, "weekly_recap", facts=lf), voice.exemplars(situation, 3, seed), False,
                 tuple(str(r["run_id"]) for r in week if r.get("run_id")))
