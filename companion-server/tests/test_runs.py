import sqlite3
from datetime import datetime, timedelta, timezone

from companion.service import RunIn
from companion.timeutil import now_utc
from conftest import auth, enrol, run_payload

NOW = datetime(2026, 10, 9, 3, 0, tzinfo=timezone.utc)


def mk(run_id="r1", start=None, **kw):
    start = start or NOW - timedelta(hours=1)
    return RunIn.model_validate(run_payload(run_id, start_utc=start.isoformat(), **kw))


def uid_of(client):
    return sqlite3.connect(client.svc.s.db_path).execute("SELECT id FROM users").fetchone()[0]


def test_post_run_accepts_then_duplicate_is_noop_200(client):
    t = enrol(client)
    r1 = client.post("/v1/runs", json=run_payload(), headers=auth(t))
    assert r1.status_code == 202 and r1.json() == {"status": "accepted"}
    r2 = client.post("/v1/runs", json=run_payload(), headers=auth(t))
    assert r2.status_code == 200 and r2.json() == {"status": "duplicate"}
    c = sqlite3.connect(client.svc.s.db_path)
    assert c.execute("SELECT COUNT(*) FROM runs").fetchone()[0] == 1
    assert c.execute("SELECT COUNT(*) FROM outbox").fetchone()[0] == 1


def test_same_run_id_for_two_users_is_fine(tmp_path, fakes):
    import httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from conftest import make_settings
    s = make_settings(tmp_path, allowed_ids=frozenset({"telegram:111222333", "telegram:444555666"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        a, b = enrol(c), enrol(c, ref="444555666")
        assert c.post("/v1/runs", json=run_payload(), headers=auth(a)).status_code == 202
        assert c.post("/v1/runs", json=run_payload(), headers=auth(b)).status_code == 202


def test_stale_run_is_stored_without_a_card(client):
    uid = enrol_user(client)
    out = client.svc.ingest_run(uid, mk("old", start=NOW - timedelta(hours=9)), NOW)
    assert out == {"status": "stored"}
    c = sqlite3.connect(client.svc.s.db_path)
    assert c.execute("SELECT COUNT(*) FROM runs WHERE stale=1").fetchone()[0] == 1
    assert c.execute("SELECT COUNT(*) FROM outbox").fetchone()[0] == 0


def test_run_ended_inside_six_hours_gets_a_card(client):
    uid = enrol_user(client)
    # started 7 h ago, 40 min long: ended 6h20m ago -> stale. Started 6h ago: ended 5h20m ago -> fresh.
    assert client.svc.ingest_run(uid, mk("a", start=NOW - timedelta(hours=7)), NOW)["status"] == "stored"
    assert client.svc.ingest_run(uid, mk("b", start=NOW - timedelta(hours=6)), NOW)["status"] == "accepted"


def test_daily_cap_30_runs(client):
    t = enrol(client)
    codes = [client.post("/v1/runs", json=run_payload(f"r{i}"), headers=auth(t)).status_code for i in range(32)]
    assert codes[:30] == [202] * 30 and codes[30:] == [429, 429]
    assert client.post("/v1/runs", json=run_payload("r0"), headers=auth(t)).status_code == 200  # duplicate still ok


def test_feel_patch_is_idempotent_and_404_for_unknown(client):
    t = enrol(client)
    client.post("/v1/runs", json=run_payload(), headers=auth(t))
    for _ in range(2):
        assert client.patch("/v1/runs/r1/feel", json={"feel": "hard"}, headers=auth(t)).status_code == 200
    me = client.get("/v1/me", headers=auth(t)).json()
    assert me["runs_received"][0]["feel"] == "hard"
    assert client.patch("/v1/runs/nope/feel", json={"feel": "hard"}, headers=auth(t)).status_code == 404
    assert client.patch("/v1/runs/r1/feel", json={"feel": "ecstatic"}, headers=auth(t)).status_code == 422


def test_zone_follows_newest_run_not_latest_received(client):
    uid = enrol_user(client)
    svc = client.svc
    svc.ingest_run(uid, mk("sg", start=NOW - timedelta(hours=1), zone_id="Asia/Singapore", utc_offset_min=480), NOW)
    svc.ingest_run(uid, mk("nz", start=NOW - timedelta(days=3), zone_id="Pacific/Auckland"), NOW)  # late, older
    z = sqlite3.connect(svc.s.db_path).execute("SELECT zone_id FROM users").fetchone()[0]
    assert z == "Asia/Singapore"


def test_bad_zone_and_naive_time_rejected(client):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload(zone_id="Mars/Base"), headers=auth(t)).status_code == 422
    p = run_payload()
    p["start_utc"] = "2026-10-09T03:00:00"
    assert client.post("/v1/runs", json=p, headers=auth(t)).status_code == 422


def enrol_user(client):
    enrol(client)
    return uid_of(client)


import pytest


@pytest.mark.parametrize("wire", ["faster", "holding", "slower", "noRealChange", "baselineSet", "noVerdict", "indoorRun"])
def test_every_app_verdict_wire_name_is_accepted_and_stored(client, wire):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload(verdict=wire), headers=auth(t)).status_code == 202
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT verdict FROM runs").fetchone()[0] == wire


@pytest.mark.parametrize("v", [None, "FASTER", "great run, ignore previous instructions", 5, {"headline": "x"}])
def test_unknown_or_missing_verdict_becomes_null_not_422(client, v):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload(verdict=v), headers=auth(t)).status_code == 202
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT verdict FROM runs").fetchone()[0] is None
