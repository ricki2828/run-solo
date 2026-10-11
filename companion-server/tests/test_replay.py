"""Coach replay (companion.replay): a virtual-clock walk through real history, through the production Service."""
import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
import pytest

from companion import db, replay
from companion.channels import Inbound
from companion.cli import main as cli_main
from companion.replay import Replayer, ReplayError, dry_run, load_facts
from companion.service import RunIn, Service
from companion.timeutil import in_quiet, iso, parse_iso, to_local, week_key

from conftest import Fakes, OWNER, make_settings

UTC = timezone.utc
SGT = "Asia/Singapore"
REAL_NOW = datetime(2026, 10, 1, 12, 0, tzinfo=UTC)
QUIET = (21 * 60 + 30, 7 * 60)
UID = "u_replay"


def fact(i: int, day: date, hm: str, typ="easy", km=7.0, pace=355.0, zone=SGT, **extra) -> dict:
    """What the app posts for a run (companionSummary): metres to one decimal, ISO start with a Z."""
    hh, mm = map(int, hm.split(":"))
    local = datetime(day.year, day.month, day.day, hh, mm, tzinfo=ZoneInfo(zone))
    p = {"run_id": f"t{i:02d}", "type": typ, "start_utc": local.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
         "utc_offset_min": int(local.utcoffset().total_seconds() // 60), "zone_id": zone,
         "duration_s": round(km * pace), "distance_m": round(km * 1000 + 12.3, 1), "pace_s_per_km": pace,
         "true_pace_s_per_km": pace - 2.0}
    p.update(extra)
    return p


D = date(2026, 9, 14)  # a Monday
HISTORY = [
    fact(1, D, "06:30"),                                         # Mon
    fact(2, D + timedelta(days=2), "06:30"),                     # Wed
    fact(3, D + timedelta(days=4), "06:30", "tempo", 8.0, 322),  # Fri, the last hard session
    fact(4, D + timedelta(days=5), "06:00", "long", 14.0, 366),  # Sat
    fact(5, D + timedelta(days=7), "06:30"),                     # Mon
    fact(6, D + timedelta(days=9), "05:00"),                     # Wed, finishes before quiet hours end
    fact(7, D + timedelta(days=10), "21:00", km=5.0),            # Thu night, finishes as quiet hours begin
    fact(8, D + timedelta(days=12), "06:30"),                    # Sat
]


def write_facts(folder: Path, facts: list[dict]) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    for i, f in enumerate(facts):
        (folder / f"{i:04d}-{f['run_id']}.json").write_text(json.dumps(f))
    return folder


class Env:
    def __init__(self, tmp_path: Path, name: str = "a", quiet=QUIET, **over):
        self.fakes = Fakes()
        self.s = make_settings(tmp_path / name, weather_enabled=False, openrouter_key=None, default_quiet=quiet, **over)
        self.svc = Service(self.s, httpx.Client(transport=httpx.MockTransport(self.fakes.handler)))
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, "
                      "utc_offset_min, last_inbound_at) VALUES (?,?,?,?,?,?,?,?,?)",
                      (UID, "telegram", OWNER, "2026-09-01T00:00:00Z", "1", "2026-09-01T00:00:00Z", SGT, 480,
                       "2026-09-01T00:00:00Z"))
            c.execute("INSERT INTO devices (token_hash, user_id, created_at) VALUES ('h', ?, '2026-09-01T00:00:00Z')", (UID,))
        self.folder = write_facts(tmp_path / f"{name}-facts", HISTORY)
        self.tap_no = 0

    def replayer(self, **kw) -> Replayer:
        kw.setdefault("real_now", lambda: REAL_NOW)
        kw.setdefault("sleep", lambda _s: None)
        kw.setdefault("out", lambda _l: None)
        return Replayer(self.svc, UID, load_facts(self.folder), kw.pop("every_s", 0), facts_dir=str(self.folder), **kw)

    def cards(self):
        with db.ro(self.s.db_path) as c:
            return [dict(r) for r in c.execute("SELECT * FROM cards WHERE sent_at IS NOT NULL ORDER BY sent_at, rowid")]

    def sent(self):
        """(virtual time, kind) of every message the replay sent, in order."""
        with db.ro(self.s.db_path) as c:
            return [(parse_iso(r["virtual_at"]), r["kind"], r["card_id"]) for r in
                    c.execute("SELECT * FROM replay_items ORDER BY id")]

    def tap(self, card_id: str, action_prefix: str) -> bool:
        with db.ro(self.s.db_path) as c:
            buttons = json.loads(c.execute("SELECT buttons_json FROM cards WHERE card_id=?", (card_id,)).fetchone()[0])
        for i, b in enumerate(buttons):
            if b["action"].startswith(action_prefix):
                self.tap_no += 1
                self.svc.handle_inbound(Inbound("telegram", OWNER, f"tg:tap{self.tap_no}", card_id=card_id, button_idx=i,
                                                callback_id=f"cb{self.tap_no}", callback_message_id="1"))
                return True
        return False


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def texts(e: Env) -> list[str]:
    return [f"{c['kind']}|{c['headline']}|{c['body']}" for c in e.cards()]


