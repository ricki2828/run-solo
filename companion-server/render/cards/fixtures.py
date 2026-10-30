"""Realistic fixtures for the cards and their goldens. Deterministic: no clocks, no randomness at import.

Run facts (shared by cards and motion): type, title, start_local, place_note, distance_km, duration_s,
pace_s_per_km, avg_hr, climb_m, zone_s [z1..z5 seconds], route [[lat, lon]], verdict, headline, hero {value, unit},
reps [{time_s, zone}] (one per rep, in order), pb, pb_detail, and splits: a list of {km, pace_s, zone} where `km` is the split length
(1.0, the last one fractional), `pace_s` its pace in s/km and `zone` the dominant HR zone 1..5.
"""
from __future__ import annotations

import math
import random
from typing import Any

MEMORY = {"name": "Ricki"}


def _stadium(lat0: float, lon0: float, straight_m: float = 84, radius_m: float = 36, turns: int = 1) -> list[list[float]]:
    pts = []
    mlat = 1 / 110540.0
    mlon = 1 / (111320.0 * math.cos(math.radians(lat0)))
    for _ in range(turns):
        for i in range(0, 181, 6):
            a = math.radians(i - 90)
            pts.append((radius_m * math.cos(a) + straight_m / 2, radius_m * math.sin(a)))
        for i in range(0, 181, 6):
            a = math.radians(i + 90)
            pts.append((radius_m * math.cos(a) - straight_m / 2, radius_m * math.sin(a)))
    pts.append(pts[0])
    return [[lat0 + y * mlat, lon0 + x * mlon] for x, y in pts]


def _loop(lat0: float, lon0: float, size_m: float, seed: int, wobble: float = 0.28, tail: float = 0.0) -> list[list[float]]:
    rnd = random.Random(seed)
    ph = [rnd.uniform(0, 6.28) for _ in range(4)]
    am = [wobble * rnd.uniform(.5, 1), wobble * .6 * rnd.uniform(.4, 1), wobble * .35 * rnd.uniform(.3, 1)]
    pts = []
    for i in range(0, 361, 3):
        t = math.radians(i)
        r = size_m * (1 + am[0] * math.sin(2 * t + ph[0]) + am[1] * math.sin(3 * t + ph[1]) + am[2] * math.cos(5 * t + ph[2]))
        pts.append((r * math.cos(t) * 1.15, r * math.sin(t) * .8))
    if tail:
        pts += [(pts[0][0] - tail * k / 8, pts[0][1] + tail * .15 * math.sin(k)) for k in range(1, 9)][::1]
    mlat = 1 / 110540.0
    mlon = 1 / (111320.0 * math.cos(math.radians(lat0)))
    return [[lat0 + y * mlat, lon0 + x * mlon] for x, y in pts]


def _out_and_back(lat0: float, lon0: float, length_m: float, seed: int) -> list[list[float]]:
    rnd = random.Random(seed)
    mlat = 1 / 110540.0
    mlon = 1 / (111320.0 * math.cos(math.radians(lat0)))
    out = []
    for i in range(0, 101):
        x = length_m * i / 100
        y = 110 * math.sin(i / 100 * 4.2 + rnd.random() * .3) + 9 * math.sin(i / 100 * 9 + seed)
        out.append((x, y))
    back = [(x, y + 5) for x, y in reversed(out)]
    return [[lat0 + y * mlat, lon0 + x * mlon] for x, y in out + back]


def shape_xy(route: list[list[float]], max_points: int = 100, grid: int = 255) -> list[list[int]]:
    """A lat/lon fixture route as the app sends it: x,y whole numbers on a 0..255 grid, y down, longer side the full
    grid, no coordinates left. (Fixture-only: it skips the phone's rotation and Douglas-Peucker, it only thins.)"""
    k = math.cos(math.radians(sum(p[0] for p in route) / len(route)))
    pts = [(lon * k, -lat) for lat, lon in route]
    step = max(1, math.ceil(len(pts) / max_points))
    pts = pts[::step] + ([pts[-1]] if (len(pts) - 1) % step else [])
    x0, y0 = min(p[0] for p in pts), min(p[1] for p in pts)
    span = max(max(p[0] for p in pts) - x0, max(p[1] for p in pts) - y0)
    return [[round((x - x0) / span * grid), round((y - y0) / span * grid)] for x, y in pts]


