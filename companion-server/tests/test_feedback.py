"""Tell Ricki: the button, /feedback, storage, expiry, consent, purge, delete, and that no model ever sees the text."""
import inspect
import json
import logging
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

import companion.media
import companion.render_client
import companion.writer
from companion import db, ops
from companion.channels import Inbound
from companion.service import (FEEDBACK_CANCELLED, FEEDBACK_DELETE_FIRST, FEEDBACK_EXPIRED, FEEDBACK_NO_CONSENT, FEEDBACK_PAUSED,
                               FEEDBACK_PROMPT, FEEDBACK_SAVED, FEEDBACK_TOO_LONG, NOTE_PROMPT, NOTE_SAVED, UNKNOWN)
from companion.timeutil import iso, now_utc
from conftest import OWNER, auth, enrol, post_tg, tg_callback, tg_update
from test_notes import SENTINEL, _week, last_text, notes_rows, q, send_run, tap_note

_n = iter(range(70_000, 10**6))


def say(client, text, ref=OWNER):
    assert post_tg(client, tg_update(next(_n), text, ref)).status_code == 200


def agree(client, token, version=2):
    assert client.put("/v1/me/consent", json={"consent_version": version}, headers=auth(token)).status_code == 200


def fb_rows(client):
    return q(client, "SELECT user_id, ts, text FROM feedback ORDER BY id")


def mode_rows(client):
    return q(client, "SELECT * FROM feedback_mode")


@pytest.fixture
def tok(client):
    t = enrol(client)
    agree(client, t)
    return t


def tap_tell(client, card_id, ref=OWNER):
    row = q(client, "SELECT buttons_json FROM cards WHERE card_id=?", card_id)[0]
    i = [b["action"] for b in json.loads(row["buttons_json"])].index("fb:tell")
    assert post_tg(client, tg_callback(next(_n), f"{card_id}:{i}", ref)).status_code == 200


def sunday_card(client, fakes):
    uid = _week(client)
    sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
    assert client.svc.plan_recap(sunday) == 1
    client.svc.run_outbox(sunday + timedelta(seconds=1))
    return q(client, "SELECT card_id FROM cards WHERE kind='recap'")[0]["card_id"], uid


# --- the entry points -------------------------------------------------------------------------------------------

def test_the_sunday_card_carries_a_tell_ricki_button_that_starts_feedback_mode(client, fakes, tok):
    card_id, _ = sunday_card(client, fakes)
    sent = [b for m, b in fakes.tg if m == "sendMessage"][-1]
    labels = [b["text"] for row in sent["reply_markup"]["inline_keyboard"] for b in row]
    assert "Tell Ricki" in labels
    tap_tell(client, card_id)
    assert last_text(fakes) == FEEDBACK_PROMPT and len(mode_rows(client)) == 1
    say(client, f"{SENTINEL} the pace on Tuesday felt wrong")
    assert last_text(fakes) == FEEDBACK_SAVED and not mode_rows(client)
    assert [r["text"] for r in fb_rows(client)] == [f"{SENTINEL} the pace on Tuesday felt wrong"]


def test_the_feedback_command_starts_feedback_mode_with_and_without_the_slash(client, fakes, tok):
    for cmd in ("/feedback", "feedback", "/FEEDBACK"):
        say(client, cmd)
        assert last_text(fakes) == FEEDBACK_PROMPT and len(mode_rows(client)) == 1
        say(client, f"via {cmd}")
        assert last_text(fakes) == FEEDBACK_SAVED
    assert [r["text"] for r in fb_rows(client)] == ["via /feedback", "via feedback", "via /FEEDBACK"]


def test_a_stranger_sending_feedback_gets_the_canned_reply_and_nothing_is_stored(client, fakes):
    say(client, "/feedback", ref="999000111")
    assert last_text(fakes) == UNKNOWN
    say(client, "hello there", ref="999000111")
    assert not fb_rows(client) and not mode_rows(client)


# --- one message, fixed reply ---------------------------------------------------------------------------------------