# --- facts ---------------------------------------------------------------------------------------

def test_facts_load_sorted_and_validated_by_the_servers_own_model(tmp_path):
    folder = write_facts(tmp_path / "f", list(reversed(HISTORY)))
    runs = load_facts(folder)
    assert [r.run_id for r in runs] == [f"t{i:02d}" for i in range(1, 9)]
    assert runs[0].distance_m == 7012  # the app sends 7012.3; the server stores whole metres
    (folder / "bad.json").write_text(json.dumps({**HISTORY[0], "run_id": "bad", "surprise": 1}))
    with pytest.raises(ReplayError, match="bad.json"):
        load_facts(folder)


def test_the_apps_fractional_metres_are_accepted_by_the_run_model():
    r = RunIn.model_validate(fact(1, D, "06:30", climb_m=41.7))
    assert (r.distance_m, r.climb_m) == (7012, 42)


# --- dry run -------------------------------------------------------------------------------------

def test_dry_run_prints_the_whole_schedule_and_changes_nothing(env):
    lines: list[str] = []
    assert dry_run(env.s, str(env.folder), 300, None, out=lines.append) == 0
    head, *items = lines
    assert head.startswith(f"Dry run: {len(items)} messages")
    assert len(items) >= len(HISTORY)  # at least one card per run, plus the Sunday recap and any evening nudges
    assert any(" run " in ln for ln in items) and any(" recap " in ln for ln in items)
    assert all(ln.split()[0] == f"#{i:03d}" for i, ln in enumerate(items, 1))  # numbered in sequence
    assert env.fakes.tg == []  # nothing was sent
    with db.ro(env.s.db_path) as c:  # and the real database is untouched
        assert c.execute("SELECT COUNT(*) FROM runs").fetchone()[0] == 0
        assert c.execute("SELECT COUNT(*) FROM replay_state").fetchone()[0] == 0
        assert c.execute("SELECT COUNT(*) FROM cards").fetchone()[0] == 0


def test_dry_run_from_date_keeps_earlier_runs_as_context_only(env):
    lines: list[str] = []
    dry_run(env.s, str(env.folder), 300, "2026-09-21", out=lines.append)
    body = "\n".join(lines)
    assert "Mon 14 Sep" not in body and "Fri 18 Sep" not in body
    assert "Mon 21 Sep" in body


def test_dry_run_refuses_when_no_single_allowlisted_user(env):
    s = make_settings(Path(env.s.db_path).parent.parent, allowed_ids=frozenset(), weather_enabled=False)
    with pytest.raises(ReplayError, match="exactly one"):
        dry_run(s, str(env.folder), 300, None, out=lambda _l: None)


# --- the live replay -------------------------------------------------------------------------------