def _splits(distance_km: float, duration_s: float, zones: list[int], seed: int) -> list[dict[str, Any]]:
    """Per-km splits whose lengths sum to distance_km and whose times sum to duration_s."""
    rnd = random.Random(seed)
    n = math.ceil(distance_km)
    kms = [1.0] * (n - 1) + [round(distance_km - (n - 1), 2)]
    raw = [1 + (z - 3) * -0.03 + rnd.uniform(-.015, .015) for z in (zones[i % len(zones)] for i in range(n))]
    scale = duration_s / sum(k * r for k, r in zip(kms, raw))
    return [{"km": k, "pace_s": round(r * scale), "zone": zones[i % len(zones)]} for i, (k, r) in enumerate(zip(kms, raw))]


def singapore_intervals() -> dict[str, Any]:
    return {
        "type": "interval", "title": "8 × 400 m", "start_local": "2026-10-08T06:10", "place_note": "Singapore",
        "distance_km": 9.6, "duration_s": 3170, "pace_s_per_km": 330, "work_pace_s_per_km": 210.4, "avg_hr": 158,
        "zone_s": [240, 420, 360, 780, 1370],
        "route": _stadium(1.3631, 103.8478, turns=1),
        "verdict": "faster", "headline": "Eight reps, all on pace.",
        "hero": {"value": "1:24", "unit": "/400 M AVG"},
        "splits": _splits(9.6, 3170, [2, 2, 4, 5, 5, 4, 5, 5, 3, 2], seed=1),
        "reps": [{"time_s": t, "zone": z} for t, z in zip((86, 85, 84, 84, 82, 81, 85, 85), (4, 5, 5, 5, 5, 5, 5, 5))],
    }


def milos_trail() -> dict[str, Any]:
    return {
        "type": "long", "title": "Kastro loop", "start_local": "2026-09-27T07:20", "place_note": "Milos",
        "distance_km": 12.4, "duration_s": 5330, "pace_s_per_km": 430, "climb_m": 234, "avg_hr": 146,
        "zone_s": [420, 2410, 1850, 560, 90],
        "route": _loop(36.7249, 24.4311, 520, seed=11, wobble=.34),
        "verdict": "holding", "headline": "Third time up the Kastro.",
        "splits": _splits(12.4, 5330, [2, 3, 3, 2, 2, 3, 4, 3, 2, 2, 3, 2, 2], seed=2),
    }


def milos_trail_run() -> dict[str, Any]:
    """The app's own `trail` type (not a coach type like `long`): what a Trail run reaches the card as."""
    return milos_trail() | {"type": "trail", "title": "Trail run"}


def slow_hot_day() -> dict[str, Any]:
    return {
        "type": "easy", "title": "Easy run", "start_local": "2026-10-06T17:40", "place_note": "32° and humid",
        "distance_km": 6.2, "duration_s": 2700, "pace_s_per_km": 435, "avg_hr": 151,
        "zone_s": [180, 760, 1290, 420, 50],
        "route": _loop(1.2903, 103.8520, 430, seed=5, wobble=.18),
        "verdict": "slower", "headline": "Slow, and fair enough.",
        "splits": _splits(6.2, 2700, [2, 3, 3, 3, 3, 4, 3], seed=3),
    }


def pb_5k() -> dict[str, Any]:
    return {
        "type": "race", "title": "5 km best", "start_local": "2026-10-04T07:00", "place_note": "Parkrun",
        "distance_km": 5.0, "duration_s": 1301, "pace_s_per_km": 260, "avg_hr": 176, "pb": "5k",
        "zone_s": [20, 60, 180, 520, 521],
        "route": _out_and_back(1.3000, 103.8600, 1250, seed=3),
        "verdict": "faster", "headline": "Forty-eight seconds off.",
        "hero": {"value": "21:41", "unit": ""},
        "splits": _splits(5.0, 1301, [3, 4, 4, 5, 5], seed=4),
        "pb_detail": {"label": "5 KM BEST", "delta_s": -48, "previous_s": 1349},
    }


# --- the runner's week so far on a run card (facts["week_track"]) ---------------------------------------------------
def with_week(facts: dict[str, Any], days: list[float], usual_km: float | None) -> dict[str, Any]:
    """A run's facts plus the week so far: `days` is km per local weekday, Monday first, the run's day the last non-zero one."""
    today = max(i for i, d in enumerate(days) if d)
    wt: dict[str, Any] = {"days": days, "today_idx": today, "runs": sum(1 for d in days if d), "km": round(sum(days), 1)}
    if usual_km is not None:
        wt["usual_km"] = usual_km
    return {**facts, "week_track": wt}


def week_first_run() -> dict[str, Any]:
    """Tuesday's easy run is the first of the week; the usual week is 31 km."""
    return with_week(slow_hot_day(), [0, 6.2, 0, 0, 0, 0, 0], 31.0)