def test_one_message_ends_feedback_mode_and_the_reply_is_one_fixed_line(client, fakes, tok):
    say(client, "/feedback")
    say(client, "first thing")
    assert last_text(fakes) == FEEDBACK_SAVED == "Got it. Ricki will read this."
    say(client, "second thing")                          # the mode is over: today's reply
    assert last_text(fakes) == UNKNOWN and len(fb_rows(client)) == 1


def test_feedback_mode_expires_after_thirty_minutes(client, fakes, tok):
    say(client, "/feedback")
    exp = datetime.fromisoformat(mode_rows(client)[0]["expires_at"].replace("Z", "+00:00"))
    assert timedelta(minutes=29) < exp - datetime.now(timezone.utc) <= timedelta(minutes=30)
    client.svc.handle_inbound(Inbound("telegram", OWNER, "late", text="too late"), now=now_utc() + timedelta(minutes=31))
    assert last_text(fakes) == FEEDBACK_EXPIRED and not fb_rows(client) and not mode_rows(client)
    say(client, "/feedback")                             # and just inside the window it still counts
    client.svc.handle_inbound(Inbound("telegram", OWNER, "ontime", text="made it"), now=now_utc() + timedelta(minutes=29))
    assert [r["text"] for r in fb_rows(client)] == ["made it"]


def test_a_too_long_message_is_not_stored_and_the_runner_can_retry(client, fakes, tok):
    say(client, "/feedback")
    say(client, "x" * 1001)
    assert last_text(fakes) == FEEDBACK_TOO_LONG and not fb_rows(client) and len(mode_rows(client)) == 1
    say(client, "y" * 1000)
    assert last_text(fakes) == FEEDBACK_SAVED and len(fb_rows(client)[0]["text"]) == 1000


def test_feedback_text_is_cleaned_to_one_printable_line(client, fakes, tok):
    say(client, "/feedback")
    say(client, "line one\n\n  line\x00 two\t!")
    assert fb_rows(client)[0]["text"] == "line one line two !"


# --- keywords -------------------------------------------------------------------------------------------------

def test_bare_keywords_do_not_become_feedback_or_erase_on_one_word(client, fakes, tok):
    say(client, "/feedback")
    say(client, "DELETE")                                # must not erase the account on one word
    assert last_text(fakes) == FEEDBACK_DELETE_FIRST and not mode_rows(client) and q(client, "SELECT id FROM users")
    say(client, "/feedback")
    say(client, "cancel")
    assert last_text(fakes) == FEEDBACK_CANCELLED and not mode_rows(client) and not fb_rows(client)
    say(client, "/feedback")
    say(client, "STOP")                                  # opt-out always works and closes the mode
    assert q(client, "SELECT paused FROM users")[0]["paused"] == 1 and not mode_rows(client) and not fb_rows(client)


def test_delete_outside_feedback_mode_erases_everything_including_feedback(client, fakes, tok):
    say(client, "/feedback")
    say(client, "something for Ricki")
    assert len(fb_rows(client)) == 1
    say(client, "DELETE")
    assert not q(client, "SELECT id FROM users") and not fb_rows(client) and not mode_rows(client)


def test_delete_from_the_app_also_wipes_feedback(client, fakes, tok):
    say(client, "/feedback")
    say(client, "bye")
    say(client, "/feedback")                             # and a waiting mode row
    assert client.delete("/v1/me", headers=auth(tok)).json() == {"status": "deleted"}
    assert not fb_rows(client) and not mode_rows(client)


def test_a_paused_runner_cannot_start_or_finish_feedback(client, fakes, tok):
    say(client, "/feedback")
    say(client, "STOP")
    say(client, "/feedback")
    assert last_text(fakes) == FEEDBACK_PAUSED and not mode_rows(client)
    say(client, "RESUME")
    say(client, "/feedback")
    assert last_text(fakes) == FEEDBACK_PROMPT
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("UPDATE users SET paused=1")
    c.commit()
    say(client, "text while paused")
    assert last_text(fakes) == FEEDBACK_PAUSED and not fb_rows(client)


def test_resume_closes_a_stale_feedback_mode(client, fakes, tok):
    say(client, "/feedback")
    say(client, "STOP")
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("INSERT INTO feedback_mode VALUES ((SELECT id FROM users), ?)", (iso(now_utc() + timedelta(minutes=5)),))
    c.commit()
    say(client, "RESUME")
    assert not mode_rows(client)