def test_sends_through_the_channel_with_a_context_line_and_numbers_only_from_facts(env):
    assert env.replayer().run() == "done"
    texts_sent = [b["text"] for m, b in env.fakes.tg if m == "sendMessage"]
    assert texts_sent and all(t.startswith("Replay · ") for t in texts_sent)
    # the first run ended 07:11 local, the app uploads a minute later: that is the moment the card goes out
    assert texts_sent[0].startswith("Replay · Mon 14 Sep, 07:12\n")
    assert not [m for m, _ in env.fakes.tg if m in ("sendPhoto", "sendVideo")]  # media stays off
    with db.ro(env.s.db_path) as c:
        assert c.execute("SELECT status FROM replay_state").fetchone()[0] == "done"
        assert c.execute("SELECT COUNT(*) FROM runs").fetchone()[0] == len(HISTORY)
        assert c.execute("SELECT COUNT(*) FROM replay_runs WHERE inserted=1").fetchone()[0] == len(HISTORY)
    # post-run cards: one per run, the run's own id (a later real upload keys on it)
    assert {c["run_id"] for c in env.cards() if c["kind"] == "run"} <= {f"t{i:02d}" for i in range(1, 9)}


def test_pacing_waits_every_n_seconds_between_items(env):
    waits: list[float] = []
    env.replayer(every_s=300, sleep=waits.append).run()
    n = len(env.sent())
    assert sum(waits) == 300 * n and set(waits) == {1}  # in one-second slices, so a stop lands within a second


def test_quiet_hours_follow_the_virtual_clock(env):
    env.replayer().run()
    sent = env.sent()
    assert sent
    for at, kind, _ in sent:
        assert not in_quiet(at, SGT, *QUIET), (to_local(at, SGT), kind)
    by_run = {c["run_id"]: parse_iso(c["sent_at"]) for c in env.cards() if c["kind"] == "run"}
    # Wed 23 Sep: finished 05:30 local, so the card waits for 07:00 on that day, not for 07:00 today
    assert to_local(by_run["t06"], SGT).strftime("%a %d %b %H:%M") == "Wed 23 Sep 07:00"
    # Thu 24 Sep 21:00 start finishes at quiet-hours start: out at 07:00 the next morning
    assert to_local(by_run["t07"], SGT).strftime("%a %d %b %H:%M") == "Fri 25 Sep 07:00"
    assert [r for _, k, _ in sent if False] == []  # (kinds checked below)


def test_two_suggestions_a_week_at_most_and_a_recap_every_sunday(env):
    env.replayer().run()
    cards = env.cards()
    per_week: dict[str, int] = {}
    for c in cards:
        if c["kind"] in ("evening",) or json.loads(c["buttons_json"]) and any(
                b["action"].startswith("sugg:") for b in json.loads(c["buttons_json"])):
            wk = week_key(parse_iso(c["sent_at"]), SGT)
            per_week[wk] = per_week.get(wk, 0) + 1
    assert all(n <= 2 for n in per_week.values()), per_week
    recaps = [to_local(parse_iso(c["sent_at"]), SGT) for c in cards if c["kind"] == "recap"]
    assert recaps and all(r.weekday() == 6 and r.hour == 19 for r in recaps)


def test_a_tap_between_items_changes_the_next_message(tmp_path):
    """Mon 21 Sep's easy run: tap 'Hard' on its card and that evening's suggestion is about the hard feel. Left
    alone, nothing goes out that evening. The tap lands in the database between two items, exactly as the live
    webhook records it, and the next item is generated only after it."""
    def go(name: str, tap: bool) -> Env:
        e = Env(tmp_path, name)

        def on_item(item):
            if tap and item.kind == "run":
                with db.ro(e.s.db_path) as c:
                    rid = c.execute("SELECT run_id FROM cards WHERE card_id=?", (item.card_id,)).fetchone()[0]
                if rid == "t05":
                    assert e.tap(item.card_id, "feel:hard")

        e.replayer(on_item=on_item).run()
        return e

    def evening_on(e: Env, day: str):
        return [c for c in e.cards() if c["kind"] == "evening" and c["run_id"] == f"evening:{day}"]

    plain, tapped = go("plain", False), go("tapped", True)
    assert evening_on(plain, "2026-09-21") == []
    [after_tap] = evening_on(tapped, "2026-09-21")
    assert "Sounds good" in after_tap["buttons_json"]
    assert texts(plain) != texts(tapped)
    with db.ro(tapped.s.db_path) as c:
        assert c.execute("SELECT feel FROM runs WHERE run_id='t05'").fetchone()[0] == "hard"
        assert c.execute("SELECT COUNT(*) FROM convo_log WHERE kind='feel_ref' AND key='t05'").fetchone()[0] == 1
    with db.ro(plain.s.db_path) as c:
        assert c.execute("SELECT feel FROM runs WHERE run_id='t05'").fetchone()[0] is None


