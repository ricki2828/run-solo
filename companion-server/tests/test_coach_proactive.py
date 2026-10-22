"""Proactive coach (PR5): the three triggers, the one-a-day cap, quiet hours, the gates, the triage windows and the OFF flag.
The model and Telegram are the fakes in conftest and the forecast is a stub: no network. Every test pins its clock.
"""
from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import db
from companion.app import create_app
from companion.coach.ext import ToolContext, triage as coach_triage

from conftest import OWNER, auth, coach_text, enrol, make_settings

OTHER = "444555666"
T0 = datetime(2026, 10, 21, 6, 30, tzinfo=timezone.utc)   # Wednesday 19:30 in Auckland
H = timedelta(hours=1)


class Wx:
    def __init__(self, temp=31, dew=22):
        self.td, self.calls = (temp, dew), 0

    def heat_at(self, *_a, **_k):
        self.calls += 1
        return self.td


def settings(tmp_path, **over):
    ids = frozenset({f"telegram:{OWNER}", f"telegram:{OTHER}"})
    base = dict(coach_chat=True, coach_proactive=True, coach_allowlist=ids, coach_proactive_allowlist=ids, allowed_ids=ids)
    base.update(over)
    return make_settings(tmp_path, **base)


def build(tmp_path, fakes, **over):
    app = create_app(settings(tmp_path, **over), httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    return app


@pytest.fixture
def cc(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes)) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        assert c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token)).status_code == 200
        assert c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(c.token)).status_code == 200
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")   # enrolment ran on the real clock
        c.wx = c.svc.coach.proactive.weather = Wx()
        fakes.tg.clear()   # enrolment's own messages
        yield c


def rows(c, q, *a):
    con = sqlite3.connect(c.svc.s.db_path)
    con.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in con.execute(q, a)]
    finally:
        con.close()


def sql(c, q, *a):
    with db.tx(c.svc.s.db_path) as con:
        con.execute(q, a)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def chat_job(c, hours_ago, *, niggle=None, triage=None, now=T0, state="sent", mac=None):
    t = iso(now - hours_ago * H)
    sql(c, "INSERT INTO coach_jobs (user_id, msg_mac, kind, state, niggle, triage, created_at, replied_at, sent_at) "
           "VALUES (?,?,?,?,?,?,?,?,?)", c.uid, mac or f"m{hours_ago}{niggle}{triage}", "chat", state, niggle, triage, t, t, t)


def race(c, hours_ago, now=T0):
    end = now - hours_ago * H
    sql(c, "INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, received_at) "
           "VALUES (?,?,?,?,?,?,?,?,?,?)", c.uid, "race1", iso(end - H), iso(end), 780, "Pacific/Auckland", "race", 3600, 10000, iso(end))


def quality_tomorrow(c, hot=True, now=T0):
    sql(c, "UPDATE users SET weather_optin=1 WHERE id=?", c.uid)
    sql(c, "INSERT INTO convo_area (user_id, run_id, lat, lon) VALUES (?,?,?,?)", c.uid, "a1", -36.8, 174.8)
    sql(c, "INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, received_at, "
           "plan_next_type, plan_next_day, plan_next_session_name) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        c.uid, "r0", iso(now - 20 * H), iso(now - 19 * H), 780, "Pacific/Auckland", "easy", 2400, 7000, iso(now - 19 * H),
        "quality", "2026-10-22", "Tempo")
    c.wx.td = (31, 22) if hot else (18, 8)


def tick(c, now=T0):
    return c.svc.coach.proactive.tick(now)


def jobs(c):
    return rows(c, "SELECT kind, state, outcome, msg_mac FROM coach_jobs WHERE kind='proactive' ORDER BY id")


def sent_texts(fakes):
    return fakes.tg_texts()


# ------------------------------------------------------------------------------------------------- the triggers
def test_niggle_check_back_48h_after_a_green_triage(cc, fakes):
    chat_job(cc, 49, niggle="green")
    fakes.coach_queue = [coach_text("How's the knee today?\n<chips>Better|Same|Worse</chips>")]
    assert tick(cc) == 1
    assert sent_texts(fakes)[-1] == "How's the knee today?"
    j = jobs(cc)
    assert [(x["state"], x["msg_mac"].startswith("proactive:niggle:")) for x in j] == [("sent", True)]
    turn = fakes.coach_calls[0]["messages"][-1]["content"]
    assert "<host_note>PROACTIVE" in turn   # the server's own note is not defanged
    assert "pace" in turn and "No training" in turn
    markup = [b for m, b in fakes.tg if m == "sendMessage"][-1]["reply_markup"]
    assert len(markup["inline_keyboard"][0]) == 3   # chips are buttons
    assert [m["role"] for m in rows(cc, "SELECT role FROM coach_messages ORDER BY id")] == ["coach"]


