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
        self.td, self.calls, self.hours = (temp, dew), 0, []

    def heat_at(self, lat, lon, zone, day, hour):
        self.calls += 1
        self.hours.append(hour)
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


def usual_runs(c, utc_hour, n=3):
    for i in range(n):
        start = T0.replace(hour=utc_hour, minute=0) - timedelta(days=2 + i)
        sql(c, "INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, "
               "received_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            c.uid, f"u{utc_hour}_{i}", iso(start), iso(start + H), 780, "Pacific/Auckland", "easy", 2400, 7000, iso(start + H))


def test_the_heat_forecast_is_for_the_runners_usual_start_hour(cc, fakes):
    quality_tomorrow(cc)
    usual_runs(cc, 0)   # 00:00 UTC = 13:00 in Auckland: a lunchtime runner
    fakes.coach_queue = [coach_text("Hot one tomorrow.")]
    assert tick(cc) == 1 and cc.wx.hours == [13]


def test_the_heat_forecast_falls_back_to_seven_with_few_runs(cc, fakes):
    quality_tomorrow(cc)
    fakes.coach_queue = [coach_text("Hot one tomorrow.")]
    assert tick(cc) == 1 and cc.wx.hours == [7]


def test_heat_note_names_the_hour_it_was_given():
    from companion.coach import proactive
    assert "Thursday at 13:00 the forecast" in proactive.heat_note("Tempo", "Thursday", (31, 22), 0.059, 13)
    assert "Thursday at 07:00 the forecast" in proactive.heat_note("Tempo", "Thursday", (31, 22), 0.059)


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
    tick(cc, T0 + 40 * H)               # the same race is 45 h old by now (and already debriefed); only a morning message may follow
    assert [j["msg_mac"].split(":")[1] for j in jobs(cc)].count("race") == 1


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
    assert rows(cc, "SELECT * FROM coach_messages") == []   # a held message is not in the chat history either


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


# ------------------------------------------------------------------------------------------------- the run debrief and the day message
def real_run(c, hours_ago, *, rid="g1", typ="tempo", real=1, km=5.0, now=T0, session="5K goal", goal=1, **extra):
    end = now - hours_ago * H
    cols = dict(user_id=c.uid, run_id=rid, start_utc=iso(end - H / 2), end_utc=iso(end), utc_offset_min=780, zone_id="Pacific/Auckland",
                type=typ, duration_s=1800, distance_m=int(km * 1000), pace_s_per_km=360.0, true_pace_s_per_km=350.0, received_at=iso(end),
                real_upload=real, session_name=session, goal_reached=goal, feel="right", zone_min="[0,4,20,6,0]")
    cols.update(extra)
    sql(c, f"INSERT INTO runs ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", *cols.values())


def turn(fakes):
    t = fakes.coach_calls[-1]["messages"][-1]["content"]
    return t if isinstance(t, str) else "".join(p.get("text", "") for p in t)


def test_a_goal_run_gets_a_debrief_once_and_a_second_run_the_same_day_does_not(cc, fakes):
    real_run(cc, 2)
    fakes.coach_queue = [coach_text("Steady 5K, level pace all the way. Thursday's tempo is next.\n<chips>Good one|Tough one|Tell you more</chips>")]
    assert tick(cc) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:run:{cc.uid}:g1"
    t = turn(fakes)
    assert "5 km in 30:00" in t and "5K goal (goal reached)" in t and "true pace 5:50/km" in t
    assert "how it felt, as the runner tapped it: right" in t and "[0,4,20,6,0]" in t
    assert tick(cc, T0 + timedelta(minutes=10)) == 0                      # the same run: once
    real_run(cc, 0.5, rid="g2", session="Easy")
    assert tick(cc, T0 + 1 * H) == 0                                      # a second run the same day: the cap
    assert len(jobs(cc)) == 1 and len(fakes.coach_calls) == 1


def test_the_debrief_compares_with_the_earlier_runs(cc, fakes):
    real_run(cc, 30, rid="old", typ="easy", session="Easy", km=6)
    real_run(cc, 2)
    fakes.coach_queue = [coach_text("Good run.")]
    assert tick(cc) == 1
    assert "Their previous runs, newest first:" in turn(fakes) and "6 km" in turn(fakes)


def test_a_race_keeps_its_own_opener(cc, fakes):
    real_run(cc, 5, rid="race1", typ="race", session=None, goal=None)
    fakes.coach_queue = [coach_text("What a result.")]
    assert tick(cc) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:race:{cc.uid}:race1"


def test_a_too_fresh_a_too_short_or_a_non_real_run_is_skipped(cc, fakes):
    real_run(cc, 0.05, rid="fresh")                       # 3 minutes ago
    real_run(cc, 3, rid="short", km=0.6)
    real_run(cc, 3, rid="replay", real=0)
    real_run(cc, 3, rid="old_row", real=None)
    assert tick(cc) == 0 and fakes.coach_calls == [] and jobs(cc) == []


def test_a_run_in_quiet_hours_waits_for_the_morning_and_is_skipped_after_12_hours(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes, default_quiet=(21 * 60 + 30, 7 * 60))) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token))
        c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(c.token))
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")
        real_run(c, 0, rid="late")                                       # finished at T0 = 19:30 local
        assert tick(c, T0 + 3 * H) == 0 and tick(c, T0 + 9 * H) == 0     # 22:30 and 04:30: quiet
        assert fakes.coach_calls == []
        fakes.coach_queue = [coach_text("Nice one last night.")]
        assert tick(c, T0 + 11 * H + timedelta(minutes=40)) == 1         # 07:10 local, 11 h 40 min old: inside 12 h
        assert jobs(c)[0]["msg_mac"] == f"proactive:run:{c.uid}:late"


