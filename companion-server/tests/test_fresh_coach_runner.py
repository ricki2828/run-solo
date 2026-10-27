"""A fresh tester end to end, as the 27-Oct cohort will meet the coach: enrol, in-app consent v3, chat, the memory sheet (v4),
a first run upload (briefing + proactive debrief), the per-runner cap, then Delete everything. Open mode, no allowlist entry,
not an operator. OpenRouter and Telegram are the fakes in conftest; every call is pinned to T0 (a throwaway DB per test).
"""
from __future__ import annotations

import dataclasses
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
from fastapi.testclient import TestClient

from companion import db
from companion.app import create_app
from companion.coach import chat as coach_chat
from companion.service import RunIn

from conftest import OWNER, auth, coach_text, enrol, make_settings
from test_coach_chat import rows, run_worker, say, uid_of

T0 = datetime(2026, 10, 28, 6, 30, tzinfo=timezone.utc)   # Wednesday 19:30 in Auckland
SESSION = "Easy run today. Keep it relaxed and chatty, and finish feeling like you could go again."


class Wx:
    def heat_at(self, *_a, **_k):
        return (20, 10)


def app_for(tmp_path, fakes, **over):
    base = dict(coach_chat=True, coach_open=True, coach_allowlist=frozenset(), coach_briefing=True, coach_proactive=True,
                coach_proactive_allowlist=frozenset(), allowed_ids=frozenset({f"telegram:{OWNER}"}), coach_merge_s=5.0,
                coach_monthly_cap_usd=30.0, user_monthly_cap_usd=0.5)
    base.update(over)
    return create_app(make_settings(tmp_path, **base), httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)


def put(c, path, body):
    r = c.put(path, json=body, headers=auth(c.token))
    assert r.status_code == 200, r.text
    return r


def upload(c, uid, run_id="r1", now=T0):
    p = dict(run_id=run_id, type="easy", start_utc=now - timedelta(hours=3), utc_offset_min=780, zone_id="Pacific/Auckland",
             duration_s=2400, distance_m=7000, pace_s_per_km=342.0, true_pace_s_per_km=338.0, verdict="holding")
    return c.svc.ingest_run(uid, RunIn(**p), now=now)


def test_a_fresh_tester_from_consent_to_delete_everything(tmp_path, fakes):
    with TestClient(app_for(tmp_path, fakes)) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.svc.coach.proactive.weather = Wx()
        put(c, "/v1/me/timezone", {"zone_id": "Pacific/Auckland"})
        uid = uid_of(c)
        # 1 consent v2 -> chat is the canned reply; v3 (the coach sheet) -> chat works
        put(c, "/v1/me/consent", {"consent_version": 2})
        say(c, "hello", now=T0)
        assert fakes.coach_calls == []
        put(c, "/v1/me/consent", {"consent_version": 3})
        fakes.coach_queue = [coach_text("Good to hear from you.")]
        say(c, "how should I ease in?", now=T0 + timedelta(minutes=1))
        run_worker(c, T0 + timedelta(minutes=1, seconds=10))
        assert fakes.tg_texts()[-1] == "Good to hear from you."
        # 2 the memory sheet (v4): memory is readable only now (not an operator, not on the override)
        from companion.coach.ext import memory as mem
        with db.ro(c.svc.s.db_path) as con:
            assert mem.gate(c.svc, con, uid) is not None, "no memory at v3 for a tester"
        put(c, "/v1/me/consent", {"consent_version": 4})
        with db.ro(c.svc.s.db_path) as con:
            assert mem.gate(c.svc, con, uid) is None
        # 3 a first run: no briefing yet (one run is not a coach week; needs ~6 plain runs or an app plan); the debrief is proactive and NOT sent
        # (proactive keeps its own allowlist, empty for testers)
        fakes.coach_queue = [coach_text(SESSION)]
        upload(c, uid, now=T0 - timedelta(hours=1))
        c.svc.coach.drain(T0 + timedelta(seconds=30))
        assert c.svc.coach.proactive.tick(T0 + timedelta(hours=2)) == 0, "proactive is allowlist-only"
        sent_before = len(fakes.tg_texts())
        # 4 the per-runner cap: past it, chat stops with the budget line and nothing else is generated for them
        with db.tx(c.svc.s.db_path) as con:
            con.execute("INSERT INTO cost_ledger (ts, user_id, model, purpose, state, cost_usd) VALUES (?,?,?,?,?,?)",
                        (T0.strftime("%Y-%m-%dT%H:%M:%SZ"), uid, "m", "chat", "settled", 1.0))
        fakes.coach_queue = [coach_text("should not be said")]
        calls = len(fakes.coach_calls)
        say(c, "one more question", now=T0 + timedelta(minutes=5))
        run_worker(c, T0 + timedelta(minutes=5, seconds=10))
        assert len(fakes.coach_calls) == calls, "no model call past the runner's cap"
        assert len(fakes.tg_texts()) > sent_before, "the runner is told, not left on read"
        assert "should not be said" not in fakes.tg_texts()[-1]
        # 5 Delete everything: nothing with their id is left in any table
        assert c.delete("/v1/me", headers=auth(c.token)).status_code == 200
        con = sqlite3.connect(c.svc.s.db_path)
        try:
            for (t,) in con.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
                cols = [r[1] for r in con.execute(f'PRAGMA table_info("{t}")')]
                if "user_id" in cols:
                    n = con.execute(f'SELECT COUNT(*) FROM "{t}" WHERE user_id=?', (uid,)).fetchone()[0]
                    assert n == 0, f"{t} still holds {n} row(s) for the deleted runner"
            assert con.execute("SELECT COUNT(*) FROM users WHERE id=?", (uid,)).fetchone()[0] == 0
        finally:
            con.close()


def test_the_same_tester_gets_the_debrief_only_when_proactive_lists_them(tmp_path, fakes):
    with TestClient(app_for(tmp_path, fakes)) as c:
        c.svc = c.app.state.svc
        c.token = enrol(c)
        c.svc.coach.proactive.weather = Wx()
        put(c, "/v1/me/timezone", {"zone_id": "Pacific/Auckland"})
        uid = uid_of(c)
        put(c, "/v1/me/consent", {"consent_version": 3})
        with db.tx(c.svc.s.db_path) as con:
            con.execute("UPDATE users SET last_inbound_at=NULL")
        fakes.coach_queue = [coach_text(SESSION)]
        upload(c, uid, now=T0 - timedelta(hours=1))
        c.svc.coach.drain(T0 - timedelta(minutes=30))   # the first run also queues its briefing; proactive waits for it
        c.svc.s = c.svc.coach.s = c.svc.coach.proactive.s = dataclasses.replace(c.svc.s, coach_proactive_allowlist=frozenset({f"telegram:{OWNER}"}))
        fakes.coach_queue = [coach_text("Steady easy run, nicely done.")]
        assert c.svc.coach.proactive.tick(T0) == 1
        assert fakes.tg_texts()[-1] == "Steady easy run, nicely done."
