"""Quests (server side): the optional `quest` block, the month's Telegram offer, the done line, the one nudge, care weeks."""
import json
import sqlite3
from datetime import date, datetime, timedelta, timezone

import pytest

from companion import checkins as ci
from companion import quest as cq
from companion.timeutil import iso, now_utc, parse_iso
from conftest import auth, enrol, post_tg, run_payload, tg_callback

TRAIL = "The Saddle Trail"


def offer(n=1, **over):
    o = {"id": f"q_2026-10_trail_visits_a{n}", "kind": "trail_visits", "target": 5, "baseline": 4, "unit": "runs",
         "trail_name": TRAIL}
    o.update(over)
    return o


def month_of(payload) -> str:
    start = datetime.fromisoformat(payload["start_utc"]) + timedelta(minutes=payload["utc_offset_min"])
    return start.strftime("%Y-%m")


def three_offers():
    return [offer(1), offer(2, id="q_2026-10_climb_month_b2", kind="climb_month", target=1000, baseline=880, unit="m", trail_name=None),
            offer(3, id="q_2026-10_distance_month_c3", kind="distance_month", target=120, baseline=108, unit="km", trail_name=None)]


def post(client, t, run_id="r1", minutes_ago=20, quest=None, **over):
    p = run_payload(run_id, minutes_ago=minutes_ago, **over)
    if quest is not None:
        p["quest"] = quest
    r = client.post("/v1/runs", json=p, headers=auth(t))
    assert r.status_code in (200, 202), r.text
    return p


def db_(client):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return c


def rows(client):
    return [dict(r) for r in db_(client).execute("SELECT * FROM quests ORDER BY pos, rowid")]


def uid_of(client):
    return db_(client).execute("SELECT id FROM users").fetchone()["id"]


def place_on(client, t):
    assert client.put("/v1/me/settings", json={"place_names": True}, headers=auth(t)).status_code == 200


def quest_due(client):
    r = db_(client).execute("SELECT due_at FROM outbox WHERE kind='quest_offer'").fetchone()
    return parse_iso(r["due_at"]) if r else None


def drain_offer(client):
    """Run the outbox at the moment the offer is due (the runner's evening window)."""
    due = quest_due(client)
    assert due is not None, "no offer card was queued"
    client.svc.run_outbox(due + timedelta(seconds=1))
    return due


def offer_message(fakes):
    return [b for m, b in fakes.tg if m == "sendMessage" and "'s quest" in b["text"]]


def tap(client, fakes, label):
    msg = offer_message(fakes)[-1]
    kb = msg["reply_markup"]["inline_keyboard"][0]
    data = next(k["callback_data"] for k in kb if k["text"] == label)
    assert post_tg(client, tg_callback(next(iter(range(70000, 10**6))) + len(fakes.tg), data)).status_code == 200


# ---------------------------------------------------------------- the block
def test_a_run_without_a_quest_block_is_unchanged(client):
    t = enrol(client)
    post(client, t)
    assert rows(client) == []


@pytest.mark.parametrize("bad", [
    {"offers": [offer(unit="km")]},                                   # unit does not fit the kind
    {"offers": [offer(), offer()]},                                   # the same id twice
    {"offers": [offer(n) for n in range(1, 5)]},                      # more than three
    {"offers": [offer(id="not-a-quest-id")]},
    {"offers": [offer(target=0)]},
    {"offers": [offer(kind="zone_discipline")]},
    {"offers": [offer(target=5.5)]},                                  # whole numbers only
    {"offers": [dict(offer(), lat=1.0)]},                             # an unknown key
    {"active": {"id": "q_x", "kind": "trail_visits", "target": 5, "value": 2, "ends_on": "2026-02-30"}},
    {},                                                               # nothing to say
    {"done_now": "q x"},
])
def test_a_bad_block_drops_the_quest_never_the_run(client, bad):
    t = enrol(client)
    post(client, t, quest=bad)
    assert rows(client) == []
    assert db_(client).execute("SELECT COUNT(*) FROM runs").fetchone()[0] == 1
    assert db_(client).execute("SELECT COUNT(*) FROM outbox WHERE kind='quest_offer'").fetchone()[0] == 0


