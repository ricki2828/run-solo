"""COMPANION_WEATHER gates (sec-review-223 F2/F3/F5): the app switch governs the server, the stored area is the
latest one only, it expires after 30 days without a run, and it goes on switch-off, delete and export."""
import sqlite3
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from companion.app import create_app
from companion.service import RETENTION_AREA_DAYS
from companion.timeutil import now_utc
from conftest import OWNER, auth, enrol, make_settings, run_payload, weather_on


def rows(client, sql, *a):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return [dict(r) for r in c.execute(sql, a)]


def areas(client):
    return rows(client, "SELECT run_id, lat, lon FROM convo_area ORDER BY run_id")


def post(client, t, rid, minutes_ago=20, **over):
    return client.post("/v1/runs", json=run_payload(rid, minutes_ago=minutes_ago, area_lat=1.3521, area_lon=103.8198, **over),
                       headers=auth(t))


# --- gate 1: the app switch governs the server -------------------------------------------------

def test_switch_is_off_by_default_and_area_is_ignored_not_rejected(client):
    t = enrol(client)
    assert client.get("/v1/me", headers=auth(t)).json()["profile"]["weather_in_suggestions"] is False
    assert post(client, t, "n1").status_code == 202  # accepted, area quietly dropped
    assert areas(client) == []


def test_area_is_stored_only_after_the_switch_is_on(client):
    t = enrol(client)
    post(client, t, "n1", minutes_ago=300)
    assert areas(client) == []
    assert weather_on(client, t).json() == {"status": "ok"}
    post(client, t, "n2")
    assert areas(client) == [{"run_id": "n2", "lat": 1.4, "lon": 103.8}]


def test_switch_off_forgets_the_stored_area_and_later_areas_are_ignored(client):
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "a1")
    assert len(areas(client)) == 1
    weather_on(client, t, False)
    assert areas(client) == []
    assert client.get("/v1/me", headers=auth(t)).json()["areas"] == []
    post(client, t, "a2", minutes_ago=5)
    assert areas(client) == []
    assert rows(client, "SELECT COUNT(*) n FROM runs")[0]["n"] == 2  # only the location goes; the runs stay


def test_switch_off_works_even_when_the_server_flag_is_off(tmp_path, fakes):
    s = make_settings(tmp_path, weather_enabled=False)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        t = enrol(c)
        weather_on(c, t)
        con = sqlite3.connect(s.db_path)  # an area left from when the flag was on
        uid = con.execute("SELECT id FROM users").fetchone()[0]
        con.execute("INSERT INTO convo_area (user_id, run_id, lat, lon) VALUES (?,?,?,?)", (uid, "old", 1.4, 103.8))
        con.commit()
        con.close()
        weather_on(c, t, False)
        assert areas(c) == []