def test_niggle_after_an_amber_text_triage_and_only_inside_the_window(cc, fakes):
    chat_job(cc, 47, triage="amber")
    assert tick(cc) == 0 and fakes.coach_calls == []            # not due yet
    cc.svc.coach.proactive.tick(T0 + 2 * H)                      # 49 h
    assert len(jobs(cc)) == 1
    fakes.tg.clear()
    sql(cc, "DELETE FROM coach_jobs")
    chat_job(cc, 100, niggle="green")
    assert tick(cc) == 0                                         # stale: past 96 h


def test_race_debrief_two_hours_after_the_finish(cc, fakes):
    race(cc, 5)
    fakes.coach_queue = [coach_text("What a result on Wednesday. How did it feel out there?")]
    assert tick(cc) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:race:{cc.uid}:race1"
    assert "10 km in 1:00:00" in fakes.coach_calls[0]["messages"][-1]["content"]
    assert tick(cc, T0 + 40 * H) == 0   # the same race is 45 h old by now (and already debriefed)


def test_race_too_fresh_gets_nothing(cc, fakes):
    race(cc, 1)
    assert tick(cc) == 0 and fakes.coach_calls == []


def test_heat_heads_up_the_evening_before_a_quality_session(cc, fakes):
    quality_tomorrow(cc)
    fakes.coach_queue = [coach_text("Tomorrow's tempo will be hot. Run it by effort, or go earlier.")]
    assert tick(cc) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:heat:{cc.uid}:2026-10-22"
    turn = fakes.coach_calls[0]["messages"][-1]["content"]
    assert "31 C" in turn and "Tempo" in turn


def test_a_mild_forecast_sends_no_heat_nudge(cc, fakes):
    quality_tomorrow(cc, hot=False)
    assert tick(cc) == 0 and cc.wx.calls == 1 and fakes.coach_calls == []


def test_heat_waits_for_the_evening(cc, fakes):
    quality_tomorrow(cc)
    assert tick(cc, T0 - 5 * H) == 0   # 14:30 local
    assert fakes.coach_calls == []


# ------------------------------------------------------------------------------------------------- the rules
def test_one_a_day_per_runner_then_the_next_local_day(cc, fakes):
    chat_job(cc, 49, niggle="green")
    race(cc, 5)
    fakes.coach_queue = [coach_text("How's the knee today?"), coach_text("How did the race feel?")]
    assert tick(cc) == 1 and tick(cc, T0 + timedelta(minutes=10)) == 0
    assert len(fakes.coach_calls) == 1 and len(jobs(cc)) == 1
    assert tick(cc, T0 + 24 * H) == 1     # next local day: the race (29 h old) is still in its window
    assert [j["msg_mac"].split(":")[1] for j in jobs(cc)] == ["niggle", "race"]


def test_quiet_hours_hold_everything(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes, default_quiet=(21 * 60 + 30, 7 * 60))) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token))
        c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(c.token))
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")
        chat_job(c, 49, niggle="green")
        assert tick(c, T0 + 3 * H) == 0          # 22:30 local, quiet
        assert tick(c, T0 + 9 * H) == 0          # 04:30 local, quiet
        assert fakes.coach_calls == [] and jobs(c) == []
        fakes.coach_queue = [coach_text("How's the knee today?")]
        assert tick(c, T0 + 13 * H) == 1         # 08:30 local, open


def test_a_paused_runner_never_gets_one(cc, fakes):
    chat_job(cc, 49, niggle="green")
    sql(cc, "UPDATE users SET paused=1")
    assert tick(cc) == 0
    sql(cc, "UPDATE users SET paused=0, ops_paused=1")
    assert tick(cc) == 0
    assert fakes.coach_calls == [] and jobs(cc) == []


def test_a_withdrawn_consent_gets_none(cc, fakes):
    chat_job(cc, 49, niggle="green")
    assert cc.put("/v1/me/consent", json={"consent_version": 0}, headers=auth(cc.token)).status_code == 200
    assert tick(cc) == 0 and fakes.coach_calls == []


def test_an_amber_window_blocks_the_heat_nudge_but_not_the_check_back(cc, fakes):
    quality_tomorrow(cc)
    chat_job(cc, 30, triage="amber")
    assert tick(cc) == 0 and fakes.coach_calls == []
    assert cc.wx.calls == 0                    # decided before any forecast was fetched


def test_a_red_triage_blocks_every_trigger_for_72_hours(cc, fakes):
    chat_job(cc, 49, niggle="green", mac="a")
    race(cc, 5)
    quality_tomorrow(cc)
    chat_job(cc, 20, triage="red", mac="b")
    assert tick(cc) == 0 and fakes.coach_calls == []


