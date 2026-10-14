"""Tester rails (M2 enrolment cap + ops CLI, M5 cost and abuse rails). Each test here fails on origin/main."""
import sqlite3
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import db, ops
from companion.app import create_app
from companion.channels import Inbound, TelegramChannel
from companion.config import Settings
from companion.rails import RateLimiter
from companion.service import RATE_PAUSED, TEST_FULL
from companion.timeutil import iso, now_utc
from companion.writer import Writer
from conftest import OWNER, auth, confirm, enrol, make_settings, post_tg, run_payload, start, status, tg_update

_ids = iter(range(5_000_000, 10**8))


def app_for(tmp_path, fakes, **over):
    import companion.app as capp
    capp.ENROLS_PER_HOUR = capp.CONFIRMS_PER_HOUR = capp.STATUS_PER_MIN = 10_000   # these tests enrol dozens from one test IP
    s = make_settings(tmp_path, **over)
    return create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False), s


def rows(path, sql, args=()):
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    try:
        return c.execute(sql, args).fetchall()
    finally:
        c.close()


def inbound(text, ref=OWNER):
    return TelegramChannel.parse(tg_update(next(_ids), text, ref))


# ---------------------------------------------------------------- M2: the enrolment cap


def test_cap_defaults_to_25_and_the_26th_runner_is_refused(tmp_path, fakes):
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20}).max_users == 25
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20, "COMPANION_MAX_USERS": "nonsense"}).max_users == 25
    app, s = app_for(tmp_path, fakes, open_enrolment=True)
    assert s.max_users == 25
    with TestClient(app) as c:
        for n in range(25):
            enrol(c, ref=str(700000 + n))
        assert rows(s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 25
        st = start(c)
        post_tg(c, tg_update(next(_ids), f"/start {st['nonce']}", "999000444"))
        assert fakes.tg_texts()[-1] == TEST_FULL
        assert status(c, st) == {"state": "denied"}
        assert rows(s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 25


def test_a_full_refusal_keeps_no_chat_id_and_the_reply_says_what_is_kept(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, open_enrolment=True, max_users=1)
    with TestClient(app) as c:
        enrol(c, ref="700001")
        for ref in ("999000444", "999000555"):
            st = start(c)
            post_tg(c, tg_update(next(_ids), f"/start {st['nonce']}", ref))
        assert rows(s.db_path, "SELECT n FROM enrol_refused")[0]["n"] == 2   # a tally per day, nothing else
        db.checkpoint_truncate(s.db_path)
        import os
        raw = b"".join(open(p, "rb").read() for p in (s.db_path, s.db_path + "-wal") if os.path.exists(p))
        assert b"999000444" not in raw and b"999000555" not in raw
        assert "tally" in TEST_FULL and "haven't kept your chat" in TEST_FULL
        assert rows(s.db_path, "SELECT COUNT(*) AS n FROM enrolments WHERE state='denied' AND user_id IS NULL AND chat_name IS NULL")[0]["n"] == 2


def test_the_allowlist_still_works_when_full_and_an_existing_runner_can_reconnect(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, open_enrolment=True, max_users=1,
                     allowed_ids=frozenset({f"telegram:{OWNER}", "telegram:444555666"}))
    with TestClient(app) as c:
        enrol(c, ref="700001")   # takes the only open place
        assert enrol(c, ref=OWNER) and enrol(c, ref="444555666")   # Ricki's path is not held to the cap
        assert rows(s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 3
        assert enrol(c, ref="700001")   # an existing runner re-connecting is not a new place


def test_tester_numbers_follow_enrolment_and_are_never_reused(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, open_enrolment=True)
    with TestClient(app) as c:
        t1, t2 = enrol(c, ref="700001"), enrol(c, ref="700002")
        c.delete("/v1/me", headers=auth(t1))
        enrol(c, ref="700003")
        assert [r["tester_no"] for r in rows(s.db_path, "SELECT tester_no FROM users ORDER BY tester_no")] == [2, 3]
        assert t2


def test_old_databases_gain_the_new_columns_and_existing_runners_are_numbered_oldest_first(tmp_path):
    path = str(tmp_path / "old.db")
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE users (id TEXT PRIMARY KEY, channel TEXT NOT NULL, chat_ref TEXT NOT NULL, chat_name TEXT, "
              "created_at TEXT NOT NULL, consent_version TEXT, consent_at TEXT, consent_msg_id TEXT, "
              "zone_id TEXT NOT NULL DEFAULT 'UTC', paused INTEGER NOT NULL DEFAULT 0, UNIQUE (channel, chat_ref))")
    c.execute("CREATE TABLE llm_calls (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, model TEXT, provider TEXT, "
              "cost_usd REAL NOT NULL DEFAULT 0, outcome TEXT NOT NULL)")
    c.execute("INSERT INTO llm_calls (ts, cost_usd, outcome) VALUES ('2026-10-01T00:00:00Z', 1.5, 'ok')")
    for uid, ts in (("b", "2026-10-02T00:00:00Z"), ("a", "2026-10-01T00:00:00Z")):
        c.execute("INSERT INTO users (id, channel, chat_ref, created_at) VALUES (?, 'telegram', ?, ?)", (uid, uid, ts))
    c.commit()
    c.close()
    db.init(path)
    db.init(path)   # twice: the migration is safe to repeat
    assert [(r["id"], r["tester_no"]) for r in rows(path, "SELECT id, tester_no FROM users ORDER BY tester_no")] == [("a", 1), ("b", 2)]
    assert rows(path, "SELECT user_id, cost_usd FROM llm_calls")[0]["user_id"] is None
    assert rows(path, "SELECT ops_paused FROM users")[0]["ops_paused"] == 0


# ---------------------------------------------------------------- M5: cost per runner and the monthly cap


def test_each_call_is_charged_to_the_runner_it_wrote_for(client, fakes):
    t = enrol(client)
    client.post("/v1/runs", json=run_payload("a"), headers=auth(t))
    client.post("/v1/runs", json=run_payload("b", minutes_ago=300), headers=auth(t))
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))
    uid = rows(client.svc.s.db_path, "SELECT id FROM users")[0]["id"]
    calls = rows(client.svc.s.db_path, "SELECT user_id, cost_usd FROM llm_calls")
    assert calls and all(r["user_id"] == uid for r in calls)
    total = sum(r["cost_usd"] for r in calls)
    assert total > 0 and client.svc.writer.user_month_spend(uid) == pytest.approx(total)


def test_cost_is_split_by_runner_and_deleting_a_runner_keeps_the_spend(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, allowed_ids=frozenset({f"telegram:{OWNER}", "telegram:444555666"}))
    with TestClient(app) as c:
        a, b = enrol(c), enrol(c, ref="444555666")
        w: Writer = c.app.state.svc.writer
        ids = {r["tester_no"]: r["id"] for r in rows(s.db_path, "SELECT id, tester_no FROM users")}
        w._log("m", "p", 1.25, "ok", ids[1])
        w._log("m", "p", 0.5, "ok", ids[2])
        assert w.user_month_spend(ids[1]) == 1.25 and w.user_month_spend(ids[2]) == 0.5 and w.month_spend() == 1.75
        roster = "\n".join(ops.roster(s))
        assert "T1 " in roster and "llm_month_usd=1.2500" in roster and "llm_month_usd=0.5000" in roster
        c.delete("/v1/me", headers=auth(a))
        assert w.month_spend() == 1.75                      # the cap cannot be reset by deleting
        assert rows(s.db_path, "SELECT COUNT(*) AS n FROM llm_calls WHERE user_id=?", (ids[1],))[0]["n"] == 0
        assert b


def test_cap_alerts_fire_once_each_at_50_80_and_100_percent(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, monthly_cap_usd=20.0)
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20}).monthly_cap_usd == 20.0
    with TestClient(app) as c:
        w: Writer = c.app.state.svc.writer

        def keys():
            return [r["key"] for r in rows(s.db_path, "SELECT key FROM alerts WHERE sent_at IS NULL ORDER BY id")]
        w._log("m", "p", 9.9, "ok")
        assert keys() == []
        w._log("m", "p", 0.1, "ok")          # exactly 50%
        assert [k.split(":")[-1] for k in keys()] == ["50"]
        w._log("m", "p", 0.5, "ok")          # still under 80%: nothing new
        w._log("m", "p", 5.5, "ok")          # 16.0 = 80%
        w._log("m", "p", 1.0, "ok")          # between 80 and 100
        assert [k.split(":")[-1] for k in keys()] == ["50", "80"]
        w._log("m", "p", 4.0, "ok")          # 21.0: over the cap
        assert [k.split(":")[-1] for k in keys()] == ["50", "80", "100"]
        w._log("m", "p", 1.0, "ok")
        assert len(keys()) == 3              # no repeats
        body = " ".join(r["title"] + r["body"] for r in rows(s.db_path, "SELECT title, body FROM alerts"))
        assert "templates only" in body and "20" in body