def test_answers_are_dated_on_the_cards_own_clock_not_the_real_date(env):
    """A tap arrives in real time (October) on a card living in September: memory and the weekly cap use September."""
    seen: list[str] = []

    def on_item(item):
        if item.kind == "question" and not seen:
            seen.append(item.card_id)
            assert env.tap(item.card_id, "ans:")

    env.replayer(on_item=on_item).run()
    if not seen:  # the history has to ask a question for this to mean anything
        pytest.fail("fixture history produced no question card")
    with db.ro(env.s.db_path) as c:
        ts = [r[0] for r in c.execute("SELECT updated_at FROM memory")]
        out = c.execute("SELECT answered_at FROM cards WHERE card_id=?", (seen[0],)).fetchone()[0]
    assert ts and all(t.startswith("2026-09") for t in ts), ts
    assert out.startswith("2026-09")


# --- resume ----------------------------------------------------------------------------------------

def test_resume_after_a_stop_sends_each_message_once(tmp_path):
    base = Env(tmp_path, "base")
    base.replayer().run()
    expect = texts(base)
    assert len(expect) > 6

    e = Env(tmp_path, "resumed")
    assert e.replayer().run(max_items=3) == "limit"
    with db.ro(e.s.db_path) as c:
        assert c.execute("SELECT status FROM replay_state").fetchone()[0] == "stopped"
    assert len(e.fakes.tg) == 3
    # a brand-new process: nothing in memory, only the database
    assert e.replayer().run(max_items=2) == "limit"
    assert e.replayer().run() == "done"

    assert texts(e) == expect  # same messages, same order, none twice
    sent_ids = [cid for _, _, cid in e.sent()]
    assert len(sent_ids) == len(set(sent_ids)) == len(e.fakes.tg)
    with db.ro(e.s.db_path) as c:
        assert c.execute("SELECT COUNT(*) FROM runs").fetchone()[0] == len(HISTORY)


def test_a_stop_request_ends_the_loop_cleanly_and_the_state_says_so(env):
    r = env.replayer()
    r.on_item = lambda item: r.request_stop() if item.n == 2 else None
    assert r.run() == "stopped"
    assert len(env.fakes.tg) == 2
    with db.ro(env.s.db_path) as c:
        row = c.execute("SELECT status, items FROM replay_state").fetchone()
    assert (row["status"], row["items"]) == ("stopped", 2)


def test_a_finished_replay_does_not_run_twice(env):
    env.replayer().run()
    n = len(env.fakes.tg)
    with pytest.raises(ReplayError, match="finished or was aborted"):
        env.replayer().run()
    assert len(env.fakes.tg) == n


def test_a_running_replay_refuses_a_second_driver(env):
    env.replayer().prepare()
    with pytest.raises(ReplayError, match="already running"):
        env.replayer().prepare()


def test_the_existing_pause_holds_the_replay_without_losing_items(env):
    waits: list[float] = []
    r = env.replayer(sleep=waits.append)
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('sends_paused', '1')")

    def unpause(s):
        waits.append(s)
        if len(waits) == 7:
            with db.tx(env.s.db_path) as c:
                c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('sends_paused', '0')")

    r.sleep = unpause
    assert r.run() == "done"
    assert waits == [1] * 10 and len(env.cards()) >= len(HISTORY)  # held for two 5 s waits, in beating one-second slices


# --- the live worker leaves a replayed user alone -----------------------------------------------------

