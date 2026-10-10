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
        "distance_km": 9.6, "duration_s": 3170, "pace_s_per_km": 330, "avg_hr": 158,
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
        {"date": "2026-10-05", "zone_s": [300, 1500, 600, 0, 0]},
        {"date": "2026-10-06", "zone_s": []},
        {"date": "2026-10-07", "zone_s": [200, 1700, 900, 200, 0]},
        {"date": "2026-10-08", "zone_s": sg["zone_s"]},
        {"date": "2026-10-09", "zone_s": []},
        {"date": "2026-10-10", "zone_s": milos["zone_s"]},
        {"date": "2026-10-11", "zone_s": [300, 1900, 500, 0, 0]},
    ]
    total = sum(sum(x["zone_s"]) for x in d)
    return {
        "week_label": "Week 41", "distance_km": 43.6, "runs": 5, "duration_s": total, "days": d,
        "score_moves": {"aerobic": 3, "speed": 5, "mid": 0, "long": -2},
        "best_moment": {"text": "Rep 6 on Thursday: 1:21 for 400 m, your fastest yet."},
    }


def race_countdown() -> dict[str, Any]:
    return {"race_name": "Sydney Half", "days_to_race": 23, "plan_weeks": 12, "weeks_done": 9,
            "race_line": "Sunday 1 Nov. Long run this weekend: 16 km."}


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
