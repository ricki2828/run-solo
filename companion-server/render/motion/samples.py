"""Deterministic sample data (synthetic route, no personal data) for previews and tests."""
from __future__ import annotations

import math

from .run_video import RunVideoSpec, Split, Verdict


def sample_route(n: int = 260, lat0: float = -41.29, lon0: float = 174.78):
    """A wobbly loop with an out-and-back spur, as lat/lon."""
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / (n - 1)
        r = 0.0105 * (1 + 0.28 * math.sin(3 * a + 0.6) + 0.14 * math.sin(5 * a + 2.0))
        pts.append((lat0 + r * 0.82 * math.sin(a) + 0.002 * math.sin(2 * a), lon0 + r * 1.25 * math.cos(a)))
    return pts


def easy_run() -> RunVideoSpec:
    paces = [318, 311, 308, 305, 303, 301, 302, 299, 296, 292]
    zones = [2, 2, 2, 2, 2, 3, 2, 3, 3, 3]
    return RunVideoSpec(
        kind_label="EASY RUN", date_label="SAT 10 OCT", route=sample_route(), distance_km=10.12, duration_s=3032,
        splits=[Split(str(i + 1), p, z) for i, (p, z) in enumerate(zip(paces, zones))],
        verdict=Verdict("faster", 12, 0, "S/KM", context="VS YOUR LAST 10K", caption="Per km. The legs turned up."),
        run_type="AEROBIC", signoff="Back tomorrow. Easy does it.",
    )


def hard_run() -> RunVideoSpec:
    paces = [285, 268, 262, 259, 266, 258, 261, 255, 252, 240]
    zones = [3, 4, 4, 4, 4, 4, 5, 4, 5, 5]
    return RunVideoSpec(
        kind_label="TEMPO 10K", date_label="WED 7 OCT", route=sample_route(lon0=174.80), distance_km=10.0,
        duration_s=2640, splits=[Split(str(i + 1), p, z) for i, (p, z) in enumerate(zip(paces, zones))],
        verdict=Verdict("pb", 41, 0, "SEC", context="10K PERSONAL BEST", caption="Off your old best of 45:12."),
        run_type="SPEED", flood_zone=4, signoff="Put the feet up.",
    )


def slower_run() -> RunVideoSpec:
    paces = [330, 328, 331, 335, 333, 338]
    zones = [2, 2, 2, 3, 2, 3]
    return RunVideoSpec(
        kind_label="LONG RUN", date_label="SUN 4 OCT", route=sample_route(lon0=174.76), distance_km=6.1,
        duration_s=2030, splits=[Split(str(i + 1), p, z) for i, (p, z) in enumerate(zip(paces, zones))],
        verdict=Verdict("slower", 9, 0, "S/KM", context="VS YOUR LAST 6K", caption="Heat and a headwind. It happens."),
        run_type="LONG", signoff="Tomorrow is another run.",
    )


def weekly():
    from .weekly_video import Best, Day, ScoreChange, WeeklySpec

    z = lambda *m: list(m)  # noqa: E731
    return WeeklySpec(
        week_label="6 TO 12 OCT", total_km=47.3, runs=5, total_min=262,
        days=[Day("M", z(0, 0, 0, 0, 0)), Day("T", z(4, 36, 14, 8, 2)), Day("W", z(30, 22, 0, 0, 0)),
              Day("T", z(0, 0, 0, 0, 0)), Day("F", z(6, 44, 6, 0, 0)), Day("S", z(5, 30, 20, 4, 0)),
              Day("S", z(8, 62, 38, 9, 0))],
        scores=[ScoreChange("AEROBIC", 71, 74), ScoreChange("SPEED", 58, 61), ScoreChange("MID", 66, 65),
                ScoreChange("LONG", 62, 62)],
        best=Best(headline="5K PB", detail="22:41 on Tuesday. Kastro loop.", pb=True),
        signoff="Rest up. Monday is a day off.",
    )