def test_a_run_whose_next_allowed_time_is_past_12_hours_is_skipped(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes, default_quiet=(21 * 60 + 30, 8 * 60))) as c:   # quiet until 08:00
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token))
        c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(c.token))
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")
        real_run(c, 0, rid="late")                                       # 19:30 local; 08:00 is 12 h 30 min later
        tick(c, T0 + 12 * H + timedelta(minutes=40))     # a morning message may go; the debrief may not
        assert all(j["msg_mac"].split(":")[1] != "run" for j in jobs(c))


def test_a_red_flag_holds_the_debrief(cc, fakes):
    real_run(cc, 2)
    chat_job(cc, 20, triage="red", mac="r")
    assert tick(cc) == 0 and fakes.coach_calls == []
    sql(cc, "DELETE FROM coach_jobs")
    sql(cc, "INSERT INTO health_flags (user_id, kind, state, source, set_at) VALUES (?,?,?,?,?)", cc.uid, "wellbeing", "active", "rail", iso(T0))
    assert tick(cc) == 0 and fakes.coach_calls == []


def test_an_amber_window_makes_the_debrief_amber_and_drops_the_next_session_line(cc, fakes):
    real_run(cc, 2, plan_next_day="2026-10-23", plan_next_session_name="Tempo", plan_next_type="quality")
    chat_job(cc, 30, triage="amber", mac="a")
    fakes.coach_queue = [coach_text("A steady one. How is the leg?")]
    assert tick(cc) == 1
    assert "Do not give paces" in turn(fakes) and "next planned session" not in turn(fakes)


def test_a_clear_week_gives_the_next_session_line(cc, fakes):
    real_run(cc, 2, plan_next_day="2026-10-23", plan_next_session_name="Tempo", plan_next_type="quality")
    fakes.coach_queue = [coach_text("Good one.")]
    assert tick(cc) == 1
    assert "The app's next planned session: Tempo on Friday 23 Oct." in turn(fakes) and "get_plan" in turn(fakes)


# a Wednesday evening to Thursday morning in Auckland: T0 + 12 h is 07:30 on Thursday 22 Oct
MORNING = T0 + 12 * H


def plan_today(c, day="2026-10-22", name="Tempo", hours_before=40, now=MORNING):
    real_run(c, hours_before, rid="p0", typ="easy", session="Easy", now=now, real=0,
             plan_next_type="quality", plan_next_day=day, plan_next_session_name=name, plan_next_pace_lo=300.0, plan_next_pace_hi=310.0)