def test_one_call_that_jumps_the_thresholds_sends_only_the_highest(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, monthly_cap_usd=10.0)
    with TestClient(app) as c:
        c.app.state.svc.writer._log("m", "p", 9.0, "ok")
        unsent = [r["key"] for r in rows(s.db_path, "SELECT key FROM alerts WHERE sent_at IS NULL")]
        assert [k.split(":")[-1] for k in unsent] == ["80"] and rows(s.db_path, "SELECT COUNT(*) AS n FROM alerts")[0]["n"] == 2


def test_above_the_cap_the_writer_makes_no_call_and_uses_templates(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, monthly_cap_usd=20.0)
    with TestClient(app) as c:
        w: Writer = c.app.state.svc.writer
        w._log("m", "p", 20.0, "ok")
        from test_writer import R
        out = w.write(R, {}, user_id="u")
        assert out.source == "template" and out.note == "spend_cap" and not fakes.llm


# ---------------------------------------------------------------- M5: the inbound rate limiter


def test_limiter_boundary_20_a_minute_then_one_note_then_silence_then_recovery():
    rl = RateLimiter(20, 200)
    t0 = now_utc()
    assert [rl.check("k", t0 + timedelta(seconds=i)) for i in range(20)] == ["ok"] * 20
    assert rl.check("k", t0 + timedelta(seconds=21)) == "notice"
    assert rl.check("k", t0 + timedelta(seconds=22)) == "silent"
    assert rl.check("other", t0 + timedelta(seconds=22)) == "ok"       # per chat
    assert rl.check("k", t0 + timedelta(seconds=61)) == "ok"           # the minute window has slid on