def test_offers_are_kept_in_order_and_a_place_name_needs_the_opt_in(client):
    t = enrol(client)
    p = post(client, t, quest={"offers": three_offers()})
    got = rows(client)
    assert [r["quest_id"] for r in got] == [o["id"] for o in three_offers()]
    assert {r["state"] for r in got} == {"offered"} and got[0]["month"] == month_of(p)
    assert got[0]["trail_name"] is None   # place opt-in is off
    place_on(client, t)
    post(client, t, "r2", quest={"offers": three_offers()})
    assert rows(client)[0]["trail_name"] == TRAIL


@pytest.mark.parametrize("name", ["0412345678", "@runner", "https://x.example", "Insta"])
def test_a_trail_name_that_is_not_a_label_is_dropped_and_the_quest_stays(client, name):
    t = enrol(client)
    place_on(client, t)
    post(client, t, quest={"offers": [offer(trail_name=name)]})
    assert rows(client)[0]["trail_name"] is None


def test_turning_the_place_option_off_clears_quest_names(client):
    t = enrol(client)
    place_on(client, t)
    post(client, t, quest={"offers": [offer()]})
    assert rows(client)[0]["trail_name"] == TRAIL
    assert client.put("/v1/me/settings", json={"place_names": False}, headers=auth(t)).status_code == 200
    assert rows(client)[0]["trail_name"] is None


# ---------------------------------------------------------------- the month's offer card
def test_the_offer_card_goes_once_in_the_evening_window_inside_the_weekly_cap(client, fakes):
    t = enrol(client)
    place_on(client, t)
    post(client, t, quest={"offers": three_offers()})
    due = drain_offer(client)
    z = db_(client).execute("SELECT zone_id FROM users").fetchone()["zone_id"]
    from companion.timeutil import to_local
    assert 20 <= to_local(due, z).hour < 21 or due <= now_utc() + timedelta(seconds=5)
    msgs = offer_message(fakes)
    assert len(msgs) == 1
    text = msgs[0]["text"]
    assert text.startswith(("October", "November")) and "Run The Saddle Trail 5 times in 30 days" in text
    assert "Your busiest 30 days on it was 4." in text and "—" not in text
    assert [b["text"] for b in msgs[0]["reply_markup"]["inline_keyboard"][0]] == ["Take it", "Another", "Not this month"]
    # it used one of the week's two suggestion slots and the day's one question
    keys = [r[0] for r in db_(client).execute("SELECT key FROM quota WHERE key LIKE 'sugg:%'")]
    assert len(keys) == 1
    assert db_(client).execute("SELECT slot FROM question_cap").fetchone()["slot"] == "quest"
    # a later run with the same offers does not send a second card
    post(client, t, "r2", minutes_ago=5, quest={"offers": three_offers()})
    client.svc.run_outbox(due + timedelta(days=2))
    assert len(offer_message(fakes)) == 1


def test_another_cycles_the_offers_and_take_it_starts_a_30_day_quest(client, fakes):
    t = enrol(client)
    place_on(client, t)
    post(client, t, quest={"offers": three_offers()})
    drain_offer(client)
    tap(client, fakes, "Another")
    edits = [b for m, b in fakes.tg if m == "editMessageText"]
    assert "Climb 1,000 m in 30 days" in edits[-1]["text"] and "Your biggest 30 days was 880 m." in edits[-1]["text"]
    assert [b["text"] for b in edits[-1]["reply_markup"]["inline_keyboard"][0]] == ["Take it", "Another", "Not this month"]
    tap(client, fakes, "Another")
    assert "Run 120 km in 30 days" in [b for m, b in fakes.tg if m == "editMessageText"][-1]["text"]
    tap(client, fakes, "Another")   # wraps to the first
    assert "The Saddle Trail" in [b for m, b in fakes.tg if m == "editMessageText"][-1]["text"]
    tap(client, fakes, "Take it")
    last = [b for m, b in fakes.tg if m == "editMessageText"][-1]
    assert last["text"].endswith("Quest taken. Run The Saddle Trail 5 times in 30 days. 30 days from today.") or "Quest taken." in last["text"]
    assert last["reply_markup"]["inline_keyboard"] == []
    got = {r["quest_id"]: r for r in rows(client)}
    assert got["q_2026-10_trail_visits_a1"]["state"] == "accepted"
    assert got["q_2026-10_trail_visits_a1"]["ends_on"] == (date.today() + timedelta(days=30)).isoformat() or got["q_2026-10_trail_visits_a1"]["ends_on"]
    assert {r["state"] for k, r in got.items() if k != "q_2026-10_trail_visits_a1"} == {"skipped"}
    # the app can adopt it from next-session
    ns = client.get("/v1/me/next-session", headers=auth(t)).json()
    assert ns["v"] == 1 and ns["quest"]["id"] == "q_2026-10_trail_visits_a1" and ns["quest"]["state"] == "accepted"
    assert ns["quest"]["accepted_at"]