def test_the_morning_message_names_todays_session_and_the_week_and_fires_once_per_local_day(cc, fakes):
    plan_today(cc)
    fakes.coach_queue = [coach_text("Morning. Tempo today.\n<chips>Sounds good|Need to change it</chips>")]
    assert tick(cc, MORNING) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:day:{cc.uid}:2026-10-22"
    t = turn(fakes)
    assert "today's session is Tempo" in t and "target pace 5:00 to 5:10 per km" in t and "runs done since Monday: 0" in t
    assert tick(cc, MORNING + timedelta(minutes=30)) == 0                 # once a day
    assert tick(cc, MORNING + 2 * H) == 0
    fakes.coach_queue = [coach_text("How is the week looking?")]
    assert tick(cc, MORNING + 24 * H) == 1                                # the next local date is a new key (the plan has run out: a question)
    assert [j["msg_mac"].split(":")[-1] for j in jobs(cc)] == ["2026-10-22", "2026-10-23"]
    assert "how is the week looking" in turn(fakes).lower()


def test_the_morning_message_is_never_sent_in_quiet_hours_or_after_noon(cc, fakes):
    plan_today(cc)
    assert tick(cc, T0 + 10 * H) == 0          # 05:30 local, before 06:30
    assert tick(cc, T0 + 17 * H) == 0          # 12:30 local: too late for a good morning
    assert fakes.coach_calls == [] and jobs(cc) == []


def test_the_morning_message_waits_out_a_late_quiet_window(tmp_path, fakes):
    with TestClient(build(tmp_path, fakes, default_quiet=(21 * 60 + 30, 8 * 60))) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(c.token))
        c.put("/v1/me/timezone", json={"zone_id": "Pacific/Auckland"}, headers=auth(c.token))
        c.uid = rows(c, "SELECT id FROM users")[0]["id"]
        sql(c, "UPDATE users SET last_inbound_at=NULL")
        plan_today(c)
        assert tick(c, MORNING) == 0               # 07:30 local, quiet until 08:00
        fakes.coach_queue = [coach_text("Morning.")]
        assert tick(c, MORNING + timedelta(minutes=40)) == 1   # 08:10 local


def test_a_run_debrief_the_same_morning_suppresses_the_day_message(cc, fakes):
    plan_today(cc)
    real_run(cc, 3, rid="dawn", now=MORNING)                              # finished 3 h before, 04:30 local
    fakes.coach_queue = [coach_text("Early start. Nice 5K.")]
    assert tick(cc, MORNING) == 1
    assert jobs(cc)[0]["msg_mac"].startswith(f"proactive:run:{cc.uid}")
    assert tick(cc, MORNING + 1 * H) == 0 and len(jobs(cc)) == 1


def test_a_rest_day_after_a_run_is_skipped_only_when_that_run_was_debriefed(cc, fakes):
    # yesterday's run (11:30 local on the 21st) carries the plan: the next session is tomorrow, so today is a rest day
    real_run(cc, 20, rid="yday", now=MORNING, plan_next_type="quality", plan_next_day="2026-10-23", plan_next_session_name="Tempo")
    # no debrief was ever sent for it (it came before deploy, was capped or held): the morning message still goes
    fakes.coach_queue = [coach_text("Rest day today.")]
    assert tick(cc, MORNING) == 1
    assert "today is a rest day in the plan" in turn(fakes)
    sql(cc, "DELETE FROM coach_jobs")
    # a debrief that really went out covers it
    sql(cc, "INSERT INTO coach_jobs (user_id, msg_mac, kind, state, created_at) VALUES (?,?,?,?,?)",
        cc.uid, f"proactive:run:{cc.uid}:yday", "proactive", "sent", iso(MORNING - 10 * H))
    assert tick(cc, MORNING) == 0
    sql(cc, "UPDATE coach_jobs SET state='cancelled'")                  # a debrief that was cancelled does not
    fakes.coach_queue = [coach_text("Rest day today.")]
    assert tick(cc, MORNING) == 1


def test_fri_23_oct_after_the_22_oct_run_with_no_debrief_the_morning_message_goes(cc, fakes):
    sql(cc, "UPDATE users SET zone_id='Asia/Singapore'")
    fri = datetime(2026, 10, 22, 23, 30, tzinfo=timezone.utc)                    # Fri 23 Oct 07:30 SGT
    real_run(cc, 18, rid="thu", now=fri, session="5K goal", plan_next_type="easy", plan_next_day="2026-10-26", plan_next_session_name="Easy")
    fakes.coach_queue = [coach_text("Rest day today.")]
    assert tick(cc, fri) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:day:{cc.uid}:2026-10-23"


