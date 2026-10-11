"""Timezone endpoint + scheduling, optional rounded area on run upload, WhatsApp media-template payloads (fixtures only)."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import pytest

from companion.channels import (OutCard, WhatsAppChannel, feel_template_eligible, wa_media_upload_spec,
                                wa_template_payload)
from companion.service import RunIn
from conftest import OWNER, auth, enrol, make_settings, run_payload, weather_on

FX = Path(__file__).parent / "fixtures"


def q(client, sql, *a):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return [dict(r) for r in c.execute(sql, a)]


# --- timezone ----------------------------------------------------------------------------------

def test_put_timezone_needs_a_token(client):
    assert client.put("/v1/me/timezone", json={"zone_id": "Europe/Athens"}).status_code == 401


def test_put_timezone_updates_zone_and_offset(client):
    t = enrol(client)
    r = client.put("/v1/me/timezone", json={"zone_id": "Europe/Athens"}, headers=auth(t))
    assert r.status_code == 200 and r.json()["zone_id"] == "Europe/Athens" and r.json()["utc_offset_min"] in (120, 180)
    row = q(client, "SELECT zone_id, utc_offset_min FROM users")[0]
    assert row["zone_id"] == "Europe/Athens" and row["utc_offset_min"] in (120, 180)
    assert client.get("/v1/me", headers=auth(t)).json()["profile"]["zone_id"] == "Europe/Athens"


@pytest.mark.parametrize("bad", ["", "Mars/Base", "../../etc/passwd", "Europe/Athens\n", "UTC+3 ", "x" * 65, "Europe//Athens",
                                 "/etc/localtime", "A/B/C/D", "Europe/Athéns", "Europe/Athens; DROP TABLE users"])
def test_put_timezone_rejects_non_iana_names(client, bad):
    t = enrol(client)
    before = q(client, "SELECT zone_id FROM users")
    assert client.put("/v1/me/timezone", json={"zone_id": bad}, headers=auth(t)).status_code == 422
    assert q(client, "SELECT zone_id FROM users") == before


def test_put_timezone_rejects_extra_fields_and_wrong_types(client):
    t = enrol(client)
    assert client.put("/v1/me/timezone", json={"zone_id": "UTC", "x": 1}, headers=auth(t)).status_code == 422
    assert client.put("/v1/me/timezone", json={"zone_id": 5}, headers=auth(t)).status_code == 422
    assert client.put("/v1/me/timezone", json={}, headers=auth(t)).status_code == 422


def test_settings_endpoint_now_rejects_a_bad_zone_instead_of_ignoring_it(client):
    t = enrol(client)
    assert client.put("/v1/me/settings", json={"zone_id": "Mars/Base"}, headers=auth(t)).status_code == 422
    assert client.put("/v1/me/settings", json={"zone_id": "Asia/Tokyo"}, headers=auth(t)).status_code == 200
    assert q(client, "SELECT zone_id FROM users")[0]["zone_id"] == "Asia/Tokyo"


def put_zone(client, token, zone):
    r = client.put("/v1/me/timezone", json={"zone_id": zone}, headers=auth(token))
    assert r.status_code == 200, r.text


def seed_history(client, zone="UTC"):
    svc = client.svc
    uid = q(client, "SELECT id FROM users")[0]["id"]
    base = datetime(2026, 10, 14, 17, 30, tzinfo=timezone.utc)
    for i, (d, typ) in enumerate([(1, "easy"), (3, "easy"), (5, "easy"), (9, "tempo")]):
        start = base - timedelta(days=d, hours=1)
        svc.ingest_run(uid, RunIn.model_validate(run_payload(f"e{i}", type=typ, start_utc=start.isoformat(), zone_id=zone, utc_offset_min=0)),
                       start + timedelta(hours=2))
    con = sqlite3.connect(svc.s.db_path)
    con.execute("UPDATE outbox SET state='done'")
    con.commit()
    return base


def test_evening_suggestion_follows_the_zone_the_app_put(client):
    t = enrol(client)
    base = seed_history(client)  # 17:30 UTC on Wed 14 Oct: 20:30 in Athens (UTC+3), 06:30 Thursday in Auckland
    put_zone(client, t, "Pacific/Auckland")
    assert client.svc.plan_evening(base) == 0
    put_zone(client, t, "Europe/Athens")
    assert client.svc.plan_evening(base) == 1
    row = q(client, "SELECT ref FROM outbox WHERE kind='evening'")[0]
    assert row["ref"] == "2026-10-14"  # the local date in the new zone


def test_sunday_recap_follows_the_zone_the_app_put(client):
    t = enrol(client)
    seed_history(client)
    sunday = datetime(2026, 10, 11, 16, 30, tzinfo=timezone.utc)  # Sun 19:30 in Athens, Mon 05:30 in Auckland
    con = sqlite3.connect(client.svc.s.db_path)
    con.execute("UPDATE users SET last_run_utc=?", ("2026-10-10T08:00:00Z",))
    con.commit()
    put_zone(client, t, "Pacific/Auckland")
    assert client.svc.plan_recap(sunday) == 0
    put_zone(client, t, "Europe/Athens")
    assert client.svc.plan_recap(sunday) == 1
    assert q(client, "SELECT ref FROM outbox WHERE kind='recap'")[0]["ref"] == "2026-W41"


def test_changing_zone_does_not_reset_the_weekly_caps(client):
    """resolve_cap_week keeps the old zone defining the current week, so a flight cannot mint a second allowance."""
    from companion.timeutil import resolve_cap_week
    now = datetime(2026, 10, 14, 17, 30, tzinfo=timezone.utc)
    zone, week = resolve_cap_week("Pacific/Auckland", "2026-W42", "Asia/Tokyo", now)
    assert (zone, week) == ("Pacific/Auckland", "2026-W42")


# --- optional rounded area ---------------------------------------------------------------------

def test_run_without_area_is_accepted_and_stores_none(client):
    t = enrol(client)
    r = client.post("/v1/runs", json=run_payload("a0"), headers=auth(t))
    assert r.status_code == 202
    assert q(client, "SELECT COUNT(*) n FROM convo_area")[0]["n"] == 0


def test_area_is_rounded_to_a_tenth_of_a_degree_and_exported(client):
    t = enrol(client)
    weather_on(client, t)
    r = client.post("/v1/runs", json=run_payload("a1", area_lat=37.97123, area_lon=23.72571), headers=auth(t))
    assert r.status_code == 202
    row = q(client, "SELECT lat, lon FROM convo_area")[0]
    assert (row["lat"], row["lon"]) == (38.0, 23.7)
    assert client.get("/v1/me", headers=auth(t)).json()["areas"] == [{"run_id": "a1", "lat": 38.0, "lon": 23.7}]


@pytest.mark.parametrize("extra", [{"area_lat": 1.35}, {"area_lon": 103.8}, {"area_lat": None, "area_lon": None}])
def test_half_an_area_or_nulls_store_nothing_and_still_accept_the_run(client, extra):
    t = enrol(client)
    weather_on(client, t)
    assert client.post("/v1/runs", json=run_payload("a2", **extra), headers=auth(t)).status_code == 202
    assert q(client, "SELECT COUNT(*) n FROM convo_area")[0]["n"] == 0


@pytest.mark.parametrize("extra", [{"area_lat": 91, "area_lon": 0}, {"area_lat": 0, "area_lon": 181}, {"area_lat": "x", "area_lon": 0}])
def test_out_of_range_area_is_422(client, extra):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload("a3", **extra), headers=auth(t)).status_code == 422


def test_area_is_dropped_when_weather_is_off(tmp_path, fakes):
    from fastapi.testclient import TestClient
    from companion.app import create_app
    app = create_app(make_settings(tmp_path, weather_enabled=False), httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        t = enrol(c)
        assert c.post("/v1/runs", json=run_payload("a4", area_lat=1.3, area_lon=103.8), headers=auth(t)).status_code == 202
        assert q(c, "SELECT COUNT(*) n FROM convo_area")[0]["n"] == 0


# --- WhatsApp media templates (fixtures only: Meta is never called) ----------------------------

def feel_card():
    feel = [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
    return OutCard("abc123", "Easy one", "7.0 km at 5:42.\nSteady.", feel)


def other_card():
    return OutCard("abc123", "Easy one", "7.0 km at 5:42.", [
        {"label": "Sounds good", "action": "sugg:yes:recover", "row": 1},
        {"label": "Not this week", "action": "sugg:skip:recover", "row": 1}])


def fixture(name):
    return json.loads((FX / name).read_text())


def test_image_header_template_matches_fixture():
    got = wa_template_payload("61400111222", "run_card", "en", feel_card(), media_id="MEDIA_ID_IMG", url_suffix="run/r1")
    assert got == fixture("wa_template_image.json")


def test_video_header_template_matches_fixture():
    got = wa_template_payload("61400111222", "run_card", "en", feel_card(), media_id="MEDIA_ID_VID", media_kind="video",
                              url_suffix="week/2026-W41")
    assert got == fixture("wa_template_video.json")


def test_template_without_media_has_no_header():
    assert wa_template_payload("61400111222", "run_card", "en", feel_card()) == fixture("wa_template_text_only.json")


def test_non_feel_card_never_sends_mismatched_quick_reply_payloads():
    """The approved template's labels are Easy/Right/Hard; a suggestion card's payloads would disagree with them."""
    assert not feel_template_eligible(other_card()) and feel_template_eligible(feel_card())
    assert wa_template_payload("61400111222", "run_card", "en", other_card(), media_id="MEDIA_ID_IMG") == fixture("wa_template_not_feel.json")


def test_template_shape_limits():
    p = wa_template_payload("1", "run_card", "en", OutCard("abc123", "h" * 200, "b " * 900, []), media_id="m")
    body = [c for c in p["template"]["components"] if c["type"] == "body"][0]["parameters"]
    assert len(body[0]["text"]) == 60 and len(body[1]["text"]) <= 1000 and "\n" not in body[1]["text"]
    assert [c["type"] for c in p["template"]["components"]] == ["header", "body"]
    with pytest.raises(ValueError):
        wa_template_payload("1", "run_card", "en", feel_card(), media_id="m", media_kind="document")


def test_url_button_index_is_the_templates_fixed_slot():
    p = wa_template_payload("1", "run_card", "en", other_card(), url_suffix="run/r1")
    btns = [c for c in p["template"]["components"] if c["type"] == "button"]
    assert len(btns) == 1 and btns[0]["sub_type"] == "url" and btns[0]["index"] == "3"  # the template's fixed slot
    p2 = wa_template_payload("1", "run_card", "en", feel_card(), url_suffix="run/r1")
    assert [b["index"] for b in p2["template"]["components"] if b["type"] == "button"] == ["0", "1", "2", "3"]
    p3 = wa_template_payload("1", "run_card", "en", feel_card(), url_suffix="run/r1", url_index=4)
    assert [b["index"] for b in p3["template"]["components"] if b["type"] == "button"][-1] == "4"


def test_media_upload_spec_is_built_not_sent(fakes):
    spec = wa_media_upload_spec("https://graph.facebook.com/v21.0", "PHONEID", b"\x89PNG0", "image/png")
    assert spec["url"] == "https://graph.facebook.com/v21.0/PHONEID/media"
    assert spec["data"] == {"messaging_product": "whatsapp", "type": "image/png"} and spec["files"]["file"][2] == "image/png"
    assert fakes.wa == []
    vid = wa_media_upload_spec("https://x", "P", b"0", "video/mp4")
    assert vid["files"]["file"][0] == "card.mp4"


@pytest.mark.parametrize("data,mime", [(b"0" * (5 * 1024 * 1024 + 1), "image/png"), (b"0" * (16 * 1024 * 1024 + 1), "video/mp4"),
                                       (b"0", "image/gif"), (b"0", "application/pdf")])
def test_media_upload_spec_enforces_whatsapp_limits(data, mime):
    with pytest.raises(ValueError):
        wa_media_upload_spec("https://x", "P", data, mime)


def test_whatsapp_channel_sends_the_payload_through_the_mocked_graph_api_only(tmp_path, fakes):
    ch = WhatsAppChannel(make_settings(tmp_path), httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    ch.send_card("61400111222", feel_card(), in_window=False, media_id="MEDIA_ID_IMG", url_suffix="run/r1")
    assert fakes.wa == [fixture("wa_template_image.json")]
    assert fakes.tg == []
