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


def test_it_works_on_a_database_from_before_the_run_marks_by_timestamps(env):
    env.replayer().run()
    real = real_run(env)
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE runs SET real_upload=NULL")          # rows written before the column existed
        c.execute("DELETE FROM replay_rows")                    # and before row tagging
    replay.reset(env.s)
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert len(plan.created) == len(HISTORY) and plan.cut      # untagged history rows: bounded by the first real upload
    assert [x[0] for x in rows(env, "SELECT run_id FROM runs")] == [real.run_id]
    assert "this database predates row tagging" in plan.summary()


def test_a_takeover_survives_reset_and_repeated_fresh_starts(env):
    """replay -> the app uploads t03 -> --fresh -> replay -> replay-reset -> --fresh: t03 and its note are still there."""
    env.replayer().run()
    taken = RunIn.model_validate({**HISTORY[2], "locality": "Bishan"})
    assert env.svc.ingest_run(UID, taken, REAL_NOW)["status"] == "updated"
    row = rows(env, "SELECT real_upload, received_at FROM runs WHERE run_id='t03'")[0]
    assert row["real_upload"] == 1 and row["received_at"] == iso(REAL_NOW)   # the run itself says it is real
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)", (UID, "t03", "mine", iso(REAL_NOW)))
    fresh_apply(env.s, UID, load_facts(env.folder))
    assert [x[0] for x in rows(env, "SELECT run_id FROM runs")] == ["t03"]
    env.replayer().run()                                       # t03 is adopted by the new replay (re-marked in replay_runs)
    assert replay.reset(env.s)[0] == 0                         # and the marks are wiped
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert "t03" in plan.real and "t03" not in plan.created
    assert [x[0] for x in rows(env, "SELECT run_id FROM runs")] == ["t03"]
    assert rows(env, "SELECT note FROM run_notes WHERE run_id='t03'")[0][0] == "mine"


def test_only_rows_the_replay_wrote_are_removed_not_the_live_workers(env):
    ticks: list[str] = []

    def on_item(item):  # Ricki answers the question on a replayed card, as the live webhook records it
        if item.kind == "question" and not ticks:
            ticks.append(item.card_id)
            assert env.tap(item.card_id, "ans:")

    env.replayer(on_item=on_item).run()
    assert ticks and rows(env, "SELECT COUNT(*) FROM memory")[0][0] == 1
    real = real_run(env)                                         # live card: live convo_log/msglog rows, untagged
    with db.tx(env.s.db_path) as c:                              # a live answer, as a live tap would write it
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (UID, "surface", "road", iso(REAL_NOW)))
        c.execute("INSERT INTO quota (user_id, key, created_at) VALUES (?,?,?)", (UID, "sugg:live:1", iso(REAL_NOW)))
    live_log = rows(env, "SELECT COUNT(*) FROM convo_log WHERE ts >= ?", iso(REAL_NOW))[0][0]
    live_msg = rows(env, "SELECT COUNT(*) FROM msglog WHERE ts >= ?", iso(REAL_NOW))[0][0]
    assert live_log and live_msg
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert plan.counts["memory"] == 1 and plan.counts["quota"] > 0        # the replay's tap and caps, not the live ones
    assert [tuple(x) for x in rows(env, "SELECT key, value FROM memory")] == [("surface", "road")]
    assert [x[0] for x in rows(env, "SELECT key FROM quota")] == ["sugg:live:1"]
    assert rows(env, "SELECT COUNT(*) FROM convo_log")[0][0] == live_log
    assert rows(env, "SELECT COUNT(*) FROM msglog")[0][0] == live_msg
    assert rows(env, "SELECT 1 FROM cards WHERE run_id=?", real.run_id)


def replay_with_a_tapped_answer(env):
    taps: list[str] = []

    def on_item(item):
        if item.kind == "question" and not taps:
            taps.append(item.card_id)
            assert env.tap(item.card_id, "ans:")

    env.replayer(on_item=on_item).run()
    key = rows(env, "SELECT key FROM memory")[0][0]
    assert rows(env, "SELECT 1 FROM replay_rows WHERE tbl='memory' AND rid=?", key)
    return key


def test_a_live_answer_to_a_key_the_replay_answered_is_no_longer_the_replays(env):
    key = replay_with_a_tapped_answer(env)
    live = Service(env.s, httpx.Client(transport=httpx.MockTransport(env.fakes.handler)))
    with db.tx(env.s.db_path) as c:                      # Ricki answers the same question on a live card
        live._memory_set(c, UID, key, "live-answer", REAL_NOW)
    assert not rows(env, "SELECT 1 FROM replay_rows WHERE tbl='memory' AND rid=?", key)
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert plan.counts["memory"] == 0
    assert [tuple(x) for x in rows(env, "SELECT key, value FROM memory")] == [(key, "live-answer")]


