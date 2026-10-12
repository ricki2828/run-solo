import json
import sqlite3
from datetime import datetime, timedelta, timezone

from companion import db
from companion.scorecard import compute_scorecard, format_text, main

NOW = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc)  # a Wednesday; week starts Mon 2026-10-12


def z(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def user(c, uid, ref, created):
    c.execute("INSERT INTO users (id, channel, chat_ref, chat_name, created_at) VALUES (?,?,?,?,?)",
              (uid, "telegram", ref, "Secret Name " + uid, z(created)))


def run(c, uid, rid, at, feel=None, real=1):
    c.execute("INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m,"
              " feel, received_at, real_upload) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
              (uid, rid, z(at), z(at), 0, "UTC", "easy", 1800, 5000, feel, z(at), real))


def card(c, uid, cid, sent, answered=None):
    c.execute("INSERT INTO cards (card_id, user_id, kind, headline, body, buttons_json, source, created_at,"
              " sent_at, answered_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
              (cid, uid, "recap", "h", "b", "[]", "t", z(NOW), z(sent) if sent else None, z(answered) if answered else None))


def build(tmp_path):
    p = str(tmp_path / "sc.db")
    db.init(p)
    c = db.connect(p)
    old = NOW - timedelta(days=40)
    user(c, "u-old", "999111", old)
    user(c, "u-new", "999222", NOW - timedelta(days=2))
    run(c, "u-old", "a", old + timedelta(days=22))
    run(c, "u-old", "b", NOW - timedelta(days=1), feel="hard")
    run(c, "u-old", "r", NOW - timedelta(days=1), real=0)  # replay-created row, ignored
    card(c, "u-old", "c1", NOW - timedelta(days=1), answered=NOW - timedelta(hours=20))
    card(c, "u-old", "c2", None)  # never sent
    card(c, "u-new", "c3", NOW - timedelta(days=1))
    c.execute("INSERT INTO inbound_seen (msg_id, user_id, ts) VALUES ('m1','u-old',?)", (z(NOW - timedelta(days=1)),))
    c.execute("INSERT INTO inbound_seen (msg_id, user_id, ts) VALUES ('m2',NULL,?)", (z(NOW - timedelta(days=1)),))
    c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES ('u-old','b','SECRET NOTE',?)",
              (z(NOW - timedelta(days=1)),))
    c.execute("INSERT INTO llm_calls (ts, model, provider, cost_usd, outcome) VALUES (?,?,?,?,?)",
              (z(NOW - timedelta(days=1)), "m", "p", 0.30, "ok"))
    c.execute("INSERT INTO llm_calls (ts, model, provider, cost_usd, outcome) VALUES (?,?,?,?,?)",
              (z(NOW - timedelta(days=30)), "m", "p", 9.0, "ok"))
    c.commit()
    c.close()
    return p


def score(p, weeks=2):
    c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
    try:
        return compute_scorecard(c, now=NOW, weeks=weeks)
    finally:
        c.close()


def test_counts_and_retention(tmp_path):
    sc = score(build(tmp_path))
    old, new = sc["testers"]
    assert (old["id"], new["id"]) == ("T1", "T2")
    assert sc["week_starts"] == ["2026-10-05", "2026-10-12"]
    assert old["weeks"][1] == dict(runs=1, cards=1, taps=1, feel=1, replies=1, notes=1)
    assert new["weeks"][1]["cards"] == 1 and new["weeks"][1]["runs"] == 0
    assert old["week4_retained"] is True   # run on day 22
    assert new["week4_retained"] is None   # too new to judge
    assert old["active_weeks"] == 2
    assert sc["week4"] == {"retained": 1, "eligible": 1}


def test_cost_allocation(tmp_path):
    sc = score(build(tmp_path))
    assert sc["llm_cost_usd_total"] == [0.0, 0.3]  # the 30-day-old call is outside both weeks
    assert [t["llm_cost_usd_alloc"][1] for t in sc["testers"]] == [0.15, 0.15]


def test_no_identifiers_and_read_only(tmp_path, capsys):
    p = build(tmp_path)
    assert main(["--db", p, "--weeks", "2"]) == 0
    text = capsys.readouterr().out
    assert main(["--db", p, "--format", "json"]) == 0
    js = capsys.readouterr().out
    json.loads(js)
    for s in (text, js):
        for bad in ("999111", "999222", "Secret Name", "SECRET NOTE", "u-old", "u-new"):
            assert bad not in s
    assert len(text) < 4000
    assert "T1" in text and "Week-4 retention" in text


def test_empty_db(tmp_path):
    p = str(tmp_path / "e.db")
    db.init(p)
    c = db.connect(p)
    sc = compute_scorecard(c, now=NOW)
    assert sc["testers"] == []
    assert "Week-4 retention: 0/0" in format_text(sc)
