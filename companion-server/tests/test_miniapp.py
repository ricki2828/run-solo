"""Telegram Mini App v1 (S4): initData auth (eng-review A1), the read-only view, headers, flag and the web_app button."""
import hashlib
import hmac
import json
import logging
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import db
from companion.app import create_app
from companion.miniapp import build_view
from companion.miniapp_auth import InitDataError, verify_init_data
from companion.timeutil import now_utc
from conftest import OWNER, TG_TOKEN, auth, enrol, make_settings, run_payload, shape_payload

OTHER = "555666777"      # linked second runner
STRANGER = 999000111     # a Telegram user who never linked


def sign(user_id, *, token=TG_TOKEN, auth_date=None, extra=None, tamper=None):
    """initData the way Telegram builds it: every field but `hash`, sorted, HMAC with the WebAppData-derived key."""
    f = {"auth_date": str(int(time.time()) if auth_date is None else auth_date), "query_id": "AAH-test",
         "user": json.dumps({"id": user_id, "first_name": "Sam"}, separators=(",", ":")),
         "signature": "c2lnbmF0dXJl"}
    f.update(extra or {})
    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
    f["hash"] = hmac.new(secret, "\n".join(f"{k}={f[k]}" for k in sorted(f)).encode(), hashlib.sha256).hexdigest()
    if tamper:
        f.update(tamper)
    return urlencode(f)


def tma(raw):
    return {"Authorization": f"tma {raw}"}