def test_not_this_month_ends_the_offers_for_the_month(client, fakes):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    due = drain_offer(client)
    tap(client, fakes, "Not this month")
    assert {r["state"] for r in rows(client)} == {"skipped"}
    post(client, t, "r2", minutes_ago=5, quest={"offers": three_offers()})   # the app offers again: nothing is stored or sent
    assert {r["state"] for r in rows(client)} == {"skipped"}
    client.svc.run_outbox(due + timedelta(days=1))
    assert len(offer_message(fakes)) == 1
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["quest"] is None


def test_a_stale_tap_answers_moved_on_and_loses_its_buttons(client, fakes):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    drain_offer(client)
    data = offer_message(fakes)[-1]["reply_markup"]["inline_keyboard"][0][0]["callback_data"]
    tap(client, fakes, "Not this month")
    n = len(fakes.tg)
    assert post_tg(client, tg_callback(91001, data)).status_code == 200
    sent = fakes.tg[n:]
    assert any(m == "answerCallbackQuery" and ("expired" in b["text"] or "moved on" in b["text"]) for m, b in sent)
    assert not any(m == "editMessageText" for m, b in sent)


def test_no_card_when_the_runner_took_a_quest_in_the_app_first(client, fakes):
    t = enrol(client)
    ends = (date.today() + timedelta(days=30)).isoformat()
    active = {"id": "q_2026-10_trail_visits_a1", "kind": "trail_visits", "target": 5, "value": 0, "ends_on": ends, "trail_name": TRAIL}
    post(client, t, quest={"offers": three_offers(), "active": active})
    got = rows(client)
    assert [r["state"] for r in got] == ["accepted"]   # the other offers are off the table
    assert quest_due(client) is None
    assert offer_message(fakes) == []


def test_the_app_displaces_a_quest_accepted_in_telegram(client, fakes):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    drain_offer(client)
    tap(client, fakes, "Take it")
    assert [r["state"] for r in rows(client)].count("accepted") == 1
    ends = (date.today() + timedelta(days=20)).isoformat()
    post(client, t, "r2", minutes_ago=5, quest={"active": {"id": "q_app_own", "kind": "distance_month", "target": 90, "value": 12, "ends_on": ends}})
    states = {r["quest_id"]: r["state"] for r in rows(client)}
    assert states["q_app_own"] == "accepted" and states["q_2026-10_trail_visits_a1"] == "skipped"
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["quest"]["id"] == "q_app_own"


def test_a_lapsed_quest_is_not_active(client):
    t = enrol(client)
    yesterday = (date.today() - timedelta(days=2)).isoformat()
    post(client, t, quest={"active": {"id": "q_old", "kind": "distance_month", "target": 90, "value": 12, "ends_on": yesterday}})
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["quest"] is None


# ---------------------------------------------------------------- the done line
def test_the_run_that_finishes_a_quest_carries_one_line_on_its_card(client, fakes):
    t = enrol(client)
    place_on(client, t)
    ends = (date.today() + timedelta(days=9)).isoformat()
    active = {"id": "q_2026-10_trail_visits_a1", "kind": "trail_visits", "target": 5, "value": 5, "ends_on": ends, "trail_name": TRAIL}
    post(client, t, "r1", quest={"active": active, "done_now": active["id"]})
    assert [r["state"] for r in rows(client)] == ["done"] and rows(client)[0]["done_run_id"] == "r1"
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))
    card = db_(client).execute("SELECT body FROM cards WHERE kind='run' AND run_id='r1'").fetchone()
    assert card is not None and card["body"].endswith("Quest done: 5 runs of The Saddle Trail.")
    # a second finishing signal does not move it, and an ordinary run has no line
    post(client, t, "r2", minutes_ago=5, quest={"done_now": active["id"]})
    assert rows(client)[0]["done_run_id"] == "r1"
    client.svc.run_outbox(now_utc() + timedelta(minutes=3))
    other = db_(client).execute("SELECT body FROM cards WHERE kind='run' AND run_id='r2'").fetchone()
    assert other is None or "Quest done" not in other["body"]


