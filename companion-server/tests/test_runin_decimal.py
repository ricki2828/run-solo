import math

import pytest
from pydantic import ValidationError

from companion.service import RunIn

BASE = dict(run_id="r1", type="free", start_utc="2026-10-11T07:00:00+00:00", utc_offset_min=180,
            zone_id="Europe/Athens", duration_s=1800)


def test_app_decimal_metres_are_accepted_and_rounded():
    r = RunIn(**BASE, distance_m=4900.3, climb_m=123.6)
    assert r.distance_m == 4900 and r.climb_m == 124


def test_whole_and_missing_climb_still_fine():
    r = RunIn(**BASE, distance_m=5000)
    assert r.distance_m == 5000 and r.climb_m is None


@pytest.mark.parametrize("bad", [math.nan, math.inf, "lots", -1.0])
def test_bad_distance_still_rejected(bad):
    with pytest.raises(ValidationError):
        RunIn(**BASE, distance_m=bad)
