"""infer_coach_type: the app's run type (intervals|cooper|laps|free|trail) to the coach's (easy|long|tempo|interval|race)."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from companion.facts import infer_coach_type
from companion.service import RunIn
from conftest import auth, enrol, run_payload

EASY7 = [{"type": "easy", "distance_m": 7000}] * 5


def infer(app, km=7.0, mins=40, zones=None, pb=None, hist=EASY7, **kw):
    return infer_coach_type(app, distance_m=km * 1000, duration_s=mins * 60, zone_min=zones, pb=pb, history=hist, **kw)


def test_app_types_map_straight():
    assert infer("intervals", reps_done=4) == "interval"
    assert infer("intervals", work_pace=300.0) == "interval"
    assert infer("cooper", km=2.8, mins=12) == "race"
    assert infer("laps") == "easy"
    assert infer("laps", has_reps=True) == "interval"


def test_intervals_stopped_before_any_rep_is_a_free_run():
    assert infer("intervals") == "easy"
    assert infer("intervals", reps_done=0) == "easy"
    assert infer("intervals", km=15, mins=80) == "long"
    assert infer("intervals", pb="5k") == "race"


@pytest.mark.parametrize("app", ["free", "trail"])
def test_free_and_trail_by_the_facts(app):
    assert infer(app) == "easy"
    # long: >= max(1.5 x typical easy 7 km = 10.5, 12 km), or 75+ minutes
    assert infer(app, km=11.9) == "easy" and infer(app, km=12.0) == "long"
    assert infer(app, km=8, mins=75) == "long" and infer(app, km=8, mins=74) == "easy"


def test_long_threshold_scales_with_the_typical_easy_run():
    big = [{"type": "easy", "distance_m": 10000}] * 5  # 1.5 x 10 km = 15 km
    assert infer("free", km=14, mins=70, hist=big) == "easy"
    assert infer("free", km=15, mins=80, hist=big) == "long"
    assert infer("free", km=14, mins=70, hist=[]) == "long"  # no easy history: the 12 km floor alone


def test_tempo_needs_mostly_z3_z4_and_20_to_60_minutes():
    hard = {"z1": 2, "z2": 5, "z3": 15, "z4": 10, "z5": 0}
    assert infer("free", mins=40, zones=hard) == "tempo"
    assert infer("free", mins=19, zones=hard) == "easy" and infer("free", mins=61, zones=hard) == "easy"
    assert infer("free", mins=40, zones={"z1": 5, "z2": 30, "z3": 5, "z4": 0, "z5": 0}) == "easy"
    assert infer("free", mins=40, zones=None) == "easy"


def test_pb_flag_makes_it_a_race_and_beats_the_other_rules():
    assert infer("free", pb="10k") == "race"
    assert infer("trail", km=20, mins=120, pb="longest") == "race"


def test_a_coach_type_passes_through_untouched():
    for t in ("easy", "long", "tempo", "interval", "race"):
        assert infer(t) == t


def test_the_apps_decimal_metres_are_accepted_and_rounded():
    r = RunIn.model_validate({**run_payload(), "distance_m": 7012.3, "climb_m": 41.7})
    assert (r.distance_m, r.climb_m) == (7012, 42)
    with pytest.raises(ValueError):
        RunIn.model_validate({**run_payload(), "distance_m": float("nan")})
    with pytest.raises(ValueError):
        RunIn.model_validate({**run_payload(), "distance_m": "7012.3"})


def test_upload_stores_the_coach_type_keeps_the_apps_and_exports_it(client, fakes):
    t = enrol(client)
    p = run_payload("a1", type="trail", distance_m=6012.3, climb_m=41.7, zone_min={"z2": 10.0})
    r = client.post("/v1/runs", json=p, headers=auth(t))
    assert r.status_code == 202, r.text  # a decimal distance used to be a 422
    con = sqlite3.connect(client.svc.s.db_path)
    assert con.execute("SELECT type, app_type, distance_m, climb_m FROM runs").fetchone() == ("easy", "trail", 6012, 42)
    client.post("/v1/runs", json=run_payload("a2", type="easy", minutes_ago=5), headers=auth(t))
    assert con.execute("SELECT app_type FROM runs WHERE run_id='a2'").fetchone()[0] is None
    me = client.get("/v1/me", headers=auth(t)).json()
    by_id = {x["run_id"]: x for x in me["runs_received"]}
    assert (by_id["a1"]["type"], by_id["a1"]["app_type"]) == ("easy", "trail")


def test_bailed_interval_upload_is_stored_and_worded_as_a_free_run(client, fakes):
    t = enrol(client)
    client.post("/v1/runs", json=run_payload("b1", type="intervals", distance_m=3200, duration_s=1200), headers=auth(t))
    client.svc.run_outbox(datetime.now(timezone.utc) + timedelta(seconds=1))
    assert "interval" not in fakes.tg_texts()[-1].lower()
    client.post("/v1/runs", json=run_payload("b2", type="intervals", minutes_ago=5, reps_done=4, work_pace_s_per_km=257.0,
                                              session_name="Norwegian 4x4"), headers=auth(t))
    con = sqlite3.connect(client.svc.s.db_path)
    rows = {r: (a, b) for r, a, b in con.execute("SELECT run_id, type, app_type FROM runs")}
    assert rows["b1"] == ("easy", "free")
    assert rows["b2"] == ("interval", "intervals")


def test_a_trail_run_stays_a_trail_run_in_the_copy(client, fakes):
    t = enrol(client)
    client.post("/v1/runs", json=run_payload("a1", type="trail", distance_m=6012.3, climb_m=41.7), headers=auth(t))
    client.svc.run_outbox(datetime.now(timezone.utc) + timedelta(seconds=1))
    assert "trail" in fakes.tg_texts()[-1].lower()




def test_trail_run_is_not_a_tempo_because_climbs_lift_hr_into_z3():
    # Ricki's 14 Oct trail run: 4.7 km in 28 min, 17 of 28 min in Z3, 2.7 in Z4 -> was "tempo", is an easy trail run.
    z = {"z1": 0.7, "z2": 8.6, "z3": 16.3, "z4": 2.7, "z5": 0.0}
    assert infer("trail", km=4.7, mins=28.5, zones=z) == "easy"
    assert infer("free", km=4.7, mins=28.5, zones=z) == "easy"   # a free run needs real Z4+Z5 (>= 15%) too: 2.7 of 28 is 10%


def test_trail_run_is_a_tempo_only_when_mostly_z4_z5():
    z = {"z1": 0.6, "z2": 2.0, "z3": 9.1, "z4": 26.7, "z5": 0.0}
    assert infer("trail", km=6.5, mins=38.7, zones=z) == "tempo"
    assert infer("trail", km=6.5, mins=38.7, zones=None) == "easy"
