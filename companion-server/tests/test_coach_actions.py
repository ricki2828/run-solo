"""Coach PR4: propose_plan_change (Confirm / Decline, 24 h, triage window), coach memory (/memory, withdraw, DELETE, the 30-day
purge) and the one-shot location share. OpenRouter, Telegram and OSM are fakes: no real network or model call.

Every test pins its clock (T0, a Wednesday 2 pm in Auckland); the next session is Thursday 2026-10-22, a Tempo.
"""
from __future__ import annotations

import json
import sqlite3
from datetime import date, timedelta

import httpx
import pytest

from companion import db
from companion.channels import TelegramChannel
from companion.coach.ext import actions, memory, places

from conftest import OWNER, auth, coach_text, coach_tools, enrol, run_payload, tg_callback
from test_coach_chat import T0, OTHER, cc, rows, run_worker, say, uid_of  # noqa: F401  (cc is a fixture)

THURSDAY, FRIDAY = "2026-10-22", "2026-10-23"
MOVE_FRI = ("propose_plan_change", {"change": "move", "to_day": "friday", "reason": "busy thursday"})
_n = iter(range(900_000, 10**7))


def q(c, sql, *a):
    return rows(c, sql, *a)


def plan(c):
    """A run (at a pinned time: the real clock once put it on the target Friday) with a 4-week plan snapshot whose next session is Thursday's Tempo."""
    assert c.post("/v1/runs", json=run_payload("r1", start_utc=(T0 - timedelta(hours=3)).isoformat()), headers=auth(c.token)).status_code in (200, 201, 202)
    with db.tx(c.svc.s.db_path) as con:
        con.execute("UPDATE runs SET plan_next_type='quality', plan_next_day=?, plan_next_session_name='Tempo', plan_next_week=2, "
                    "plan_weeks=4", (THURSDAY,))


def next_session(c, now=T0):
    return c.svc.next_session(uid_of(c), now)["next_session"]


def tap(c, data, ref=OWNER, now=T0 + timedelta(minutes=5)):
    u = next(_n)
    c.svc.handle_inbound(TelegramChannel.parse(tg_callback(u, data, ref)), now=now)


def propose(c, fakes, args=MOVE_FRI, text="I'd move Thursday's tempo to Friday if that suits you. Your call."):
    fakes.coach_queue = [coach_tools(("propose_plan_change", args[1]) if isinstance(args, tuple) else args), coach_text(text)]
    say(c, "can we shuffle my week?")
    run_worker(c)


def buttons_of(fakes, label_start):
    for m, b in reversed(fakes.tg):
        if m == "sendMessage" and b.get("text", "").startswith(label_start):
            return [x["callback_data"] for row in b["reply_markup"]["inline_keyboard"] for x in row]
    raise AssertionError("no message starting with " + label_start)


def toasts(fakes):
    return [b.get("text") for m, b in fakes.tg if m == "answerCallbackQuery"]


# ---------------------------------------------------------------------------------------------------- the tools are wired
def test_the_two_tools_reach_the_model_and_override_the_old_read_only_rule(cc):
    reg = cc.svc.coach.prompt.registry
    assert reg.has("propose_plan_change") and reg.has("remember")
    names = [t["name"] for t in cc.svc.coach.prompt.tools]
    assert names.count("propose_plan_change") == 1 and names.count("remember") == 1
    assert "no longer applies" in reg.rules() and "/memory" in reg.rules()