def week_third_run() -> dict[str, Any]:
    """Thursday's long run is the third of the week."""
    return with_week(milos_trail() | {"start_local": "2026-10-08T07:20"}, [8.0, 0, 10.4, 12.4, 0, 0, 0], 34.5)


def week_big() -> dict[str, Any]:
    """Sunday's 5 K best closes a 57 km week against a 31 km usual one."""
    return with_week(pb_5k() | {"start_local": "2026-10-11T07:00"}, [10.2, 0, 12.5, 8.0, 0, 21.1, 5.0], 31.5)


def milestone_1000km() -> dict[str, Any]:
    return {"kind": "distance_km", "value": 1000, "since": "March", "runs": 143, "line": "A lot of early mornings."}


def milestone_100th() -> dict[str, Any]:
    return {"kind": "runs", "value": 100, "since": "April", "total_km": 742, "line": "Triple digits."}


def suggestion_easy_hot() -> dict[str, Any]:
    return {
        "type": "easy", "session": "Easy run", "distance_km": 8, "date_local": "2026-10-11T06:00",
        "reason": "Thursday's reps were hard. Keep tomorrow easy and let them land.",
        "weather": {"icon": "sun", "temp_c": 29, "label": "Humid by 7"},
    }


def suggestion_quality_rain() -> dict[str, Any]:
    return {
        "type": "tempo", "session": "Tempo", "distance_km": 10, "date_local": "2026-10-13T06:00",
        "reason": "It has been 6 days since your last hard session, so tomorrow suits one.",
        "weather": {"icon": "rain", "temp_c": 24, "label": "Showers after 8"},
    }


def weekly_recap() -> dict[str, Any]:
    """Week 41, Mon 5 Oct to Sun 11 Oct 2026. Thursday is the 8 x 400 m session, Saturday the Kastro loop."""
    sg, milos = singapore_intervals(), milos_trail()
    d = [
        {"date": "2026-10-05", "distance_km": 7.2, "zone_s": [300, 1500, 600, 0, 0]},
        {"date": "2026-10-06", "distance_km": 0, "zone_s": []},
        {"date": "2026-10-07", "distance_km": 8.4, "zone_s": [200, 1700, 900, 200, 0]},
        {"date": "2026-10-08", "distance_km": sg["distance_km"], "zone_s": sg["zone_s"]},
        {"date": "2026-10-09", "distance_km": 0, "zone_s": []},
        {"date": "2026-10-10", "distance_km": milos["distance_km"], "zone_s": milos["zone_s"]},
        {"date": "2026-10-11", "distance_km": 6.0, "zone_s": [300, 1900, 500, 0, 0]},
    ]
    total = sum(sum(x["zone_s"]) for x in d)
    quickest = min(sum(x["zone_s"]) / x["distance_km"] for x in d if x["distance_km"])
    return {
        "week_label": "Week 41", "distance_km": 43.6, "runs": 5, "duration_s": total, "days": d,
        "pace_s_per_km": total / 43.6, "quickest_pace_s_per_km": quickest,
        "score_moves": {"aerobic": 3, "speed": 5, "mid": 0, "long": -2},
        "best_moment": {"text": "Rep 6 on Thursday: 1:21 for 400 m, your fastest yet."},
    }


def weekly_recap_big() -> dict[str, Any]:
    """A heavy week: 12 runs, 11:05:00 on the move, 123.4 km (the longest strings the weekly hero line can hold)."""
    w = weekly_recap()
    km = [18.0, 0, 21.4, 15.0, 12.0, 30.0, 27.0]
    zone = [[400, 3000, 2400, 800, 300] for _ in km]
    days = [{"date": d["date"], "distance_km": k, "zone_s": z if k else []} for d, k, z in zip(w["days"], km, zone)]
    return {**w, "distance_km": 123.4, "runs": 12, "duration_s": 39900, "days": days,
            "pace_s_per_km": 39900 / 123.4, "quickest_pace_s_per_km": 301}


_LOAD_MONDAYS = ("2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05")


def _load_weeks(loads: list[int], *, nohr: float = 0.0, paused: tuple[int, ...] = ()) -> list[dict[str, Any]]:
    """Six weeks of load, oldest first: heart-rate zones split as a mostly easy runner's would, `nohr` of each week with
    no strap. A paused week counts for nothing."""
    zone = [0.06, 0.52, 0.24, 0.14, 0.04]
    return [{"monday": m, "load": 0 if i in paused else ld, "paused": i in paused,
             "zone_share": [0.0] * 5 if i in paused else [round(z * (1 - nohr), 3) for z in zone],
             "nohr_share": 0.0 if i in paused else nohr}
            for i, (m, ld) in enumerate(zip(_LOAD_MONDAYS, loads))]