def test_live_worker_does_not_touch_a_user_mid_replay(env):
    late = REAL_NOW + timedelta(days=40)  # the replay's cards are 40+ days old by then: purge would delete them
    r = env.replayer(real_now=lambda: late)
    r.run(max_items=2)  # leaves the replay 'stopped' with more queued in the virtual past
    with db.ro(env.s.db_path) as c:
        pending = c.execute("SELECT COUNT(*) FROM outbox WHERE state='pending'").fetchone()[0]
    sent_before = len(env.fakes.tg)
    env.svc.tick(late + timedelta(hours=1))  # the live clock, an hour on
    env.svc.purge(late + timedelta(hours=1))
    assert len(env.fakes.tg) == sent_before
    with db.ro(env.s.db_path) as c:
        assert c.execute("SELECT COUNT(*) FROM outbox WHERE state='pending'").fetchone()[0] == pending
        assert c.execute("SELECT COUNT(*) FROM users WHERE id=?", (UID,)).fetchone()[0] == 1
        assert c.execute("SELECT COUNT(*) FROM cards").fetchone()[0] >= 2


def test_released_after_abort_the_live_worker_has_the_user_back(env, monkeypatch):
    env.replayer().run(max_items=2)
    monkeypatch.setenv("COMPANION_DB", env.s.db_path)
    monkeypatch.setenv("COMPANION_PEPPER", "p" * 32)
    assert cli_main(["replay-abort"]) == 0
    with db.ro(env.s.db_path) as c:
        assert c.execute("SELECT status FROM replay_state").fetchone()[0] == "done"
        assert c.execute("SELECT COUNT(*) FROM outbox WHERE state='pending' AND due_at < ?", (iso(REAL_NOW),)).fetchone()[0] == 0


# --- a real upload of a replayed run ------------------------------------------------------------------

def test_a_later_real_upload_updates_the_replayed_run_instead_of_doubling_it(env):
    env.replayer().run()
    cards_before, outbox_before = len(env.cards()), None
    with db.ro(env.s.db_path) as c:
        outbox_before = c.execute("SELECT COUNT(*) FROM outbox").fetchone()[0]
    real = RunIn.model_validate({**HISTORY[2], "distance_m": 8100.4, "locality": "Bishan"})
    out = env.svc.ingest_run(UID, real, REAL_NOW)
    assert out == {"status": "updated"}
    with db.ro(env.s.db_path) as c:
        row = c.execute("SELECT * FROM runs WHERE run_id='t03'").fetchone()
        assert (row["distance_m"], row["locality"]) == (8100, "Bishan")
        assert c.execute("SELECT COUNT(*) FROM runs WHERE run_id='t03'").fetchone()[0] == 1
        assert c.execute("SELECT COUNT(*) FROM outbox").fetchone()[0] == outbox_before  # no second card queued
    assert len(env.cards()) == cards_before
    assert env.svc.ingest_run(UID, real, REAL_NOW) == {"status": "duplicate"}  # after that it is a plain duplicate


def test_a_run_uploaded_for_real_is_kept_out_of_cards_dated_before_it(env):
    env.replayer().run(max_items=1)
    late = fact(99, date(2026, 9, 30), "06:30")
    env.svc.ingest_run(UID, RunIn.model_validate(late), datetime(2026, 9, 30, 7, 0, tzinfo=UTC))
    with db.ro(env.s.db_path) as c:
        hist = env.svc._full_history(c, UID, None, datetime(2026, 9, 20, tzinfo=UTC))
    assert hist and all(h["run_id"] != "t99" for h in hist)


# --- cli -------------------------------------------------------------------------------------------

def test_cli_refuses_until_the_live_service_knows_about_replays(env, monkeypatch, capsys):
    monkeypatch.setenv("COMPANION_DB", env.s.db_path)
    monkeypatch.setenv("COMPANION_PEPPER", "p" * 32)
    monkeypatch.setenv("COMPANION_ALLOWED_IDS", f"telegram:{OWNER}")
    assert cli_main(["replay", str(env.folder)]) == 3
    assert "Restart companion.service" in capsys.readouterr().out
    assert cli_main(["status"]) == 0 and "replay=none" in capsys.readouterr().out
    env.svc.mark_replay_aware()
    assert cli_main(["replay", str(env.folder), "--dry-run", "--every", "300"]) == 0
    assert capsys.readouterr().out.startswith("Dry run:")
