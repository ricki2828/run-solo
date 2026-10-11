"""Coach replay controls and hold: stop, abort, takeover, bounded hold, live uploads, caps at the virtual clock."""
import json
from datetime import date, datetime, timedelta, timezone

import httpx
import pytest

from companion import db, replay
from companion.channels import ChannelError
from companion.convo import touches as cv_touches
from companion.replay import Replayer, ReplayError, load_facts
from companion.service import RunIn, Service
from companion.timeutil import iso
from test_replay import HISTORY, REAL_NOW, UID, Env, fact, write_facts

UTC = timezone.utc


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def sql(e: Env, q: str, *args):
    with db.ro(e.s.db_path) as c:
        return c.execute(q, args).fetchall()


def status(e: Env) -> str:
    return sql(e, "SELECT status FROM replay_state")[0][0]


# --- F1: stop, abort, takeover -------------------------------------------------------------------------

def test_abort_while_the_process_runs_releases_nothing_and_never_floods_the_chat(env):
    """The reviewer's 13+4 case: abort during a run used to mark 'done' while the process carried on, and the live
    worker then sent its queued virtual-past items. Now abort asks the process to stop and waits for it."""
    refused: list[tuple[int, str]] = []

    def on_item(item):
        if item.n == 2:
            refused.append(replay.abort(env.s, wait_s=0, now=lambda: REAL_NOW))

    r = env.replayer(on_item=on_item)
    assert r.run() == "stopped"                      # it saw 'stopping' and stopped by itself
    assert refused[0][0] == 4 and "not stopped" in refused[0][1]
    assert status(env) == "stopped"                  # not 'done': nothing was released while it ran
    assert len(env.fakes.tg) == 2
    env.svc.run_outbox(REAL_NOW + timedelta(hours=1))  # the live worker: still holding the user
    assert len(env.fakes.tg) == 2
    code, _ = replay.abort(env.s, wait_s=0, now=lambda: REAL_NOW)  # the process is gone now
    assert code == 0 and status(env) == "done"
    env.svc.run_outbox(REAL_NOW + timedelta(hours=1))  # released: its past items were dropped, no flood
    assert len(env.fakes.tg) == 2


def test_stop_always_asks_even_when_the_heartbeat_looks_stale(env):
    def on_item(item):
        if item.n == 2:
            with db.tx(env.s.db_path) as c:  # a long model call or back-off: no beat for minutes
                c.execute("UPDATE replay_state SET heartbeat_at=?", (iso(REAL_NOW - timedelta(hours=1)),))
            assert replay.stop(env.s, REAL_NOW) == "stopping after the current message"

    assert env.replayer(on_item=on_item).run() == "stopped"
    assert len(env.fakes.tg) == 2 and status(env) == "stopped"


def test_a_stopped_or_aborted_row_ends_the_loop_and_done_is_never_overwritten(env):
    def on_item(item):
        if item.n == 2:
            with db.tx(env.s.db_path) as c:
                c.execute("UPDATE replay_state SET status='done'")  # e.g. an abort from another shell

    assert env.replayer(on_item=on_item).run() == "stopped"
    assert status(env) == "done" and len(env.fakes.tg) == 2


def test_a_second_driver_that_takes_over_stops_the_first(env):
    taken: list[Replayer] = []

    def on_item(item):
        if item.n == 2:  # the first process stopped beating long ago, so a new one may take the row
            with db.tx(env.s.db_path) as c:
                c.execute("UPDATE replay_state SET heartbeat_at=?", (iso(REAL_NOW - timedelta(hours=1)),))
            second = env.replayer()
            second.prepare()
            taken.append(second)

    first = env.replayer(on_item=on_item)
    assert first.run() == "stopped"
    assert status(env) == "running"  # the first one did not touch the second's row
    assert sql(env, "SELECT driver FROM replay_state")[0][0] == taken[0].token
    assert len(env.fakes.tg) == 2


def test_a_second_driver_is_refused_while_a_fresh_heartbeat_exists(env):
    env.replayer().prepare()
    with pytest.raises(ReplayError, match="already running"):
        env.replayer().prepare()


