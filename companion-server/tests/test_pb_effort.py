"""A pb set inside a longer run is told as the effort, never as the run: its own time and distance (the app's `pb_s`)."""
from datetime import datetime, timezone

import pytest

from companion.coach.tools import _pb_fields
from companion.convo import engine, voice
from companion.media import run_facts
from companion.service import RunIn
from conftest import run_payload

NOW = datetime(2026, 10, 28, tzinfo=timezone.utc)


def row(**over):
    r = {"run_id": "r1", "type": "easy", "app_type": "easy", "start_utc": "2026-10-26T22:30:00+00:00", "zone_id": "Etc/GMT-8",
         "duration_s": 4010, "distance_m": 12400, "pace_s_per_km": 323.4, "true_pace_s_per_km": None, "verdict": None,
         "pb": "5k", "pb_s": 1450, "climb_m": None, "zone_min": "{}", "feel": None}
    r.update(over)
    return r


def test_a_5k_inside_a_12k_run_never_says_the_run_time_for_12_km():
    sit, slots = engine.situation_for(row(), [], None)
    assert sit == "pb_effort"
    assert slots["time"] == "24:10" and slots["pb_dist"] == "5 km"
    whole = engine.fmt_duration(4010)
    for h, b in voice.SITUATIONS["pb_effort"]:
        text = h.format(**slots) + " " + b.format(**slots)
        assert whole not in text, text
    r = voice.render("pb_effort", slots, {}, NOW, "s")
    assert r is not None and whole not in r.body


def test_a_pb_that_is_the_whole_run_keeps_the_whole_run_lines():
    sit, slots = engine.situation_for(row(distance_m=5040, duration_s=1455, pb_s=1450), [], None)
    assert sit == "pb" and slots["time"] == "24:10"


def test_an_old_pb_with_no_effort_time_is_the_whole_runs():
    sit, slots = engine.situation_for(row(pb_s=None, distance_m=5040, duration_s=1455), [], None)
    assert sit == "pb" and slots["time"] == "24:15"


def test_the_card_draws_the_effort_not_the_run():
    f = run_facts(row(_shape={"route": [[0, 0], [255, 255]], "splits": [{"km": 1.0, "pace_s": 300, "zone": None}]}), "New best")
    assert (f["distance_km"], f["duration_s"], f["pace_s_per_km"]) == (5.0, 1450, 290.0)
    assert "route_xy" not in f and "splits" not in f


def test_coach_stats_give_the_effort_time_and_name_the_run():
    out = _pb_fields({"pb": "5k", "pb_s": 1450, "distance_m": 12400, "duration_s": 4010})
    assert out == {"distance_km": 5.0, "duration": "24:10", "set_inside_a_run_of_km": 12.4}
    assert _pb_fields({"pb": "5k", "pb_s": None, "distance_m": 5040, "duration_s": 1455})["duration"] == "24:15"


@pytest.mark.parametrize("over,kept", [({"pb": "5k", "pb_s": 1450}, 1450), ({"pb_s": 1450}, None),
                                       ({"pb": "5k", "pb_s": 99999}, None), ({"pb": "longest", "pb_s": 1450}, None)])
def test_pb_s_is_only_kept_for_a_distance_pb_inside_the_run(over, kept):
    assert RunIn.model_validate(run_payload("a1") | over).pb_s == kept


def test_a_5k_pb_inside_a_long_run_does_not_make_it_a_race(client, fakes):
    import sqlite3
    from datetime import datetime, timedelta, timezone
    from conftest import auth, enrol
    t = enrol(client)
    body = run_payload("long1", distance_m=12400, duration_s=4010, pb="5k", pb_s=1450, type="free")
    assert client.post("/v1/runs", json=body, headers=auth(t)).status_code == 202
    c = sqlite3.connect(client.svc.s.db_path)
    typ, pb_s = c.execute("SELECT type, pb_s FROM runs").fetchone()
    assert typ != "race" and pb_s == 1450