def weekly_recap_load_usual() -> dict[str, Any]:
    """The week-41 recap with the load panel: 352 load against a usual 345, so 'About your usual week'."""
    loads = [300, 350, 340, 360, 330, 352]
    return {**weekly_recap(), "load": 352, "usual_load": 345, "band": "usual", "pct": 2, "words": "About your usual week", "weeks": _load_weeks(loads)}


def weekly_recap_load_bigjump() -> dict[str, Any]:
    """A big week: 470 against a usual 345 (36% more), with a paused week in the history. The bar gets the amber outline."""
    loads = [300, 350, 0, 340, 330, 470]
    w = _load_weeks(loads, paused=(2,))
    return {**weekly_recap(), "load": 470, "usual_load": 340, "band": "bigJump", "pct": 38, "words": "38% more than your usual week", "weeks": w}


def weekly_recap_load_stepup() -> dict[str, Any]:
    """460 against a usual 340 is over 1.3x, but no run that week carried a high load_state: a step up, no amber."""
    loads = [300, 350, 330, 340, 350, 460]
    return {**weekly_recap(), "load": 460, "usual_load": 340, "band": "stepUp", "pct": 35,
            "words": "35% more than your usual week", "weeks": _load_weeks(loads)}


def weekly_recap_load_nohr() -> dict[str, Any]:
    """A runner with no strap: every bar is the easy-run colour, and the week is lighter than usual."""
    loads = [210, 240, 230, 250, 220, 170]
    return {**weekly_recap(), "load": 170, "usual_load": 235, "band": "lighter", "pct": 28, "words": "28% less than your usual week", "weeks": _load_weeks(loads, nohr=1.0)}


def pb_marathon_half() -> dict[str, Any]:
    """An hour-plus PB (half marathon, 1:45:12): the hero is as wide as it gets."""
    f = pb_5k()
    return {**f, "title": "Half marathon best", "distance_km": 21.1, "duration_s": 6312, "pace_s_per_km": 299,
            "hero": {"value": "1:45:12", "unit": ""}, "headline": "Two minutes off.",
            "pb_detail": {"label": "HALF MARATHON BEST", "delta_s": -131, "previous_s": 6443},
            "splits": _splits(21.1, 6312, [3, 4, 4, 4, 5], seed=5)}


def race_countdown() -> dict[str, Any]:
    # Same race as the month simulator (companion/convo/sim.py RACE_DAY, a half marathon on Sunday 6 Dec 2026),
    # on its 6 Oct card: 61 days to go, "8 weeks to go" of a 12 week plan. tests/test_render_cards.py keeps them equal.
    return {"race_name": "Half Marathon", "days_to_race": 61, "plan_weeks": 12, "weeks_done": 4,
            "race_line": "Sunday 6 Dec. Long run this weekend: 14 km."}


def monthly_poster() -> dict[str, Any]:
    kinds = ["easy", "easy", "interval", "long", "easy", "tempo", "easy", "long", "interval", "easy", "easy", "tempo",
             "long", "easy", "interval", "easy", "race", "easy"]
    runs = []
    for i, k in enumerate(kinds):
        route = _stadium(1.36, 103.85, turns=3) if k == "interval" else (
            _out_and_back(1.3, 103.86, 900 + 60 * i, seed=i) if i % 3 == 0 else _loop(1.29, 103.85, 300 + 25 * i, seed=i + 20))
        runs.append({"type": k, "route": route})
    return {"month_label": "September", "distance_km": 186.4, "run_count": 18, "duration_s": 62300, "climb_m": 1240,
            "runs": runs, "best_run": {"text": "Kastro loop on Sunday 27 Sep: 12.4 km, 234 m up."}}


def monthly_poster_noroute() -> dict[str, Any]:
    """What the server really stores per run: date, distance, duration, type, zone_s. No routes."""
    plan = [(1, "easy", 6.0), (2, "easy", 5.0), (4, "interval", 7.5), (6, "long", 14.0), (8, "easy", 6.0), (9, "tempo", 8.0),
            (11, "easy", 5.5), (13, "long", 15.5), (15, "interval", 7.0), (16, "easy", 6.0), (18, "easy", 5.0),
            (20, "tempo", 9.0), (20, "easy", 3.0), (22, "easy", 6.0), (23, "interval", 8.0), (25, "easy", 6.5),
            (27, "long", 12.4), (29, "race", 5.0)]
    zones = {"easy": [300, 1800, 400, 0, 0], "long": [240, 3200, 1200, 300, 0], "tempo": [240, 600, 900, 1200, 100],
             "interval": [300, 500, 400, 900, 500], "race": [200, 100, 300, 700, 400]}
    pace = {"easy": 365, "long": 372, "tempo": 325, "interval": 340, "race": 305}
    runs = [{"date": f"2026-09-{d:02d}", "type": t, "distance_km": km, "duration_s": round(km * pace[t]), "zone_s": zones[t]}
            for d, t, km in plan]
    return {"month_label": "September", "month_start": "2026-09-01", "runs": runs, "run_count": len(runs),
            "distance_km": round(sum(r["distance_km"] for r in runs), 1), "duration_s": sum(r["duration_s"] for r in runs),
            "climb_m": 1240, "best_run": {"text": "Sunday 27 Sep: 12.4 km long run, 234 m up."}}