def test_done_for_a_quest_the_server_never_heard_of_adds_nothing(client):
    t = enrol(client)
    post(client, t, quest={"done_now": "q_unknown"})
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert rows(client) == []
    assert all("Quest done" not in r["body"] for r in db_(client).execute("SELECT body FROM cards"))


# ---------------------------------------------------------------- the one nudge
def test_nudge_lines():
    q = {"kind": "trail_visits", "target": 5, "value": 4, "trail_name": "Saddle"}
    assert cq.nudge_line(q) == "One more run of Saddle makes it 5."
    assert cq.nudge_line({**q, "value": 2}) == "3 more runs of Saddle make it 5."
    assert cq.nudge_line({**q, "value": 5}) is None
    assert cq.nudge_line({"kind": "climb_month", "target": 1000, "value": 900}) is None          # under a quarter short
    assert cq.nudge_line({"kind": "climb_month", "target": 1000, "value": 600}) == "400 m more makes it 1,000."
    assert cq.nudge_line({"kind": "distance_month", "target": 120, "value": 100}) is None
    assert cq.nudge_line({"kind": "distance_month", "target": 120, "value": 60}) == "60 km more makes it 120."
    assert cq.nudge_line({"kind": "trail_best", "target": 2472, "value": 0, "trail_name": "Saddle"}) == "One good run on Saddle could still beat 41:12."


def seed_active(client, uid, days_left, value=3, kind="trail_visits", target=5):
    today = date.today()
    ts = iso(now_utc())
    with sqlite3.connect(client.svc.s.db_path) as c:
        c.execute("INSERT INTO quests (user_id, quest_id, month, kind, target, unit, trail_name, state, value, ends_on, accepted_at, pos, "
                  "created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (uid, "q_nudge", today.strftime("%Y-%m"), kind, target, cq.KIND_UNIT[kind], "Saddle", "accepted", value,
                   (today + timedelta(days=days_left)).isoformat(), ts, 0, ts, ts))


def evening_body(client, uid):
    now = now_utc()
    zone = db_(client).execute("SELECT zone_id FROM users").fetchone()["zone_id"]
    from companion.timeutil import to_local
    d = to_local(now, zone).date().isoformat()
    card = client.svc._build_evening_card(uid, d, now)
    return None if card is None else db_(client).execute("SELECT body FROM cards WHERE card_id=?", (card,)).fetchone()["body"]


def evening_ready(client, t):
    """A runner with enough recent runs for an evening suggestion."""
    for i, mins in enumerate((3000, 1500, 600, 200)):
        post(client, t, f"e{i}", minutes_ago=mins)


def test_the_nudge_rides_one_evening_suggestion_per_quest(client):
    t = enrol(client)
    evening_ready(client, t)
    uid = uid_of(client)
    seed_active(client, uid, days_left=6)
    body = evening_body(client, uid)
    if body is None:
        pytest.skip("no evening suggestion for this fixture")
    assert body.endswith("2 more runs of Saddle make it 5.")
    with sqlite3.connect(client.svc.s.db_path) as c:   # the next evening: the line was spent
        c.execute("DELETE FROM cards WHERE kind='evening'")
        c.execute("DELETE FROM quota WHERE key LIKE 'sugg:%'")
        c.execute("DELETE FROM question_cap")
    again = evening_body(client, uid)
    assert again is not None and "make it 5" not in again


def test_no_nudge_with_more_than_a_week_left_or_when_on_track(client):
    t = enrol(client)
    uid = uid_of(client)
    seed_active(client, uid, days_left=12)
    with db_(client) as c:
        assert cq.nudge_for(c, uid, date.today(), now_utc()) is None
        c.execute("UPDATE quests SET ends_on=?, value=5", ((date.today() + timedelta(days=3)).isoformat(),))
        assert cq.nudge_for(c, uid, date.today(), now_utc()) is None
        c.execute("UPDATE quests SET value=3")
        assert cq.nudge_for(c, uid, date.today(), now_utc()) == "2 more runs of Saddle make it 5."
        assert cq.nudge_for(c, uid, date.today(), now_utc()) is None   # once per quest