def test_switch_is_per_user(tmp_path, fakes):
    s = make_settings(tmp_path, allowed_ids=frozenset({f"telegram:{OWNER}", "telegram:999888777"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        a = enrol(c)
        weather_on(c, a)
        post(c, a, "a1")
        b = enrol(c, ref="999888777")
        post(c, b, "b1")
        assert [r["run_id"] for r in areas(c)] == ["a1"]
        weather_on(c, b, False)
        assert [r["run_id"] for r in areas(c)] == ["a1"]


@pytest.mark.parametrize("bad", ["yes", 2, [True], {"on": 1}])
def test_switch_rejects_non_booleans(client, bad):
    t = enrol(client)
    assert client.put("/v1/me/settings", json={"weather": bad}, headers=auth(t)).status_code == 422


def test_weather_only_put_leaves_quiet_hours_alone(client):
    t = enrol(client)
    client.put("/v1/me/settings", json={"quiet_start_min": 60, "quiet_end_min": 120}, headers=auth(t))
    weather_on(client, t)
    u = rows(client, "SELECT quiet_start, quiet_end, weather_optin FROM users")[0]
    assert (u["quiet_start"], u["quiet_end"], u["weather_optin"]) == (60, 120, 1)


def test_open_meteo_gets_nothing_without_the_switch_and_only_a_cell_with_it(tmp_path, fakes):
    sent: list[httpx.Request] = []

    def handler(req):
        if req.url.host == "api.open-meteo.com":
            sent.append(req)
            return httpx.Response(404)
        return fakes.handler(req)

    s = make_settings(tmp_path, weather_enabled=True)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        t = enrol(c)
        post(c, t, "w0", minutes_ago=300)
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        assert sent == []  # not opted in: Open-Meteo is never called
        weather_on(c, t)
        post(c, t, "w1")
        c.svc.run_outbox(now_utc() + timedelta(seconds=2))
    assert sent, "opted in, so the lookup should happen"
    for req in sent:
        q = dict(req.url.params)
        assert set(q) == {"latitude", "longitude", "timezone", "hourly", "daily", "past_days", "forecast_days"}
        assert (q["latitude"], q["longitude"]) == ("1.4", "103.8")  # 0.1 degree cell, nothing finer
        assert not req.content and "authorization" not in req.headers


# --- gate 3: retention -------------------------------------------------------------------------

def test_only_the_latest_area_is_kept(client):
    t = enrol(client)
    weather_on(client, t)
    client.post("/v1/runs", json=run_payload("r1", minutes_ago=600, area_lat=1.3, area_lon=103.8), headers=auth(t))
    client.post("/v1/runs", json=run_payload("r2", minutes_ago=300, area_lat=37.97, area_lon=23.72), headers=auth(t))
    assert areas(client) == [{"run_id": "r2", "lat": 38.0, "lon": 23.7}]


def test_a_late_older_run_does_not_replace_a_newer_area(client):
    t = enrol(client)
    weather_on(client, t)
    client.post("/v1/runs", json=run_payload("new", minutes_ago=100, area_lat=37.97, area_lon=23.72), headers=auth(t))
    client.post("/v1/runs", json=run_payload("old", minutes_ago=900, area_lat=1.3, area_lon=103.8), headers=auth(t))
    assert [r["run_id"] for r in areas(client)] == ["new"]


def test_area_expires_after_30_days_without_a_run_but_not_before(client):
    assert RETENTION_AREA_DAYS == 30
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "r1")
    client.svc.purge(now_utc() + timedelta(days=29))
    assert len(areas(client)) == 1
    client.svc.purge(now_utc() + timedelta(days=31))
    assert areas(client) == []
    assert rows(client, "SELECT weather_optin FROM users")[0]["weather_optin"] == 1  # the switch itself is not forgotten
    assert rows(client, "SELECT COUNT(*) n FROM runs")[0]["n"] == 1


# --- gate 3: delete and export -----------------------------------------------------------------

def test_delete_me_removes_the_area_and_the_switch(client):
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "r1")
    assert client.delete("/v1/me", headers=auth(t)).json() == {"status": "deleted"}
    assert areas(client) == [] and rows(client, "SELECT COUNT(*) n FROM users")[0]["n"] == 0


def test_export_shows_the_switch_and_the_one_stored_area(client):
    t = enrol(client)
    me = client.get("/v1/me", headers=auth(t)).json()
    assert me["profile"]["weather_in_suggestions"] is False and me["areas"] == []
    weather_on(client, t)
    post(client, t, "r1")
    me = client.get("/v1/me", headers=auth(t)).json()
    assert me["profile"]["weather_in_suggestions"] is True
    assert me["areas"] == [{"run_id": "r1", "lat": 1.4, "lon": 103.8}]


def test_an_old_database_gets_the_switch_column(tmp_path):
    from companion import db
    path = str(tmp_path / "old.db")
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE users (id TEXT PRIMARY KEY, channel TEXT, chat_ref TEXT, created_at TEXT)")
    con.execute("INSERT INTO users VALUES ('u_x','telegram','1','2026-01-01T00:00:00Z')")
    con.commit()
    con.close()
    db.init(path)
    db.init(path)  # idempotent
    assert sqlite3.connect(path).execute("SELECT weather_optin FROM users").fetchone() == (0,)