def share_private() -> dict[str, Any]:
    d = singapore_intervals()
    d["share"] = {"reps": True, "hr": True, "headline": "Eight reps, all on pace."}
    return d


def share_opted_in() -> dict[str, Any]:
    d = milos_trail()
    d["share"] = {"route": True, "place": True, "time": True, "climb": True, "name": True, "headline": "Third time up the Kastro."}
    return d


# Route generators and every run fixture, public so other renderers (motion) share one source.
stadium, loop, out_and_back = _stadium, _loop, _out_and_back
RUNS = {"singapore_intervals": singapore_intervals, "milos_trail": milos_trail, "slow_hot_day": slow_hot_day, "pb_5k": pb_5k}


# --- coach cards (today, today_verdict, moved, pinned_week) ---------------------------------------------------------
# Only numbers, fixed enums and short labels: see render/protocol.py COACH_* for the contract.

def today_4x4() -> dict[str, Any]:
    return {"type": "interval", "session": "Norwegian 4x4", "duration_s": 2820, "date_local": "2026-10-20T06:45",
            "target_pace_lo_s": 255, "target_pace_hi_s": 260, "target_kind": "work", "units": "km"}


def today_easy_no_target() -> dict[str, Any]:
    return {"type": "easy", "session": "Easy run", "distance_km": 6, "date_local": "2026-10-21T07:00", "guide": "chatty", "units": "km"}


def today_long_name() -> dict[str, Any]:
    return {"type": "long", "session": "Progressive long run, strides", "distance_km": 18.5, "date_local": "2026-10-24T08:10",
            "target_pace_lo_s": 345, "target_pace_hi_s": 365, "target_kind": "pace", "units": "km"}


def today_tempo_miles() -> dict[str, Any]:
    return {"type": "tempo", "session": "Tempo", "distance_km": 9.66, "date_local": "2026-10-22T18:00",
            "target_pace_lo_s": 335, "target_pace_hi_s": 345, "target_kind": "work", "units": "mi"}


def verdict_faster() -> dict[str, Any]:
    return today_4x4() | {"result_pace_s": 243}


def verdict_slower() -> dict[str, Any]:
    return today_4x4() | {"result_pace_s": 272}


def verdict_in_range() -> dict[str, Any]:
    return today_4x4() | {"result_pace_s": 257}


def verdict_pb() -> dict[str, Any]:
    return {"type": "race", "session": "5 km time trial", "distance_km": 5, "date_local": "2026-10-25T07:00",
            "target_pace_lo_s": 262, "target_pace_hi_s": 268, "target_kind": "pace", "result_pace_s": 260, "pb": True, "units": "km"}


def verdict_miles() -> dict[str, Any]:
    return today_tempo_miles() | {"result_pace_s": 322}


def moved_tempo_tired() -> dict[str, Any]:
    return {"type": "tempo", "session": "Tempo", "distance_km": 9, "to_day": "tue", "from_day": "thu", "skip_reason": "tired",
            "units": "km"}


def moved_next_week_long_name() -> dict[str, Any]:
    return {"type": "interval", "session": "Norwegian 4x4 with warm-up", "duration_s": 3000, "to_day": "next_week",
            "from_day": "thu", "skip_reason": "travelling", "units": "km"}


def moved_miles_no_reason() -> dict[str, Any]:
    return {"type": "long", "session": "Long run", "distance_km": 19.3, "to_day": "sun", "units": "mi"}


def pinned_week_midweek() -> dict[str, Any]:
    return {"week_label": "Week 43", "duration_s": 5560, "today_idx": 2, "units": "km", "days": [
        {"type": "rest"}, {"type": "interval", "planned_km": 8.4, "done_km": 8.4}, {"type": "easy", "planned_km": 6, "done_km": 0},
        {"type": "tempo", "planned_km": 9}, {"type": "rest"}, {"type": "long", "planned_km": 14}, {"type": "rest"}]}


