"""Coach for strangers: in-app consent to the coach (v3), the open chat mode, and one coherent set of caps.
OpenRouter and Telegram are the fakes in conftest; every test pins its clock. Run with test_enrol_auth in one process.
"""
from __future__ import annotations

import dataclasses
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import db
from companion.app import create_app
from companion.coach import chat as coach_chat

from conftest import OWNER, auth, coach_text, enrol, make_settings
from test_coach_chat import OTHER, rows, run_worker, say, uid_of

T0 = datetime(2026, 10, 21, 1, 0, tzinfo=timezone.utc)   # a Wednesday, 2 pm in Auckland


def open_settings(tmp_path, **over):
    base = dict(coach_chat=True, coach_open=True, coach_allowlist=frozenset(), allowed_ids=frozenset({f"telegram:{OWNER}", f"telegram:{OTHER}"}),
                coach_merge_s=5.0, default_quiet=(0, 0))
    base.update(over)
    return make_settings(tmp_path, **base)


def client(tmp_path, fakes, **over):
    app = create_app(open_settings(tmp_path, **over), httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    return TestClient(app), app


def consent(c, v, **kw):
    r = c.put("/v1/me/consent", json={"consent_version": v, **kw}, headers=auth(c.token))
    assert r.status_code == 200, r.text
    return r


def start(c, app, ref=OWNER):
    c.svc = app.state.svc
    c.token = enrol(c, ref)
    assert c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(c.token)).status_code == 200
    return c


def sent(fakes):
    return fakes.tg_texts()


# ------------------------------------------------------------------------------------------------- consent in the app
def test_a_fresh_runner_goes_v2_then_in_app_consent_then_chat_works(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 2)                                               # what the app records on Turn on
        assert rows(c, "SELECT checkin_consent, coach_consent_at FROM users")[0] == {"checkin_consent": 2, "coach_consent_at": None}
        say(c, "how was my run?")                                    # not consented to the coach yet: the canned reply
        assert sent(fakes)[-1].startswith("I only send run recaps") and fakes.coach_calls == []
        consent(c, 3)                                                # the coach consent sheet, Agree
        row = rows(c, "SELECT checkin_consent, coach_consent_at FROM users")[0]
        assert row["checkin_consent"] == 3 and row["coach_consent_at"] is not None     # recorded with a timestamp
        fakes.coach_queue = [coach_text("Good to hear from you.")]
        say(c, "how was my run?", now=T0)
        run_worker(c)
        assert sent(fakes)[-1] == "Good to hear from you."
        # the v4 memory sheet follows exactly as before: only now is it accepted
        assert consent(c, 4).json() == {"status": "ok"}
        assert rows(c, "SELECT checkin_consent FROM users")[0]["checkin_consent"] == 4
        prof = c.get("/v1/me", headers=auth(c.token)).json()["profile"]
        assert prof["coach_consent_at"] is not None