@pytest.fixture
def mc(tmp_path, fakes):
    s = make_settings(tmp_path, miniapp_enabled=True,
                      allowed_ids=frozenset({f"telegram:{OWNER}", f"telegram:{OTHER}"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        c.tok = enrol(c)
        c.tok2 = enrol(c, ref=OTHER)
        yield c


# --- verify_init_data ----------------------------------------------------------------------------

def test_valid_init_data_returns_the_user():
    assert verify_init_data(sign(42), TG_TOKEN, now_utc())["user_id"] == 42


def test_forged_hash_wrong_token_and_tampered_field():
    now = now_utc()
    for raw in (sign(42, tamper={"hash": "0" * 64}), sign(42, token="1:" + "B" * 35),
                sign(42, tamper={"user": json.dumps({"id": 43})})):
        with pytest.raises(InitDataError) as e:
            verify_init_data(raw, TG_TOKEN, now)
        assert e.value.code == "bad_hash"


def test_stale_future_and_replay_outside_the_window():
    now = now_utc()
    t = int(now.timestamp())
    with pytest.raises(InitDataError) as e:
        verify_init_data(sign(42, auth_date=t - 3601), TG_TOKEN, now)
    assert e.value.code == "stale"
    with pytest.raises(InitDataError) as e:
        verify_init_data(sign(42, auth_date=t + 600), TG_TOKEN, now)
    assert e.value.code == "future"
    good = sign(42, auth_date=t)                                  # genuine, signed data replayed two hours later
    with pytest.raises(InitDataError) as e:
        verify_init_data(good, TG_TOKEN, now + timedelta(hours=2))
    assert e.value.code == "stale"
    assert verify_init_data(good, TG_TOKEN, now + timedelta(minutes=59))["user_id"] == 42
    assert verify_init_data(sign(42, auth_date=t + 30), TG_TOKEN, now)["user_id"] == 42   # small clock skew is fine


@pytest.mark.parametrize("raw", ["", "garbage", "a=1&a=2&hash=00", "auth_date=1", "x" * 5000])
def test_malformed_or_missing_fields(raw):
    with pytest.raises(InitDataError):
        verify_init_data(raw, TG_TOKEN, now_utc())


def test_duplicate_key_is_refused_even_when_signed():
    raw = sign(42) + "&auth_date=1"
    with pytest.raises(InitDataError) as e:
        verify_init_data(raw, TG_TOKEN, now_utc())
    assert e.value.code == "malformed"


def test_signature_field_stays_in_the_check_string():
    now = now_utc()
    assert verify_init_data(sign(42, extra={"signature": "AAAA_bbbb-CC"}), TG_TOKEN, now)["user_id"] == 42
    with pytest.raises(InitDataError):   # dropping it after signing breaks the hash
        verify_init_data("&".join(p for p in sign(42).split("&") if not p.startswith("signature=")), TG_TOKEN, now)


def test_comparison_is_constant_time():
    import inspect
    from companion import miniapp_auth
    assert "compare_digest" in inspect.getsource(miniapp_auth)


# --- the API -------------------------------------------------------------------------------------

def test_linked_user_gets_their_own_view_with_no_store(mc):
    mc.post("/v1/runs", json={**run_payload("r1"), **shape_payload(reps=True)}, headers=auth(mc.tok))
    r = mc.get("/miniapp/api/me", headers=tma(sign(int(OWNER))))
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["latest"]["km"] == 7.0 and len(j["lanes"]) == 4 and len(j["week"]["days"]) == 7
    assert r.headers["cache-control"] == "no-store"
    assert "frame-ancestors" in r.headers["content-security-policy"] and "'unsafe-inline'" not in r.headers["content-security-policy"]
    assert r.headers["referrer-policy"] == "no-referrer"


def test_response_has_no_pack_age_route_zone_or_place(mc):
    mc.post("/v1/runs", json={**run_payload("r1", locality="Ponsonby", zone_min={"z2": 30.0}), **shape_payload(reps=True)},
            headers=auth(mc.tok))
    j = mc.get("/miniapp/api/me", headers=tma(sign(int(OWNER)))).json()
    keys = set()

    def walk(x):
        if isinstance(x, dict):
            keys.update(x)
            [walk(v) for v in x.values()]
        elif isinstance(x, list):
            [walk(v) for v in x]
    walk(j)
    assert not keys & {"route", "pack", "age_band", "age", "locality", "zone", "zone_min", "zones", "lat", "lon", "user_id", "id", "run_id"}
    assert "Ponsonby" not in json.dumps(j)


def test_unlinked_user_is_403(mc):
    assert mc.get("/miniapp/api/me", headers=tma(sign(STRANGER))).status_code == 403


def test_unconfirmed_enrolment_is_403(mc):
    """A users row exists from /start, but until the app confirms the code (consent_at set) the user is not linked."""
    con = sqlite3.connect(mc.svc.s.db_path)
    con.execute("UPDATE users SET consent_at=NULL WHERE chat_ref=?", (OTHER,))
    con.commit()
    assert mc.get("/miniapp/api/me", headers=tma(sign(int(OTHER)))).status_code == 403
    assert mc.get("/miniapp/api/me", headers=tma(sign(int(OWNER)))).status_code == 200


def test_missing_and_wrong_scheme_headers_are_401(mc):
    assert mc.get("/miniapp/api/me").status_code == 401
    assert mc.get("/miniapp/api/me", headers={"Authorization": f"Bearer {mc.tok}"}).status_code == 401  # a device token is not initData
    assert mc.get("/miniapp/api/me", headers={"Authorization": "tma "}).status_code == 401


def test_forged_stale_and_future_are_401_over_http(mc):
    now = int(time.time())
    for raw in (sign(int(OWNER), tamper={"hash": "1" * 64}), sign(int(OWNER), auth_date=now - 7200),
                sign(int(OWNER), auth_date=now + 7200)):
        assert mc.get("/miniapp/api/me", headers=tma(raw)).status_code == 401


def test_init_data_in_the_query_string_is_ignored(mc):
    assert mc.get("/miniapp/api/me", params={"initData": sign(int(OWNER))}).status_code == 401


def test_runner_id_injection_cannot_reach_another_runner(mc):
    mc.post("/v1/runs", json=run_payload("mine", distance_m=7000), headers=auth(mc.tok))
    mc.post("/v1/runs", json=run_payload("theirs", distance_m=21000), headers=auth(mc.tok2))
    con = sqlite3.connect(mc.svc.s.db_path)
    other_id = con.execute("SELECT id FROM users WHERE chat_ref=?", (OTHER,)).fetchone()[0]
    r = mc.get("/miniapp/api/me", headers=tma(sign(int(OWNER))),
               params={"runner_id": other_id, "user_id": other_id, "uid": other_id, "chat_ref": OTHER})
    assert r.status_code == 200 and r.json()["latest"]["km"] == 7.0
    r = mc.get(f"/miniapp/api/me/{other_id}", headers=tma(sign(int(OWNER))))
    assert r.status_code in (404, 405)
    r = mc.get("/miniapp/api/me", headers={**tma(sign(int(OWNER))), "X-Runner-Id": other_id})
    assert r.json()["latest"]["km"] == 7.0
    # and the injected user id inside signed initData cannot be forged to a stranger
    assert mc.get("/miniapp/api/me", headers=tma(sign(int(OWNER), tamper={"user": json.dumps({"id": int(OTHER)})}))).status_code == 401


def test_no_init_data_or_token_in_the_logs(mc, caplog):
    caplog.set_level(logging.DEBUG)
    raw = sign(int(OWNER), tamper={"hash": "2" * 64})
    mc.get("/miniapp/api/me", headers=tma(raw))
    mc.get("/miniapp/api/me", headers=tma(sign(STRANGER)))
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "2" * 64 not in text and "AAH-test" not in text and TG_TOKEN not in text and "Sam" not in text


def test_failed_auth_is_rate_limited(mc):
    codes = {mc.get("/miniapp/api/me", headers=tma(sign(int(OWNER), tamper={"hash": "3" * 64}))).status_code
             for _ in range(30)}
    assert 429 in codes


def test_flag_off_means_no_routes(tmp_path, fakes):
    s = make_settings(tmp_path)  # miniapp_enabled defaults to False
    assert s.miniapp_enabled is False
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        assert c.get("/miniapp/api/me", headers=tma(sign(int(OWNER)))).status_code == 404
        assert c.get("/miniapp/").status_code == 404


def test_static_app_and_fonts_served_with_headers(mc):
    r = mc.get("/miniapp/")
    assert r.status_code == 200 and "telegram-web-app.js" in r.text and "<script>" not in r.text
    assert "script-src 'self' https://telegram.org" in r.headers["content-security-policy"]
    assert mc.get("/miniapp/app.js").status_code == 200
    assert mc.get("/miniapp/fonts/SairaExtraCondensed-ExtraBold.ttf").status_code == 200
    assert mc.get("/miniapp/fonts/..%2fcompanion.db").status_code == 404
    assert mc.get("/miniapp/fonts/passwd").status_code == 404


def test_settings_default_off_and_from_env():
    from companion.config import Settings
    base = {"COMPANION_PEPPER": "p" * 20}
    assert Settings.from_env(base).miniapp_enabled is False
    s = Settings.from_env({**base, "COMPANION_MINIAPP": "1", "COMPANION_MINIAPP_URL": "https://x.example/miniapp"})
    assert s.miniapp_enabled and s.miniapp_url == "https://x.example/miniapp/"
    assert Settings.from_env({**base, "COMPANION_MINIAPP_URL": "http://insecure"}).miniapp_url.startswith("https://")


# --- the view (clock pinned) ---------------------------------------------------------------------

def _seed(tmp_path):
    path = str(tmp_path / "v.db")
    db.init(path)
    now = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)   # Wednesday, ISO week 43
    with db.tx(path) as c:
        c.execute("INSERT INTO users (id, channel, chat_ref, created_at, zone_id) VALUES ('u','telegram','1','x','UTC')")
        for rid, day, typ, m, sd, nxt in (
                ("a", "2026-10-20T07:00:00+00:00", "interval", 8400, '{"speed": 3, "aerobic": -1}', None),
                ("b", "2026-10-21T07:00:00+00:00", "easy", 5000, '{"aerobic": 2}', ("tempo", "2026-10-22"))):
            c.execute("INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, "
                      "distance_m, pace_s_per_km, scores_delta, received_at, plan_next_type, plan_next_day, plan_next_week) "
                      "VALUES ('u',?,?,?,0,'UTC',?,2400,?,300,?,?,?,?,1)",
                      (rid, day, day, typ, m, sd, day, nxt[0] if nxt else None, nxt[1] if nxt else None))
        c.execute("INSERT INTO run_shape (user_id, run_id, route_json, splits_json, reps_json) VALUES "
                  "('u','b','[[0,0],[5,5]]','[{\"km\":1.0,\"pace_s\":300.0,\"zone\":2}]','[{\"time_s\":250.0,\"zone\":5}]')")
    return path, now


def test_view_week_lanes_latest_next(tmp_path):
    path, now = _seed(tmp_path)
    with db.ro(path) as c:
        v = build_view(c, "u", "UTC", now)
    assert v["week"]["label"] == "Week 43" and v["week"]["done_runs"] == 2 and v["week"]["done_km"] == 13.4
    assert [len(d["runs"]) for d in v["week"]["days"]] == [0, 1, 1, 0, 0, 0, 0]
    assert v["week"]["days"][1]["runs"][0]["lane"] == "speed"
    assert {x["lane"]: x["change"] for x in v["lanes"]} == {"aerobic": 1, "speed": 3, "mid": 0, "long": 0}
    assert v["week"]["next"]["type"] == "tempo" and v["latest"]["reps"] == [{"time_s": 250.0}]
    assert "route" not in json.dumps(v)


def test_lane_change_is_the_42_day_sum_of_stored_deltas(tmp_path):
    """Server definition: the sum of the per-run deltas over the last 42 days. It cannot be the app's percentile change
    (ScoreNorms.change needs VDOT, age and sex, which stay on the phone), and the app does not send scores_delta today."""
    path, now = _seed(tmp_path)
    with db.tx(path) as c:
        c.execute("INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, "
                  "scores_delta, received_at) VALUES ('u','old',?,?,0,'UTC','easy',100,1000,'{\"aerobic\": 5}','x')",
                  ((now - timedelta(days=41)).isoformat(),) * 2)
        c.execute("INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, "
                  "scores_delta, received_at) VALUES ('u','older',?,?,0,'UTC','easy',100,1000,'{\"aerobic\": 9}','x')",
                  ((now - timedelta(days=43)).isoformat(),) * 2)
    with db.ro(path) as c:
        v = build_view(c, "u", "UTC", now)
    assert v["lane_days"] == 42 and {x["lane"]: x["change"] for x in v["lanes"]}["aerobic"] == 1 + 5


def test_view_with_no_runs_and_a_past_next_session(tmp_path):
    path, now = _seed(tmp_path)
    with db.ro(path) as c:
        v = build_view(c, "u", "UTC", now + timedelta(days=3))   # the planned day has passed
    assert v["week"]["next"] is None
    with db.tx(path) as c:
        c.execute("INSERT INTO users (id, channel, chat_ref, created_at, zone_id) VALUES ('e','telegram','2','x','UTC')")
    with db.ro(path) as c:
        v = build_view(c, "e", "UTC", now)
    assert v["latest"] is None and v["week"]["done_runs"] == 0 and all(x["change"] is None for x in v["lanes"])


# --- the keyboard hook ---------------------------------------------------------------------------

def test_run_card_carries_a_web_app_button_only_when_enabled(tmp_path, fakes):
    for on in (True, False):
        s = make_settings(tmp_path / str(on), miniapp_enabled=on)
        app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
        with TestClient(app) as c:
            t = enrol(c)
            fakes.tg.clear()
            c.post("/v1/runs", json=run_payload("r1", minutes_ago=5), headers=auth(t))
            app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
            btns = [b for m, p in fakes.tg if m == "sendMessage"
                    for row in p.get("reply_markup", {}).get("inline_keyboard", []) for b in row]
            webapp = [b for b in btns if "web_app" in b]
            assert bool(webapp) is on
            if on:
                assert webapp[0]["web_app"]["url"] == "https://companion.taiaroa.xyz/miniapp/" and "url" not in webapp[0]