def pinned_week_big_missed() -> dict[str, Any]:
    """A 10+ hour week with a missed day (Tuesday's easy run) and an unplanned extra on the rest day."""
    return {"week_label": "Week 44 build", "duration_s": 12 * 3600 + 31 * 60 + 45, "today_idx": 5, "units": "km", "days": [
        {"type": "easy", "planned_km": 12, "done_km": 12.4}, {"type": "easy", "planned_km": 10, "done_km": 0},
        {"type": "interval", "planned_km": 14, "done_km": 14.6}, {"type": "easy", "planned_km": 12, "done_km": 11.8},
        {"type": "rest", "done_km": 6.2}, {"type": "long", "planned_km": 32, "done_km": 0}, {"type": "tempo", "planned_km": 16}]}


def pinned_week_miles() -> dict[str, Any]:
    return pinned_week_midweek() | {"units": "mi"}


def today_easy_hr_ceiling() -> dict[str, Any]:
    return today_easy_no_target() | {"hr_ceiling_bpm": 148, "guide": "recovery", "session": "Recovery run", "distance_km": 5}


def today_bare() -> dict[str, Any]:
    """An easy run with neither a pace target nor a guide: the one case that keeps the single big block."""
    return {"type": "easy", "session": "Easy run", "distance_km": 6, "units": "km"}


def today_two_digit_km() -> dict[str, Any]:
    """A slow easy range (10:30-11:15 /km): two-digit minutes in the plate."""
    return {"type": "easy", "session": "Easy run", "distance_km": 8, "date_local": "2026-10-21T07:00",
            "target_pace_lo_s": 630, "target_pace_hi_s": 675, "target_kind": "pace", "units": "km"}


def today_two_digit_mi() -> dict[str, Any]:
    """12:30-13:10 /mi, the widest range the plate has to hold."""
    return {"type": "easy", "session": "Easy run", "distance_km": 8, "date_local": "2026-10-21T07:00",
            "target_pace_lo_s": 466, "target_pace_hi_s": 491, "target_kind": "pace", "units": "mi"}


def verdict_two_digit_km() -> dict[str, Any]:
    return today_two_digit_km() | {"result_pace_s": 700}


def verdict_two_digit_mi() -> dict[str, Any]:
    return today_two_digit_mi() | {"result_pace_s": 520}


def verdict_enum_small_gap_faster() -> dict[str, Any]:
    """The app scored this faster (a short session has a small floor) although it is only 3 s/km under the band."""
    return today_4x4() | {"result_pace_s": 252, "verdict": "faster"}


def verdict_enum_big_gap_in_range() -> dict[str, Any]:
    """15 s/km under the band, but the app scored it as noise (a long session has a bigger floor)."""
    return today_4x4() | {"result_pace_s": 240, "verdict": "in_range"}


def verdict_no_target() -> dict[str, Any]:
    """An easy run with a guide but no pace band: the result still shows, neutral, with no verdict word invented."""
    return today_easy_no_target() | {"result_pace_s": 345}


# --- trail cards (trail_board, trail_record): an invented 9.6 km out-and-back, whole numbers only ---------------------

def _trail_profile(n: int = 64, top: int = 387, noisy: bool = False) -> list[int]:
    """Metres above the start, evenly spaced along an out-and-back: gentle, steady, steep, very steep, then a ridge."""
    segs = [(0, 1.2, 0.03), (1.2, 2.6, 0.07), (2.6, 3.6, 0.12), (3.6, 4.2, 0.19), (4.2, 4.8, 0.035)]
    raw = []
    for i in range(n):
        d = i / (n - 1) * 9.6
        x = min(d, 9.6 - d)
        e = sum((min(x, b) - a) * 1000 * g for a, b, g in segs if x > a)
        raw.append(e)
    scale = top / max(raw)
    out = [round(e * scale) for e in raw]
    if noisy:
        out = [v + (7 if i % 2 else -7) for i, v in enumerate(out)]
    return out


def _trail_gap(n: int = 64) -> list[int]:
    """Signed seconds vs the old best along the run (positive = ahead): lost a little early, won the climb, pulled away on the way down."""
    out = []
    for i in range(n):
        d = i / (n - 1) * 9.6
        if d < 1.5:
            v = 4 * d / 1.5
        elif d < 4.2:
            v = 4 - 16 * (d - 1.5) / 2.7
        elif d < 5.4:
            v = -12 + (d - 4.2)
        else:
            v = -11 - 30 * ((d - 5.4) / 4.2) ** 1.3
        out.append(-round(v))
    out[-1] = 41
    return out


