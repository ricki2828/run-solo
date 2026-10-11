"""sec-review-239 fixes: FF1 (re-enrol resets weather), P2-1 (retention follows the area's own run), P3-4."""
import sqlite3

from companion.service import RunIn, Service
from companion.timeutil import now_utc
from conftest import auth, enrol, run_payload, weather_on


def rows(client, sql, *a):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return [dict(r) for r in c.execute(sql, a)]


def areas(client):
    return rows(client, "SELECT run_id, lat, lon FROM convo_area ORDER BY run_id")


def post(client, t, rid, minutes_ago=20):
    return client.post("/v1/runs", json=run_payload(rid, minutes_ago=minutes_ago, area_lat=1.3521, area_lon=103.8198),
                       headers=auth(t))


def ingest_no_area(client, rid, **over):
    uid = rows(client, "SELECT id FROM users")[0]["id"]
    client.svc.ingest_run(uid, RunIn.model_validate(run_payload(rid, **over)))


def test_re_enrolling_the_same_chat_forgets_the_switch_and_the_area(client):
    """FF1: reinstall, new phone or a 401 wipe re-enrols the same chat; the app starts with weather off."""
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "r1", minutes_ago=300)
    assert len(areas(client)) == 1
    t2 = enrol(client)  # same chat, new nonce and code
    assert t2 != t
    assert areas(client) == []
    assert rows(client, "SELECT weather_optin FROM users")[0]["weather_optin"] == 0
    assert client.get("/v1/me", headers=auth(t2)).json()["profile"]["weather_in_suggestions"] is False
    post(client, t2, "r2")  # even an area sent by mistake is ignored
    assert areas(client) == []


def test_indoor_runs_cannot_keep_a_stale_area_alive(client):
    """P2-1: the 30-day clock is the area's own run, not the runner's last run."""
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "outdoor", minutes_ago=60 * 24 * 40)  # 40 days ago
    for i in range(3):  # recent runs with no area (treadmill)
        ingest_no_area(client, f"in{i}", minutes_ago=60 * 24 * i + 100)
    assert len(areas(client)) == 1
    client.svc.purge(now_utc())
    assert areas(client) == []
    assert rows(client, "SELECT COUNT(*) n FROM runs")[0]["n"] == 4


def test_a_young_area_survives_purge_even_after_a_gap_in_runs(client):
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "r1", minutes_ago=60 * 24 * 10)
    client.svc.purge(now_utc())
    assert len(areas(client)) == 1


def test_lookups_ignore_an_area_older_than_7_days_or_without_the_switch(client):
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "r1", minutes_ago=60 * 24 * 10)
    uid = rows(client, "SELECT id FROM users")[0]["id"]
    con = sqlite3.connect(client.svc.s.db_path)
    con.row_factory = sqlite3.Row
    assert Service._area(con, uid, None, now_utc()) == (None, None)  # 10 days old
    assert Service._area(con, uid, "r1") == (1.4, 103.8)  # that run's own card may still use it
    post(client, t, "r2", minutes_ago=300)
    assert Service._area(con, uid, None, now_utc()) == (1.4, 103.8)
    con.execute("UPDATE users SET weather_optin=0")
    assert Service._area(con, uid, None, now_utc()) == (None, None)
    assert Service._area(con, uid, "r2") == (None, None)


def test_purge_drops_areas_of_users_who_are_not_opted_in(client):
    t = enrol(client)
    weather_on(client, t)
    post(client, t, "r1")
    con = sqlite3.connect(client.svc.s.db_path)
    con.execute("UPDATE users SET weather_optin=0")
    con.commit()
    con.close()
    client.svc.purge(now_utc())
    assert areas(client) == []