def test_a_live_row_that_reuses_a_purged_rowid_does_not_inherit_the_tag(env):
    replay_with_a_tapped_answer(env)
    top = rows(env, "SELECT MAX(rowid) FROM quota")[0][0]
    with db.tx(env.s.db_path) as c:                      # the purge took the newest replay quota row ...
        c.execute("DELETE FROM quota WHERE rowid=?", (top,))
        c.execute("INSERT INTO quota (user_id, key, created_at) VALUES (?,?,?)", (UID, "live:key", iso(REAL_NOW)))
    assert rows(env, "SELECT rowid FROM quota WHERE key='live:key'")[0][0] == top   # ... and a live row took its rowid
    fresh_apply(env.s, UID, load_facts(env.folder))
    assert [x[0] for x in rows(env, "SELECT key FROM quota")] == ["live:key"]


def test_purge_drops_the_tags_of_rows_that_are_gone(env):
    key = replay_with_a_tapped_answer(env)
    with db.tx(env.s.db_path) as c:
        c.execute("DELETE FROM memory WHERE key=?", (key,))      # e.g. the 8-week niggle expiry
    env.svc.purge(REAL_NOW + timedelta(hours=1))
    assert not rows(env, "SELECT 1 FROM replay_rows WHERE tbl='memory'")
    live = Service(env.s, httpx.Client(transport=httpx.MockTransport(env.fakes.handler)))
    with db.tx(env.s.db_path) as c:
        live._memory_set(c, UID, key, "later", REAL_NOW)
    fresh_apply(env.s, UID, load_facts(env.folder))
    assert rows(env, "SELECT value FROM memory WHERE key=?", key)[0][0] == "later"


def test_no_tags_after_the_tags_were_purged_means_nothing_replay_made_not_an_old_database(env):
    env.replayer().run()
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (UID, "x", "live", iso(REAL_NOW)))
    env.svc.purge(REAL_NOW + timedelta(days=31))           # the replay is done and a month old: its tags go
    assert not rows(env, "SELECT 1 FROM replay_rows")
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert "EVERYTHING" not in plan.summary() and not plan.everything
    assert rows(env, "SELECT value FROM memory WHERE key='x'")[0][0] == "live"


def test_an_old_database_with_no_real_upload_says_everything_goes(env):
    env.replayer().run()
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE runs SET real_upload=NULL")
        c.execute("DELETE FROM replay_rows")
    plan = fresh_apply(env.s, UID, load_facts(env.folder))
    assert plan.everything and "EVERYTHING" in plan.summary()
    assert not rows(env, "SELECT 1 FROM convo_log")


def test_a_done_queue_row_whose_card_was_purged_is_not_queued_again(env):
    live = Service(env.s, httpx.Client(transport=httpx.MockTransport(env.fakes.handler)))
    live.ingest_run(UID, RunIn.model_validate(HISTORY[4]), REAL_NOW)         # t05: stale on upload, real, no queue row
    with db.tx(env.s.db_path) as c:                                          # it had a card once; the 30-day purge took it
        c.execute("INSERT INTO outbox (user_id, kind, due_at, state, dedupe_key, ref) VALUES (?,?,?,?,?,?)",
                  (UID, "run_card", "2026-08-01T00:00:00Z", "done", f"card:{UID}:t05", "t05"))
    env.replayer().run()
    assert not rows(env, "SELECT 1 FROM cards WHERE run_id='t05'")


def test_it_refuses_when_it_cannot_tell_replayed_runs_from_real_ones(env):
    live = Service(env.s, httpx.Client(transport=httpx.MockTransport(env.fakes.handler)))
    for h in HISTORY[:3]:  # old rows with no mark: real uploads of runs that are also in the facts folder
        live.ingest_run(UID, RunIn.model_validate(h), REAL_NOW)
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE runs SET real_upload=NULL")
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
    assert lines[0].startswith("Fresh start would remove: 8 replayed runs, ") and "cards" in lines[0]
    assert lines[0].endswith("; 1 real upload kept")                                  # plain words, not table names
    assert lines[1].startswith("Dry run:") and int(lines[1].split()[2]) > 6   # the schedule starts over from item 1
    assert [rows(env, f"SELECT COUNT(*) FROM {t}")[0][0] for t in ("runs", "cards", "outbox", "run_notes")] == before