def test_limiter_day_limit_is_200():
    rl = RateLimiter(1000, 200)
    t0 = now_utc()
    assert all(rl.check("k", t0 + timedelta(seconds=i)) == "ok" for i in range(200))
    assert rl.check("k", t0 + timedelta(seconds=201)) == "notice-day"
    assert rl.check("k", t0 + timedelta(days=1, seconds=300)) == "ok"


def flood(svc, t0, n=21, ref=OWNER):
    for i in range(n):
        svc.handle_inbound(inbound("hello", ref), now=t0 + timedelta(seconds=i))


def texts(fakes):
    return fakes.tg_texts()


def test_a_flood_gets_one_slow_down_note_and_the_rest_is_ignored(client, fakes):
    enrol(client)
    before = len(texts(fakes))
    flood(client.svc, now_utc(), n=60)
    sent = texts(fakes)[before:]
    # enrolling used one place in the minute: 19 canned replies, then exactly one slow-down note, then nothing
    assert len(sent) == 20 and "faster than I can keep up" in sent[-1]
    assert sum("faster than I can keep up" in x for x in sent) == 1


def test_a_strangers_flood_is_limited_without_storing_the_chat(client, fakes):
    flood(client.svc, now_utc(), n=40, ref="888777666")
    assert sum("faster than I can keep up" in x for x in texts(fakes)) == 1
    assert rows(client.svc.s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 0
    assert rows(client.svc.s.db_path, "SELECT COUNT(*) AS n FROM inbound_strikes")[0]["n"] == 0


def test_three_floods_in_a_day_pause_the_runner_and_raise_an_alert_then_they_get_nothing(client, fakes):
    t = enrol(client)
    svc, t0 = client.svc, now_utc()
    for k in range(3):
        flood(svc, t0 + timedelta(minutes=11 * k))
    u = rows(svc.s.db_path, "SELECT ops_paused, ops_paused_reason FROM users")[0]
    assert (u["ops_paused"], u["ops_paused_reason"]) == (1, "rate")
    assert texts(fakes)[-1] == RATE_PAUSED
    al = rows(svc.s.db_path, "SELECT title, body FROM alerts WHERE sent_at IS NULL")
    assert len(al) == 1 and "T1 paused for flooding" in al[0]["title"] and "ops resume T1" in al[0]["body"]
    assert OWNER not in al[0]["title"] + al[0]["body"]
    n = len(texts(fakes))
    svc.handle_inbound(inbound("hello again"), now=t0 + timedelta(hours=2))
    svc.handle_inbound(inbound("RESUME"), now=t0 + timedelta(hours=2, seconds=5))   # their own RESUME does not undo it
    client.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
    svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert len(texts(fakes)) == n and rows(svc.s.db_path, "SELECT ops_paused FROM users")[0]["ops_paused"] == 1


def test_two_floods_are_not_enough_and_old_strikes_age_out(client, fakes):
    enrol(client)
    svc, t0 = client.svc, now_utc()
    flood(svc, t0)
    flood(svc, t0 + timedelta(minutes=11))
    flood(svc, t0 + timedelta(hours=25))   # only this one is inside the last 24 hours
    assert rows(svc.s.db_path, "SELECT ops_paused FROM users")[0]["ops_paused"] == 0


def test_rate_settings_come_from_the_environment():
    s = Settings.from_env({"COMPANION_PEPPER": "p" * 20, "COMPANION_RATE_PER_MIN": "5", "COMPANION_RATE_PER_DAY": "0"})
    assert (s.rate_per_min, s.rate_per_day, s.rate_strikes_to_pause) == (5, 200, 3)   # 0 is a typo, not "off"


# ---------------------------------------------------------------- ops CLI: pause, resume, status


def test_a_paused_tester_gets_nothing_and_resume_brings_cards_back(client, fakes):
    t = enrol(client)
    svc = client.svc
    code, msg = ops.set_ops_pause(svc.s, "T1", True)
    assert code == 0 and "T1" in msg and OWNER not in msg
    n = len(fakes.tg)
    svc.handle_inbound(inbound("hello"))
    svc.handle_inbound(inbound("RESUME"))
    client.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
    svc.run_outbox(now_utc() + timedelta(seconds=1))
    svc.plan_evening(now_utc())
    svc.plan_recap(now_utc())
    svc.plan_checkins(now_utc())
    svc.run_outbox(now_utc() + timedelta(days=1))
    assert len(fakes.tg) == n    # nothing at all went to Telegram
    assert ops.set_ops_pause(svc.s, "T1", False)[0] == 0
    client.post("/v1/runs", json=run_payload("r2", minutes_ago=90), headers=auth(t))
    svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert len(fakes.tg) > n


def test_a_paused_tester_can_still_delete_everything(client, fakes):
    enrol(client)
    ops.set_ops_pause(client.svc.s, "T1", True)
    client.svc.handle_inbound(inbound("DELETE"))
    assert "Done. Everything we held about you is deleted" in texts(fakes)[-1]
    assert rows(client.svc.s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 0


def test_ops_commands_use_tester_numbers_only(client, fakes, caplog):
    import logging
    caplog.set_level(logging.INFO)
    enrol(client)
    s = client.svc.s
    out = []
    assert ops.main(s, ["roster"], out.append) == 0
    assert ops.main(s, ["pause", "T1"], out.append) == 0 and ops.main(s, ["roster"], out.append) == 0
    assert ops.main(s, ["status"], out.append) == 0
    text = "\n".join(out) + "\n".join(r.getMessage() for r in caplog.records)
    assert "T1 telegram state=active" in text and "state=ops-paused(ops)" in text
    assert "runners=1 places=0/25" in text and "cap_usd=5" in text and "enrol_refused_today=0" in text
    assert OWNER not in text and "chat" not in text.lower().replace("chat is ignored", "")
    assert "ops pause tester=T1" in caplog.text


def test_ops_rejects_unknown_runners_and_bad_input(client):
    s = client.svc.s
    out = []
    assert ops.main(s, ["pause", "T9"], out.append) == 1 and "no runner T9" in out[-1]
    assert ops.main(s, ["pause", "nobody"], out.append) == 2
    assert ops.main(s, ["pause"], out.append) == 2
    assert ops.main(s, ["bogus"], out.append) == 2


def test_resume_clears_the_strikes_so_one_more_flood_does_not_repause(client, fakes):
    enrol(client)
    svc, t0 = client.svc, now_utc()
    for k in range(3):
        flood(svc, t0 + timedelta(minutes=11 * k))
    assert ops.set_ops_pause(svc.s, "T1", False)[0] == 0
    flood(svc, t0 + timedelta(minutes=40))
    assert rows(svc.s.db_path, "SELECT ops_paused FROM users")[0]["ops_paused"] == 0


def test_purge_drops_strikes_after_2_days(client):
    enrol(client)
    svc = client.svc
    uid = rows(svc.s.db_path, "SELECT id FROM users")[0]["id"]
    old = iso(now_utc() - timedelta(days=3))
    with db.tx(svc.s.db_path) as c:
        c.execute("INSERT INTO inbound_strikes (user_id, ts) VALUES (?,?)", (uid, old))
    svc.purge()
    assert rows(svc.s.db_path, "SELECT COUNT(*) AS n FROM inbound_strikes")[0]["n"] == 0


def test_the_alert_flush_script_parses():
    import os
    import subprocess
    here = os.path.join(os.path.dirname(__file__), "..", "deploy", "flush-alerts.sh")
    assert subprocess.run(["bash", "-n", here]).returncode == 0


# ---------------------------------------------------------------- round 2 (review-298)


def test_chat_delete_works_while_rate_limited_and_while_ops_paused(client, fakes):
    enrol(client)
    svc, t0 = client.svc, now_utc()
    flood(svc, t0, n=40)   # over the limit
    svc.handle_inbound(inbound("DELETE"), now=t0 + timedelta(seconds=45))
    assert "Everything we held about you is deleted" in texts(fakes)[-1]
    assert rows(svc.s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 0


def test_chat_delete_works_for_a_paused_flooder(client, fakes):
    enrol(client)
    svc, t0 = client.svc, now_utc()
    for k in range(3):
        flood(svc, t0 + timedelta(minutes=11 * k))
    assert rows(svc.s.db_path, "SELECT ops_paused FROM users")[0]["ops_paused"] == 1
    flood(svc, t0 + timedelta(minutes=40), n=40)
    svc.handle_inbound(inbound("/delete"), now=t0 + timedelta(minutes=40, seconds=50))
    assert rows(svc.s.db_path, "SELECT COUNT(*) AS n FROM users")[0]["n"] == 0


def test_a_paused_runner_costs_no_model_call_even_if_a_card_is_built(client, fakes):
    t = enrol(client)
    svc = client.svc
    uid = rows(svc.s.db_path, "SELECT id FROM users")[0]["id"]
    client.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
    ops.set_ops_pause(svc.s, "T1", True)
    n = len(fakes.llm)
    assert svc._build_run_card(uid, "r1", now_utc() + timedelta(seconds=1))   # a card is built, from the template
    from test_writer import R
    assert svc.writer.write(R, {}, user_id=uid).note == "ops_paused"
    assert len(fakes.llm) == n
    assert rows(svc.s.db_path, "SELECT COUNT(*) AS n FROM llm_calls WHERE user_id=?", (uid,))[0]["n"] == 0


def test_one_runner_cannot_drain_the_shared_cap(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, user_monthly_cap_usd=1.0, monthly_cap_usd=20.0,
                     allowed_ids=frozenset({f"telegram:{OWNER}", "telegram:444555666"}))
    assert Settings.from_env({"COMPANION_PEPPER": "p" * 20}).user_monthly_cap_usd == 3.0
    from test_writer import R
    with TestClient(app) as c:
        enrol(c), enrol(c, ref="444555666")
        w: Writer = c.app.state.svc.writer
        ids = {r["tester_no"]: r["id"] for r in rows(s.db_path, "SELECT id, tester_no FROM users")}
        w._log("m", "p", 0.99, "ok", ids[1])
        assert w.write(R, {}, user_id=ids[1]).source == "llm"          # 0.99 + this call's 0.0004: still allowed
        w._log("m", "p", 0.01, "ok", ids[1])
        n = len(fakes.llm)
        out = w.write(R, {}, user_id=ids[1])
        assert out.note == "user_cap" and len(fakes.llm) == n           # T1 is at their ceiling: template, no call
        assert w.write(R, {}, user_id=ids[2]).source == "llm"           # T2 is unaffected
        titles = [r["title"] for r in rows(s.db_path, "SELECT title FROM alerts")]
        assert any("T1 hit the per-runner LLM ceiling" in t for t in titles)
        w.write(R, {}, user_id=ids[1])
        assert sum("per-runner" in r["title"] for r in rows(s.db_path, "SELECT title FROM alerts")) == 1   # once


def test_raising_the_cap_mid_month_rearms_the_alerts(tmp_path, fakes):
    import dataclasses
    app, s = app_for(tmp_path, fakes, monthly_cap_usd=10.0)
    with TestClient(app) as c:
        w: Writer = c.app.state.svc.writer
        w._log("m", "p", 10.5, "ok")
        assert [r["key"].split(":")[-1] for r in rows(s.db_path, "SELECT key FROM alerts WHERE sent_at IS NULL")] == ["100"]
        w2 = Writer(dataclasses.replace(s, monthly_cap_usd=40.0), w.http)   # Ricki raises the cap and restarts
        w2._log("m", "p", 9.5, "ok")      # 20.0 = 50% of the new cap
        w2._log("m", "p", 12.0, "ok")     # 32.0 = 80%
        w2._log("m", "p", 9.0, "ok")      # 41.0 = 100%
        keys = [r["key"] for r in rows(s.db_path, "SELECT key FROM alerts WHERE sent_at IS NULL ORDER BY id")]
        assert [k.split(":")[-1] for k in keys] == ["100", "50", "80", "100"] and ":40:" in keys[-1]


def test_only_sent_alerts_age_out_and_a_months_cap_keys_outlive_the_month(client):
    svc = client.svc
    old = lambda d: iso(now_utc() - timedelta(days=d))   # noqa: E731
    with db.tx(svc.s.db_path) as c:
        c.execute("INSERT INTO alerts (key, ts, title, body) VALUES ('unsent-old', ?, 't', 'b')", (old(45),))
        c.execute("INSERT INTO alerts (key, ts, title, body, sent_at) VALUES ('sent-31d', ?, 't', 'b', ?)", (old(31), old(31)))
        c.execute("INSERT INTO alerts (key, ts, title, body, sent_at) VALUES ('sent-63d', ?, 't', 'b', ?)", (old(63), old(63)))
    svc.purge()
    assert sorted(r["key"] for r in rows(svc.s.db_path, "SELECT key FROM alerts")) == ["sent-31d", "unsent-old"]


def test_ops_status_flags_a_stale_alert_queue(client):
    s = client.svc.s
    out = []
    ops.main(s, ["status"], out.append)
    assert "ALERTS_STALE" not in "\n".join(out)
    with db.tx(s.db_path) as c:
        c.execute("INSERT INTO alerts (key, ts, title, body) VALUES ('x', ?, 't', 'b')", (iso(now_utc() - timedelta(hours=25)),))
    out.clear()
    ops.main(s, ["status"], out.append)
    assert "ALERTS_STALE=1" in "\n".join(out) and "alert cron is not delivering" in "\n".join(out)


def test_allowlisted_runners_take_no_open_place(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, open_enrolment=True, max_users=1)   # the allowlist holds OWNER
    with TestClient(app) as c:
        enrol(c, ref=OWNER)                       # Ricki connects: no place used
        enrol(c, ref="700001")                    # the one open place is still free
        st = start(c)
        post_tg(c, tg_update(next(_ids), f"/start {st['nonce']}", "700002"))
        assert fakes.tg_texts()[-1] == TEST_FULL  # now it is full
        out = []
        ops.main(s, ["status"], out.append)
        assert "runners=2 places=1/1" in out[0]


def test_an_unfinished_connection_older_than_an_hour_does_not_hold_a_place(tmp_path, fakes):
    app, s = app_for(tmp_path, fakes, open_enrolment=True, max_users=1)
    with TestClient(app) as c:
        with db.tx(s.db_path) as w:
            w.execute("INSERT INTO users (id, channel, chat_ref, created_at, tester_no) VALUES ('ghost', 'telegram', '555', ?, 99)",
                      (iso(now_utc() - timedelta(hours=2)),))
            w.execute("INSERT INTO users (id, channel, chat_ref, created_at, tester_no) VALUES ('fresh', 'telegram', '556', ?, 98)",
                      (iso(now_utc() - timedelta(minutes=5)),))
        st = start(c)
        post_tg(c, tg_update(next(_ids), f"/start {st['nonce']}", "700003"))
        assert fakes.tg_texts()[-1] == TEST_FULL   # the 5-minute-old unfinished connection still holds the place
        w2 = sqlite3.connect(s.db_path)
        w2.execute("DELETE FROM users WHERE id='fresh'")
        w2.commit()
        st = start(c)
        post_tg(c, tg_update(next(_ids), f"/start {st['nonce']}", "700003"))
        assert fakes.tg_texts()[-1] != TEST_FULL   # only the 2-hour-old ghost is left: it holds nothing


def test_webhook_redeliveries_do_not_count_against_the_limit(client, fakes):
    enrol(client)
    svc, t0 = client.svc, now_utc()
    same = inbound("hello")
    for i in range(60):
        svc.handle_inbound(same, now=t0 + timedelta(seconds=i))
    assert not any("faster than I can keep up" in x for x in texts(fakes))
    assert rows(svc.s.db_path, "SELECT COUNT(*) AS n FROM inbound_strikes")[0]["n"] == 0


def test_the_scorecard_reports_refusals_by_day(tmp_path, fakes):
    from companion import scorecard
    app, s = app_for(tmp_path, fakes, open_enrolment=True, max_users=1)
    with TestClient(app) as c:
        enrol(c, ref="700001")
        st = start(c)
        post_tg(c, tg_update(next(_ids), f"/start {st['nonce']}", "700002"))
        con = scorecard.open_ro(s.db_path)
        try:
            sc = scorecard.compute_scorecard(con)
        finally:
            con.close()
        assert list(sc["enrol_refused_by_day"].values()) == [1]