def test_monday_a_morning_note_at_07_then_the_run_debrief_at_12_40_and_nothing_else(cc, fakes):
    sql(cc, "UPDATE users SET zone_id='Asia/Singapore'")
    sql(cc, "INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", cc.uid, "runs_per_week", "4", iso(T0))
    sun_night = datetime(2026, 10, 25, 23, 0, tzinfo=timezone.utc)               # Mon 26 Oct 07:00 SGT
    noon_end = datetime(2026, 10, 26, 4, 27, tzinfo=timezone.utc)                 # the run ends 12:27 SGT
    real_run(cc, 80, rid="sat", now=sun_night, session="5K goal", plan_next_type="easy", plan_next_day="2026-10-26",
             plan_next_session_name="Easy", plan_next_m=5000)
    fakes.coach_queue = [coach_text("Morning. Easy 5 today.")]
    assert tick(cc, sun_night) == 1
    assert jobs(cc)[0]["msg_mac"] == f"proactive:day:{cc.uid}:2026-10-26"
    real_run(cc, 0, rid="mon", now=noon_end, session="5K goal", typ="easy")
    fakes.coach_queue = [coach_text("Good one. Tuesday next.")]
    assert tick(cc, noon_end + timedelta(minutes=13)) == 1                       # 12:40 SGT: the debrief goes
    assert [j["msg_mac"].split(":")[1] for j in jobs(cc)] == ["day", "run"]
    chat_job(cc, 60, niggle="green", now=noon_end, mac="n")
    fakes.coach_queue = [coach_text("How's the knee?")]
    assert tick(cc, noon_end + timedelta(minutes=30)) == 0                       # never a third, and no second debrief
    assert len(jobs(cc)) == 2


def test_two_runs_the_same_day_still_get_one_debrief_after_a_morning_note(cc, fakes):
    plan_today(cc)
    fakes.coach_queue = [coach_text("Morning.")]
    assert tick(cc, MORNING) == 1
    real_run(cc, 2, rid="a", now=MORNING + 5 * H)
    fakes.coach_queue = [coach_text("Nice.")]
    assert tick(cc, MORNING + 5 * H) == 1
    real_run(cc, 0.5, rid="b", now=MORNING + 8 * H)
    assert tick(cc, MORNING + 8 * H) == 0
    assert [j["msg_mac"].split(":")[1] for j in jobs(cc)] == ["day", "run"]


def test_the_facts_block_for_his_profile_takes_the_count_from_runs_per_week(cc, fakes):
    """Ricki: memory runs_per_week 4, usual_days weekdays. The planned count is 4, never the 5 weekdays."""
    sql(cc, "INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", cc.uid, "runs_per_week", "4", iso(T0))
    sql(cc, "INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", cc.uid, "usual_days", "weekdays", iso(T0))
    for i in range(3):                                                                # three runs since Monday; the last carries the plan
        extra = dict(plan_next_type="quality", plan_next_day="2026-10-23", plan_next_session_name="Tempo") if i == 2 else {}
        real_run(cc, 40 - 10 * i, rid=f"w{i}", now=MORNING, session="5K goal", **extra)
    sql(cc, "UPDATE coach_jobs SET state='cancelled'")
    fakes.coach_queue = [coach_text("Morning.")]
    assert tick(cc, MORNING) == 1
    t = turn(fakes)
    assert "runs done since Monday: 3; the runner's planned runs a week: 4" in t
    assert "usual run days" not in t and "(usual" not in t
    assert "the next session is on Friday 23 Oct" in t


def test_with_no_runs_per_week_the_planned_count_is_left_out(cc, fakes):
    plan_today(cc)
    fakes.coach_queue = [coach_text("Morning.")]
    assert tick(cc, MORNING) == 1
    assert "planned runs a week" not in turn(fakes)