def test_the_heartbeat_beats_inside_the_failure_backoff_sleep(env):
    beats: list[str] = []
    r = env.replayer()
    real_beat = r._beat
    r._beat = lambda: (beats.append("b"), real_beat())[1]
    r.prepare()
    r._sleep(30)
    assert len(beats) == 30


def test_a_refused_abort_message_and_reset_after_an_abort(env):
    env.replayer().run(max_items=2)
    assert replay.abort(env.s, wait_s=0, now=lambda: REAL_NOW)[0] == 0
    with pytest.raises(ReplayError, match="replay-reset"):
        env.replayer().run()
    assert replay.reset(env.s)[0] == 0
    assert sql(env, "SELECT COUNT(*) FROM replay_state")[0][0] == 0
    assert replay.reset(env.s)[0] == 1


# --- F2: the hold is bounded and visible -------------------------------------------------------------------

def test_a_stopped_replay_releases_the_user_after_48_hours_without_a_flood(env):
    env.replayer().run(max_items=2)
    sent = len(env.fakes.tg)
    env.svc.tick(REAL_NOW + timedelta(hours=47))
    assert status(env) == "stopped" and len(env.fakes.tg) == sent
    env.svc.tick(REAL_NOW + timedelta(hours=49))
    assert status(env) == "done"
    env.svc.run_outbox(REAL_NOW + timedelta(hours=49))
    assert len(env.fakes.tg) == sent  # its virtual-past queue was skipped on release, not sent


def test_a_running_replay_with_a_dead_process_releases_the_user_after_15_minutes(env):
    env.replayer().prepare()  # heartbeat at REAL_NOW, then the process is killed
    env.svc.tick(REAL_NOW + timedelta(minutes=10))
    assert status(env) == "running"
    env.svc.tick(REAL_NOW + timedelta(minutes=16))
    assert status(env) == "done"


def test_health_shows_a_held_user_and_alerts_on_a_stalled_replay(env, client):
    env.replayer().run(max_items=1)
    later = REAL_NOW + timedelta(hours=3)
    assert env.svc.replay_held(REAL_NOW + timedelta(hours=1)) == 1
    assert env.svc.overdue_count(later) > 0          # stopped, items overdue: the health watch sees it
    with db.tx(env.s.db_path) as c:                   # a live process, beating a moment ago, is not an alert
        c.execute("UPDATE replay_state SET status='running', heartbeat_at=?", (iso(later - timedelta(minutes=1)),))
    assert env.svc.overdue_count(later) == 0
    assert "replay_held" in client.get("/healthz").json()


# --- P2: caps at the virtual clock, live uploads, an old run uploaded early ------------------------------------

def test_state_dated_after_the_virtual_now_is_invisible_to_it(env):
    past, future = datetime(2026, 9, 20, tzinfo=UTC), datetime(2026, 9, 25, tzinfo=UTC)
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)", (UID, "touch", "milestone|x", iso(future)))
        c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)", (UID, "variant", "v1", iso(future)))
        c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)", (UID, "feel_ref", "t01", iso(future)))
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (UID, "goal", "10k", iso(future)))
    env.replayer().prepare()
    for i, d in enumerate((22, 24)):
        env.svc.ingest_run(UID, RunIn.model_validate(fact(70 + i, date(2026, 9, d), "06:30", feel="hard")),
                           datetime(2026, 9, d, 9, tzinfo=UTC))
    with db.ro(env.s.db_path) as c:
        u = env.svc._usage(c, UID, past)
        assert u.touches == [] and "v1" not in u.variants and u.feel_refs == set()
        assert env.svc._memory_get(c, UID, past) == {}
        assert env.svc._feel_counts(c, UID, past) == {}   # both runs start after `past`
        assert env.svc._feel_counts(c, UID, datetime(2026, 9, 30, tzinfo=UTC)) == {"hard": 2}
        assert env.svc._memory_get(c, UID, future + timedelta(seconds=1)) == {"goal": "10k"}
        assert env.svc._usage(c, UID, future).touches[0][1] == "milestone"