# --- consent v2 -----------------------------------------------------------------------------------------------

def test_without_consent_v2_nothing_is_stored(client, fakes):
    t = enrol(client)                                    # the app has not reported consent
    say(client, "/feedback")
    assert last_text(fakes) == FEEDBACK_NO_CONSENT and not mode_rows(client)
    agree(client, t, 1)                                  # the old consent text is not enough
    say(client, "/feedback")
    assert last_text(fakes) == FEEDBACK_NO_CONSENT and not mode_rows(client)
    agree(client, t, 2)
    say(client, "/feedback")
    assert last_text(fakes) == FEEDBACK_PROMPT


def test_consent_withdrawn_between_the_prompt_and_the_text_stores_nothing(client, fakes, tok):
    say(client, "/feedback")
    agree(client, tok, 1)                                # the runner now reports an older version
    say(client, "too late for this")
    assert last_text(fakes) == FEEDBACK_NO_CONSENT and not fb_rows(client) and not mode_rows(client)


def test_the_tell_ricki_button_needs_consent_too(client, fakes):
    enrol(client)
    card_id, _ = sunday_card(client, fakes)
    tap_tell(client, card_id)
    assert last_text(fakes) == FEEDBACK_NO_CONSENT and not mode_rows(client)


# --- rate limit -----------------------------------------------------------------------------------------------

def test_the_per_chat_limiter_sits_in_front_of_feedback(tmp_path, fakes):
    import httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from conftest import make_settings
    s = make_settings(tmp_path, rate_per_min=3)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        t = enrol(c)
        agree(c, t)
        base = now_utc()
        c.svc.handle_inbound(Inbound("telegram", OWNER, "m0", text="/feedback"), now=base)
        assert len(mode_rows(c)) == 1
        for _ in range(2):                                           # the chat uses up the rest of its minute
            c.svc.limiter.check(f"telegram:{OWNER}", base)
        c.svc.handle_inbound(Inbound("telegram", OWNER, "m3", text="over the limit"), now=base)
        assert not fb_rows(c) and len(mode_rows(c)) == 1             # limited: nothing stored, mode still waiting
        c.svc.handle_inbound(Inbound("telegram", OWNER, "m4", text="after the minute"), now=base + timedelta(minutes=2))
        assert [r["text"] for r in fb_rows(c)] == ["after the minute"]


# --- modes do not overlap -----------------------------------------------------------------------------------------

def test_the_last_tap_wins_between_add_a_note_and_tell_ricki(client, fakes, tok):
    send_run(client, tok)
    tap_note(client)
    assert last_text(fakes) == NOTE_PROMPT
    say(client, "/feedback")
    assert q(client, "SELECT * FROM note_mode") == [] and len(mode_rows(client)) == 1
    say(client, "this is feedback")
    assert [r["text"] for r in fb_rows(client)] == ["this is feedback"] and not notes_rows(client)
    tap_note(client)
    say(client, "/feedback")
    tap_note(client)                                     # note tapped last: the text is a note
    assert not mode_rows(client)
    say(client, "this is a note")
    assert last_text(fakes) == NOTE_SAVED and notes_rows(client) == {"r1": "this is a note"} and len(fb_rows(client)) == 1


# --- retention and backup -------------------------------------------------------------------------------------------

def test_feedback_is_purged_after_thirty_days_and_not_before(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = now_utc()
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("INSERT INTO feedback (user_id, ts, text) VALUES (?,?,?)", (uid, iso(now - timedelta(days=31)), "old"))
    c.execute("INSERT INTO feedback (user_id, ts, text) VALUES (?,?,?)", (uid, iso(now - timedelta(days=29)), "young"))
    c.execute("INSERT INTO feedback_mode VALUES (?,?)", (uid, iso(now - timedelta(hours=3))))
    c.commit()
    client.svc.purge(now)
    assert [r["text"] for r in fb_rows(client)] == ["young"] and not mode_rows(client)
    client.svc.purge(now + timedelta(days=2))
    assert not fb_rows(client)


def test_the_nightly_backup_leaves_feedback_out(client, fakes, tok, tmp_path):
    from companion.backup import backup, restore
    say(client, "/feedback")
    say(client, "keep me off the backup")
    say(client, "/feedback")
    path = client.svc.s.db_path
    key = tmp_path / "k.key"
    key.write_bytes(b"k" * 32)
    out = str(tmp_path / "restored.db")
    restore(backup(path, str(tmp_path / "bk"), str(key)), out, str(key))
    r = sqlite3.connect(out)
    for t in ("feedback", "feedback_mode"):
        assert r.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] == 0, t
    assert r.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
    assert len(fb_rows(client)) == 1                                # the live database is untouched


