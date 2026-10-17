"""Phase A measurement: inbound_events (kind and time, no content), the trust and Sean Ellis questions, tombstones, the gate."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from companion import db, ops, scorecard
from companion.backup import backup, restore
from companion.measure import ELLIS_RUN_ID
from companion.timeutil import iso, now_utc
from conftest import OWNER, auth, enrol, post_tg, tg_callback, tg_update
from test_feedback import agree, say, sunday_card, tap_tell
from test_notes import SENTINEL, q, send_run, tap_note

_n = iter(range(300_000, 10**6))


@pytest.fixture
def tok(client):
    t = enrol(client)
    agree(client, t)
    return t


def events(client):
    return [(r["kind"]) for r in q(client, "SELECT kind FROM inbound_events ORDER BY id")]


def tap(client, card_id, action, ref=OWNER):
    row = q(client, "SELECT buttons_json FROM cards WHERE card_id=?", card_id)[0]
    i = [b["action"] for b in json.loads(row["buttons_json"])].index(action)
    assert post_tg(client, tg_callback(next(_n), f"{card_id}:{i}", ref)).status_code == 200


# --- inbound_events -----------------------------------------------------------------------------------------------

def test_each_kind_is_logged_with_no_content(client, fakes, tok):
    send_run(client, tok, "r1")
    say(client, "/feedback")                      # command
    say(client, f"{SENTINEL} my calf is sore")    # feedback
    say(client, "hello coach")                    # text (a fixed reply)
    tap_note(client, "r1")                        # tap
    say(client, "a note about the run")           # note
    assert events(client) == ["command", "feedback", "text", "tap", "note"]
    cols = [r[1] for r in sqlite3.connect(client.svc.s.db_path).execute("PRAGMA table_info(inbound_events)")]
    assert cols == ["id", "user_id", "kind", "ts"]
    dump = "\n".join(str(tuple(r)) for r in sqlite3.connect(client.svc.s.db_path).execute("SELECT * FROM inbound_events"))
    assert SENTINEL not in dump and "calf" not in dump and "hello coach" not in dump


def test_nothing_is_logged_before_consent_v2(client, fakes):
    t = enrol(client)                             # joined, but the app has not reported consent v2
    say(client, "hello")
    assert events(client) == []
    agree(client, t)
    say(client, "hello again")
    assert events(client) == ["text"]


def test_a_flooding_chat_is_not_logged_beyond_the_limiter(tmp_path, fakes):
    import httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from conftest import make_settings
    s = make_settings(tmp_path, rate_per_min=2)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        t = enrol(c)
        agree(c, t)
        for _ in range(6):
            say(c, "spam")
        assert len(events(c)) <= 2


def test_stop_resume_and_delete_commands(client, fakes, tok):
    say(client, "STOP")
    say(client, "hello while paused")             # a paused runner's texts are not counted
    say(client, "RESUME")
    assert events(client) == ["command"]          # only the STOP itself
    say(client, "DELETE")                         # the runner and their events are gone
    assert q(client, "SELECT COUNT(*) n FROM inbound_events")[0]["n"] == 0


def test_events_go_after_120_days_and_with_the_runner(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = now_utc()
    with db.tx(client.svc.s.db_path) as c:
        for days in (130, 119, 1):
            c.execute("INSERT INTO inbound_events (user_id, kind, ts) VALUES (?,?,?)", (uid, "tap", iso(now - timedelta(days=days))))
    client.svc.purge(now)
    assert q(client, "SELECT COUNT(*) n FROM inbound_events")[0]["n"] == 2
    assert client.delete("/v1/me", headers=auth(tok)).status_code == 200
    assert q(client, "SELECT COUNT(*) n FROM inbound_events")[0]["n"] == 0


def test_the_backup_leaves_events_out(client, fakes, tok, tmp_path):
    say(client, "hello")
    assert events(client) == ["text"]
    key = tmp_path / "k.key"
    key.write_bytes(b"k" * 32)
    enc = backup(client.svc.s.db_path, str(tmp_path / "bk"), str(key))
    restore(enc, str(tmp_path / "r.db"), str(key))
    assert sqlite3.connect(str(tmp_path / "r.db")).execute("SELECT COUNT(*) FROM inbound_events").fetchone()[0] == 0


def test_a_miniapp_open_is_one_event_per_half_hour(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = now_utc()
    client.svc.log_miniapp_open(uid, now)
    client.svc.log_miniapp_open(uid, now + timedelta(minutes=5))
    client.svc.log_miniapp_open(uid, now + timedelta(minutes=40))
    assert events(client) == ["miniapp_open", "miniapp_open"]


# --- trust question, the day after the recap ------------------------------------------------------------------------

SUNDAY = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
MONDAY = datetime(2026, 10, 12, 19, 40, tzinfo=timezone.utc)


def trust_card(client, fakes):
    """A recap on Sunday, then the trust question on Monday. Returns (trust card id, user id)."""
    recap_id, uid = sunday_card(client, fakes)
    assert client.svc.plan_trust(MONDAY) == 1
    client.svc.run_outbox(MONDAY + timedelta(seconds=1))
    return q(client, "SELECT card_id FROM cards WHERE kind='trust'")[0]["card_id"], uid


def test_the_recap_carries_no_trust_buttons_and_leaves_sundays_question_free(client, fakes, tok):
    card_id, uid = sunday_card(client, fakes)
    buttons = json.loads(q(client, "SELECT buttons_json FROM cards WHERE card_id=?", card_id)[0]["buttons_json"])
    assert [b["action"] for b in buttons] == ["fb:tell"]
    assert q(client, "SELECT COUNT(*) n FROM question_cap WHERE user_id=?", uid)[0]["n"] == 0   # the 19:05 shape check-in still fits
    assert client.svc.plan_trust(SUNDAY + timedelta(minutes=5)) == 0                            # not on the recap's own day


def test_trust_lands_the_day_after_the_recap_and_counts_as_that_days_question(client, fakes, tok):
    card_id, uid = trust_card(client, fakes)
    row = q(client, "SELECT buttons_json, body FROM cards WHERE card_id=?", card_id)[0]
    assert [b["action"] for b in json.loads(row["buttons_json"])] == ["trust:spot", "trust:mostly", "trust:not"]
    assert "last week" in row["body"] and "get you right" in row["body"]
    assert q(client, "SELECT slot FROM question_cap WHERE user_id=?", uid)[0]["slot"] == "trust"
    assert client.svc.plan_trust(MONDAY + timedelta(days=1)) == 0       # asked once per recap


def test_trust_skips_a_day_that_already_has_a_question_and_stops_after_the_window(client, fakes, tok):
    _, uid = sunday_card(client, fakes)
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO question_cap VALUES (?,?,?,?)", (uid, "2026-10-12", "evening", iso(MONDAY)))
    assert client.svc.plan_trust(MONDAY) == 0                           # Monday is taken
    assert client.svc.plan_trust(MONDAY + timedelta(days=1)) == 1       # Tuesday is the first free day
    with db.tx(client.svc.s.db_path) as c:
        c.execute("DELETE FROM outbox WHERE kind='trust'")
    assert client.svc.plan_trust(SUNDAY + timedelta(days=7, hours=-5)) == 0   # a week on: past the window, nothing sent


def test_no_trust_question_without_consent_v2_or_after_stop(client, fakes, tok):
    sunday_card(client, fakes)
    with db.tx(client.svc.s.db_path) as c:
        c.execute("UPDATE users SET checkin_consent=NULL")
    assert client.svc.plan_trust(MONDAY) == 0
    with db.tx(client.svc.s.db_path) as c:
        c.execute("UPDATE users SET checkin_consent=consent_version, paused=1")
    assert client.svc.plan_trust(MONDAY) == 0


def test_a_trust_tap_is_stored_as_a_fixed_option(client, fakes, tok):
    card_id, uid = trust_card(client, fakes)
    tap(client, card_id, "trust:mostly")
    recap_run = q(client, "SELECT run_id FROM cards WHERE kind='recap'")[0]["run_id"]
    assert [tuple(r) for r in q(client, "SELECT kind, ref, value FROM survey_answers")] == [("trust", recap_run, "mostly")]
    assert events(client)[-1] == "tap"
    tap(client, card_id, "trust:spot")            # a changed mind replaces, never adds
    assert [r["value"] for r in q(client, "SELECT value FROM survey_answers")] == ["spot"]


def test_a_bad_option_or_the_wrong_card_stores_nothing(client, fakes, tok):
    send_run(client, tok, "r1")
    run_card = q(client, "SELECT card_id FROM cards WHERE kind='run'")[0]["card_id"]
    with db.tx(client.svc.s.db_path) as c:        # forge: a trust button on a run card
        c.execute("UPDATE cards SET buttons_json=? WHERE card_id=?", (json.dumps([{"label": "x", "action": "trust:spot", "row": 0}]), run_card))
    tap(client, run_card, "trust:spot")
    card_id, _ = trust_card(client, None)
    with db.tx(client.svc.s.db_path) as c:
        c.execute("UPDATE cards SET buttons_json=? WHERE card_id=?", (json.dumps([{"label": "x", "action": "trust:wow", "row": 0}]), card_id))
    tap(client, card_id, "trust:wow")
    assert q(client, "SELECT COUNT(*) n FROM survey_answers")[0]["n"] == 0


# --- Sean Ellis ------------------------------------------------------------------------------------------------------

def joined_days_ago(client, days):
    """Joined `days` whole days (and a few hours) before at_local_noon()."""
    with db.tx(client.svc.s.db_path) as c:
        c.execute("UPDATE users SET consent_at=?, created_at=?", (iso(at_local_noon() - timedelta(days=days, hours=3)),) * 2)


def at_local_noon():
    return now_utc().replace(hour=19, minute=40, second=0, microsecond=0)


def test_ellis_is_asked_once_in_days_21_to_27_and_counts_as_the_days_question(client, fakes, tok):
    now = at_local_noon()
    for days, expect in ((10, 0), (20, 0), (28, 0), (22, 1)):
        joined_days_ago(client, days)
        assert client.svc.plan_ellis(now) == expect, days
    client.svc.run_outbox(now + timedelta(seconds=1))
    card = q(client, "SELECT card_id, buttons_json, body FROM cards WHERE kind='ellis'")[0]
    assert [b["action"] for b in json.loads(card["buttons_json"])] == ["ellis:very", "ellis:somewhat", "ellis:not", "ellis:stopped"]
    assert "went away tomorrow" in card["body"]
    assert q(client, "SELECT slot FROM question_cap")[0]["slot"] == "ellis"
    assert client.svc.plan_ellis(now + timedelta(days=1)) == 0       # never a second time
    tap(client, card["card_id"], "ellis:stopped")
    assert [tuple(r) for r in q(client, "SELECT kind, ref, value FROM survey_answers")] == [("ellis", ELLIS_RUN_ID, "stopped")]


def test_ellis_waits_for_a_day_without_another_question_and_needs_consent(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = at_local_noon()
    joined_days_ago(client, 22)
    local = now.date().isoformat()
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO question_cap VALUES (?,?,?,?)", (uid, local, "evening", iso(now)))
    assert client.svc.plan_ellis(now) == 0                           # today already had its question
    assert client.svc.plan_ellis(now + timedelta(days=1)) == 1       # tomorrow it can go
    with db.tx(client.svc.s.db_path) as c:
        c.execute("UPDATE users SET checkin_consent=NULL")
    assert client.svc.plan_ellis(now + timedelta(days=2)) == 0


def test_ellis_is_never_outside_waking_hours(client, fakes, tok):
    joined_days_ago(client, 22)
    assert client.svc.plan_ellis(now_utc().replace(hour=13, minute=0)) == 0


# --- tombstones and STOP --------------------------------------------------------------------------------------------

def test_delete_and_stop_leave_a_count_with_no_id(client, fakes, tok):
    say(client, "STOP")
    say(client, "STOP")                                              # already paused: not a second opt-out
    assert q(client, "SELECT SUM(n) n FROM stop_counts")[0]["n"] == 1
    say(client, "DELETE")
    rows = q(client, "SELECT week, n FROM deleted_tombstones")
    assert len(rows) == 1 and rows[0]["n"] == 1 and rows[0]["week"].count("-W") == 1
    t2 = enrol(client)
    assert client.delete("/v1/me", headers=auth(t2)).status_code == 200
    assert q(client, "SELECT SUM(n) n FROM deleted_tombstones")[0]["n"] == 2
    cols = [r[1] for r in sqlite3.connect(client.svc.s.db_path).execute("PRAGMA table_info(deleted_tombstones)")]
    assert cols == ["week", "n"]


def test_a_retention_delete_is_not_counted_as_an_opt_out(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    db.hard_delete_user(client.svc.s.db_path, uid)
    assert q(client, "SELECT COUNT(*) n FROM deleted_tombstones")[0]["n"] == 0


# --- scorecard -----------------------------------------------------------------------------------------------------

def card(client):
    con = scorecard.open_ro(client.svc.s.db_path)
    try:
        return scorecard.compute_scorecard(con)
    finally:
        con.close()


def test_engaged_uses_every_kind_and_replies_are_by_kind(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        for kind in ("tap", "tap", "note", "feedback", "command", "text", "miniapp_open"):
            c.execute("INSERT INTO inbound_events (user_id, kind, ts) VALUES (?,?,?)", (uid, kind, iso(now_utc())))
    wk = card(client)["testers"][0]["weeks"][-1]
    assert wk["events"] == {"tap": 2, "note": 1, "feedback": 1, "command": 1, "text": 1, "miniapp_open": 1}
    assert wk["replies"] == 4                                        # taps + notes + feedback only
    assert card(client)["testers"][0]["active_weeks"] == 1


def test_week_four_counts_a_miniapp_open_with_no_run(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    long_ago = now_utc() - timedelta(days=40)
    with db.tx(client.svc.s.db_path) as c:
        c.execute("UPDATE users SET created_at=?", (iso(long_ago),))
        c.execute("INSERT INTO inbound_events (user_id, kind, ts) VALUES (?,?,?)", (uid, "miniapp_open", iso(long_ago + timedelta(days=23))))
    assert card(client)["testers"][0]["week4_retained"] is True


def gate(sc, name):
    return next(g for g in sc["gate"] if g["signal"].startswith(name))


def test_the_gate_shows_counts_but_no_percentage_under_8_answers(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "trust", "recap:W1", "spot", iso(now_utc())))
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "trust", "recap:W2", "spot", iso(now_utc())))
    g = gate(card(client), "Trust: recap")
    assert (g["n"], g["N"], g["pct"], g["met"]) == (2, 2, None, None)
    text = scorecard.format_text(card(client))
    assert "Trust: recap says got me right (Spot on): 2/2 (needs 70% or more of answers)" in text


def test_the_gate_gives_a_percentage_and_verdict_from_8_answers(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        for i, v in enumerate(["spot"] * 5 + ["mostly"] * 2 + ["not"]):
            c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "trust", f"recap:W{i}", v, iso(now_utc())))
    sc = card(client)
    g = gate(sc, "Trust: recap")
    assert (g["n"], g["N"], g["pct"], g["met"]) == (5, 8, 62.5, False)
    u = gate(sc, "Cards useful")
    assert (u["n"], u["N"], u["pct"], u["met"]) == (7, 8, 87.5, True)
    assert gate(sc, "Trust: misreads")["n"] == 1
    assert sc["surveys"]["trust_answered_by"] == ["T1"]


def test_ellis_gate_and_optout_totals(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "ellis", "once", "very", iso(now_utc())))
        c.execute("INSERT INTO deleted_tombstones VALUES ('2026-W41', 2)")
        c.execute("INSERT INTO stop_counts VALUES ('2026-W41', 3)")
    sc = card(client)
    e = gate(sc, "Sean Ellis")
    assert (e["n"], e["N"], e["pct"]) == (1, 1, None)
    o = gate(sc, "Guard: opt-outs")
    assert (o["deleted_total"], o["stopped_total"]) == (2, 3)


def test_active_testers_need_a_real_run(client, fakes, tok):
    assert gate(card(client), "Coach-enrolled")["n"] == 0
    send_run(client, tok, "r1")
    g = gate(card(client), "Coach-enrolled")
    assert (g["n"], g["N"], g["met"]) == (1, 1, False)


def test_the_snapshot_is_written_with_t_numbers_only(client, fakes, tok, tmp_path):
    send_run(client, tok, "r1")
    out = []
    assert ops.main(client.svc.s, ["scorecard-snapshot", str(tmp_path / "snap")], out.append) == 0
    path = out[0]
    assert path.startswith(str(tmp_path / "snap")) and "scorecard-20" in path and path.endswith(".json")
    data = json.loads(open(path).read())
    assert data["testers"][0]["id"] == "T1" and data["gate"]
    blob = json.dumps(data)
    assert OWNER not in blob and q(client, "SELECT id FROM users")[0]["id"] not in blob
    assert ops.main(client.svc.s, ["scorecard-snapshot", str(tmp_path / "snap")], out.append) == 0   # same week: replaced
    assert len(list((tmp_path / "snap").glob("scorecard-*.json"))) == 1


def test_the_runner_can_see_their_own_events_and_answers(client, fakes, tok):
    say(client, "hello")
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "ellis", "once", "somewhat", iso(now_utc())))
    me = client.get("/v1/me", headers=auth(tok)).json()
    assert [a["kind"] for a in me["activity"]] == ["text"]
    assert me["survey_answers"][0]["value"] == "somewhat"


# --- review fixes: engaged kinds, replies window, cost spread, Ellis N, survey purge ---------------------------------

def _insert_events(client, uid, kinds, when):
    with db.tx(client.svc.s.db_path) as c:
        for k in kinds:
            c.execute("INSERT INTO inbound_events (user_id, kind, ts) VALUES (?,?,?)", (uid, k, iso(when)))


def test_commands_and_texts_do_not_make_a_week_engaged(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = now_utc()
    _insert_events(client, uid, ["command", "text"], now)
    assert card(client)["testers"][0]["active_weeks"] == 0
    _insert_events(client, uid, ["miniapp_open"], now)
    assert card(client)["testers"][0]["active_weeks"] == 1


def test_ellis_n_leaves_out_stopped_users_and_reports_them(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "ellis", "once", "stopped", iso(now_utc())))
    e = gate(card(client), "Sean Ellis")
    assert (e["n"], e["N"], e["stopped"]) == (0, 0, 1)


def test_replies_median_starts_at_the_first_logged_event_or_consent(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    now = now_utc()
    _insert_events(client, uid, ["tap"] * 3, now - timedelta(days=14))     # first logged event: deploy
    send_run(client, tok, "r1")
    sc = card(client)
    t = sc["testers"][0]
    assert t["replies_from"] is not None
    assert t["replies_from"] >= scorecard._week_start(now - timedelta(days=14)).strftime("%Y-%m-%d")


def test_survey_answers_are_purged_with_the_ops_audit_at_the_test_end_date(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "ellis", "once", "very", iso(now_utc())))
    end = client.svc.s.test_end_date
    day = datetime.fromisoformat(end).replace(tzinfo=timezone.utc)
    client.svc.purge(day - timedelta(days=1))
    assert q(client, "SELECT COUNT(*) n FROM survey_answers")[0]["n"] == 1
    client.svc.purge(day + timedelta(hours=1))
    assert q(client, "SELECT COUNT(*) n FROM survey_answers")[0]["n"] == 0


def test_ops_survey_purge_needs_yes(client, fakes, tok):
    uid = q(client, "SELECT id FROM users")[0]["id"]
    with db.tx(client.svc.s.db_path) as c:
        c.execute("INSERT INTO survey_answers VALUES (?,?,?,?,?)", (uid, "ellis", "once", "very", iso(now_utc())))
    out = []
    assert ops.main(client.svc.s, ["survey", "purge"], out.append) == 2
    assert q(client, "SELECT COUNT(*) n FROM survey_answers")[0]["n"] == 1
    assert ops.main(client.svc.s, ["survey", "purge", "--yes"], out.append) == 0 and out[-1] == "deleted 1 survey answers"
