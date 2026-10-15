"""The heat slowdown for the morning card's "Hot one" line. A mirror of the app's HeatModel
(packages/run_engine/lib/src/weather/heat_model.dart): Hadley's temperature + dew point table, both in degrees F,
interpolated linearly between the band edges. Never a cold bonus, and above 180 F it is "too hot to compare", so no
number. Keep the knots in step with the Dart file (tests/test_morning_buttons.py pins the same figures as the Dart test).
"""
from __future__ import annotations

TOO_HOT_ABOVE_F = 180.0
KNOTS = ((100, 0.0), (101, 0.0), (110, 0.005), (111, 0.005), (120, 0.01), (121, 0.01), (130, 0.02), (131, 0.02),
         (140, 0.03), (141, 0.03), (150, 0.045), (151, 0.045), (160, 0.06), (161, 0.06), (170, 0.08), (171, 0.08),
         (180, 0.10))
# The line shows from a 2% slowdown (a 130 F sum, e.g. 28 C with a 21 C dew point); under it the number is noise.
LINE_MIN_FRACTION = 0.02


def c_to_f(c: float) -> float:
    return c * 9 / 5 + 32


def slowdown_fraction(temp_c: float, dew_point_c: float) -> float | None:
    """HeatModel.of(...).fraction: the slowdown (0.047 = 4.7%), or None when too hot to compare."""
    s = c_to_f(temp_c) + c_to_f(dew_point_c)
    if s > TOO_HOT_ABOVE_F:
        return None
    if s <= KNOTS[0][0]:
        return 0.0
    for (x0, y0), (x1, y1) in zip(KNOTS, KNOTS[1:]):
        if s <= x1:
            return y0 + (y1 - y0) * (s - x0) / (x1 - x0)
    return KNOTS[-1][1]


def extra_s_per_km(cool_pace_s_per_km: float, temp_c: float, dew_point_c: float) -> int | None:
    """How many seconds per km slower an easy pace runs in this heat, or None when the line should not show. The app's
    rule is cool = raw x (1 - f), so the hot-day pace is cool / (1 - f)."""
    f = slowdown_fraction(temp_c, dew_point_c)
    if f is None or f < LINE_MIN_FRACTION:
        return None
    x = round(cool_pace_s_per_km * (1 / (1 - f) - 1))
    return x if x >= 1 else None