def _board(rows: list[tuple[int, int]], today: int) -> list[dict[str, Any]]:
    return [{"attempt": a, "time_s": t, **({"today": True} if a == today else {})} for a, t in rows]


def trail_board_five() -> dict[str, Any]:
    """5th run, second fastest, with the trail's name (place opt-in)."""
    return {"type": "trail", "distance_km": 9.6, "duration_s": 3734, "pace_s_per_km": 389, "climb_m": 412, "trail_runs": 5,
            "trail_board": _board([(4, 3683), (5, 3734), (2, 3790), (3, 3852), (1, 3978)], 5),
            "elev_profile": _trail_profile(), "elev_src": "baro", "turn_idx": 31, "trail_shape": "out_and_back", "trail_name": "The Saddle Trail"}


def trail_board_third_private() -> dict[str, Any]:
    """3rd run, no name, no turn index, a loop: the card says only what the numbers say."""
    return {"type": "trail", "distance_km": 6.2, "duration_s": 2410, "pace_s_per_km": 389, "climb_m": 180, "trail_runs": 3,
            "trail_board": _board([(1, 2455), (2, 2402), (3, 2410)], 3),
            "elev_profile": _trail_profile(top=96), "elev_src": "baro", "trail_shape": "loop"}


def trail_board_many_runs() -> dict[str, Any]:
    """The 12th run, ranked 9th among 12 (the app sends each row's true rank; runs 10 and 11 are not on the board): the card keeps the best four and today, and a time over an hour with a long name."""
    rows = [(1, 3978), (2, 3790), (3, 3852), (4, 3683), (5, 3734), (6, 3701), (7, 3722), (8, 3811), (9, 3765), (12, 3905)]
    return {"type": "trail", "distance_km": 9.6, "duration_s": 3905, "pace_s_per_km": 407, "climb_m": 412, "trail_runs": 12,
            "trail_board": [r | {"rank": {4: 1, 6: 2, 7: 3, 5: 4, 9: 5, 2: 6, 8: 7, 3: 8, 12: 9, 1: 11}[r["attempt"]]} for r in _board(rows, 12)],
            "elev_profile": _trail_profile(), "elev_src": "baro", "turn_idx": 31, "trail_shape": "out_and_back",
            "trail_name": "Mt Wellington Pinnacle Circuit"}


def trail_board_no_profile() -> dict[str, Any]:
    """GPS-only altitude was too noisy to draw: no profile, the stat blocks stand in."""
    return {k: v for k, v in trail_board_five().items() if k not in ("elev_profile", "turn_idx", "trail_name")}


def trail_record_six() -> dict[str, Any]:
    return {"type": "trail", "distance_km": 9.6, "duration_s": 3642, "pace_s_per_km": 379, "climb_m": 412, "trail_runs": 6,
            "trail_board": _board([(1, 3978), (2, 3790), (3, 3852), (4, 3683), (5, 3734), (6, 3642)], 6),
            "elev_profile": _trail_profile(), "elev_src": "baro", "ghost_gap": _trail_gap(), "turn_idx": 31, "trail_shape": "out_and_back",
            "trail_name": "The Saddle Trail"}


def trail_record_hours() -> dict[str, Any]:
    """A long trail: 12:34:56 on the hero, no profile of the gap, a loop."""
    return {"type": "trail", "distance_km": 52.0, "duration_s": 45296, "pace_s_per_km": 871, "climb_m": 2900, "trail_runs": 2,
            "trail_board": _board([(1, 47010), (2, 45296)], 2), "elev_profile": _trail_profile(top=420), "elev_src": "baro", "trail_shape": "loop"}


def trail_board_gps() -> dict[str, Any]:
    """A GPS-only profile (noisy): a calm smoothed line, no steepness bands, no steepness label."""
    return trail_board_five() | {"elev_profile": _trail_profile(noisy=True), "elev_src": "gps"}


def trail_record_gps() -> dict[str, Any]:
    return trail_record_six() | {"elev_profile": _trail_profile(noisy=True), "elev_src": "gps"}


def trail_record_no_gap() -> dict[str, Any]:
    """The ghost gap did not arrive: the profile alone stands in for the panel."""
    return {k: v for k, v in trail_record_six().items() if k not in ("ghost_gap", "trail_name")}


