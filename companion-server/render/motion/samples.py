"""Deterministic sample facts (synthetic routes, no personal data), in the same schema as the cards fixtures
(render/cards/fixtures.py): distance_km, duration_s, pace_s_per_km, zone_s, route, verdict, headline, hero,
pb_detail. Motion also needs `splits`; `with_splits` derives them from the facts so they always agree."""
from __future__ import annotations

import math

from .run_video import RunVideoSpec, spec_from_facts
from .weekly_video import WeeklySpec, weekly_from_facts


def sample_route(n: int = 260, lat0: float = -41.29, lon0: float = 174.78):
    """A wobbly loop, as lat/lon."""
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / (n - 1)
        r = 0.0105 * (1 + 0.28 * math.sin(3 * a + 0.6) + 0.14 * math.sin(5 * a + 2.0))
        pts.append((lat0 + r * 0.82 * math.sin(a) + 0.002 * math.sin(2 * a), lon0 + r * 1.25 * math.cos(a)))
    return pts


def with_splits(f: dict) -> dict:
    """Whole-km splits plus a partial last one. Paces wobble around the average, are scaled to add up to the
    run exactly, and the fastest splits get the highest zones in proportion to zone_s."""
    dist, dur = f["distance_km"], f["duration_s"]
    n = math.ceil(dist - 0.02)
    dists = [1.0] * n
    dists[-1] = round(dist - (n - 1), 3)
    avg = dur / dist
    raw = [avg * (1 + 0.035 * math.sin(i * 1.3 + 0.4) - 0.012 * (i - n / 2) / n * 4) for i in range(n)]
    k = dur / sum(d * p for d, p in zip(dists, raw))
    paces = [p * k for p in raw]
    zs = f["zone_s"]
    tot = sum(zs) or 1
    counts = [round(n * z / tot) for z in zs]
    while sum(counts) < n:
        counts[counts.index(max(counts))] += 1
    while sum(counts) > n:
        counts[counts.index(max(counts))] -= 1
    zones = [z + 1 for z, c in enumerate(counts) for _ in range(c)]  # low to high
    order = sorted(range(n), key=lambda i: paces[i], reverse=True)  # slowest first -> lowest zone
    zone_of = {i: zones[r] for r, i in enumerate(order)}
    out = dict(f)
    out["splits"] = [
        {"km": str(i + 1) if dists[i] >= 0.995 else f"{dist:.1f}", "pace_s": round(paces[i], 1), "zone": zone_of[i],
         "dist_km": dists[i]} for i in range(n)]
    return out


def milos_trail() -> dict:
    return with_splits({
        "type": "long", "title": "Kastro loop", "start_local": "2026-09-27T07:20", "place_note": "Milos",
        "distance_km": 12.4, "duration_s": 5330, "pace_s_per_km": 430, "climb_m": 234, "avg_hr": 146,
        "zone_s": [420, 2410, 1850, 560, 90], "route": sample_route(lat0=36.7249, lon0=24.4311),
        "verdict": "holding", "headline": "Third time up the Kastro."})


def singapore_intervals() -> dict:
    return with_splits({
        "type": "interval", "title": "8 × 400 m", "start_local": "2026-10-08T06:10", "place_note": "Singapore",
        "distance_km": 9.6, "duration_s": 3170, "pace_s_per_km": 330, "avg_hr": 158,
        "zone_s": [240, 420, 360, 780, 1370], "route": sample_route(lat0=1.3631, lon0=103.8478),
        "verdict": "faster", "headline": "Eight reps, all on pace.",
        "hero": {"value": "1:24", "unit": "/400 M AVG"}, "reps": {"count": 8, "best_s": 81}})


def slow_hot_day() -> dict:
    return with_splits({
        "type": "easy", "title": "Easy run", "start_local": "2026-10-06T17:40", "place_note": "32° and humid",
        "distance_km": 6.2, "duration_s": 2700, "pace_s_per_km": 435, "avg_hr": 151,
        "zone_s": [180, 760, 1290, 420, 50], "route": sample_route(lat0=1.2903, lon0=103.8520),
        "verdict": "slower", "headline": "Slow, and fair enough."})


def pb_5k() -> dict:
    return with_splits({
        "type": "race", "title": "5 km best", "start_local": "2026-10-04T07:00", "place_note": "Parkrun",
        "distance_km": 5.0, "duration_s": 1301, "pace_s_per_km": 260, "avg_hr": 176, "pb": "5k",
        "zone_s": [20, 60, 180, 520, 521], "route": sample_route(lat0=1.30, lon0=103.86),
        "verdict": "faster", "headline": "Forty-eight seconds off.",
        "hero": {"value": "21:41", "unit": ""},
        "pb_detail": {"label": "5 KM BEST", "delta_s": -48, "previous_s": 1349}})


def weekly_facts() -> dict:
    """Day zone_s add up to duration_s; the Thursday session is the intervals run above (8 Oct 2026 is a Thursday)."""
    days = [
        {"zone_s": [300, 1500, 600, 0, 0]},      # Mon easy 40:00
        {"zone_s": []},                           # Tue rest
        {"zone_s": [200, 1700, 900, 200, 0]},     # Wed 50:00
        {"zone_s": [240, 420, 360, 780, 1370]},   # Thu intervals 52:50
        {"zone_s": []},                           # Fri rest
        {"zone_s": [420, 2410, 1850, 560, 90]},   # Sat long 88:50
        {"zone_s": [300, 1900, 500, 0, 0]},       # Sun easy 45:00
    ]
    secs = sum(sum(d["zone_s"]) for d in days)
    return {
        "week_label": "Week 41", "distance_km": 52.6, "runs": 5, "duration_s": secs, "days": days,
        "score_moves": {"aerobic": 3, "speed": 5, "mid": 0, "long": -2},
        "best_moment": {"text": "Rep 6 on Thursday: 1:21 for 400 m, your fastest yet."}}


def run_spec(which: str) -> RunVideoSpec:
    f = {"milos": milos_trail, "intervals": singapore_intervals, "slow": slow_hot_day, "pb": pb_5k}[which]()
    return spec_from_facts(f)


def weekly() -> WeeklySpec:
    return weekly_from_facts(weekly_facts())
