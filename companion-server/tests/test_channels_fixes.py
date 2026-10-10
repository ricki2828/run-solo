"""Regressions from the #225 security review (sec-review-225.md): F1, F3, F4, P3-1, P3-3, tz_set_at."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import db, deeplink
from companion.app import create_app
from companion.channels import ChannelError, OutCard, TelegramChannel, _media_rejected, utf16_len
from companion.media import Media, MediaRenderer
from companion.service import RunIn
from companion.timeutil import iso, now_utc
from conftest import OWNER, Fakes, auth, enrol, make_settings, post_tg, run_payload, tg_callback
from test_channels_media import BASE, PNG, markup
from test_channels_media import media_client  # noqa: F401  (used as a context manager)
from test_cards import wa_post, wa_text
from conftest import chat_code, confirm, start


def q(client, sql, *a):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return [dict(r) for r in c.execute(sql, a)]


class FlakyFakes(Fakes):
    """sendMessage answers from `msg_script` (a list of (status, description)) before behaving normally."""

    def __init__(self):
        super().__init__()
        self.msg_script: list[tuple[int, str]] = []

    def handler(self, req):
        if req.url.host == "api.telegram.org" and req.url.path.endswith("/sendMessage") and self.msg_script:
            status, desc = self.msg_script.pop(0)
            self.tg.append(("sendMessage", {"_failed": status}))
            return httpx.Response(status, json={"ok": False, "description": desc})
        return super().handler(req)


def long_texts(fk):
    """The delivered text messages carrying the stretched card body."""
    return [b for m, b in fk.tg if m == "sendMessage" and "_failed" not in b and "xxxx" in b.get("text", "")]


def long_card_ready(c, run_id="r1", body="x" * 1100, buttons=None):
    """Enrol, take a run, build its card, then stretch the body so it cannot be a caption. Returns (svc, user, card_id)."""
    t = enrol(c)
    c.post("/v1/runs", json=run_payload(run_id), headers=auth(t))
    svc = c.svc
    uid = q(c, "SELECT id FROM users")[0]["id"]
    card_id = svc._build_run_card(uid, run_id, now_utc())
    con = sqlite3.connect(svc.s.db_path)
    con.execute("UPDATE cards SET body=? WHERE card_id=?", (body, card_id))
    if buttons is not None:
        con.execute("UPDATE cards SET buttons_json=? WHERE card_id=?", (json.dumps(buttons), card_id))
    con.commit()
    return svc, uid, card_id


# --- F1: no duplicate sends ---------------------------------------------------------------------

def test_followup_failure_never_re_uploads_the_photo(tmp_path):
    fk = FlakyFakes()
    with media_client(tmp_path, fk) as c:
        svc, uid, card_id = long_card_ready(c)
        fk.msg_script = [(500, "Internal"), (500, "Internal")]
        svc.run_outbox(now_utc() + timedelta(seconds=1))      # sends the photo, queues the follow-up
        assert fk.tg_methods().count("sendPhoto") == 1
        assert q(c, "SELECT sent_at FROM cards")[0]["sent_at"]                 # the photo counts as delivered
        for minutes in (2, 10, 30, 90):                                        # follow-up retries with backoff
            svc.run_outbox(now_utc() + timedelta(minutes=minutes))
        assert fk.tg_methods().count("sendPhoto") == 1
        texts = long_texts(fk)
        assert len(texts) == 1 and len(texts[0]["reply_markup"]["inline_keyboard"][0]) == 3
        assert q(c, "SELECT state FROM outbox WHERE kind='followup'")[0]["state"] == "done"


def test_followup_400_adds_no_extra_text_card(tmp_path):
    fk = FlakyFakes()
    with media_client(tmp_path, fk) as c:
        svc, uid, card_id = long_card_ready(c)
        fk.msg_script = [(400, "Bad Request: chat not found")] * 6
        for minutes in (1, 3, 8, 20, 50, 130):
            svc.run_outbox(now_utc() + timedelta(minutes=minutes))
        assert fk.tg_methods().count("sendPhoto") == 1
        assert [b for m, b in fk.tg if m == "sendMessage" and b.get("_failed") == 400]   # the follow-up tried and failed
        assert long_texts(fk) == []                                                      # and no text card got out
        assert q(c, "SELECT COUNT(*) n FROM cards WHERE kind='run'")[0]["n"] == 1


def test_a_long_caption_card_sends_exactly_one_photo_and_one_text(tmp_path, fakes):
    with media_client(tmp_path, fakes) as c:
        svc, uid, card_id = long_card_ready(c)
        svc.run_outbox(now_utc() + timedelta(seconds=1))
        svc.run_outbox(now_utc() + timedelta(seconds=2))
        assert [m for m in fakes.tg_methods() if m in ("sendPhoto", "sendMessage")].count("sendPhoto") == 1
        photo = [b for m, b in fakes.tg if m == "sendPhoto"][0]
        assert "caption" not in photo and "reply_markup" not in photo


# --- P3-3: dropped questions go as their own message ---------------------------------------------

def test_question_buttons_dropped_from_a_media_card_go_as_a_follow_up(tmp_path, fakes):
    buttons = [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
    buttons += [{"label": "10k", "action": "ans:goal_type:10k", "row": 1}, {"label": "Half", "action": "ans:goal_type:half", "row": 1}]
    with media_client(tmp_path, fakes) as c:
        svc, uid, card_id = long_card_ready(c, body="Short body.", buttons=buttons)
        svc.run_outbox(now_utc() + timedelta(seconds=1))
        photo = [b for m, b in fakes.tg if m == "sendPhoto"][0]
        assert all(not b["callback_data"].endswith((":3", ":4")) for row in markup(photo) for b in row if "callback_data" in b)
        assert q(c, "SELECT kind FROM outbox WHERE kind='followup'")
        svc.run_outbox(now_utc() + timedelta(seconds=2))
        text = [b for m, b in fakes.tg if m == "sendMessage"][-1]
        kb = text["reply_markup"]["inline_keyboard"]
        assert [r[0]["callback_data"] for r in kb] == [f"{card_id}:3", f"{card_id}:4"]
        # tapping it still works: the callback index points at the stored button
        post_tg(c, tg_callback(9100, f"{card_id}:3"))
        assert q(c, "SELECT value FROM memory WHERE key='goal_type'")[0]["value"] == "10k"


# --- P3-1: only media rejections are permanent ---------------------------------------------------

@pytest.mark.parametrize("status,desc,want", [
    (413, "Request Entity Too Large", True), (400, "Bad Request: PHOTO_INVALID_DIMENSIONS", True),
    (400, "Bad Request: wrong file identifier", True), (400, "Bad Request: IMAGE_PROCESS_FAILED", True),
    (400, "Bad Request: chat not found", False), (400, "Bad Request: can't parse reply markup", False),
    (400, None, False), (403, "Forbidden: bot was blocked by the user", False), (500, "photo", False), (429, "photo", False)])
def test_only_media_rejections_are_permanent(status, desc, want):
    assert _media_rejected(status, desc) is want


def test_a_non_media_400_on_the_photo_is_retried_not_turned_into_a_second_card(tmp_path):
    fk = Fakes()
    seen = []

    def handler(req):
        m = req.url.path.rsplit("/", 1)[-1]
        seen.append(m)
        if m == "sendPhoto":
            return httpx.Response(400, json={"ok": False, "description": "Bad Request: chat not found"})
        return fk.handler(req)
    s = make_settings(tmp_path, media_enabled=True)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(handler)), run_worker=False)
    app.state.svc.media = MediaRenderer({k: (lambda f, m: PNG) for k in ("light", "flood", "pb")}, {})
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
        assert seen.count("sendMessage") == 2 and seen.count("sendPhoto") == 1   # code + welcome only, no text card
        con = sqlite3.connect(s.db_path)
        assert con.execute("SELECT sent_at FROM cards").fetchone()[0] is None
        assert con.execute("SELECT state FROM outbox WHERE kind='run_card'").fetchone()[0] == "pending"


def test_utf16_caption_length():
    assert utf16_len("a" * 10) == 10 and utf16_len("\U0001F3C3" * 10) == 20


def test_emoji_heavy_text_near_the_limit_becomes_a_follow_up():
    card = OutCard("abc123", "h", "\U0001F3C3" * 600, [], Media(photo=PNG))
    assert TelegramChannel.followups(card) == ["caption"]


# --- F3: deep-link ids ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad", [".", "..", "...", "....."])
def test_all_dot_run_ids_make_no_link(bad):
    assert deeplink.run_link(bad) is None
    assert deeplink.web_twin(BASE, f"runsupreme://run/{bad}") is None


def test_encoded_dot_dot_is_refused_when_parsing():
    assert deeplink.parse("runsupreme://run/%2e%2e") is None and deeplink.parse("runsupreme://run/..") is None
    assert deeplink.parse("runsupreme://run/a..b") == ("run", "a..b")   # dots inside an id are fine


def test_service_emits_no_link_button_for_a_dot_dot_run_id(tmp_path, fakes):
    with media_client(tmp_path, fakes) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("..", minutes_ago=5), headers=auth(t))
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        photo = [b for m, b in fakes.tg if m == "sendPhoto"][0]
        assert all("url" not in b for row in markup(photo) for b in row)


# --- F4: WhatsApp outside the window ------------------------------------------------------------

def test_wa_non_feel_card_outside_the_window_is_not_sent_as_the_feel_template(tmp_path, fakes):
    s = make_settings(tmp_path, allowed_ids=frozenset({"whatsapp:61400111222"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        st = start(c)
        wa_post(c, wa_text("wamid.A", "61400111222", f"START {st['nonce']}"))
        tok = confirm(c, st, chat_code(c, st["nonce"])).json()["token"]
        c.post("/v1/runs", json=run_payload("r1", feel="easy"), headers=auth(tok))   # feel already known: no feel row
        svc = app.state.svc
        n = len(fakes.wa)
        svc.run_outbox(now_utc() + timedelta(hours=30))                       # 24 h window closed
        assert len(fakes.wa) == n                                              # nothing went to Meta
        con = sqlite3.connect(s.db_path)
        assert con.execute("SELECT sent_at FROM cards").fetchone()[0] is None
        assert con.execute("SELECT state FROM outbox WHERE kind='run_card'").fetchone()[0] == "skipped"


def test_wa_url_button_slot_is_configurable(tmp_path):
    from companion.config import Settings
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20}).wa_url_index == 3
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20, "COMPANION_WA_URL_INDEX": "2"}).wa_url_index == 2


# --- tz_set_at ---------------------------------------------------------------------------------

T0 = datetime(2026, 10, 14, 6, 0, tzinfo=timezone.utc)


def mk(run_id, start, zone, off):
    return RunIn.model_validate(run_payload(run_id, start_utc=start.isoformat(), zone_id=zone, utc_offset_min=off))


def test_a_queued_offline_run_cannot_undo_a_put_timezone(client):
    enrol(client)
    svc = client.svc
    uid = q(client, "SELECT id FROM users")[0]["id"]
    svc.ingest_run(uid, mk("a", T0 - timedelta(days=2), "Asia/Singapore", 480), T0)
    svc.set_timezone(uid, "Europe/Athens", now=T0)
    # the phone had run in Singapore just before the flight; the upload arrives after the PUT
    svc.ingest_run(uid, mk("b", T0 - timedelta(hours=1), "Asia/Singapore", 480), T0 + timedelta(minutes=5))
    row = q(client, "SELECT zone_id, tz_set_at FROM users")[0]
    assert row["zone_id"] == "Europe/Athens" and row["tz_set_at"] == iso(T0)
    # a run that starts after the PUT still decides the zone again
    svc.ingest_run(uid, mk("c", T0 + timedelta(hours=2), "Pacific/Auckland", 780), T0 + timedelta(hours=4))
    assert q(client, "SELECT zone_id FROM users")[0]["zone_id"] == "Pacific/Auckland"


def test_without_a_put_the_newest_run_still_decides_the_zone(client):
    enrol(client)
    uid = q(client, "SELECT id FROM users")[0]["id"]
    assert q(client, "SELECT tz_set_at FROM users")[0]["tz_set_at"] is None
    client.svc.ingest_run(uid, mk("a", T0 - timedelta(hours=3), "Asia/Singapore", 480), T0)
    assert q(client, "SELECT zone_id FROM users")[0]["zone_id"] == "Asia/Singapore"


def test_tz_set_at_is_in_the_export_and_wiped_with_the_user(client):
    t = enrol(client)
    assert client.get("/v1/me", headers=auth(t)).json()["profile"]["tz_set_at"] is None
    assert client.put("/v1/me/timezone", json={"zone_id": "Europe/Athens"}, headers=auth(t)).status_code == 200
    prof = client.get("/v1/me", headers=auth(t)).json()["profile"]
    assert prof["zone_id"] == "Europe/Athens" and prof["tz_set_at"].endswith("Z")
    path = client.svc.s.db_path
    client.delete("/v1/me", headers=auth(t))
    assert sqlite3.connect(path).execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
    raw = b"".join(open(p, "rb").read() for p in (path, path + "-wal") if __import__("os").path.exists(p))
    assert b"Europe/Athens" not in raw


def test_an_existing_database_gets_the_column(tmp_path):
    path = str(tmp_path / "old.db")
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE users (id TEXT PRIMARY KEY, channel TEXT NOT NULL, chat_ref TEXT NOT NULL, chat_name TEXT, "
                "created_at TEXT NOT NULL, consent_version TEXT, consent_at TEXT, consent_msg_id TEXT, "
                "zone_id TEXT NOT NULL DEFAULT 'UTC', utc_offset_min INTEGER NOT NULL DEFAULT 0, quiet_start INTEGER, "
                "quiet_end INTEGER, paused INTEGER NOT NULL DEFAULT 0, last_run_utc TEXT, last_inbound_at TEXT, "
                "cap_zone TEXT, cap_week TEXT, UNIQUE (channel, chat_ref))")
    con.commit()
    con.close()
    db.init(path)
    db.init(path)  # idempotent
    cols = [r[1] for r in sqlite3.connect(path).execute("PRAGMA table_info(users)")]
    assert "tz_set_at" in cols


# --- recheck of #227 -------------------------------------------------------------------------------

def test_a_held_back_run_still_advances_last_run_utc(client):
    """R1: the tz_set_at guard holds back the zone only; evening and recap targeting read last_run_utc."""
    enrol(client)
    svc = client.svc
    uid = q(client, "SELECT id FROM users")[0]["id"]
    svc.ingest_run(uid, mk("a", T0 - timedelta(days=2), "Asia/Singapore", 480), T0)
    svc.set_timezone(uid, "Europe/Athens", now=T0)
    held = T0 - timedelta(hours=1)
    svc.ingest_run(uid, mk("b", held, "Asia/Singapore", 480), T0 + timedelta(minutes=5))
    row = q(client, "SELECT zone_id, last_run_utc FROM users")[0]
    assert row["zone_id"] == "Europe/Athens" and row["last_run_utc"] == iso(held)
    # and an older delivery never moves last_run_utc backwards
    svc.ingest_run(uid, mk("c", T0 - timedelta(days=1), "Asia/Singapore", 480), T0 + timedelta(minutes=6))
    assert q(client, "SELECT last_run_utc FROM users")[0]["last_run_utc"] == iso(held)


def test_held_back_run_user_is_still_planned_for_the_recap(client):
    enrol(client)
    svc = client.svc
    uid = q(client, "SELECT id FROM users")[0]["id"]
    sat = datetime(2026, 10, 10, 6, 0, tzinfo=timezone.utc)
    svc.ingest_run(uid, mk("a", sat - timedelta(days=3), "UTC", 0), sat)
    svc.set_timezone(uid, "Europe/Athens", now=sat)
    svc.ingest_run(uid, mk("b", sat - timedelta(hours=2), "UTC", 0), sat + timedelta(minutes=5))
    sunday = datetime(2026, 10, 11, 16, 30, tzinfo=timezone.utc)                  # Sunday 19:30 in Athens
    assert svc.plan_recap(sunday) == 1


def test_body_is_sent_once_when_both_follow_ups_would_fire():
    buttons = [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
    buttons += [{"label": "10k", "action": "ans:goal_type:10k", "row": 1}]
    long_card = OutCard("abc123", "Head", "BODY " * 300, buttons, Media(photo=PNG))
    assert TelegramChannel.followups(long_card) == ["caption"]          # one follow-up, not two
    short_card = OutCard("abc123", "Head", "BODY", buttons, Media(photo=PNG))
    assert TelegramChannel.followups(short_card) == ["question"]


def test_one_message_carries_the_text_and_every_button_including_the_question(tmp_path, fakes):
    buttons = [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
    buttons += [{"label": "10k", "action": "ans:goal_type:10k", "row": 1}]
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    card = OutCard("abc123", "Head", "BODY " * 300, buttons, Media(photo=PNG))
    ch.send_card(OWNER, card)
    for mode in TelegramChannel.followups(card):
        ch.send_followup(OWNER, card, mode)
    texts = [b["text"] for m, b in fakes.tg if m == "sendMessage"]
    assert len(texts) == 1 and texts[0].count("BODY") == 300
    assert [x["callback_data"] for r in texts and fakes.tg[-1][1]["reply_markup"]["inline_keyboard"] for x in r] == [
        "abc123:0", "abc123:1", "abc123:2", "abc123:3"]
    fakes.tg.clear()
    short = OutCard("abc123", "Head", "BODY", buttons, Media(photo=PNG))
    ch.send_followup(OWNER, short, "question")
    sent_text = fakes.tg[-1][1]
    assert "BODY" not in sent_text["text"] and sent_text["reply_markup"]["inline_keyboard"] == [
        [{"text": "10k", "callback_data": "abc123:3"}]]


@pytest.mark.parametrize("raw,want", [(None, 3), ("", 3), ("0", 0), ("9", 9), ("10", 3), ("-1", 3), ("x", 3), (" 4 ", 4), ("3.5", 3)])
def test_wa_url_index_is_clamped_to_the_valid_range(raw, want):
    from companion.config import Settings
    env = {"COMPANION_PEPPER": "p" * 20}
    if raw is not None:
        env["COMPANION_WA_URL_INDEX"] = raw
    assert Settings.from_env(env).wa_url_index == want


def test_a_stale_follow_up_is_dropped_not_sent_late(tmp_path, fakes):
    with media_client(tmp_path, fakes) as c:
        svc, uid, card_id = long_card_ready(c)
        svc.run_outbox(now_utc() + timedelta(seconds=1))                  # photo goes out, follow-up queued
        svc.run_outbox(now_utc() + timedelta(hours=7))                    # e.g. after a long kill-switch pause
        assert long_texts(fakes) == []
        assert q(c, "SELECT state FROM outbox WHERE kind='followup'")[0]["state"] == "skipped"


def test_a_fresh_follow_up_after_a_short_pause_still_goes(tmp_path, fakes):
    with media_client(tmp_path, fakes) as c:
        svc, uid, card_id = long_card_ready(c)
        svc.run_outbox(now_utc() + timedelta(seconds=1))
        svc.run_outbox(now_utc() + timedelta(hours=2))
        assert len(long_texts(fakes)) == 1