def test_the_coach_consent_timestamp_uses_the_given_clock(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        uid = uid_of(c)
        c.svc.set_checkin_consent(uid, 2, now=T0)
        c.svc.set_checkin_consent(uid, 3, now=T0 + timedelta(hours=1))
        assert rows(c, "SELECT coach_consent_at FROM users")[0]["coach_consent_at"] == "2026-10-21T02:00:00Z"
        c.svc.set_checkin_consent(uid, 3, now=T0 + timedelta(hours=5))                       # a repeat does not move it
        assert rows(c, "SELECT coach_consent_at FROM users")[0]["coach_consent_at"] == "2026-10-21T02:00:00Z"


def test_a_v4_grant_is_still_ignored_before_the_coach_consent(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 2)
        assert consent(c, 4).json() == {"status": "ignored"}
        assert rows(c, "SELECT checkin_consent FROM users")[0]["checkin_consent"] == 2


def test_turning_the_coach_off_in_the_app_deletes_chats_and_memory_and_keeps_checkins(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 3)
        consent(c, 4, health_notes=True)
        uid = uid_of(c)
        with db.tx(c.svc.s.db_path) as con:
            con.execute("INSERT INTO coach_memory (user_id, kind, topic, text, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                        (uid, "fact", "schedule", "I run Tuesdays", "2026-10-21T00:00:00Z", "2026-10-21T00:00:00Z"))
            con.execute("INSERT INTO coach_messages (user_id, role, text, ts) VALUES (?,?,?,?)", (uid, "runner", "hello", "2026-10-21T00:00:00Z"))
        consent(c, 2, coach_chat=False)
        assert rows(c, "SELECT checkin_consent, coach_consent_at, memory_health_optin h FROM users")[0] == \
            {"checkin_consent": 2, "coach_consent_at": None, "h": 0}
        assert rows(c, "SELECT * FROM coach_memory") == [] and rows(c, "SELECT * FROM coach_messages") == []
        say(c, "are you there?")
        assert sent(fakes)[-1].startswith("I only send run recaps") and fakes.coach_calls == []
        # and turning it on again is the same sheet
        consent(c, 3)
        assert rows(c, "SELECT checkin_consent FROM users")[0]["checkin_consent"] == 3


def test_turning_the_coach_off_never_raises_consent(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 2)
        consent(c, 2, coach_chat=False)
        assert rows(c, "SELECT checkin_consent FROM users")[0]["checkin_consent"] == 2


# ------------------------------------------------------------------------------------------------- open mode
def test_open_mode_lets_a_consented_runner_chat_with_no_allowlist_entry(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 3)
        fakes.coach_queue = [coach_text("Hello.")]
        say(c, "hi coach")
        run_worker(c)
        assert sent(fakes)[-1] == "Hello."


def test_open_mode_still_needs_the_coach_consent(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 2)
        say(c, "hi coach")
        assert fakes.coach_calls == [] and sent(fakes)[-1].startswith("I only send run recaps")


def test_with_open_mode_off_nothing_changes_a_consented_stranger_gets_no_chat(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_open=False, coach_allowlist=frozenset({"T99"}))
    with tc as c:
        start(c, app)
        consent(c, 3)
        with db.ro(c.svc.s.db_path) as con:
            assert c.svc.coach.gate(con, uid_of(c)) == "allowlist"
        say(c, "hi coach")
        assert fakes.coach_calls == [] and sent(fakes)[-1].startswith("I only send run recaps")


def test_with_open_mode_off_and_an_empty_allowlist_the_coach_is_off(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_open=False, coach_allowlist=frozenset())
    with tc as c:
        assert not app.state.svc.coach.enabled


def test_open_mode_leaves_memory_and_proactive_on_their_own_gates(tmp_path, fakes):
    from companion.coach.ext import memory
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = uid_of(c)
        with db.ro(c.svc.s.db_path) as con:
            assert memory.gate(c.svc, con, uid) == "memory_consent"                      # consent 4 or the override, not open mode
            u = con.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            assert not c.svc.coach.allowlisted(u, c.svc.s.coach_proactive_allowlist)    # proactive keeps its own list (empty)
        consent(c, 4)
        with db.ro(c.svc.s.db_path) as con:
            assert memory.gate(c.svc, con, uid) is None


# ------------------------------------------------------------------------------------------------- caps
def test_defaults_are_one_coherent_set():
    from companion.config import Settings
    s = Settings.from_env({"COMPANION_PEPPER": "p" * 20})
    assert (s.coach_monthly_cap_usd, s.user_monthly_cap_usd, s.coach_daily_msgs, s.max_users) == (30.0, 3.0, 30, 25)
    assert s.monthly_cap_usd <= s.coach_monthly_cap_usd and s.coach_open is False
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20, "COMPANION_COACH_OPEN": "1"}).coach_open is True


def alerts(c, like):
    return rows(c, "SELECT key, title, body FROM alerts WHERE key LIKE ?", like)


def test_the_daily_message_limit_gives_a_friendly_reply_and_one_alert(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_daily_msgs=2)
    with tc as c:
        start(c, app)
        consent(c, 3)
        for i in range(2):
            fakes.coach_queue = [coach_text(f"answer {i}")]
            say(c, f"question {i}", now=T0 + timedelta(minutes=i))
            run_worker(c, now=T0 + timedelta(minutes=i, seconds=10))
        say(c, "one more", now=T0 + timedelta(minutes=5))
        run_worker(c, now=T0 + timedelta(minutes=5, seconds=10))
        assert sent(fakes)[-1] == coach_chat.DAILY_CAP and "tomorrow" in coach_chat.DAILY_CAP
        say(c, "and another", now=T0 + timedelta(minutes=6))
        run_worker(c, now=T0 + timedelta(minutes=6, seconds=10))
        a = alerts(c, "capfire:daily:%")
        assert len(a) == 1 and "daily message limit" in a[0]["title"] and "question" not in a[0]["body"]