def _comeback_gap(n: int = 64) -> list[int]:
    """Down 22 s at 2 km of 4.7, level by the turn, then ahead by 1 s at the line."""
    pts = [(0.0, 0), (1.0, -9), (2.0, -22), (2.9, -14), (3.6, -6), (4.2, -2), (4.7, 1)]
    out = []
    for i in range(n):
        d = i / (n - 1) * 4.7
        k = max(j for j, (x, _) in enumerate(pts) if x <= d) if d < 4.7 else len(pts) - 2
        (x0, y0), (x1, y1) = pts[k], pts[k + 1]
        out.append(round(y0 + (y1 - y0) * (d - x0) / (x1 - x0)))
    return out


def ghost_clip_comeback() -> dict[str, Any]:
    """The ghost clip's drama: 22 s down at 2 km, a second clear at the line. A 4.7 km out-and-back, run 4 of 4."""
    return {"type": "trail", "distance_km": 4.7, "duration_s": 1621, "pace_s_per_km": 345, "climb_m": 98, "trail_runs": 4,
            "trail_board": _board([(1, 1702), (2, 1655), (3, 1650), (4, 1649)], 4),
            "elev_profile": _trail_profile(top=98), "elev_src": "baro", "ghost_gap": _comeback_gap(), "turn_idx": 31, "trail_shape": "out_and_back"}


def ghost_clip_clear_win() -> dict[str, Any]:
    """Ahead the whole way (the stock record fixture, with the place opt-in name)."""
    return trail_record_six()


GHOST_CLIPS = {"comeback": ghost_clip_comeback, "clear_win": ghost_clip_clear_win,
               "gps_profile": trail_record_gps}
def _heart_series(profile: list[int], peak_after_top: bool, max_hr: int = 190) -> tuple[list[int], list[int]]:
    """bpm and the runner's zone (percent-of-max zones) per profile point: warm-up, a climb that keeps pushing it up, then either
    a heart that keeps rising after the top (drift, the hook) or one that already peaked on the way up."""
    n = len(profile)
    top = max(range(n), key=lambda i: profile[i])
    hr = []
    for i in range(n):
        up = profile[i] / max(profile[top], 1)
        if i <= top:
            v = 118 + 52 * up
        elif peak_after_top:
            v = 170 + 4 * (i - top) / max(n - 1 - top, 1) * (1 if i < n - 6 else 0.5)
        else:
            v = 172 - 30 * (i - top) / max(n - 1 - top, 1)
        hr.append(round(v))
    if not peak_after_top:
        hr[max(top - 2, 0)] = 176
    cut = [max_hr * 0.6, max_hr * 0.7, max_hr * 0.8, max_hr * 0.9]
    return hr, [1 + sum(1 for c in cut if b >= c) for b in hr]


def trail_heart_outlasts() -> dict[str, Any]:
    """The hook: the hill tops out at 98 m and the heart keeps climbing after it."""
    prof = _trail_profile(top=98)
    hr, z = _heart_series(prof, True)
    return {"type": "trail", "distance_km": 9.6, "duration_s": 3734, "pace_s_per_km": 389, "climb_m": 98, "trail_runs": 5,
            "trail_board": _board([(4, 3683), (5, 3734), (2, 3790), (3, 3852), (1, 3978)], 5),
            "elev_profile": prof, "elev_src": "baro", "turn_idx": 31, "trail_shape": "out_and_back", "trail_name": "The Saddle Trail",
            "hr_series": hr, "hr_zones": z}


def trail_heart_peaked_early() -> dict[str, Any]:
    """The heart peaked on the climb and settled on the way down: the card states the climb and the peak, no 'my heart didn't'."""
    prof = _trail_profile(top=387)
    hr, z = _heart_series(prof, False)
    return {"type": "trail", "distance_km": 6.2, "duration_s": 2410, "pace_s_per_km": 389, "climb_m": 387, "trail_runs": 3,
            "trail_board": _board([(1, 2455), (2, 2402), (3, 2410)], 3), "elev_profile": prof, "elev_src": "baro", "trail_shape": "loop",
            "hr_series": hr, "hr_zones": z}


TRAIL_CARDS = {
    "trail_board_five": ("trail_board", trail_board_five), "trail_board_third_private": ("trail_board", trail_board_third_private),
    "trail_board_many_runs": ("trail_board", trail_board_many_runs), "trail_board_no_profile": ("trail_board", trail_board_no_profile),
    "trail_record_six": ("trail_record", trail_record_six), "trail_record_hours": ("trail_record", trail_record_hours),
    "trail_record_no_gap": ("trail_record", trail_record_no_gap), "trail_board_gps": ("trail_board", trail_board_gps),
    "trail_record_gps": ("trail_record", trail_record_gps),
    "trail_heart_outlasts": ("trail_heart", trail_heart_outlasts), "trail_heart_peaked_early": ("trail_heart", trail_heart_peaked_early),
}