def test_the_redflag_rail_flags_block_proactive_messages(cc, fakes):
    race(cc, 5)
    sql(cc, "INSERT INTO health_flags (user_id, kind, state, source, set_at) VALUES (?,?,?,?,?)", cc.uid, "wellbeing", "active", "rail", iso(T0))
    assert tick(cc) == 0 and fakes.coach_calls == []


def test_an_open_chat_or_a_recent_message_keeps_it_quiet(cc, fakes):
    race(cc, 5)
    sql(cc, "UPDATE users SET last_inbound_at=?", iso(T0 - H))
    assert tick(cc) == 0
    sql(cc, "UPDATE users SET last_inbound_at=NULL")
    chat_job(cc, 0, state="pending")
    assert tick(cc) == 0 and fakes.coach_calls == []


def test_flag_off_sends_nothing(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes, coach_proactive=False)) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token))
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")
        chat_job(c, 49, niggle="green")
        race(c, 5)
        assert tick(c) == 0
        assert fakes.coach_calls == [] and jobs(c) == []


def test_a_failed_model_call_sends_no_template_and_does_not_retry(cc, fakes):
    race(cc, 5)
    fakes.coach_queue = [400]
    assert tick(cc) == 0
    assert [j["state"] for j in jobs(cc)] == ["cancelled"]
    assert not sent_texts(fakes)[-1:] or "got away" not in sent_texts(fakes)[-1]
    n = len(fakes.coach_calls)
    assert tick(cc, T0 + timedelta(minutes=5)) == 0 and len(fakes.coach_calls) == n   # the trigger does not come back


def test_withdrawal_while_thinking_drops_the_message(cc, fakes):
    race(cc, 5)
    real = cc.svc.coach._agent

    def agent(job, now):
        sql(cc, "UPDATE users SET paused=1")
        return real(job, now)
    cc.svc.coach._agent = agent
    fakes.coach_queue = [coach_text("How did it feel?")]
    assert tick(cc) == 0
    assert [j["state"] for j in jobs(cc)] == ["cancelled"] and not sent_texts(fakes)


def test_triage_check_records_the_level_for_the_check_back(cc):
    sql(cc, "INSERT INTO coach_jobs (user_id, msg_mac, kind, state, created_at) VALUES (?,?,?,?,?)", cc.uid, "x", "chat", "running", iso(T0))
    jid = rows(cc, "SELECT id FROM coach_jobs")[0]["id"]
    ctx = ToolContext(cc.svc, cc.uid, T0, jid)
    assert coach_triage.call("triage_check", {"pain_0_10": 2}, ctx)["level"] == "green"
    assert rows(cc, "SELECT niggle FROM coach_jobs")[0]["niggle"] == "green"
    assert coach_triage.call("triage_check", {"swelling": True}, ctx)["level"] == "amber"
    assert rows(cc, "SELECT niggle FROM coach_jobs")[0]["niggle"] == "amber"


# ------------------------------------------------------------------------------------------------- review fixes (#373)
def second_runner(c):
    tok = enrol(c, OTHER)
    c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(tok))
    c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(tok))
    other = rows(c, "SELECT id FROM users WHERE chat_ref=?", OTHER)[0]["id"]
    sql(c, "UPDATE users SET last_inbound_at=NULL")
    return other


def test_one_runners_trigger_never_blocks_anothers(cc, fakes):
    other = second_runner(cc)
    first = cc.uid
    for uid in (first, other):
        cc.uid = uid
        quality_tomorrow(cc)
        sql(cc, "UPDATE users SET paused=0 WHERE id=?", uid)
        race(cc, 5) if uid == first else None
    fakes.coach_queue = [coach_text("Hot one tomorrow."), coach_text("Hot one tomorrow too.")]
    sql(cc, "DELETE FROM runs WHERE type='race'")
    assert tick(cc) == 2
    macs = [j["msg_mac"] for j in jobs(cc)]
    assert sorted(macs) == sorted(f"proactive:heat:{u}:2026-10-22" for u in (first, other))


def test_every_key_carries_the_runner(cc, fakes):
    chat_job(cc, 49, niggle="green")
    fakes.coach_queue = [coach_text("How's the knee?")]
    tick(cc)
    sql(cc, "UPDATE coach_jobs SET state='cancelled' WHERE kind='proactive'")   # so the one-a-day cap lets the next one through
    race(cc, 5)
    fakes.coach_queue = [coach_text("How did it feel?")]
    tick(cc, T0 + 24 * H)
    assert [j["msg_mac"].rsplit(":", 1)[0] for j in jobs(cc)][0].startswith(f"proactive:niggle:{cc.uid}")
    assert jobs(cc)[-1]["msg_mac"] == f"proactive:race:{cc.uid}:race1"