def test_a_real_run_uploaded_during_a_replay_goes_out_live_and_unprefixed(env):
    env.replayer().run(max_items=2)                    # the replay is holding the user
    sent = len(env.fakes.tg)
    start = REAL_NOW - timedelta(minutes=50)
    live = RunIn.model_validate(fact(90, date(2026, 10, 1), "00:00", "easy", 7.0, 355,
                                     start_utc=start.strftime("%Y-%m-%dT%H:%M:%S.000Z")))
    assert env.svc.ingest_run(UID, live, REAL_NOW)["status"] == "accepted"
    live_worker = Service(env.s, httpx.Client(transport=httpx.MockTransport(env.fakes.handler)))  # the service process
    live_worker.run_outbox(REAL_NOW)
    assert len(env.fakes.tg) == sent + 1
    text = [b["text"] for m, b in env.fakes.tg if m == "sendMessage"][-1]
    assert not text.startswith("Replay")
    assert not sql(env, "SELECT 1 FROM replay_items WHERE card_id IN (SELECT card_id FROM cards WHERE run_id='t90')")
    # the replay carries on from where it was and never jumps its clock to the live item
    r = env.replayer()
    assert r.run() == "done"
    assert all(b["text"].startswith("Replay") for m, b in env.fakes.tg[sent + 1:] if m == "sendMessage")


def test_an_old_run_uploaded_before_the_replay_reaches_it_keeps_its_replay_card(env):
    old = RunIn.model_validate(HISTORY[4])             # t05, Mon 21 Sep: stale on upload, so no card is queued
    assert env.svc.ingest_run(UID, old, REAL_NOW)["status"] == "stored"
    assert not sql(env, "SELECT 1 FROM outbox")
    env.replayer().run()
    assert sql(env, "SELECT COUNT(*) FROM cards WHERE run_id='t05' AND kind='run' AND sent_at IS NOT NULL")[0][0] == 1
    assert sql(env, "SELECT inserted FROM replay_runs WHERE run_id='t05'")[0][0] == 0


# --- P3 ----------------------------------------------------------------------------------------------------

def test_a_failed_send_is_not_counted_as_an_item(env):
    inner = env.svc.channels["telegram"]

    class Flaky:
        name = "telegram"
        failed = 0

        def __getattr__(self, k):
            return getattr(inner, k)

        def send_card(self, ref, card, **kw):
            if not self.failed:
                self.failed = 1
                raise ChannelError("telegram: http 502")
            return inner.send_card(ref, card, **kw)

    r = env.replayer(channel=Flaky())
    assert r.run() == "done"
    assert len(r.items) == len(sql(env, "SELECT 1 FROM replay_items")) == len(env.cards())


def test_replay_rows_are_purged_a_month_after_the_replay_is_done(env):
    env.replayer().run()
    assert status(env) == "done"
    env.svc.purge(REAL_NOW + timedelta(days=10))
    assert sql(env, "SELECT COUNT(*) FROM replay_state")[0][0] == 1
    env.svc.purge(REAL_NOW + timedelta(days=40))
    for t in ("replay_state", "replay_runs", "replay_items"):
        assert sql(env, f"SELECT COUNT(*) FROM {t}")[0][0] == 0, t


def test_the_cli_gate_needs_a_fresh_live_flag(env, monkeypatch, capsys):
    from companion.cli import main
    monkeypatch.setenv("COMPANION_DB", env.s.db_path)
    monkeypatch.setenv("COMPANION_PEPPER", "p" * 32)
    monkeypatch.setenv("COMPANION_ALLOWED_IDS", f"telegram:{__import__('conftest').OWNER}")
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('replay_aware_at', ?)",
                  (iso(datetime.now(UTC) - timedelta(hours=2)),))
    assert main(["replay", str(env.folder)]) == 3  # written two hours ago: the live worker is not running this code now
    assert "not running code that knows about replays" in capsys.readouterr().out


def test_a_bad_facts_file_names_the_field_never_the_value(tmp_path):
    bad = dict(HISTORY[0], locality="Secret Suburb " * 10)
    folder = write_facts(tmp_path / "f", [bad])
    with pytest.raises(ReplayError) as e:
        load_facts(folder)
    assert "locality" in str(e.value) and "Secret" not in str(e.value)