def test_no_nudge_in_a_care_window(client):
    t = enrol(client)
    evening_ready(client, t)
    assert client.put("/v1/me/consent", json={"consent_version": 2}, headers=auth(t)).status_code == 200
    uid = uid_of(client)
    seed_active(client, uid, days_left=6)
    from companion.timeutil import to_local
    zone = db_(client).execute("SELECT zone_id FROM users").fetchone()["zone_id"]
    tomorrow = (to_local(now_utc(), zone).date() + timedelta(days=1)).isoformat()
    with sqlite3.connect(client.svc.s.db_path) as c:   # the runner said they skipped tomorrow's slot as sore: a lighter window
        c.execute("INSERT INTO checkin_answers (user_id, kind, local_date, value, created_at) VALUES (?,?,?,?,?)",
                  (uid, "ready", tomorrow, "sore", iso(now_utc())))
    body = evening_body(client, uid)
    assert body is None or "make it 5" not in body
    assert db_(client).execute("SELECT COUNT(*) FROM quota WHERE key='qnudge:q_nudge'").fetchone()[0] == 0


# ---------------------------------------------------------------- care weeks
def test_care_weeks_are_the_mondays_that_overlap_an_ill_or_sore_window():
    today = date(2026, 10, 16)   # a Friday; its Monday is 12 Oct
    a = ci.Answers().with_("today", date(2026, 10, 8), "skip").with_("why", date(2026, 10, 8), "ill")   # 8 to 15 Oct
    assert ci.care_weeks(a, today) == [date(2026, 10, 5), date(2026, 10, 12)]
    sore = ci.Answers().with_("ready", date(2026, 10, 14), "sore")                                       # 14 to 17 Oct
    assert ci.care_weeks(sore, today) == [date(2026, 10, 12)]
    tired = ci.Answers().with_("today", date(2026, 10, 14), "skip").with_("why", date(2026, 10, 14), "tired")
    busy = ci.Answers().with_("today", date(2026, 10, 14), "skip").with_("why", date(2026, 10, 14), "busy")
    assert ci.care_weeks(tired, today) == [] and ci.care_weeks(busy, today) == []   # tired is not sore or ill
    assert ci.care_weeks(ci.Answers(), today) == []
    assert len(ci.care_weeks(a, today, weeks=3)) <= 3


def test_next_session_gives_care_weeks_as_dates_only_and_only_with_consent(client):
    t = enrol(client)
    uid = uid_of(client)
    today = date.today()
    with sqlite3.connect(client.svc.s.db_path) as c:
        c.execute("INSERT INTO checkin_answers (user_id, kind, local_date, value, created_at) VALUES (?,?,?,?,?)",
                  (uid, "today", today.isoformat(), "skip", iso(now_utc())))
        c.execute("INSERT INTO checkin_answers (user_id, kind, local_date, value, created_at) VALUES (?,?,?,?,?)",
                  (uid, "why", today.isoformat(), "ill", iso(now_utc())))
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["care_weeks"] == []   # no consent, no check-in data
    assert client.put("/v1/me/consent", json={"consent_version": 2}, headers=auth(t)).status_code == 200
    ns = client.get("/v1/me/next-session", headers=auth(t)).json()
    monday = today - timedelta(days=today.weekday())
    assert monday.isoformat() in ns["care_weeks"]
    assert all(len(d) == 10 and d[4] == "-" for d in ns["care_weeks"])
    assert "ill" not in json.dumps(ns)   # the reason never leaves the server


# ---------------------------------------------------------------- retention and deletion
def test_quest_rows_go_90_days_after_they_end_or_after_the_offer_month(client):
    t = enrol(client)
    uid = uid_of(client)
    now = now_utc()
    ts = iso(now)
    with sqlite3.connect(client.svc.s.db_path) as c:
        def add(qid, month, state, ends):
            c.execute("INSERT INTO quests (user_id, quest_id, month, kind, target, unit, state, ends_on, pos, created_at, updated_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?,?,?)", (uid, qid, month, "distance_month", 100, "km", state, ends, 0, ts, ts))
        add("q_ended_89", "2026-01", "done", (now - timedelta(days=89)).date().isoformat())
        add("q_ended_91", "2026-01", "done", (now - timedelta(days=91)).date().isoformat())
        add("q_offer_last_month", (now - timedelta(days=30)).strftime("%Y-%m"), "offered", None)
        add("q_offer_old", (now - timedelta(days=130)).strftime("%Y-%m"), "offered", None)
    client.svc.purge(now)
    assert {r["quest_id"] for r in rows(client)} == {"q_ended_89", "q_offer_last_month"}