def test_with_no_plan_it_asks_how_the_week_looks_only_after_three_quiet_days(cc, fakes, monkeypatch):
    orig = type(cc.svc)._ci_state
    monkeypatch.setattr(type(cc.svc), "_ci_state",
                        lambda self, c, user, now, *, answers=True: (*orig(self, c, user, now, answers=answers)[:4], None))   # no plan, no default week
    sql(cc, "UPDATE users SET last_inbound_at=?", iso(MORNING - 2 * 24 * H))      # wrote two days ago
    assert tick(cc, MORNING) == 0
    sql(cc, "UPDATE users SET last_inbound_at=?", iso(MORNING - 4 * 24 * H))
    fakes.coach_queue = [coach_text("How is the week looking?\n<chips>Going well|Tough week</chips>")]
    assert tick(cc, MORNING) == 1
    assert "how is the week looking" in turn(fakes).lower()


def test_an_amber_window_keeps_the_morning_message_gentle(cc, fakes):
    plan_today(cc)
    chat_job(cc, 30, triage="amber", mac="a", now=MORNING)
    fakes.coach_queue = [coach_text("Morning. Easy does it.")]
    assert tick(cc, MORNING) == 1
    t = turn(fakes)
    assert "care window" in t and "do not name, size or push" in t
    assert "Tempo" not in t and "target pace" not in t and "km" not in t.split("Facts from the plan and the app:")[1].split("How the week")[0]



def test_a_rest_day_with_no_run_yesterday_still_gets_a_message(cc, fakes):
    plan_today(cc, day="2026-10-23")
    fakes.coach_queue = [coach_text("Rest day today.")]
    assert tick(cc, MORNING) == 1
    assert "today is a rest day in the plan" in turn(fakes)


def test_the_run_note_names_the_kind_flags_gps_and_gives_weekdays():
    from companion.coach.proactive import run_note
    r = dict(start_utc="2026-10-19T18:00:00Z", type="tempo", session_name="5K goal", distance_m=3400, duration_s=2120,
             pace_s_per_km=624, true_pace_s_per_km=None, zone_min=None, feel="right", pb=None, verdict=None, goal_reached=0,
             plan_next_day="2026-10-23", plan_next_session_name=None, plan_next_type="easy")
    text = run_note(r, [], "Pacific/Auckland", amber=False)
    assert "kind of run: tempo" in text and "the app's session label: 5K goal (goal not reached)" in text
    assert "GPS glitch" in text and "easy on Friday 23 Oct" in text


def test_an_eased_goal_run_is_an_easy_run_with_no_target_in_the_note():
    from companion.coach.proactive import run_note
    r = dict(start_utc="2026-10-29T03:00:00Z", type="tempo", session_name="5K goal", distance_m=5000, duration_s=1854,
             pace_s_per_km=371, true_pace_s_per_km=None, zone_min=None, feel=None, pb=None, verdict=None, goal_reached=1,
             goal_target_s=1500, goal_target_from="5K on 26 Oct", goal_retarget_s=1700, goal_eased=1,
             plan_next_day=None, plan_next_session_name=None, plan_next_type=None)
    text = run_note(r, [], "Pacific/Auckland", amber=False)
    assert "kind of run: easy run" in text and "tempo" not in text
    assert "25:00" not in text and "28:20" not in text and "the goal's target time" not in text
    assert "ease off mid-run on purpose" in text and "do not grade the finish" in text
    # Not eased: the target is still there to judge by.
    r["goal_eased"] = None
    assert "the goal's target time: 25:00" in run_note(r, [], "Pacific/Auckland", amber=False)


def test_heat_note_carries_the_real_chips_not_the_placeholder():
    from companion.coach import proactive
    note = proactive.heat_note("Tempo", "Thursday", (31, 22), 0.059)
    assert f"<chips>{proactive.HEAT_CHIPS}</chips>" in note and "{HEAT_CHIPS}" not in note


def test_a_bimodal_runner_gets_a_real_start_hour_not_the_midpoint(cc, fakes):
    quality_tomorrow(cc)
    usual_runs(cc, 18, n=5)   # 18:00 UTC = 07:00 Auckland
    usual_runs(cc, 5, n=5)    # 05:00 UTC = 18:00 Auckland
    fakes.coach_queue = [coach_text("Hot one tomorrow.")]
    assert tick(cc) == 1 and cc.wx.hours == [7]