def test_the_per_runner_monthly_cap_stops_that_runner_with_a_friendly_reply_and_one_alert(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, user_monthly_cap_usd=0.01)
    with tc as c:
        start(c, app)
        consent(c, 3)
        say(c, "hello", now=T0)
        run_worker(c)
        assert sent(fakes)[-1] == coach_chat.USER_MONTH and "1st" in coach_chat.USER_MONTH
        assert fakes.coach_calls == []
        say(c, "hello again", now=T0 + timedelta(minutes=3))
        run_worker(c, now=T0 + timedelta(minutes=3, seconds=10))
        a = alerts(c, "capfire:user:%")
        assert len(a) == 1 and "per-runner monthly cap" in a[0]["title"]


def test_one_runner_over_their_cap_does_not_stop_another(tmp_path, fakes):
    tc, app = client(tmp_path, fakes)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = uid_of(c)
        with db.tx(c.svc.s.db_path) as con:                       # this runner already spent their US$3 this month
            con.execute("INSERT INTO cost_ledger (ts, user_id, model, purpose, state, cost_usd) VALUES (?,?,?,?,?,?)",
                        ("2026-10-10T00:00:00Z", uid, "m", "chat", "settled", 3.0))
        say(c, "hello", now=T0)
        run_worker(c)
        assert sent(fakes)[-1] == coach_chat.USER_MONTH
        # a second runner, who has spent nothing, is not affected
        tok = enrol(c, OTHER)
        assert c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(tok)).status_code == 200
        fakes.coach_queue = [coach_text("Hi there.")]
        say(c, "hello", ref=OTHER, now=T0 + timedelta(minutes=2))
        run_worker(c, now=T0 + timedelta(minutes=2, seconds=10))
        assert sent(fakes)[-1] == "Hi there."


def test_the_whole_month_cap_stops_everyone_with_a_friendly_reply_and_one_alert(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_monthly_cap_usd=1.0, coach_card_reserve_usd=0.0)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = uid_of(c)
        with db.tx(c.svc.s.db_path) as con:
            con.execute("INSERT INTO cost_ledger (ts, user_id, model, purpose, state, cost_usd) VALUES (?,?,?,?,?,?)",
                        ("2026-10-10T00:00:00Z", "someone-else", "m", "chat", "settled", 1.0))
        say(c, "hello", now=T0)
        run_worker(c)
        assert sent(fakes)[-1] == coach_chat.BUDGET and "monthly limit" in coach_chat.BUDGET
        say(c, "hello again", now=T0 + timedelta(minutes=3))
        run_worker(c, now=T0 + timedelta(minutes=3, seconds=10))
        a = alerts(c, "capfire:month:%")
        assert len(a) == 1 and "monthly cap" in a[0]["title"]
        assert uid  # the alert body never names a message


def test_a_full_test_turns_a_stranger_away_with_a_friendly_reply_and_one_alert_a_day(tmp_path, fakes):
    from conftest import chat_code, confirm, post_tg, start as enrol_start, status, tg_update
    s = open_settings(tmp_path, open_enrolment=True, max_users=1, allowed_ids=frozenset())
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        enrol(c, OWNER)
        st = enrol_start(c)
        post_tg(c, tg_update(777_001, f"/start {st['nonce']}", OTHER))
        assert "test is full" in fakes.tg_texts()[-1]
        assert len(alerts(c, "testfull:%")) == 1
        st2 = enrol_start(c)
        post_tg(c, tg_update(777_002, f"/start {st2['nonce']}", "999000111"))
        assert len(alerts(c, "testfull:%")) == 1             # one alert a day


def test_the_privacy_page_says_what_the_coach_consent_sheet_says():
    """The app's sheet (kCompanionCoachBody in lib/screens/companion_screen.dart) and the privacy page use the same sentences."""
    import os
    import re
    html = open(os.path.join(os.path.dirname(__file__), "..", "..", "docs", "privacy", "index.html")).read()
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html))
    for sentence in (
        "To reply, the coach reads your run summaries and your check-in answers, and what you type goes to an AI provider "
        "(OpenRouter and Anthropic, in the US) with zero data retention.",
        "Your GPS tracks and heart rate recordings stay on your phone.",
        "Chats are kept for 30 days",
        "You can turn the coach off any time in Settings, Companion, and that deletes your chats",
    ):
        assert sentence in text, sentence