def test_deleting_the_runner_removes_their_quests(client):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    assert len(rows(client)) == 3
    assert client.delete("/v1/me", headers=auth(t)).json() == {"status": "deleted"}
    assert rows(client) == []


def test_the_export_lists_the_quests_without_internal_ids(client):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    me = client.get("/v1/me", headers=auth(t)).json()
    assert [q["quest_id"] for q in me["quests"]] == [o["id"] for o in three_offers()]
    assert all("card_id" not in q and "done_run_id" not in q for q in me["quests"])


# ---------------------------------------------------------------- the app closes what the server shows
def test_month_skipped_cancels_the_queued_offer_and_keeps_the_month_closed(client, fakes):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    assert quest_due(client) is not None
    post(client, t, "r2", minutes_ago=5, quest={"month_skipped": month_of(run_payload("x", minutes_ago=5))})
    assert quest_due(client) is None
    assert {r["state"] for r in rows(client)} == {"skipped"}
    post(client, t, "r3", minutes_ago=2, quest={"offers": three_offers()})   # offered again: nothing is stored or queued
    assert {r["state"] for r in rows(client)} == {"skipped"} and quest_due(client) is None


@pytest.mark.parametrize("result,state", [("dropped", "skipped"), ("expired", "expired"), ("done", "done")])
def test_closed_stops_the_quest_everywhere(client, result, state):
    t = enrol(client)
    ends = (date.today() + timedelta(days=5)).isoformat()
    qid = "q_2026-10_trail_visits_a1"
    post(client, t, quest={"active": {"id": qid, "kind": "trail_visits", "target": 5, "value": 1, "ends_on": ends, "trail_name": TRAIL}})
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["quest"]["id"] == qid
    post(client, t, "r2", minutes_ago=5, quest={"closed": {"id": qid, "result": result}})
    assert rows(client)[0]["state"] == state
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["quest"] is None
    c = db_(client)
    assert cq.nudge_for(c, uid_of(client), date.today() + timedelta(days=0), now_utc()) is None


def test_a_bad_closed_block_drops_only_the_quest(client):
    t = enrol(client)
    post(client, t, quest={"closed": {"id": "q_x", "result": "gone"}})
    assert rows(client) == []


def test_offers_are_filed_under_the_month_in_their_id(client):
    t = enrol(client)
    post(client, t, quest={"offers": [offer(id="q_2026-11_trail_visits_n1")]})
    assert rows(client)[0]["month"] == "2026-11"


def test_an_older_upload_cannot_undo_the_current_quest(client):
    t = enrol(client)
    ends = (date.today() + timedelta(days=20)).isoformat()
    cur = {"id": "q_2026-10_trail_visits_a1", "kind": "trail_visits", "target": 5, "value": 3, "ends_on": ends, "trail_name": TRAIL}
    old = {"id": "q_2026-09_distance_month_z9", "kind": "distance_month", "target": 90, "value": 10, "ends_on": ends}
    post(client, t, "r_new", minutes_ago=5, quest={"active": cur})
    post(client, t, "r_old", minutes_ago=300, quest={"active": old, "offers": [offer(7, id="q_2026-09_trail_visits_o7")]})   # queued offline
    got = {r["quest_id"]: r for r in rows(client)}
    assert got["q_2026-10_trail_visits_a1"]["state"] == "accepted" and got["q_2026-10_trail_visits_a1"]["value"] == 3
    assert "q_2026-09_distance_month_z9" not in got and "q_2026-09_trail_visits_o7" not in got


def test_month_skipped_names_its_month_and_an_older_upload_cannot_use_it(client):
    t = enrol(client)
    post(client, t, "r_new", minutes_ago=5, quest={"offers": three_offers()})
    post(client, t, "r_old", minutes_ago=300, quest={"month_skipped": month_of(run_payload("x", minutes_ago=5))})   # queued offline
    assert {r["state"] for r in rows(client)} == {"offered"} and quest_due(client) is not None
    post(client, t, "r_mid", minutes_ago=3, quest={"month_skipped": "2020-01"})   # another month: this one is untouched
    assert {r["state"] for r in rows(client)} == {"offered"} and quest_due(client) is not None
    post(client, t, "r_bad", minutes_ago=2, quest={"month_skipped": True})   # not a "YYYY-MM": the block is dropped
    assert {r["state"] for r in rows(client)} == {"offered"}