# ---------------------------------------------------------------------------------------------------- proposals
def test_a_proposal_sends_confirm_and_decline_and_changes_nothing_yet(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    p = q(cc, "SELECT * FROM coach_proposals")
    assert len(p) == 1 and p[0]["state"] == "pending" and p[0]["offered"] == 1 and p[0]["change"] == "move"
    assert (p[0]["from_day"], p[0]["to_day"]) == (THURSDAY, FRIDAY)
    assert p[0]["label"] == "Move Thursday's Tempo to Friday"
    assert buttons_of(fakes, "Proposed change: Move Thursday's Tempo to Friday") == [f"cp:{p[0]['id']}:y", f"cp:{p[0]['id']}:n"]
    assert next_session(cc)["date"] == THURSDAY and next_session(cc)["moved"] is False
    tool = [json.loads(m["content"]) for m in fakes.coach_calls[1]["messages"] if m["role"] == "tool"][0]
    assert tool["ok"] and tool["status"] == "awaiting_the_runners_confirmation" and "never say it is done" in tool["note"]


def test_a_proposal_does_not_license_saying_it_is_done(cc, fakes):
    """The action-claim rule (#370) stays on: a proposal changed nothing, so "I've moved ..." is refused and repaired."""
    plan(cc)
    fakes.coach_queue = [coach_tools(MOVE_FRI), coach_text("I've moved Thursday's tempo to Friday."),
                         coach_text("I'd move Thursday's tempo to Friday. It's your call, the buttons are below.")]
    say(cc, "can we shuffle my week?")
    run_worker(cc)
    assert q(cc, "SELECT outcome FROM coach_jobs")[0]["outcome"] == "repaired"
    assert "I've moved" not in " ".join(fakes.tg_texts()) and "I'd move Thursday's tempo" in fakes.tg_texts()[-2]


def test_end_to_end_chat_then_confirm_moves_the_next_session(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    pid = q(cc, "SELECT id FROM coach_proposals")[0]["id"]
    tap(cc, f"cp:{pid}:y")
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "confirmed"
    s = next_session(cc)
    assert s["date"] == FRIDAY and s["moved"] is True and s["original_date"] == THURSDAY and s["type"] == "quality"
    assert toasts(fakes)[-1] == "Done."
    assert fakes.tg_texts()[-1] == "Done: Move Thursday's Tempo to Friday."
    msgs = [m["text"] for m in q(cc, "SELECT text FROM coach_messages ORDER BY id")]
    assert "Confirmed: Move Thursday's Tempo to Friday" in msgs   # the next turn's history knows
    # the coach's own read of the plan agrees
    fakes.coach_queue = [coach_tools(("get_plan", {})), coach_text("Friday it is.")]
    say(cc, "what's next?", now=T0 + timedelta(minutes=10))
    run_worker(cc, now=T0 + timedelta(minutes=10, seconds=10))
    plan_res = [json.loads(m["content"]) for m in fakes.coach_calls[-1]["messages"] if m["role"] == "tool"][0]
    assert plan_res["sessions"][0]["day"] == FRIDAY and plan_res["sessions"][0]["moved"] is True


def test_the_override_survives_the_original_day_passing(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    tap(cc, f"cp:{q(cc, 'SELECT id FROM coach_proposals')[0]['id']}:y")
    thu_evening = T0 + timedelta(days=1, hours=8)   # Thursday 10 pm in Auckland: the planned day is still today
    fri_morning = T0 + timedelta(days=1, hours=18)   # Friday 8 am: the planned day (Thursday) has gone by
    assert next_session(cc, thu_evening)["date"] == FRIDAY
    s = next_session(cc, fri_morning)
    assert s["date"] == FRIDAY and s["moved"] is True and s["type"] == "quality"


def test_easier_proposal_makes_the_session_easy(cc, fakes):
    plan(cc)
    propose(cc, fakes, ("propose_plan_change", {"change": "easier", "reason": "tired"}), "Easy it is, if you're happy with that.")
    p = q(cc, "SELECT * FROM coach_proposals")[0]
    assert p["label"] == "Make Thursday's Tempo an easy run" and p["to_day"] is None
    tap(cc, f"cp:{p['id']}:y")
    s = next_session(cc)
    assert s["type"] == "easy" and s["date"] == THURSDAY


def test_confirm_and_decline_are_idempotent(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    pid = q(cc, "SELECT id FROM coach_proposals")[0]["id"]
    tap(cc, f"cp:{pid}:y", now=T0 + timedelta(minutes=5))
    first = q(cc, "SELECT state, decided_at FROM coach_proposals")[0]
    n_msgs = len(q(cc, "SELECT id FROM coach_messages"))
    tap(cc, f"cp:{pid}:y", now=T0 + timedelta(minutes=9))
    tap(cc, f"cp:{pid}:n", now=T0 + timedelta(minutes=11))
    assert q(cc, "SELECT state, decided_at FROM coach_proposals")[0] == first
    assert len(q(cc, "SELECT id FROM coach_messages")) == n_msgs
    assert toasts(fakes)[-2:] == ["Already confirmed.", "Already confirmed."]
    assert next_session(cc)["date"] == FRIDAY
    # and the other way round: a Decline stays a Decline
    propose(cc, fakes, ("propose_plan_change", {"change": "move", "to_day": "saturday", "reason": "x"}), "Saturday instead?")
    pid2 = q(cc, "SELECT id FROM coach_proposals WHERE state='pending'")[0]["id"]
    tap(cc, f"cp:{pid2}:n")
    tap(cc, f"cp:{pid2}:y")
    assert q(cc, "SELECT state FROM coach_proposals WHERE id=?", pid2)[0]["state"] == "declined"
    assert toasts(fakes)[-1] == "Already declined."


def test_decline_changes_nothing(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    tap(cc, f"cp:{q(cc, 'SELECT id FROM coach_proposals')[0]['id']}:n")
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "declined"
    assert next_session(cc)["date"] == THURSDAY
    assert fakes.tg_texts()[-1] == "Okay, leaving it as it is."


def test_a_stale_proposal_cannot_apply(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    pid = q(cc, "SELECT id FROM coach_proposals")[0]["id"]
    tap(cc, f"cp:{pid}:y", now=T0 + timedelta(hours=24, minutes=1))
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "expired"
    assert toasts(fakes)[-1] == "That proposal has expired. Ask me again."
    assert next_session(cc)["date"] == THURSDAY
    tap(cc, f"cp:{pid}:y", now=T0 + timedelta(minutes=5))   # even if the clock were back inside the window
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "expired" and next_session(cc)["date"] == THURSDAY


def test_just_inside_24_hours_still_applies(cc, fakes):
    plan(cc)
    propose(cc, fakes, ("propose_plan_change", {"change": "move", "to_day": "sunday", "reason": "x"}), "Sunday?")
    tap(cc, f"cp:{q(cc, 'SELECT id FROM coach_proposals')[0]['id']}:y", now=T0 + timedelta(hours=23, minutes=59))
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "confirmed"


def test_a_session_that_changed_since_cannot_be_confirmed(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    pid = q(cc, "SELECT id FROM coach_proposals")[0]["id"]
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("UPDATE runs SET plan_next_day=?", ("2026-10-24",))   # the app's plan moved the session meanwhile
    tap(cc, f"cp:{pid}:y")
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "expired"
    assert next_session(cc)["date"] == "2026-10-24"


def test_a_new_proposal_supersedes_the_old_one_and_a_foreign_tap_does_nothing(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    propose(cc, fakes, ("propose_plan_change", {"change": "easier", "reason": "x"}), "Or we keep Thursday but easy.")
    assert [r["state"] for r in q(cc, "SELECT state FROM coach_proposals ORDER BY id")] == ["superseded", "pending"]
    enrol(cc, OTHER)
    tap(cc, f"cp:{q(cc, 'SELECT id FROM coach_proposals WHERE state=\"pending\"')[0]['id']}:y", ref=OTHER)   # someone else's id
    assert q(cc, "SELECT state FROM coach_proposals ORDER BY id")[1]["state"] == "pending"


def test_junk_callback_data_is_not_a_coach_action():
    for bad in ("cp:1:x", "cp:abc:y", "cm:", "cm:1;DROP", "cp:1234567890:y", "cx:1"):
        assert TelegramChannel.parse(tg_callback(1, bad)) is None or TelegramChannel.parse(tg_callback(1, bad)).action is None


# ---------------------------------------------------------------------------------------------------- the triage window
def refused(fakes):
    res = [json.loads(m["content"]) for m in fakes.coach_calls[1]["messages"] if m["role"] == "tool"]
    return res


@pytest.mark.parametrize("mark", [
    "UPDATE coach_jobs SET triage='amber'", "UPDATE coach_jobs SET triage='red72'", "UPDATE coach_jobs SET triage='red'"])
def test_no_proposal_in_an_amber_or_red_window(cc, fakes, mark):
    plan(cc)
    say(cc, "morning")
    run_worker(cc)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute(mark)
    fakes.coach_calls.clear()
    propose(cc, fakes, text="Let's leave the plan alone for now.")
    assert q(cc, "SELECT * FROM coach_proposals") == []
    out = [json.loads(m["content"]) for m in fakes.coach_calls[-1]["messages"] if m["role"] == "tool"][0]
    assert out["ok"] is False and "hold off" in out["error"]
    assert not any(t.startswith("Proposed change") for t in fakes.tg_texts())


def test_the_window_closes_after_72_hours(cc, fakes):
    plan(cc)
    say(cc, "morning")
    run_worker(cc)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("UPDATE coach_jobs SET triage='amber'")
    with db.ro(cc.svc.s.db_path) as con:
        assert actions.in_triage_window(con, uid_of(cc), T0 + timedelta(hours=71))
        assert not actions.in_triage_window(con, uid_of(cc), T0 + timedelta(hours=73))


def test_an_active_injury_flag_blocks_proposals(cc, fakes):
    plan(cc)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO health_flags (user_id, kind, state, source, set_at) VALUES (?,?,?,?,?)",
                    (uid_of(cc), "injury", "active", "triage", "2026-10-20T00:00:00Z"))
    propose(cc, fakes, text="No plan changes while that's being looked at.")
    assert q(cc, "SELECT * FROM coach_proposals") == []


def test_a_triage_check_amber_in_the_same_job_blocks_the_proposal(cc, fakes):
    plan(cc)
    fakes.coach_queue = [coach_tools(("triage_check", {"swelling": True}), MOVE_FRI), coach_text("Rest it and see a physio.")]
    say(cc, "my shin is a bit sore")
    run_worker(cc)
    assert q(cc, "SELECT * FROM coach_proposals") == []
    assert q(cc, "SELECT triage FROM coach_jobs")[0]["triage"] == "amber"
    res = [json.loads(m["content"]) for m in fakes.coach_calls[1]["messages"] if m["role"] == "tool"]
    assert res[0]["level"] == "amber" and res[1]["ok"] is False


def test_a_window_that_opens_after_the_offer_blocks_the_confirm(cc, fakes):
    plan(cc)
    propose(cc, fakes)
    pid = q(cc, "SELECT id FROM coach_proposals")[0]["id"]
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("UPDATE coach_jobs SET triage='amber'")
    tap(cc, f"cp:{pid}:y")
    assert q(cc, "SELECT state FROM coach_proposals")[0]["state"] == "pending"
    assert next_session(cc)["date"] == THURSDAY and "hold off" in fakes.tg_texts()[-1]


# ---------------------------------------------------------------------------------------------------- memory
def remember(c, fakes, fact, kind="schedule", now=T0):
    fakes.coach_queue = [coach_tools(("remember", {"fact": fact, "kind": kind})), coach_text("Noted.")]
    say(c, f"fyi {fact}", now=now)
    run_worker(c, now=now + timedelta(seconds=10))


def test_remember_saves_and_the_next_turn_carries_it_as_quoted_data(cc, fakes):
    remember(cc, fakes, "I work nights on Mondays")
    m = q(cc, "SELECT kind, topic, text FROM coach_memory")
    assert m == [{"kind": "fact", "topic": "schedule", "text": "I work nights on Mondays"}]
    fakes.coach_queue = [coach_text("Right.")]
    say(cc, "plan my week", now=T0 + timedelta(minutes=2))
    run_worker(cc, now=T0 + timedelta(minutes=2, seconds=10))
    turn = fakes.coach_calls[-1]["messages"][-1]["content"]
    turn = turn if isinstance(turn, str) else "".join(p["text"] for p in turn)
    assert "<coach_memory>" in turn and '"quoted_runner_text": "I work nights on Mondays"' in turn


def test_remember_refuses_links_phones_duplicates_and_a_full_memory(cc, fakes):
    uid = uid_of(cc)
    ctx = type("C", (), {"svc": cc.svc, "user_id": uid, "now": T0, "job_id": None})()
    for bad in ("see https://x.example/y", "call me 021 123 4567 anytime", "<b>hi</b> there"):
        with pytest.raises(ValueError):
            memory.call("remember", {"fact": bad, "kind": "life"}, ctx)
    assert memory.call("remember", {"fact": "Prefers mornings", "kind": "preference"}, ctx)["facts_kept"] == 1
    assert memory.call("remember", {"fact": "prefers mornings", "kind": "preference"}, ctx)["already_known"] is True
    for i in range(19):
        memory.call("remember", {"fact": f"fact number {i}", "kind": "life"}, ctx)
    with pytest.raises(ValueError, match="full"):
        memory.call("remember", {"fact": "one too many", "kind": "life"}, ctx)
    assert len(q(cc, "SELECT id FROM coach_memory")) == 20


def test_an_expired_fact_is_neither_shown_nor_sent(cc, fakes):
    uid = uid_of(cc)
    ctx = type("C", (), {"svc": cc.svc, "user_id": uid, "now": T0, "job_id": None})()
    memory.call("remember", {"fact": "away this week", "kind": "schedule", "expires_days": 3}, ctx)
    later = type("C", (), {"svc": cc.svc, "user_id": uid, "now": T0 + timedelta(days=4), "job_id": None})()
    assert "away this week" in memory.context(ctx) and memory.context(later) == ""


def test_memory_command_lists_facts_and_each_can_be_deleted(cc, fakes):
    remember(cc, fakes, "Training for the Auckland half")
    remember(cc, fakes, "Kids' swimming on Tuesdays", now=T0 + timedelta(minutes=1))
    say(cc, "/memory", now=T0 + timedelta(minutes=3))
    listing = [b for m, b in fakes.tg if m == "sendMessage"][-1]
    assert "Training for the Auckland half" in listing["text"] and "Kids' swimming on Tuesdays" in listing["text"]
    cbs = [x["callback_data"] for row in listing["reply_markup"]["inline_keyboard"] for x in row]
    assert cbs[-1] == "cm:all" and len(cbs) == 3
    assert q(cc, "SELECT * FROM coach_jobs WHERE state='pending'") == []   # /memory never became a coach turn
    tap(cc, cbs[0])
    left = q(cc, "SELECT text FROM coach_memory")
    assert [r["text"] for r in left] == ["Kids' swimming on Tuesdays"]
    assert "Kids' swimming on Tuesdays" in fakes.tg_texts()[-1] and "Training for the Auckland half" not in fakes.tg_texts()[-1]
    tap(cc, "cm:all")
    assert q(cc, "SELECT * FROM coach_memory") == []
    assert fakes.tg_texts()[-1].startswith("I haven't kept anything")


def test_a_runner_cannot_delete_another_runners_memory(cc, fakes):
    enrol(cc, OTHER)
    other = q(cc, "SELECT id FROM users WHERE chat_ref=?", OTHER)[0]["id"]
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO coach_memory (user_id, kind, topic, text, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                    (other, "fact", "life", "theirs", "2026-10-21T00:00:00Z", "2026-10-21T00:00:00Z"))
    fid = q(cc, "SELECT id FROM coach_memory")[0]["id"]
    tap(cc, f"cm:{fid}")
    tap(cc, "cm:all")
    assert len(q(cc, "SELECT id FROM coach_memory")) == 1


def test_memory_outlives_the_30_day_message_purge_but_proposals_do_not(cc, fakes):
    plan(cc)
    remember(cc, fakes, "Marathon in March")
    propose(cc, fakes)
    cc.svc.purge(T0 + timedelta(days=40))
    assert q(cc, "SELECT text FROM coach_memory") == [{"text": "Marathon in March"}]
    assert q(cc, "SELECT * FROM coach_messages") == [] and q(cc, "SELECT * FROM coach_proposals") == []


def test_rolling_summary_after_ten_runner_messages(cc, fakes):
    uid = uid_of(cc)
    with db.tx(cc.svc.s.db_path) as con:
        for i in range(10):
            con.execute("INSERT INTO coach_messages (user_id, role, text, ts) VALUES (?,?,?,?)", (uid, "runner", f"message {i}", "2026-10-21T00:00:00Z"))
    calls = []

    def handler(req):
        calls.append((req.headers.get("X-Title"), json.loads(req.content)))
        return httpx.Response(200, json=coach_text("Runs mornings, aiming at a half marathon in March."))
    real = cc.svc.http
    cc.svc.http = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        assert memory.refresh_if_due(cc.svc, uid, T0) is True
        assert memory.refresh_if_due(cc.svc, uid, T0) is False   # nothing new since it last read
    finally:
        cc.svc.http = real
    assert len(calls) == 1 and calls[0][0] == "Run Supreme coach memory"
    assert calls[0][1]["provider"]["zdr"] is True and calls[0][1]["provider"]["allow_fallbacks"] is False
    s = q(cc, "SELECT kind, text, last_msg_id FROM coach_memory")
    assert s[0]["kind"] == "summary" and s[0]["text"].startswith("Runs mornings") and s[0]["last_msg_id"] >= 10
    assert q(cc, "SELECT purpose, state FROM cost_ledger WHERE purpose='memory'") == [{"purpose": "memory", "state": "settled"}]
    ctx = type("C", (), {"svc": cc.svc, "user_id": uid, "now": T0, "job_id": None})()
    assert "summary_of_earlier_chats" in memory.context(ctx)
    tap(cc, "cm:s")
    assert q(cc, "SELECT * FROM coach_memory") == []


def test_a_summary_with_a_link_is_dropped(cc, fakes):
    uid = uid_of(cc)
    with db.tx(cc.svc.s.db_path) as con:
        for i in range(10):
            con.execute("INSERT INTO coach_messages (user_id, role, text, ts) VALUES (?,?,?,?)", (uid, "runner", f"m{i}", "2026-10-21T00:00:00Z"))
    real = cc.svc.http
    cc.svc.http = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=coach_text("Visit https://evil.example now"))))
    try:
        assert memory.refresh_if_due(cc.svc, uid, T0) is False
    finally:
        cc.svc.http = real
    assert q(cc, "SELECT * FROM coach_memory") == []


def test_withdrawing_consent_clears_memory_proposals_and_a_waiting_location(cc, fakes):
    plan(cc)
    remember(cc, fakes, "Marathon in March")
    propose(cc, fakes)
    uid = uid_of(cc)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO coach_loc_wait (user_id, job_id, kind, created_at) VALUES (?,?,?,?)", (uid, 1, "physio", "2026-10-21T01:00:00Z"))
    assert q(cc, "SELECT id FROM coach_memory") and q(cc, "SELECT id FROM coach_proposals")
    assert cc.put("/v1/me/consent", json={"consent_version": 0}, headers=auth(cc.token)).status_code == 200
    for t in ("coach_memory", "coach_proposals", "coach_loc_wait"):
        assert q(cc, f"SELECT * FROM {t}") == [], t


def test_delete_removes_memory_and_proposals(cc, fakes):
    plan(cc)
    remember(cc, fakes, "Marathon in March")
    propose(cc, fakes)
    assert cc.delete("/v1/me", headers=auth(cc.token)).json() == {"status": "deleted"}
    for t in ("coach_memory", "coach_proposals", "coach_loc_wait"):
        assert q(cc, f"SELECT * FROM {t}") == [], t


def test_the_export_shows_memory_and_proposals(cc, fakes):
    plan(cc)
    remember(cc, fakes, "Marathon in March")
    propose(cc, fakes)
    out = cc.get("/v1/me", headers=auth(cc.token)).json()
    assert out["coach_memory"][0]["text"] == "Marathon in March" and out["coach_proposals"][0]["label"].startswith("Move Thursday")


def test_the_new_tables_are_covered_by_export_and_backup_maps():
    from companion.backup import PRIVATE_TABLES
    from companion.service import EXPORTED_TABLES, NOT_EXPORTED_TABLES
    for t in ("coach_proposals", "coach_loc_wait"):
        assert t in PRIVATE_TABLES and t in {**EXPORTED_TABLES, **NOT_EXPORTED_TABLES}
    # backups keep ALL coach memory (Ricki, 22-Oct): exported, but not in the emptied-in-backup list
    assert "coach_memory" not in PRIVATE_TABLES and "coach_memory" in {**EXPORTED_TABLES, **NOT_EXPORTED_TABLES}


# ---------------------------------------------------------------------------------------------------- location
LAT, LON = 1.2764, 103.8458


def location_update(ref=OWNER, lat=LAT, lon=LON):
    u = next(_n)
    return {"update_id": u, "message": {"message_id": u, "chat": {"id": int(ref), "type": "private"}, "from": {"id": int(ref)},
                                        "location": {"latitude": lat, "longitude": lon}}}


def share(c, now=T0 + timedelta(minutes=2), **kw):
    c.svc.handle_inbound(TelegramChannel.parse(location_update(**kw)), now=now)


@pytest.fixture
def osm(monkeypatch):
    seen = []

    def fake_search(http, kind, centre):
        seen.append((kind, centre))
        return [{"name": "Tanjong Physio", "distance_km": 0.4, "address": "1 Peck Seah St", "phone": "+65 6123 4567"},
                {"name": "Harbour Sports Clinic", "distance_km": 1.1}]
    monkeypatch.setattr(places, "_search", fake_search)
    return seen


def dump_db(c) -> str:
    con = sqlite3.connect(c.svc.s.db_path)
    try:
        return "\n".join(con.iterdump())
    finally:
        con.close()


def test_find_care_without_a_place_offers_one_shot_share_location_and_the_answer_is_not_stored(cc, fakes, osm):
    fakes.coach_queue = [coach_tools(("find_care", {"kind": "physio"})), coach_text("Which suburb are you in? You can also tap Share location.")]
    say(cc, "can you find me a physio?")
    run_worker(cc)
    kb = [b for m, b in fakes.tg if m == "sendMessage" and "reply_markup" in b and "keyboard" in b["reply_markup"]]
    assert len(kb) == 1 and kb[0]["reply_markup"] == {"keyboard": [[{"text": "Share location", "request_location": True}]],
                                                      "one_time_keyboard": True, "resize_keyboard": True}
    w = q(cc, "SELECT kind, prompted FROM coach_loc_wait")
    assert w == [{"kind": "physio", "prompted": 1}]
    share(cc)
    assert osm == [("physio", (1.28, 103.85))]   # rounded to about 1 km before anything used it
    text = fakes.tg_texts()[-1]
    assert "Tanjong Physio, 0.4 km" in text and "+65 6123 4567" in text and "OpenStreetMap" in text and "not a" in text
    assert q(cc, "SELECT * FROM coach_loc_wait") == []   # consumed
    dump = dump_db(cc)
    for needle in ("1.2764", "103.8458", "103.85", "1.28,", "Tanjong Physio", "Peck Seah"):
        assert needle not in dump, needle
    assert "(I looked up nearby physios" in dump


def test_a_second_share_is_not_looked_up(cc, fakes, osm):
    fakes.coach_queue = [coach_tools(("find_care", {"kind": "gp"})), coach_text("Which suburb?")]
    say(cc, "need a doctor")
    run_worker(cc)
    share(cc)
    share(cc, now=T0 + timedelta(minutes=3))
    assert len(osm) == 1 and "wasn't waiting on a location" in fakes.tg_texts()[-1]
    assert "103.85" not in dump_db(cc)


def test_a_share_with_no_request_or_a_stale_one_is_ignored_and_never_kept(cc, fakes, osm):
    share(cc)
    assert osm == [] and "wasn't waiting" in fakes.tg_texts()[-1]
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO coach_loc_wait (user_id, job_id, kind, prompted, created_at) VALUES (?,?,?,1,?)",
                    (uid_of(cc), 1, "physio", "2026-10-21T00:00:00Z"))
    share(cc, now=T0 + timedelta(hours=2))
    assert osm == [] and q(cc, "SELECT * FROM coach_loc_wait") == []
    assert "103.8458" not in dump_db(cc)


def test_a_failed_lookup_says_so_and_still_keeps_nothing(cc, fakes, monkeypatch):
    monkeypatch.setattr(places, "_search", lambda *a: (_ for _ in ()).throw(httpx.ConnectError("x")))
    fakes.coach_queue = [coach_tools(("find_care", {"kind": "urgent"})), coach_text("Where are you?")]
    say(cc, "I need urgent care")
    run_worker(cc)
    share(cc)
    assert "Type your suburb" in fakes.tg_texts()[-1]
    assert "103.8458" not in dump_db(cc) and q(cc, "SELECT * FROM coach_loc_wait") == []


def test_urgent_results_carry_the_local_emergency_number(cc, fakes, osm):
    fakes.coach_queue = [coach_tools(("find_care", {"kind": "urgent"})), coach_text("Where are you?")]
    say(cc, "need the ER")
    run_worker(cc)
    share(cc)
    assert "call 111" in fakes.tg_texts()[-1]


def test_a_location_from_an_ungated_runner_is_dropped_silently(tmp_path, fakes, osm):
    from test_coach_chat import coach_settings
    from companion.app import create_app
    from fastapi.testclient import TestClient
    app = create_app(coach_settings(tmp_path, coach_allowlist=frozenset({"T99"})),
                     httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        enrol(c)
        before = len(fakes.tg)
        c.svc.handle_inbound(TelegramChannel.parse(location_update()), now=T0)
        assert len(fakes.tg) == before and osm == []


# ---------------------------------------------------------------------------------------------------- the Telegram edge
def test_parse_location_and_action_messages():
    inb = TelegramChannel.parse(location_update())
    assert inb.location == (LAT, LON) and inb.text == "" and "1.2764" not in repr(inb)
    assert TelegramChannel.parse(location_update(lat=95.0)) is None
    assert TelegramChannel.parse(location_update(lat="x")) is None
    a = TelegramChannel.parse(tg_callback(7, "cp:12:y"))
    assert a.action == "cp:12:y" and a.callback_id and a.card_id is None and a.chip is None
    assert TelegramChannel.parse(tg_callback(8, "cm:all")).action == "cm:all"
    assert TelegramChannel.parse(tg_callback(9, "cm:s")).action == "cm:s"


# ---------------------------------------------------------------------------------------------------- review fixes
def test_the_summary_runs_in_the_worker_after_the_reply_never_inside_send_job(cc, fakes, monkeypatch):
    calls = []
    monkeypatch.setattr(memory, "refresh_if_due", lambda svc, uid, now: calls.append(uid))
    say(cc, "hello")
    cc.svc.coach.step(T0 + timedelta(seconds=10))   # claims the job and runs it, which sends and then refreshes
    assert len(calls) == 1
    calls.clear()
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO coach_jobs (user_id, msg_mac, kind, state, reply, reply_source, created_at, replied_at) "
                    "VALUES (?,?,?,?,?,?,?,?)", (uid_of(cc), "m2", "chat", "replied", "Hi", "llm", "2026-10-21T01:00:00Z", "2026-10-21T01:00:00Z"))
    jid = q(cc, "SELECT id FROM coach_jobs WHERE msg_mac='m2'")[0]["id"]
    assert cc.svc.coach.send_job(jid) is True and calls == []   # a send alone (webhook or red-rail path) never calls the model


def test_a_leftover_share_location_keyboard_is_removed_when_the_runner_types_instead(cc, fakes, osm):
    fakes.coach_queue = [coach_tools(("find_care", {"kind": "physio"})), coach_text("Which suburb?")]
    say(cc, "need a physio")
    run_worker(cc)
    fakes.coach_queue = [coach_text("Got it, thanks.")]
    say(cc, "Tanjong Pagar", now=T0 + timedelta(minutes=3))
    run_worker(cc, now=T0 + timedelta(minutes=3, seconds=10))
    last = [b for m, b in fakes.tg if m == "sendMessage"][-1]
    assert last["reply_markup"] == {"remove_keyboard": True}
    assert q(cc, "SELECT * FROM coach_loc_wait") == []


def test_a_false_alarm_unblocks_proposals_including_red72_followups(cc, fakes):
    from companion.channels import Inbound
    from companion.coach.chat import FALSE_ALARM
    plan(cc)
    uid = uid_of(cc)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO coach_jobs (user_id, msg_mac, kind, state, triage, outcome, created_at, replied_at) VALUES (?,?,?,?,?,?,?,?)",
                    (uid, "r1", "chat", "sent", "red", "triage:red:calf", "2026-10-21T00:30:00Z", "2026-10-21T00:30:00Z"))
        con.execute("INSERT INTO coach_jobs (user_id, msg_mac, kind, state, triage, created_at) VALUES (?,?,?,?,?,?)",
                    (uid, "r2", "chat", "sent", "red72", "2026-10-21T00:40:00Z"))
    with db.ro(cc.svc.s.db_path) as con:
        assert actions.in_triage_window(con, uid, T0)
    user = dict(q(cc, "SELECT * FROM users WHERE id=?", uid)[0])
    assert cc.svc.coach.false_alarm(cc.svc.channels["telegram"], Inbound("telegram", OWNER, "fa", chip=FALSE_ALARM), user, T0)
    with db.ro(cc.svc.s.db_path) as con:
        assert not actions.in_triage_window(con, uid, T0)
    propose(cc, fakes)
    assert q(cc, "SELECT state FROM coach_proposals") == [{"state": "pending"}]


def test_no_move_onto_a_day_that_already_has_a_run_or_a_confirmed_move(cc, fakes):
    plan(cc)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, received_at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?)", (uid_of(cc), "fri", "2026-10-22T20:00:00Z", "2026-10-22T21:00:00Z", 780, "Pacific/Auckland", "easy", 3600, 9000, "2026-10-22T21:00:00Z"))
        con.execute("UPDATE runs SET plan_next_type='quality', plan_next_day=?, plan_next_session_name='Tempo'", (THURSDAY,))
    propose(cc, fakes, text="Friday is taken.")   # 20:00Z Thursday = Friday 9 am in Auckland
    assert q(cc, "SELECT * FROM coach_proposals") == []
    out = [json.loads(m["content"]) for m in fakes.coach_calls[-1]["messages"] if m["role"] == "tool"][0]
    assert out["ok"] is False and "already has a run" in out["error"]
    propose(cc, fakes, ("propose_plan_change", {"change": "move", "to_day": "saturday", "reason": "x"}), "Saturday?")
    tap(cc, f"cp:{q(cc, 'SELECT id FROM coach_proposals')[0]['id']}:y")
    with db.ro(cc.svc.s.db_path) as con:
        assert actions._day_taken(con, uid_of(cc), date(2026, 10, 24), "Pacific/Auckland")


# ---------------------------------------------------------------------------------------------------- consent v4 gate (Phase 0)
import dataclasses
import logging
import sqlite3 as _sq

from conftest import tg_update


def consent(c, v, **kw):
    r = c.put("/v1/me/consent", json={"consent_version": v, **kw}, headers=auth(c.token))
    assert r.status_code == 200, r.text
    return r


def off_allowlist(c):
    """The runner stays chat-enabled but is no longer on the allowlist as far as memory is concerned: memory then rides on consent alone."""
    c.svc.coach.allowlisted = lambda u, a=None: False


def ctx_of(c, now=T0):
    return type("C", (), {"svc": c.svc, "user_id": uid_of(c), "now": now, "job_id": None})()


def test_memory_gate_allowlist_at_v3_is_the_temporary_or_for_ricki(cc, fakes):
    with db.ro(cc.svc.s.db_path) as con:
        assert memory.gate(cc.svc, con, uid_of(cc)) is None   # consent 3 + allowlist
    remember(cc, fakes, "I run before work")
    assert len(q(cc, "SELECT id FROM coach_memory")) == 1


def test_consent_decides_memory_when_the_allowlist_does_not_apply(cc):
    off_allowlist(cc)
    uid = uid_of(cc)
    with db.ro(cc.svc.s.db_path) as con:
        assert memory.gate(cc.svc, con, uid) == "memory_consent"      # consent 3
    assert memory.context(ctx_of(cc)) == ""
    with pytest.raises(ValueError, match="memory is not on"):
        memory.call("remember", {"fact": "I like hills", "kind": "preference"}, ctx_of(cc))
    assert memory.refresh_if_due(cc.svc, uid, T0) is False
    consent(cc, 4)
    with db.ro(cc.svc.s.db_path) as con:
        assert memory.gate(cc.svc, con, uid) is None                  # consent 4
    assert memory.call("remember", {"fact": "I like hills", "kind": "preference"}, ctx_of(cc))["saved"] is True
    assert '"quoted_runner_text": "I like hills"' in memory.context(ctx_of(cc))


def test_v4_gate_still_needs_the_coach_consent_and_not_paused(cc):
    off_allowlist(cc)
    uid = uid_of(cc)
    consent(cc, 4)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("UPDATE users SET paused=1 WHERE id=?", (uid,))
    with db.ro(cc.svc.s.db_path) as con:
        assert memory.gate(cc.svc, con, uid) == "paused"


def test_v4_sub_choices_are_stored_with_the_consent_and_default_correctly(cc):
    row = lambda: q(cc, "SELECT checkin_consent, memory_health_optin h, memory_sync_optin t FROM users")[0]
    assert row() == {"checkin_consent": 3, "h": 0, "t": 1}
    consent(cc, 4)
    assert row() == {"checkin_consent": 4, "h": 0, "t": 1}   # health off, sync on by default
    consent(cc, 4, health_notes=True, training_sync=False)
    assert row() == {"checkin_consent": 4, "h": 1, "t": 0}
    consent(cc, 4)                                            # a plain re-statement leaves the sub-choices alone
    assert row() == {"checkin_consent": 4, "h": 1, "t": 0}
    consent(cc, 3)                                            # a lower app report is ignored (no silent downgrade)
    assert row() == {"checkin_consent": 4, "h": 1, "t": 0}
    prof = cc.get("/v1/me", headers=auth(cc.token)).json()["profile"]
    assert prof["memory_health_notes"] is True and prof["memory_training_sync"] is False


def test_sub_choices_are_ignored_below_v4_and_must_be_booleans(cc):
    consent(cc, 3, health_notes=True, training_sync=False)
    assert q(cc, "SELECT memory_health_optin h, memory_sync_optin t FROM users")[0] == {"h": 0, "t": 1}
    r = cc.put("/v1/me/consent", json={"consent_version": 4, "health_notes": "yes"}, headers=auth(cc.token))
    assert r.status_code == 422


def test_an_operator_lowering_consent_below_v4_deletes_memory_for_a_runner_off_the_allowlist(cc):
    off_allowlist(cc)
    uid = uid_of(cc)
    consent(cc, 4, health_notes=True)
    with db.tx(cc.svc.s.db_path) as con:
        con.execute("INSERT INTO coach_memory (user_id, kind, topic, text, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                    (uid, "fact", "schedule", "Tuesdays are long runs", "2026-10-21T00:00:00Z", "2026-10-21T00:00:00Z"))
    cc.svc.set_checkin_consent(uid, 3, source="cli")
    assert q(cc, "SELECT * FROM coach_memory") == []
    assert q(cc, "SELECT memory_health_optin h, memory_sync_optin t FROM users")[0] == {"h": 0, "t": 1}


def test_memory_off_keeps_the_coach_working(cc, fakes, monkeypatch):
    """A closed memory gate must not break a chat turn: the reply goes out, the turn has no memory block, remember saves nothing."""
    real_gate = memory.gate

    def consent_only(svc, c, uid):   # chat stays allowlisted; memory sees the runner as off the allowlist at consent 3
        keep, svc.coach.allowlisted = svc.coach.allowlisted, (lambda u, a=None: False)
        try:
            return real_gate(svc, c, uid)
        finally:
            svc.coach.allowlisted = keep
    monkeypatch.setattr(memory, "gate", consent_only)
    fakes.coach_queue = [coach_tools(("remember", {"fact": "I hate mornings", "kind": "preference"})), coach_text("Fair enough.")]
    say(cc, "I hate mornings, remember that")
    run_worker(cc, now=T0 + timedelta(seconds=10))
    assert q(cc, "SELECT * FROM coach_memory") == []
    assert any("Fair enough" in t for t in fakes.tg_texts())
    for call in fakes.coach_calls:
        turn = call["messages"][-1]["content"]
        turn = turn if isinstance(turn, str) else "".join(p.get("text", "") for p in turn if isinstance(p, dict))
        assert "<coach_memory>" not in turn


def test_memory_content_never_reaches_the_logs(cc, fakes, caplog):
    caplog.set_level(logging.DEBUG)
    secret = "my knee clicks on Zanzibar hills"
    remember(cc, fakes, secret)
    uid = uid_of(cc)
    with db.tx(cc.svc.s.db_path) as con:
        for i in range(10):
            con.execute("INSERT INTO coach_messages (user_id, role, text, ts) VALUES (?,?,?,?)", (uid, "runner", f"{secret} {i}", "2026-10-21T00:00:00Z"))
    real = cc.svc.http
    cc.svc.http = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=coach_text("Notes about Zanzibar hills and a clicking knee."))))
    try:
        assert memory.refresh_if_due(cc.svc, uid, T0) is True
    finally:
        cc.svc.http = real
    tap(cc, "cm:all")
    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert "Zanzibar" not in logged and "knee" not in logged
    assert "coach memory summary outcome=ok updated=True" in logged


def test_the_nightly_backup_keeps_coach_memory_but_not_the_proposals(cc, fakes, tmp_path):
    from companion.backup import backup, restore
    remember(cc, fakes, "Marathon in March")
    key = tmp_path / "k.key"
    key.write_bytes(b"k" * 32)
    enc = backup(cc.svc.s.db_path, str(tmp_path / "bk"), str(key))
    out = str(tmp_path / "restored.db")
    restore(enc, out, str(key))
    con = _sq.connect(out)
    assert con.execute("SELECT text FROM coach_memory").fetchall() == [("Marathon in March",)]
    assert con.execute("SELECT COUNT(*) FROM coach_proposals").fetchone()[0] == 0


def test_slash_memory_still_lists_rows_for_a_runner_whose_gate_closed(cc, fakes):
    remember(cc, fakes, "Marathon in March")
    cc.svc.coach.gate_for = lambda uid: "allowlist"   # the chat gate is closed
    cc.svc.handle_inbound(TelegramChannel.parse(tg_update(next(_n), "/memory", OWNER)), now=T0 + timedelta(minutes=3))
    assert any("Marathon in March" in t for t in fakes.tg_texts())