def test_nobody_is_on_the_proactive_allowlist_by_default(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes, coach_proactive_allowlist=frozenset())) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token))
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")
        race(c, 5)
        assert tick(c) == 0 and fakes.coach_calls == [] and jobs(c) == []
    from companion.config import Settings
    env = {"COMPANION_PEPPER": "p" * 32}
    assert Settings.from_env(env).coach_proactive_allowlist == frozenset()
    assert Settings.from_env({**env, "COMPANION_COACH_PROACTIVE_ALLOWLIST": "T1,telegram:5"}).coach_proactive_allowlist == frozenset({"T1", "telegram:5"})


def test_the_forecast_is_fetched_outside_any_write_transaction(cc, fakes):
    quality_tomorrow(cc)
    free = []

    def heat_at(*_a, **_k):
        con = sqlite3.connect(cc.svc.s.db_path, timeout=0)
        try:
            con.execute("BEGIN IMMEDIATE")   # raises "database is locked" when the fetch runs inside the write transaction
            con.rollback()
            free.append(True)
        except sqlite3.OperationalError:
            free.append(False)
        finally:
            con.close()
        return (31, 22)
    cc.wx.heat_at = heat_at
    fakes.coach_queue = [coach_text("Hot one tomorrow.")]
    assert tick(cc) == 1 and free and all(free)


def _hook(cc, fn):
    real = cc.svc.coach._agent

    def agent(job, now):
        out = real(job, now)
        fn()
        return out
    cc.svc.coach._agent = agent


def test_a_message_from_the_runner_while_it_was_thinking_holds_the_send(cc, fakes):
    race(cc, 5)
    _hook(cc, lambda: sql(cc, "UPDATE users SET last_inbound_at=?", iso(T0 + timedelta(seconds=1))))
    fakes.coach_queue = [coach_text("How did it feel?")]
    assert tick(cc) == 0
    assert jobs(cc)[0]["outcome"] == "held:runner_wrote" and not sent_texts(fakes)


def test_quiet_hours_that_begin_while_it_was_thinking_hold_the_send(cc, fakes):
    race(cc, 5)
    _hook(cc, lambda: sql(cc, "UPDATE users SET quiet_start=?, quiet_end=?", 19 * 60, 20 * 60))   # 19:30 local is now quiet
    fakes.coach_queue = [coach_text("How did it feel?")]
    assert tick(cc) == 0
    assert jobs(cc)[0]["outcome"] == "held:quiet_hours" and not sent_texts(fakes)


def test_the_kill_switch_pulled_while_it_was_thinking_holds_the_send(cc, fakes):
    race(cc, 5)
    _hook(cc, lambda: sql(cc, "INSERT OR REPLACE INTO settings (key, value) VALUES ('sends_paused', '1')"))
    fakes.coach_queue = [coach_text("How did it feel?")]
    assert tick(cc) == 0
    assert jobs(cc)[0]["outcome"] == "held:kill_switch" and not sent_texts(fakes)


def test_a_retry_of_a_failed_send_is_checked_again(cc, fakes):
    race(cc, 5)
    fakes.coach_queue = [coach_text("How did it feel?")]
    fakes.fail("sendMessage", 500)
    assert tick(cc) == 0
    assert jobs(cc)[0]["state"] == "replied"                       # stored, waiting for the worker's retry
    sql(cc, "UPDATE users SET quiet_start=?, quiet_end=?", 19 * 60, 21 * 60)
    cc.svc.coach.step(T0 + timedelta(minutes=5))
    assert jobs(cc)[0]["outcome"] == "held:quiet_hours" and jobs(cc)[0]["state"] == "cancelled"
    assert not sent_texts(fakes)


def test_a_retry_that_is_still_allowed_goes_out(cc, fakes):
    race(cc, 5)
    fakes.coach_queue = [coach_text("How did it feel?")]
    fakes.fail("sendMessage", 500)
    assert tick(cc) == 0
    cc.svc.coach.step(T0 + timedelta(minutes=5))
    assert jobs(cc)[0]["state"] == "sent" and sent_texts(fakes)[-1] == "How did it feel?"


def test_a_proactive_job_stranded_running_is_cancelled_at_startup_flag_off(tmp_path, fakes):
    app = create_app(settings(tmp_path, coach_proactive=False), httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=True)
    with TestClient(app) as c:
        c.svc = app.state.svc
        c.token = enrol(c)
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "INSERT INTO coach_jobs (user_id, msg_mac, kind, state, created_at, claimed_at) VALUES (?,?,?,?,?,?)",
            c.uid, "proactive:race:x:y", "proactive", "running", iso(T0), iso(T0))
    with TestClient(app) as c2:   # the lifespan runs again, as a restart would
        assert rows(c2.app.state.svc and c, "SELECT state, outcome FROM coach_jobs") == [{"state": "cancelled", "outcome": "restart"}]