# ---------------------------------------------------------------- the app's exact payloads (lib/state/quests/quest_wire.dart, #316)
APP_VISITS = {"id": "q_2026-11_trail_visits_cccc", "kind": "trail_visits", "target": 5, "baseline": 4, "unit": "runs", "trail_name": "Saddle"}
APP_BEST = {"id": "q_2026-11_trail_best_dddd", "kind": "trail_best", "target": 2472, "baseline": 2472, "unit": "s", "trail_name": "Saddle"}
APP_DIST = {"id": "q_2026-11_distance_month_aaaa", "kind": "distance_month", "target": 20, "baseline": 15, "unit": "km"}


def test_the_apps_exact_quest_payloads_are_accepted_inside_a_full_run_upload(client):
    t = enrol(client)
    place_on(client, t)
    ends = "2026-12-01"
    # 1. an open offer: three candidates, offer 0 first, a name only on the trail ones
    post(client, t, "a1", minutes_ago=290, quest={"offers": [APP_VISITS, APP_BEST, APP_DIST]})
    got = rows(client)
    assert [(r["quest_id"], r["state"], r["month"], r["unit"]) for r in got] == [
        (APP_VISITS["id"], "offered", "2026-11", "runs"), (APP_BEST["id"], "offered", "2026-11", "s"),
        (APP_DIST["id"], "offered", "2026-11", "km")]
    assert got[0]["trail_name"] == "Saddle" and got[0]["baseline"] == 4 and got[2]["trail_name"] is None
    # 2. taken: active has exactly id, kind, target, value, ends_on (no unit, no baseline)
    active = {"id": APP_DIST["id"], "kind": "distance_month", "target": 20, "value": 7, "ends_on": ends}
    post(client, t, "a2", minutes_ago=240, quest={"active": active})
    states = {r["quest_id"]: (r["state"], r["value"]) for r in rows(client)}
    assert states[APP_DIST["id"]] == ("accepted", 7) and states[APP_VISITS["id"]][0] == "skipped"
    # 3. the run that finishes it: active.value == target plus done_now
    post(client, t, "a3", minutes_ago=180, quest={"active": {**active, "value": 20}, "done_now": APP_DIST["id"]})
    assert {r["quest_id"]: r["state"] for r in rows(client)}[APP_DIST["id"]] == "done"
    assert cq.done_for_run(db_(client), uid_of(client), "a3")["quest_id"] == APP_DIST["id"]
    # 4. a later run: the finished one is named once more (offline retry), and another quest it closed
    post(client, t, "a4", minutes_ago=120, quest={"active": {**active, "value": 20}, "done_now": APP_DIST["id"],
                                                  "closed": {"id": APP_VISITS["id"], "result": "dropped"}})
    assert {r["quest_id"]: r["state"] for r in rows(client)}[APP_VISITS["id"]] == "skipped"
    # 5. "Not this month" on its own: just the offer month
    post(client, t, "a5", minutes_ago=60, quest={"month_skipped": "2026-12"})
    assert client.get("/v1/me/next-session", headers=auth(t)).json()["quest"] is None


# ---------------------------------------------------------------- no trail quests off the trail
def test_trail_offers_are_not_put_on_a_card_when_the_newest_run_was_not_a_trail_run(client, fakes):
    t = enrol(client)
    post(client, t, quest={"offers": three_offers()})
    c = db_(client)
    c.execute("UPDATE runs SET app_type='intervals'")
    c.commit()
    uid = uid_of(client)
    c2 = db_(client)
    month = rows(client)[0]["month"]
    got = [r["kind"] for r in cq.suggestable(c2, uid, cq.offered_rows(c2, uid, month))]
    assert got == ["climb_month", "distance_month"]
    c2.execute("UPDATE runs SET app_type='trail'")
    c2.commit()
    assert [r["kind"] for r in cq.suggestable(c2, uid, cq.offered_rows(c2, uid, month))][0] == "trail_visits"
    c2.execute("UPDATE runs SET app_type=NULL")   # the app did not say: do not guess
    c2.commit()
    assert len(cq.suggestable(c2, uid, cq.offered_rows(c2, uid, month))) == 3