def test_feedback_is_in_the_runners_own_export(client, fakes, tok):
    say(client, "/feedback")
    say(client, "for the export")
    me = client.get("/v1/me", headers=auth(tok)).json()
    assert [x["text"] for x in me["feedback"]] == ["for the export"]


# --- never a model, never a log ----------------------------------------------------------------------------------------

def test_feedback_text_is_never_sent_to_a_model(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    for i, days in enumerate((9, 7, 5, 3)):
        send_run(client, tok, f"h{i}", minutes_ago=days * 1440, type="tempo" if i == 0 else "easy")
    say(client, "/feedback")
    say(client, f"{SENTINEL} the coach got my zones wrong and my calf is sore")
    assert fb_rows(client)
    send_run(client, tok, "after", minutes_ago=10)
    client.svc.run_outbox(now_utc() + timedelta(minutes=40))
    client.svc._build_evening_card(uid, "2099-02-01", now_utc())
    client.svc._build_recap_card(uid, "2099-W01", now_utc())
    assert fakes.llm, "the writer should have been called, or this test proves nothing"
    blob = json.dumps(fakes.llm)
    assert SENTINEL not in blob and "zones wrong" not in blob
    # and the reply to the feedback itself made no model call
    say(client, "/feedback")
    before = len(fakes.llm)
    say(client, "another one, straight to Ricki")
    assert len(fakes.llm) == before


def test_feedback_text_never_appears_in_logs_or_telegram_messages(client, fakes, tok, caplog):
    caplog.set_level(logging.DEBUG)
    say(client, "/feedback")
    say(client, f"{SENTINEL} private words")
    say(client, "DELETE")
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert text and SENTINEL not in text
    assert not any(SENTINEL in t for t in fakes.tg_texts())


def test_nothing_that_talks_to_a_model_or_a_renderer_reads_the_feedback_tables():
    for mod in (companion.writer, companion.media, companion.render_client):
        src = inspect.getsource(mod)
        assert "FROM feedback" not in src and "feedback_mode" not in src, mod.__name__


# --- ops CLI --------------------------------------------------------------------------------------------------------

def test_ops_feedback_lists_recent_feedback_by_tester_number_newest_first(client, fakes, tok):
    s = client.svc.s
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = now_utc()
    c = sqlite3.connect(s.db_path)
    for days, text in ((20, "three weeks ago"), (3, "older one"), (0.1, "newest one")):
        c.execute("INSERT INTO feedback (user_id, ts, text) VALUES (?,?,?)", (uid, iso(now - timedelta(days=days)), text))
    c.commit()
    out: list[str] = []
    assert ops.main(s, ["feedback"], out.append) == 0
    assert [ln.split(" ", 2)[0] for ln in out] == ["T1", "T1"]
    assert [ln.split(" ", 2)[2] for ln in out] == ["newest one", "older one"]       # the 7-day default, newest first
    out.clear()
    assert ops.main(s, ["feedback", "30"], out.append) == 0 and len(out) == 3
    out.clear()
    assert ops.main(s, ["feedback", "0"], out.append) == 2 and "usage" in out[-1]
    assert ops.main(s, ["feedback", "abc"], out.append) == 2
    assert OWNER not in "\n".join(out)                                               # T-numbers only, never a chat id
    c.execute("DELETE FROM feedback")
    c.commit()
    out.clear()
    assert ops.main(s, ["feedback"], out.append) == 0 and out == ["no feedback in the last 7 days"]
