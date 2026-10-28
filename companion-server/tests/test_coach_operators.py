"""COMPANION_COACH_OPERATORS: who is exempt from the per-runner monthly cap and the daily message limit (never the shared
ceiling), with a fallback to COMPANION_COACH_MEMORY_OVERRIDE while OPERATORS is unset. Memory stays on its own override."""
from __future__ import annotations

import dataclasses
import logging
from datetime import datetime, timedelta, timezone

from companion import db
from companion.config import Settings
from companion.coach import chat as coach_chat

from conftest import coach_text
from test_coach_chat import run_worker, say, uid_of
from test_coach_open import client, consent, sent, start, _now_iso

P = {"COMPANION_PEPPER": "p" * 20}


def env(**kw):
    return Settings.from_env({**P, **kw})


def test_operators_parse_and_default_to_unset():
    assert env().coach_operators is None
    assert env(COMPANION_COACH_OPERATORS="u_a, u_b").coach_operators == frozenset({"u_a", "u_b"})
    assert env(COMPANION_COACH_OPERATORS="-").coach_operators == frozenset(), "an explicit empty list: nobody"


def test_unset_operators_fall_back_to_the_memory_override_with_one_warning(caplog):
    with caplog.at_level(logging.WARNING, logger="companion"):
        s = env(COMPANION_COACH_MEMORY_OVERRIDE="u_ricki")
    assert s.is_operator("u_ricki") and not s.is_operator("u_other")
    assert sum("COMPANION_COACH_OPERATORS is unset" in r.message for r in caplog.records) == 1


def test_no_warning_when_neither_or_when_operators_are_set(caplog):
    with caplog.at_level(logging.WARNING, logger="companion"):
        env()
        env(COMPANION_COACH_OPERATORS="u_ricki", COMPANION_COACH_MEMORY_OVERRIDE="u_ricki")
    assert not [r for r in caplog.records if "OPERATORS" in r.message]


def test_set_operators_win_over_the_memory_override():
    s = env(COMPANION_COACH_OPERATORS="u_ricki", COMPANION_COACH_MEMORY_OVERRIDE="u_other")
    assert s.is_operator("u_ricki") and not s.is_operator("u_other"), "memory override no longer exempts anyone from the caps"
    assert s.coach_memory_override == frozenset({"u_other"}), "memory keeps its own list"


def _arm(c, ops, override=frozenset()):
    uid = uid_of(c)
    s = dataclasses.replace(c.svc.s, coach_operators=None if ops is None else frozenset(ops), coach_memory_override=frozenset(override))
    c.svc.s = c.svc.coach.s = c.svc.writer.s = s
    return uid


def _over_user_cap(c, uid):
    with db.tx(c.svc.s.db_path) as con:
        # llm_calls counts toward the runner's month but not the Auckland-day USD cap, so this is safe on the 1st before 11:00 UTC
        con.execute("INSERT INTO llm_calls (ts, user_id, model, cost_usd, outcome) VALUES (?,?,?,?,?)",
                    (datetime.now(timezone.utc).strftime("%Y-%m-01T00:00:00Z"), uid, "m", 3.5, "ok"))


def _two_messages(c, fakes):
    t = datetime.now(timezone.utc)
    for i in range(2):
        fakes.coach_queue = [coach_text(f"ok {i}")]
        say(c, f"hello {i}", now=t + timedelta(minutes=i))
        run_worker(c, now=t + timedelta(minutes=i, seconds=10))
    return t


def test_an_operator_is_exempt_from_user_month_and_the_daily_message_limit(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_monthly_cap_usd=5.0, coach_card_reserve_usd=0.0, coach_daily_msgs=1)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = _arm(c, {uid_of(c)})
        _over_user_cap(c, uid)
        assert c.svc.writer._blocked(uid) is None
        _two_messages(c, fakes)
        assert sent(fakes)[-1] == "ok 1"


def test_the_operator_is_still_under_the_shared_ceiling(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_monthly_cap_usd=5.0, coach_card_reserve_usd=0.0, coach_daily_msgs=1)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = _arm(c, {uid_of(c)})
        t = _two_messages(c, fakes)
        with db.tx(c.svc.s.db_path) as con:
            con.execute("INSERT INTO cost_ledger (ts, user_id, model, purpose, state, cost_usd) VALUES (?,?,?,?,?,?)",
                        (_now_iso(), "someone", "m", "chat", "settled", 5.0))
        say(c, "again", now=t + timedelta(minutes=5))
        run_worker(c, now=t + timedelta(minutes=5, seconds=10))
        assert sent(fakes)[-1] == coach_chat.BUDGET


def test_a_non_operator_is_capped_on_both(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_monthly_cap_usd=5.0, coach_card_reserve_usd=0.0, coach_daily_msgs=1)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = _arm(c, {"u_somebody_else"})
        _over_user_cap(c, uid)
        assert c.svc.writer._blocked(uid) == "user_cap"
        fakes.coach_queue = [coach_text("never")]
        t = datetime.now(timezone.utc)
        say(c, "hello", now=t)
        run_worker(c, now=t + timedelta(seconds=10))
        assert sent(fakes)[-1] == coach_chat.USER_MONTH
        say(c, "hello again", now=t + timedelta(minutes=1))
        run_worker(c, now=t + timedelta(minutes=1, seconds=10))
        assert sent(fakes)[-1] == coach_chat.DAILY_CAP and fakes.coach_calls == []


def test_the_fallback_path_exempts_the_memory_override_when_operators_are_unset(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_monthly_cap_usd=5.0, coach_card_reserve_usd=0.0, coach_daily_msgs=1)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = uid_of(c)
        _arm(c, None, {uid})
        _over_user_cap(c, uid)
        assert c.svc.writer._blocked(uid) is None
        _two_messages(c, fakes)
        assert sent(fakes)[-1] == "ok 1"


def test_a_memory_override_alone_stops_exempting_once_operators_are_set(tmp_path, fakes):
    tc, app = client(tmp_path, fakes, coach_monthly_cap_usd=5.0, coach_card_reserve_usd=0.0, coach_daily_msgs=1)
    with tc as c:
        start(c, app)
        consent(c, 3)
        uid = uid_of(c)
        _arm(c, {"u_ricki"}, {uid})
        _over_user_cap(c, uid)
        assert c.svc.writer._blocked(uid) == "user_cap"


def test_operator_entries_that_are_not_user_ids_warn(caplog):
    with caplog.at_level(logging.WARNING, logger="companion"):
        s = env(COMPANION_COACH_OPERATORS="u_ricki, telegram:123")
    assert s.is_operator("u_ricki")
    assert sum("telegram:123" in r.message and "not user ids" in r.message for r in caplog.records) == 1
