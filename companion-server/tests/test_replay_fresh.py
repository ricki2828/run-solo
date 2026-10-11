"""replay --fresh: remove only what a replay created, then start again from item 1. Real uploads are never touched."""
from datetime import date, timedelta

import httpx
import pytest

from companion import db, replay
from companion.replay import ReplayError, dry_run, fresh_apply, load_facts
from companion.service import RunIn, Service
from test_replay import HISTORY, REAL_NOW, UID, Env, fact, texts


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def rows(e: Env, q: str, *args):
    with db.ro(e.s.db_path) as c:
        return c.execute(q, args).fetchall()


def real_run(e: Env, rid_n: int = 90, minutes_ago: int = 50):
    """A run the app uploaded for real, after the replay, with its live card."""
    start = REAL_NOW - timedelta(minutes=minutes_ago)
    r = RunIn.model_validate(fact(rid_n, date(2026, 10, 1), "00:00", start_utc=start.strftime("%Y-%m-%dT%H:%M:%S.000Z")))
    live = Service(e.s, httpx.Client(transport=httpx.MockTransport(e.fakes.handler)))
    assert live.ingest_run(UID, r, REAL_NOW)["status"] == "accepted"
    live.run_outbox(REAL_NOW)
    with db.tx(e.s.db_path) as c:
        c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)",
                  (UID, r.run_id, "felt strong", iso(REAL_NOW)))
    return r


def iso(dt):
    from companion.timeutil import iso as _iso
    return _iso(dt)


def test_a_fresh_rerun_sends_the_whole_sequence_again(env):
    env.replayer().run()
    first = texts(env)
    n_first = len(env.fakes.tg)
    assert n_first > 6
    # without --fresh the second pass is silent: everything dedupes against the first (the problem being fixed)
    assert replay.reset(env.s)[0] == 0
    assert env.replayer().run() == "done" and len(env.fakes.tg) == n_first
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert len(plan.created) == len(HISTORY) and not plan.real
    assert rows(env, "SELECT COUNT(*) FROM runs")[0][0] == 0 and rows(env, "SELECT COUNT(*) FROM cards")[0][0] == 0
    assert env.replayer().run() == "done"
    assert len(env.fakes.tg) == 2 * n_first
    assert texts(env) == first          # the same cards, in the same order, from item 1


def test_a_real_upload_survives_a_fresh_start(env):
    env.replayer().run()
    real = real_run(env)
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)",
                  (UID, "t01", "replay-day note", iso(REAL_NOW)))
    # the app later uploads one of the replayed runs for real: it is real from then on
    taken = RunIn.model_validate({**HISTORY[2], "locality": "Bishan"})
    assert env.svc.ingest_run(UID, taken, REAL_NOW)["status"] == "updated"
    live_card = rows(env, "SELECT card_id FROM cards WHERE run_id=?", real.run_id)[0][0]

    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert real.run_id not in plan.created and "t03" not in plan.created
    assert sorted(x[0] for x in rows(env, "SELECT run_id FROM runs")) == sorted(["t03", real.run_id])
    assert rows(env, "SELECT 1 FROM cards WHERE card_id=?", live_card)
    assert rows(env, "SELECT note FROM run_notes")[0][0] == "felt strong"      # the replayed run's note went with it
    assert [x[0] for x in rows(env, "SELECT run_id FROM run_notes")] == [real.run_id]
    assert rows(env, "SELECT locality FROM runs WHERE run_id='t03'")[0][0] == "Bishan"
    assert not rows(env, "SELECT 1 FROM cards WHERE run_id='t03' AND kind='run'")  # its replay card went; run 't03' stays
    env.replayer().run()                                                           # and a new replay sends that card again
    assert rows(env, "SELECT 1 FROM cards WHERE run_id='t03' AND kind='run' AND sent_at IS NOT NULL")
    assert rows(env, "SELECT last_run_utc FROM users")[0][0] is not None


def test_it_works_when_the_replay_marks_are_gone_by_telling_virtual_from_real_timestamps(env):
    env.replayer().run()
    real = real_run(env)
    assert replay.reset(env.s)[0] == 0                      # wipes replay_runs, as it did on the live database
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert len(plan.created) == len(HISTORY)
    assert [x[0] for x in rows(env, "SELECT run_id FROM runs")] == [real.run_id]
    assert rows(env, "SELECT 1 FROM cards WHERE run_id=?", real.run_id)


def test_it_refuses_when_it_cannot_tell_replayed_runs_from_real_ones(env):
    live = Service(env.s, httpx.Client(transport=httpx.MockTransport(env.fakes.handler)))
    for h in HISTORY[:3]:  # real uploads of runs that are also in the facts folder
        live.ingest_run(UID, RunIn.model_validate(h), REAL_NOW)
    with pytest.raises(ReplayError, match="cannot tell"):
        fresh_apply(env.s, UID, load_facts(env.folder))
    assert rows(env, "SELECT COUNT(*) FROM runs")[0][0] == 3     # nothing was removed


def test_it_refuses_while_a_replay_is_running(env):
    env.replayer().prepare()
    # (the check runs on the real clock: make the heartbeat fresh by it)
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE replay_state SET heartbeat_at=?", (iso(replay.now_utc()),))
    with pytest.raises(ReplayError, match="running"):
        fresh_apply(env.s, UID, load_facts(env.folder))


def test_dry_run_shows_what_would_be_removed_and_removes_nothing(env):
    env.replayer().run()
    real_run(env)
    before = [rows(env, f"SELECT COUNT(*) FROM {t}")[0][0] for t in ("runs", "cards", "outbox", "run_notes")]
    lines: list[str] = []
    assert dry_run(env.s, str(env.folder), 300, None, fresh=True, out=lines.append) == 0
    assert lines[0].startswith("Fresh start would remove: 8 replayed runs") and "1 real uploads kept" in lines[0]
    assert lines[1].startswith("Dry run:") and int(lines[1].split()[2]) > 6   # the schedule starts over from item 1
    assert [rows(env, f"SELECT COUNT(*) FROM {t}")[0][0] for t in ("runs", "cards", "outbox", "run_notes")] == before
