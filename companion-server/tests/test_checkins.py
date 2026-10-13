"""Check-ins (stream S1): the evening-before question, the morning card, taps that edit in place, the daily question cap,
at-most-once sends, the result card replacing the morning card, the 14-day retention, and the app's next-session view.

Every test pins its clock: the weekday and the time of day decide what the coach sends (tests never read the real clock)."""
import json
import re
import sqlite3
import threading
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from companion import checkin_copy as cc
from companion import checkins as ci
from companion import db
from companion.channels import TelegramChannel, parse_checkin_callback
from companion.service import RunIn
from companion.timeutil import iso
from conftest import OWNER, TG_TOKEN, auth, enrol, tg_callback

ROME = ZoneInfo("Europe/Rome")
CODE_RE = re.compile(r"^ci1:[0-9a-f]{32}:[a-z]\.[a-z0-9]+$")
_upd = iter(range(500000, 900000))


def at(y, mo, d, h=0, mi=0) -> datetime:
    """Local wall time in Rome as a UTC instant."""
    return datetime(y, mo, d, h, mi, tzinfo=ROME).astimezone(timezone.utc)


class Env:
    def __init__(self, client, fakes, token):
        self.client, self.fakes, self.token = client, fakes, token
        self.svc = client.svc
        self.path = self.svc.s.db_path
        self.base = len(fakes.tg)   # enrolment sent the code and a welcome; those are not the coach's
        with db.ro(self.path) as c:
            self.uid = c.execute("SELECT id FROM users").fetchone()["id"]

    # ---- data
    def q(self, sql, *args):
        with db.ro(self.path) as c:
            return [dict(r) for r in c.execute(sql, args)]

    def run(self, run_id, start, *, now=None, type="easy", verdict="holding", plan_next=None, plan_week=3, zone_min=None,
            offset=None, **over):
        offset = offset if offset is not None else int(start.astimezone(ROME).utcoffset().total_seconds() // 60)
        p = dict(run_id=run_id, type=type, start_utc=start, utc_offset_min=offset, zone_id="Europe/Rome",
                 duration_s=2400, distance_m=7000, pace_s_per_km=342.0, true_pace_s_per_km=338.0, verdict=verdict,
                 zone_min=zone_min or {}, **over)
        if plan_next:
            p.update(plan_week=plan_week, plan_weeks=4, plan_next=plan_next)
        return self.svc.ingest_run(self.uid, RunIn(**p), now=now or start + timedelta(hours=8))

    def seed(self, plan_next=None, last=at(2026, 10, 13, 7, 0)):
        """Six earlier runs at about 07:00 (all uploaded late, so no cards queue), the newest carrying the plan."""
        for i, (d, h) in enumerate([(1, 7), (3, 7), (6, 7), (8, 7), (10, 7)]):
            self.run(f"s{i}", at(2026, 10, d, h, 0))
        self.run("last", last, plan_next=plan_next if plan_next is not None else
                 {"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000})

    # ---- driving the worker
    def step(self, now):
        n = self.svc.plan_checkins(now)
        self.svc.run_outbox(now)
        return n

    def sends(self, method="sendMessage"):
        return [b for m, b in self.fakes.tg[self.base:] if m == method]

    def tap(self, code, now, *, slot=None, message_id=None, card_id=None, ref=OWNER):
        slot = slot or self.slot()
        upd = tg_callback(next(_upd), f"ci1:{card_id or slot['card_id']}:{code}", ref=ref,
                          mid=int(message_id or slot["message_id"]))
        inb = TelegramChannel.parse(upd)
        before = len(self.fakes.tg)
        self.svc.handle_inbound(inb, now=now)
        return self.fakes.tg[before:]

    def slot(self, name=None):
        rows = self.q("SELECT * FROM checkin_slots" + (" WHERE slot=?" if name else "") + " ORDER BY claimed_at DESC",
                      *([name] if name else []))
        assert rows, "no check-in slot"
        return rows[0]

    def answers(self):
        return {(r["kind"], r["local_date"]): r["value"] for r in self.q("SELECT * FROM checkin_answers")}


@pytest.fixture
def env(client, fakes):
    t = enrol(client)
    e = Env(client, fakes, t)
    e.seed()
    return e


def edited_text(calls):
    return [b["text"] for m, b in calls if m == "editMessageText"]


# ================================================================= the resolver (pure)
def test_a_skip_moves_the_session_past_the_lighter_window_and_undo_puts_it_back():
    p = ci.Planned("quality", date(2026, 10, 22), 3, 4, distance_m=6000)
    a = ci.Answers().with_("today", date(2026, 10, 22), "skip").with_("why", date(2026, 10, 22), "tired")
    r = ci.resolve(p, a, date(2026, 10, 22))
    assert r and r.day == date(2026, 10, 26) and r.moved and r.original_day == date(2026, 10, 22)
    # usual days Tue/Wed/Fri/Sat push it to the next day the runner runs
    usual = frozenset({1, 2, 4, 5})
    assert ci.resolve(p, a, date(2026, 10, 22), usual).day == date(2026, 10, 27)
    assert ci.resolve(p, ci.Answers(), date(2026, 10, 22)).moved is False


def test_ill_pauses_for_a_week_and_sore_or_not_tomorrow_move_the_session():
    p = ci.Planned("quality", date(2026, 10, 22))
    ill = ci.Answers().with_("today", date(2026, 10, 22), "skip").with_("why", date(2026, 10, 22), "ill")
    assert ci.resolve(p, ill, date(2026, 10, 22)).day == date(2026, 10, 30)
    assert ci.lighter_until(ill, date(2026, 10, 22)) == date(2026, 10, 29)
    assert ci.resolve(p, ci.Answers().with_("ready", date(2026, 10, 22), "not_tomorrow"), date(2026, 10, 21)).day \
        == date(2026, 10, 23)
    sore = ci.Answers().with_("ready", date(2026, 10, 22), "sore")
    assert ci.resolve(p, sore, date(2026, 10, 21)).day == date(2026, 10, 26)


def test_flat_makes_a_hard_session_easy_but_leaves_an_easy_one_alone():
    flat = ci.Answers().with_("ready", date(2026, 10, 22), "flat")
    r = ci.resolve(ci.Planned("quality", date(2026, 10, 22)), flat, date(2026, 10, 21))
    assert r.type == "easy" and r.easier and r.day == date(2026, 10, 22)
    assert ci.resolve(ci.Planned("easy", date(2026, 10, 22)), flat, date(2026, 10, 21)).easier is False


def test_away_moves_a_session_that_falls_in_that_week_and_a_passed_date_resolves_to_nothing():
    p = ci.Planned("easy", date(2026, 10, 27))
    away = ci.Answers().with_("shape", date(2026, 10, 26), "away")
    assert ci.resolve(p, away, date(2026, 10, 25)).day == date(2026, 11, 2)
    assert ci.resolve(p, ci.Answers(), date(2026, 10, 28)) is None
    assert ci.resolve(None, ci.Answers(), date(2026, 10, 28)) is None


def test_a_question_is_worth_asking_only_when_the_answers_lead_to_different_suggestions():
    p = ci.Planned("quality", date(2026, 10, 22))
    today = date(2026, 10, 21)
    assert ci.worth_asking("ready", p, ci.Answers(), date(2026, 10, 22), today)
    assert not ci.worth_asking("ready", None, ci.Answers(), date(2026, 10, 22), today)              # nothing planned
    assert not ci.worth_asking("ready", p, ci.Answers(), date(2026, 10, 23), today)                 # a rest day: nothing to change
    assert not ci.worth_asking("shape", p, ci.Answers(), date(2026, 10, 26), date(2026, 10, 25))   # no session next week
    assert ci.worth_asking("shape", ci.Planned("easy", date(2026, 10, 27)), ci.Answers(), date(2026, 10, 26),
                           date(2026, 10, 25))
    assert ci.worth_asking("postrun", p, ci.Answers(), date(2026, 10, 21), today)                   # sleep/stress go lighter


def test_every_callback_code_fits_telegrams_64_bytes_and_parses():
    for code in ci.CODES:
        data = f"ci1:{'a' * 32}:{code}"
        assert len(data.encode()) <= 64 and CODE_RE.match(data.replace("a" * 32, "0" * 32))
        assert parse_checkin_callback(data) == ("a" * 32, code)
    assert parse_checkin_callback("ci1:zz:") is None and parse_checkin_callback("abc:1") is None


def test_the_ambiguous_run_is_an_easy_slower_one_with_time_in_the_harder_zones():
    base = {"type": "easy", "verdict": "slower", "zone_min": json.dumps({"z2": 10, "z3": 12, "z4": 4})}
    assert ci.run_is_ambiguous(base)
    assert not ci.run_is_ambiguous({**base, "verdict": "holding"})
    assert not ci.run_is_ambiguous({**base, "type": "tempo"})
    assert not ci.run_is_ambiguous({**base, "zone_min": json.dumps({"z2": 30})})
    assert not ci.run_is_ambiguous({**base, "zone_min": "{}"})


# ================================================================= the evening-before question
def test_the_evening_before_question_is_sent_once_and_a_tap_edits_the_same_message(env):
    now = at(2026, 10, 14, 20, 5)
    assert env.step(now) == 1
    [msg] = env.sends()
    assert msg["text"].startswith("Quality session, 6 km tomorrow\nHow's the body?")
    data = [b["callback_data"] for row in msg["reply_markup"]["inline_keyboard"] for b in row]
    assert len(data) == 5 and all(CODE_RE.match(d) and len(d.encode()) <= 64 for d in data)
    slot = env.slot("ready")
    assert slot["state"] == "sent" and slot["message_id"] == str(env.fakes.mid)
    for _ in range(3):   # every later tick finds it planned already
        assert env.step(now + timedelta(minutes=1)) == 0
    assert len(env.sends()) == 1

    calls = env.tap("r.normal", now + timedelta(minutes=2))
    assert [m for m, _ in calls] == ["answerCallbackQuery", "editMessageText"]   # the tap is answered first
    [(_, edit)] = [c for c in calls if c[0] == "editMessageText"]
    assert edit["message_id"] == int(slot["message_id"]) and edit["text"].startswith("Locked in\nQuality session, 6 km, around 7:00")
    assert env.answers() == {("ready", "2026-10-15"): "normal"}
    assert len(env.sends()) == 1   # no second message


def test_each_readiness_answer_edits_to_its_own_templated_text_and_change_reopens_the_question(env):
    now = at(2026, 10, 14, 20, 5)
    env.step(now)
    out = {}
    for code in ("r.fresh", "r.flat", "r.sore", "r.not"):
        out[code] = edited_text(env.tap(code, now + timedelta(minutes=1)))[0]
    assert out["r.flat"].startswith("Easy it is") and "instead of the quality session" in out["r.flat"]
    assert out["r.sore"].startswith("Rest tomorrow") and "get it looked at" in out["r.sore"] and "Mon 19" in out["r.sore"]
    assert out["r.not"].startswith("Moved\nQuality session, 6 km moves to Fri 16")
    assert env.answers() == {("ready", "2026-10-15"): "not_tomorrow"}   # last write wins
    back = edited_text(env.tap("r.chg", now + timedelta(minutes=2)))[0]
    assert back.startswith("Quality session, 6 km tomorrow") and env.answers() == {}


def test_a_flat_answer_the_night_before_makes_the_morning_card_an_easy_run(env):
    env.step(at(2026, 10, 14, 20, 5))
    env.tap("r.flat", at(2026, 10, 14, 20, 6))
    env.step(at(2026, 10, 15, 6, 45))
    assert env.sends()[-1]["text"].startswith("Today: Easy run, 6 km")


def test_no_question_when_nothing_changes_or_without_a_plan(env):
    assert env.step(at(2026, 10, 13, 20, 5)) == 0          # tomorrow (Wed) is not the planned day
    assert env.step(at(2026, 10, 14, 19, 59)) == 0         # before the window
    assert env.step(at(2026, 10, 14, 21, 0)) == 0          # after it
    with db.tx(env.path) as c:
        c.execute("UPDATE runs SET plan_next_type=NULL, plan_next_day=NULL")
    assert env.step(at(2026, 10, 14, 20, 5)) == 0
    assert env.sends() == []


def test_stop_silences_every_check_in(env, client):
    from conftest import post_tg, tg_update
    post_tg(client, tg_update(next(_upd), "STOP"))
    env.base = len(env.fakes.tg)   # after the "Paused" reply
    assert env.step(at(2026, 10, 14, 20, 5)) == 0 and env.step(at(2026, 10, 15, 6, 45)) == 0
    assert env.sends() == []


# ================================================================= the morning card
def test_the_morning_card_goes_before_the_usual_start_and_skip_asks_why_then_moves_the_session(env):
    assert env.step(at(2026, 10, 15, 6, 40)) == 0           # not yet: due 06:45 for a 07:00 runner
    assert env.step(at(2026, 10, 15, 6, 45)) == 1
    [msg] = env.sends()
    assert msg["text"].startswith("Today: Quality session, 6 km\nPlanned for around 7:00. Going?")
    now = at(2026, 10, 15, 6, 50)
    assert edited_text(env.tap("t.skip", now))[0].startswith("No problem\nWhat's up?")
    assert env.answers() == {("today", "2026-10-15"): "skip"}
    moved = edited_text(env.tap("w.tired", now))[0]
    assert moved.startswith("Moved\nQuality session, 6 km moves to Mon 19. I'll keep the next 3 days light.")
    assert env.answers() == {("today", "2026-10-15"): "skip", ("why", "2026-10-15"): "tired"}
    assert len(env.sends()) == 1 and len(env.q("SELECT * FROM question_cap")) == 1   # follow-ups are exempt from the cap
    undone = edited_text(env.tap("u.undo", now))[0]
    assert undone.startswith("Today: Quality session, 6 km") and env.answers() == {}


def test_going_now_and_later_edit_in_place_and_can_be_changed(env):
    env.step(at(2026, 10, 15, 6, 45))
    assert edited_text(env.tap("t.go", at(2026, 10, 15, 6, 46)))[0].startswith("Go well")
    assert edited_text(env.tap("t.later", at(2026, 10, 15, 6, 47)))[0].startswith("Later it is")
    assert env.answers() == {("today", "2026-10-15"): "later"}


def test_ill_gets_a_conservative_line_with_a_see_a_doctor_note(env):
    env.step(at(2026, 10, 15, 6, 45))
    env.tap("t.skip", at(2026, 10, 15, 6, 50))
    text = edited_text(env.tap("w.ill", at(2026, 10, 15, 6, 51)))[0]
    assert text.startswith("Rest up") and "see a doctor" in text and "a week" in text and "Fri 23" in text
    env.tap("u.undo", at(2026, 10, 15, 6, 52))
    env.tap("t.skip", at(2026, 10, 15, 6, 53))
    assert "get it looked at" in edited_text(env.tap("w.sore", at(2026, 10, 15, 6, 54)))[0]


def test_no_morning_card_when_the_runner_has_already_run_today(env):
    env.run("early", at(2026, 10, 15, 5, 30), now=at(2026, 10, 15, 6, 30), plan_next={
        "type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000})
    env.svc.run_outbox(at(2026, 10, 15, 6, 31))   # its own run card
    sent = len(env.sends())
    assert env.step(at(2026, 10, 15, 6, 45)) == 0 and len(env.sends()) == sent


def test_quiet_hours_that_end_after_the_usual_start_skip_the_card_rather_than_send_it_late(env, client):
    r = client.put("/v1/me/settings", json={"quiet_start_min": 22 * 60, "quiet_end_min": 7 * 60}, headers=auth(env.token))
    assert r.status_code == 200
    for t in (at(2026, 10, 15, 6, 45), at(2026, 10, 15, 7, 0), at(2026, 10, 15, 7, 30)):
        assert env.step(t) == 0
    assert env.sends() == []


def test_quiet_hours_that_end_before_the_start_move_the_card_to_the_end_of_quiet(env, client):
    client.put("/v1/me/settings", json={"quiet_start_min": 22 * 60, "quiet_end_min": 6 * 60 + 50}, headers=auth(env.token))
    assert env.step(at(2026, 10, 15, 6, 49)) == 0    # 06:45 is inside quiet; the card waits for its end
    assert env.step(at(2026, 10, 15, 6, 51)) == 1    # sent at 06:50, still ahead of the 07:00 start


def test_the_card_time_follows_the_wall_clock_across_the_october_dst_change(env):
    # Rome leaves summer time on Sun 25 Oct: 06:45 local is 04:45 UTC before it and 05:45 UTC after it
    assert ci.at_local(date(2026, 10, 24), 6 * 60 + 45, "Europe/Rome") == datetime(2026, 10, 24, 4, 45, tzinfo=timezone.utc)
    assert ci.at_local(date(2026, 10, 26), 6 * 60 + 45, "Europe/Rome") == datetime(2026, 10, 26, 5, 45, tzinfo=timezone.utc)
    env.run("mon", at(2026, 10, 24, 7, 0), now=at(2026, 10, 24, 20, 0), plan_next={
        "type": "easy", "day": "2026-10-26", "week": 4, "distance_m": 5000})
    assert env.step(datetime(2026, 10, 26, 5, 44, tzinfo=timezone.utc)) == 0
    assert env.step(datetime(2026, 10, 26, 5, 46, tzinfo=timezone.utc)) == 1


# ================================================================= C1: one question a day
def test_one_question_per_local_day_and_concurrent_claims_have_one_winner(env):
    results = []

    def claim():
        with db.tx(env.path) as c:
            results.append(env.svc._ci_claim_question(c, env.uid, "ready", at(2026, 10, 14, 20, 5)))

    threads = [threading.Thread(target=claim) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert sorted(results) == [False] * 7 + [True]
    assert len(env.q("SELECT * FROM question_cap")) == 1


def test_the_evening_suggestion_and_the_weekly_question_yield_to_a_check_in_sent_the_same_day(env):
    now = at(2026, 10, 14, 20, 5)
    env.step(now)
    assert len(env.sends()) == 1
    assert env.svc._build_evening_card(env.uid, "2026-10-14", now) is None
    assert env.svc._build_question_card(env.uid, "last", now) is None
    # the next local day is a new day: the morning card is allowed
    assert env.step(at(2026, 10, 15, 6, 45)) == 1


def test_a_question_sent_earlier_in_the_day_holds_the_check_in_back(env):
    with db.tx(env.path) as c:
        env.svc._ci_claim_question(c, env.uid, "question", at(2026, 10, 14, 12, 0))
    env.step(at(2026, 10, 14, 20, 5))
    assert env.sends() == []


def test_the_day_is_the_runners_local_day_not_utc(env):
    # 23:30 UTC on the 14th is 01:30 on the 15th in Rome: a new local day, so a question sent at 21:00 the evening before
    # does not block it, and one sent at 00:10 local that day does
    with db.tx(env.path) as c:
        env.svc._ci_claim_question(c, env.uid, "ready", at(2026, 10, 14, 21, 0))
        assert env.svc._ci_cap_taken(c, env.uid, at(2026, 10, 15, 0, 10)) is False
        env.svc._ci_claim_question(c, env.uid, "ready", at(2026, 10, 15, 0, 10))
        assert env.svc._ci_cap_taken(c, env.uid, at(2026, 10, 15, 23, 59)) is True
        assert env.svc._ci_cap_taken(c, env.uid, at(2026, 10, 14, 23, 59)) is True


# ================================================================= C2: at most once, and never late
def test_a_replayed_outbox_row_does_not_send_a_second_time(env):
    now = at(2026, 10, 14, 20, 5)
    env.step(now)
    with db.tx(env.path) as c:   # a restart that makes the finished row claimable again
        c.execute("UPDATE outbox SET state='pending', due_at=? WHERE kind='ci'", (iso(now),))
    env.svc.run_outbox(now + timedelta(minutes=1))
    assert len(env.sends()) == 1 and len(env.q("SELECT * FROM checkin_slots")) == 1


def test_a_send_that_timed_out_may_have_been_delivered_so_it_is_not_sent_again(env):
    now = at(2026, 10, 14, 20, 5)
    env.fakes.fail("sendMessage", timeout=True)
    env.step(now)
    assert len(env.sends()) == 1                       # Telegram got it; we never saw the answer
    assert env.slot()["state"] == "claimed"
    with db.tx(env.path) as c:
        c.execute("UPDATE outbox SET state='pending', due_at=?", (iso(now),))
    env.svc.run_outbox(now + timedelta(minutes=1))
    assert len(env.sends()) == 1


def test_a_refused_send_releases_the_claim_and_a_429_is_retried_after_retry_after(env):
    now = at(2026, 10, 14, 20, 5)
    env.fakes.fail("sendMessage", status=429, description="Too Many Requests: retry after 90", retry_after=90)
    env.step(now)
    assert env.sends() == [] and env.q("SELECT * FROM checkin_slots") == [] and env.q("SELECT * FROM question_cap") == []
    [row] = env.q("SELECT * FROM outbox WHERE kind='ci'")
    assert row["state"] == "pending" and parse(row["due_at"]) >= now + timedelta(seconds=90)
    env.svc.run_outbox(now + timedelta(seconds=30))     # too early: not due
    assert env.sends() == []
    env.svc.run_outbox(now + timedelta(minutes=3))
    assert len(env.sends()) == 1 and env.slot()["state"] == "sent"


def parse(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def test_a_slot_past_its_window_is_dropped_not_sent_late(env):
    now = at(2026, 10, 14, 20, 5)
    env.svc.plan_checkins(now)                          # queued, but the worker was down
    env.svc.run_outbox(now + timedelta(minutes=76))
    assert env.sends() == []
    [row] = env.q("SELECT * FROM outbox WHERE kind='ci'")
    assert row["state"] == "skipped"


def test_a_check_in_held_by_quiet_hours_is_dropped_when_quiet_outlasts_its_window(env, client):
    client.put("/v1/me/settings", json={"quiet_start_min": 20 * 60 + 30, "quiet_end_min": 7 * 60}, headers=auth(env.token))
    now = at(2026, 10, 14, 20, 5)
    env.svc.plan_checkins(now)
    env.svc.run_outbox(now + timedelta(minutes=30))     # inside quiet now: would be deferred to 07:00, long past its window
    [row] = env.q("SELECT * FROM outbox WHERE kind='ci'")
    assert env.sends() == [] and row["state"] == "skipped"


def test_a_check_in_no_longer_wanted_is_not_sent(env):
    now = at(2026, 10, 14, 20, 5)
    env.svc.plan_checkins(now)
    with db.tx(env.path) as c:   # answered elsewhere before the worker got to it
        c.execute("INSERT INTO checkin_answers VALUES (?,?,?,?,?)", (env.uid, "ready", "2026-10-15", "fresh", iso(now)))
    env.svc.run_outbox(now)
    assert env.sends() == []


# ================================================================= taps: stale, foreign, doubled
def test_a_stale_tap_gets_a_toast_loses_its_keyboard_and_records_nothing(env):
    env.step(at(2026, 10, 14, 20, 5))
    calls = env.tap("r.fresh", at(2026, 10, 16, 9, 0))        # the day after the session
    assert [m for m, _ in calls] == ["answerCallbackQuery", "editMessageReplyMarkup"]
    assert calls[0][1]["text"] == "That one has moved on." and calls[1][1]["reply_markup"] == {"inline_keyboard": []}
    assert env.answers() == {}


def test_a_tap_from_someone_who_is_not_the_runner_changes_nothing(env):
    env.step(at(2026, 10, 14, 20, 5))
    slot = env.slot()
    calls = env.tap("r.sore", at(2026, 10, 14, 20, 6), ref="999000111")
    assert env.answers() == {} and "editMessageText" not in [m for m, _ in calls]


def test_a_tap_on_an_old_message_after_it_was_replaced_is_stale(env):
    env.step(at(2026, 10, 14, 20, 5))
    slot = env.slot()
    calls = env.tap("r.fresh", at(2026, 10, 14, 20, 6), message_id=int(slot["message_id"]) + 50)
    assert env.answers() == {} and calls[0][1]["text"] == "That one has moved on."


def test_a_reason_is_only_accepted_while_the_runner_has_said_skip(env):
    env.step(at(2026, 10, 15, 6, 45))
    env.tap("t.skip", at(2026, 10, 15, 6, 46))
    env.tap("u.undo", at(2026, 10, 15, 6, 47))
    calls = env.tap("w.sore", at(2026, 10, 15, 6, 48))         # a double tap landing after Undo
    assert env.answers() == {} and calls[0][1]["text"] == "That one has moved on."


def test_a_double_tap_records_one_answer_and_edits_to_the_same_text(env):
    env.step(at(2026, 10, 15, 6, 45))
    env.tap("t.skip", at(2026, 10, 15, 6, 46))
    env.fakes.fail("editMessageText", description="Bad Request: message is not modified: specified new message content "
                   "and reply markup are exactly the same")
    calls = env.tap("t.skip", at(2026, 10, 15, 6, 46))
    assert env.answers() == {("today", "2026-10-15"): "skip"}
    assert "sendMessage" not in [m for m, _ in calls] and env.q("SELECT * FROM outbox WHERE kind='ci_edit'") == []


def test_an_unknown_code_is_a_stale_button(env):
    env.step(at(2026, 10, 14, 20, 5))
    calls = env.tap("z.nope", at(2026, 10, 14, 20, 6))
    assert env.answers() == {} and calls[0][1]["text"] == "That one has moved on."


# ================================================================= failures around the edit
def test_when_the_message_was_deleted_the_edit_becomes_a_fresh_message_and_the_id_is_updated(env):
    now = at(2026, 10, 15, 6, 45)
    env.step(now)
    old = env.slot()["message_id"]
    env.fakes.fail("editMessageText", description="Bad Request: message to edit not found")
    env.tap("t.skip", now + timedelta(minutes=1))
    new = env.slot()["message_id"]
    assert new != old and env.sends()[-1]["text"].startswith("No problem")
    # the next tap is on the new message
    assert edited_text(env.tap("w.busy", now + timedelta(minutes=2)))[0].startswith("Moved")
    assert env.answers()[("why", "2026-10-15")] == "busy"


def test_a_429_on_the_edit_queues_a_retry_that_rebuilds_the_message_from_the_answers(env):
    now = at(2026, 10, 15, 6, 45)
    env.step(now)
    env.fakes.fail("editMessageText", status=429, description="Too Many Requests: retry after 20", retry_after=20)
    env.tap("t.skip", now + timedelta(minutes=1))
    [row] = env.q("SELECT * FROM outbox WHERE kind='ci_edit'")
    assert parse(row["due_at"]) >= now + timedelta(minutes=1, seconds=20)
    env.tap("w.tired", now + timedelta(minutes=1, seconds=5))   # another tap before the retry runs
    env.svc.run_outbox(now + timedelta(minutes=3))
    assert edited_text(env.fakes.tg[-3:])[-1].startswith("Moved") or edited_text(env.fakes.tg)[-1].startswith("Moved")
    assert env.q("SELECT state FROM outbox WHERE kind='ci_edit'")[0]["state"] == "done"


def test_a_failed_outbox_send_with_retry_after_waits_at_least_that_long(env):
    now = at(2026, 10, 14, 20, 5)
    with db.tx(env.path) as c:
        c.execute("INSERT INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                  (env.uid, "run_card", iso(now), "x1", "last"))
    env.fakes.fail("sendMessage", status=429, description="Too Many Requests: retry after 600", retry_after=600)
    env.svc.run_outbox(now)
    [row] = env.q("SELECT * FROM outbox WHERE dedupe_key='x1'")
    assert row["state"] == "pending" and parse(row["due_at"]) >= now + timedelta(seconds=600)


# ================================================================= C3: the run card becomes the result
PLAN = {"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000}


def run_thursday(env, run_id="thu", *, plan_next=None):
    start = at(2026, 10, 15, 7, 0)
    env.run(run_id, start, now=start + timedelta(minutes=45), type="tempo", verdict="faster",
            plan_next=plan_next or {"type": "easy", "day": "2026-10-16", "week": 3, "distance_m": 5000})
    env.svc.run_outbox(start + timedelta(minutes=46))


def test_the_run_card_edits_the_morning_card_into_the_result(env):
    env.step(at(2026, 10, 15, 6, 45))
    morning = env.slot()["message_id"]
    sent_before = len(env.sends())
    run_thursday(env)
    [(_, edit)] = [c for c in env.fakes.tg if c[0] == "editMessageText"]
    assert edit["message_id"] == int(morning)
    assert len(env.sends()) == sent_before                         # no new message for the result
    assert env.slot()["state"] == "consumed" and env.slot()["message_id"] == morning
    assert [b["text"] for b in edit["reply_markup"]["inline_keyboard"][0]] == ["Easy", "Right", "Hard"]


def test_not_modified_counts_as_a_successful_result_edit(env):
    env.step(at(2026, 10, 15, 6, 45))
    sent_before = len(env.sends())
    env.fakes.fail("editMessageText", description="Bad Request: message is not modified")
    run_thursday(env)
    assert len(env.sends()) == sent_before and env.slot()["state"] == "consumed"


@pytest.mark.parametrize("why", ["Bad Request: message to edit not found", "Bad Request: message can't be edited"])
def test_if_the_edit_fails_the_result_is_sent_fresh_and_the_stored_id_updated(env, why):
    env.step(at(2026, 10, 15, 6, 45))
    morning = env.slot()["message_id"]
    sent_before = len(env.sends())
    env.fakes.fail("editMessageText", description=why)
    run_thursday(env)
    assert len(env.sends()) == sent_before + 1                      # the result card was not lost
    slot = env.slot()
    assert slot["state"] == "consumed" and slot["message_id"] != morning
    assert env.q("SELECT sent_at FROM cards WHERE kind='run'")[0]["sent_at"]
    assert any(m == "editMessageReplyMarkup" for m, _ in env.fakes.tg)  # the old card loses its buttons


def test_a_second_run_the_same_day_and_an_unplanned_run_are_new_messages(env):
    env.step(at(2026, 10, 15, 6, 45))
    run_thursday(env)
    n = len(env.sends())
    start = at(2026, 10, 15, 17, 0)
    env.run("evening", start, now=start + timedelta(minutes=45), plan_next={
        "type": "easy", "day": "2026-10-16", "week": 3, "distance_m": 5000})
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert len(env.sends()) == n + 1                                 # consumed: the second run is its own message


def test_a_run_on_a_day_with_no_morning_card_is_a_plain_new_message(env):
    start = at(2026, 10, 17, 7, 0)
    env.run("sat", start, now=start + timedelta(minutes=45))
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert len(env.sends()) == 1 and not [m for m, _ in env.fakes.tg if m.startswith("editMessage")]


def test_a_429_while_editing_the_result_retries_the_card_and_never_loses_it(env):
    env.step(at(2026, 10, 15, 6, 45))
    start = at(2026, 10, 15, 7, 0)
    env.run("thu", start, now=start + timedelta(minutes=45), type="tempo", verdict="faster")
    env.fakes.fail("editMessageText", status=429, description="Too Many Requests: retry after 30", retry_after=30)
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert env.slot()["state"] == "sent" and env.q("SELECT state FROM outbox WHERE kind='run_card'")[0]["state"] == "pending"
    env.svc.run_outbox(start + timedelta(minutes=50))
    assert env.slot()["state"] == "consumed"


# ================================================================= the post-run question
def ambiguous_run(env, run_id="amb", start=None, **over):
    start = start or at(2026, 10, 15, 7, 0)
    env.run(run_id, start, now=start + timedelta(minutes=45), type="easy", verdict="slower",
            zone_min={"z2": 8, "z3": 14, "z4": 4}, plan_next={"type": "easy", "day": "2026-10-17", "week": 3, "distance_m": 5000},
            **over)
    env.svc.run_outbox(start + timedelta(minutes=46))
    return start


def test_a_post_run_question_is_asked_only_when_the_run_is_ambiguous_and_30_minutes_after_the_card(env):
    start = ambiguous_run(env)
    assert env.svc.plan_checkins(start + timedelta(minutes=60)) == 0       # card went at +46, question due at +76
    env.step(start + timedelta(minutes=80))
    texts = [b["text"] for b in env.sends()]
    assert texts[-1].startswith("Anything behind that one?")
    assert edited_text(env.tap("p.heat", start + timedelta(minutes=81)))[0].startswith("Noted\nHeat does that")
    assert env.answers() == {("postrun", "2026-10-15"): "heat"}


def test_a_clear_run_gets_no_post_run_question(env):
    start = at(2026, 10, 15, 7, 0)
    env.run("ok", start, now=start + timedelta(minutes=45), type="easy", verdict="holding", zone_min={"z2": 30},
            plan_next={"type": "easy", "day": "2026-10-17", "week": 3, "distance_m": 5000})
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert env.step(start + timedelta(minutes=90)) == 0


def test_a_post_run_question_is_skipped_when_an_earlier_answer_already_explains_the_run(env):
    with db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_answers VALUES (?,?,?,?,?)", (env.uid, "why", "2026-10-14", "tired", iso(at(2026, 10, 14, 7, 0))))
    start = ambiguous_run(env)
    assert env.step(start + timedelta(minutes=80)) == 0


def test_sleep_or_stress_after_a_run_goes_light_for_two_days(env):
    start = ambiguous_run(env)
    env.step(start + timedelta(minutes=80))
    assert "next couple of days easy" in edited_text(env.tap("p.sleep", start + timedelta(minutes=81)))[0]
    with db.ro(env.path) as c:
        a = env.svc._ci_answers(c, env.uid, start + timedelta(minutes=82))
    assert ci.lighter_until(a, date(2026, 10, 15)) == date(2026, 10, 17)


# ================================================================= the Sunday question
def test_sunday_asks_how_many_runs_and_away_moves_next_weeks_session(env):
    env.run("sat", at(2026, 10, 24, 7, 0), now=at(2026, 10, 24, 20, 0),
            plan_next={"type": "quality", "day": "2026-10-27", "week": 4, "distance_m": 6000})
    assert env.step(at(2026, 10, 25, 18, 50)) == 0                       # before 19:05
    assert env.step(at(2026, 10, 25, 19, 10)) == 1
    assert env.sends()[-1]["text"].startswith("Next week\nHow many runs are you up for?")
    assert edited_text(env.tap("s.4", at(2026, 10, 25, 19, 11)))[0].startswith("4 runs next week")
    assert "Quality session, 6 km, Tue 27" in edited_text(env.tap("s.4", at(2026, 10, 25, 19, 12)))[0]
    away = edited_text(env.tap("s.away", at(2026, 10, 25, 19, 13)))[0]
    assert away.startswith("Away next week") and "Back on Mon 2" in away
    assert env.answers() == {("shape", "2026-10-26"): "away"}
    nxt = env.svc.next_session(env.uid, at(2026, 10, 25, 19, 14))["next_session"]
    assert nxt["date"] == "2026-11-02" and nxt["moved"] and nxt["original_date"] == "2026-10-27"


# ================================================================= A2: nothing from a check-in reaches the writer
def spy_writer(env):
    seen = []
    real = env.svc.writer.write

    def write(*a, **k):
        seen.append(json.dumps([repr(a), repr(k)], default=str))
        return real(*a, **k)

    env.svc.writer.write = write
    return seen


@pytest.mark.parametrize("value", ["tired", "sore", "ill", "flat", "sleep"])
def test_no_check_in_value_reaches_the_writer_but_the_card_carries_a_templated_line(env, value):
    kind = {"tired": "why", "sore": "why", "ill": "why", "flat": "ready", "sleep": "postrun"}[value]
    day = {"why": "2026-10-15", "ready": "2026-10-16", "postrun": "2026-10-15"}[kind]
    with db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_answers VALUES (?,?,?,?,?)", (env.uid, kind, day, value, iso(at(2026, 10, 15, 8, 0))))
    seen = spy_writer(env)
    start = at(2026, 10, 16, 7, 0)
    env.run("fri", start, now=start + timedelta(minutes=45), type="easy", verdict="slower")
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert seen, "the writer ran for the card"
    blob = " ".join(seen) + json.dumps(env.fakes.llm)
    assert not re.search(rf"\b{value}\b", blob, re.I), blob
    assert not re.search(r"checkin|readiness|skip", blob, re.I)
    sent = env.sends()[-1]["text"]
    assert sent.count("You said") == 1                                     # the templated line rode the card
    [card] = env.q("SELECT body FROM cards WHERE kind='run'")
    assert "You said" not in card["body"]                                  # and was never stored with it


def test_the_tired_line_only_fits_a_slower_run(env):
    with db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_answers VALUES (?,?,?,?,?)", (env.uid, "why", "2026-10-15", "tired", iso(at(2026, 10, 15, 8, 0))))
    start = at(2026, 10, 16, 7, 0)
    env.run("fri", start, now=start + timedelta(minutes=45), type="easy", verdict="faster")
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert "You said" not in env.sends()[-1]["text"]
    assert cc.run_line([("why", "tired", date(2026, 10, 15))], "slower", date(2026, 10, 16)) == \
        "You said you were tired yesterday, and this fits it. It reads as fatigue, not lost fitness."
    assert "see a doctor" in cc.run_line([("why", "ill", date(2026, 10, 15))], "faster", date(2026, 10, 16))
    assert "get it looked at" in cc.run_line([("why", "sore", date(2026, 10, 14))], "holding", date(2026, 10, 16))


def test_the_writer_and_facts_modules_know_nothing_of_check_ins():
    import companion.facts as facts
    import companion.writer as writer
    for mod in (writer, facts):
        src = open(mod.__file__).read().lower()
        assert "checkin" not in src and "question_cap" not in src


def test_a_softened_evening_suggestion_from_a_skip_is_templated_and_skips_the_writer(env):
    day = date(2026, 10, 14)
    with db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_answers VALUES (?,?,?,?,?)", (env.uid, "today", "2026-10-12", "skip", iso(at(2026, 10, 12, 8, 0))))
    # make the evening suggestion eligible: a hard run two evenings ago and a quiet tomorrow
    env.run("tempo", at(2026, 10, 12, 7, 0), now=at(2026, 10, 12, 18, 0), type="tempo")
    seen = spy_writer(env)
    cid = env.svc._build_evening_card(env.uid, day.isoformat(), at(2026, 10, 13, 20, 5))
    if cid is not None:
        assert seen == []
        [row] = env.q("SELECT source FROM cards WHERE card_id=?", cid)
        assert row["source"] == "template"


# ================================================================= P1: 14 days, DELETE, export, backups
def put(env, kind, d, value, created):
    with db.tx(env.path) as c:
        c.execute("INSERT OR REPLACE INTO checkin_answers VALUES (?,?,?,?,?)", (env.uid, kind, d, value, iso(created)))


def test_answers_are_kept_14_days_and_gone_by_day_15(env):
    now = at(2026, 11, 3, 12, 0)
    put(env, "ready", "2026-10-21", "fresh", now - timedelta(days=13, hours=23))
    put(env, "ready", "2026-10-20", "flat", now - timedelta(days=14))               # exactly 14 days: kept
    put(env, "why", "2026-10-19", "tired", now - timedelta(days=14, minutes=1))
    put(env, "today", "2026-10-18", "skip", now - timedelta(days=15))
    with db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_slots (user_id, slot, local_date, state, claimed_at) VALUES (?,?,?,?,?)",
                  (env.uid, "ready", "2026-10-18", "sent", iso(now - timedelta(days=15))))
        c.execute("INSERT INTO question_cap VALUES (?,?,?,?)", (env.uid, "2026-10-18", "ready", iso(now - timedelta(days=15))))
        c.execute("INSERT INTO question_cap VALUES (?,?,?,?)", (env.uid, "2026-10-30", "ready", iso(now - timedelta(days=4))))
    env.svc.purge(now)
    assert sorted(v for v in env.answers().values()) == ["flat", "fresh"]
    assert env.q("SELECT * FROM checkin_slots") == []
    assert [r["local_date"] for r in env.q("SELECT * FROM question_cap")] == ["2026-10-30"]


def test_a_derived_lighter_window_goes_with_the_answers(env):
    now = at(2026, 10, 15, 9, 0)
    put(env, "today", "2026-10-15", "skip", now)
    put(env, "why", "2026-10-15", "tired", now)
    assert env.svc.next_session(env.uid, now)["next_session"]["moved"] is True
    env.svc.purge(now + timedelta(days=15))
    assert env.answers() == {}
    with db.ro(env.path) as c:
        assert env.svc._ci_lighter(c, env.uid, now + timedelta(days=15), date(2026, 11, 1)) is False


def test_delete_removes_the_check_in_tables_and_the_export_shows_the_answers(env, client):
    now = datetime.now(timezone.utc)
    put(env, "why", now.date().isoformat(), "tired", now - timedelta(days=1))
    put(env, "why", "2020-01-01", "ill", now - timedelta(days=30))                  # past retention: never shown
    with db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_slots (user_id, slot, local_date, state, claimed_at) VALUES (?,?,?,?,?)",
                  (env.uid, "today", "2026-10-15", "sent", iso(now)))
        c.execute("INSERT INTO question_cap VALUES (?,?,?,?)", (env.uid, "2026-10-15", "today", iso(now)))
    me = client.get("/v1/me", headers=auth(env.token)).json()
    assert [(x["kind"], x["value"]) for x in me["checkins"]] == [("why", "tired")]
    assert client.delete("/v1/me", headers=auth(env.token)).json() == {"status": "deleted"}
    for t in ("checkin_answers", "checkin_slots", "question_cap"):
        assert env.q(f"SELECT COUNT(*) n FROM {t}")[0]["n"] == 0, t


def test_the_nightly_backup_leaves_the_check_in_tables_out(env, tmp_path):
    from companion.backup import PRIVATE_TABLES, backup, restore
    put(env, "why", "2026-10-15", "ill", at(2026, 10, 15, 8, 0))
    with db.tx(env.path) as c:
        c.execute("INSERT INTO question_cap VALUES (?,?,?,?)", (env.uid, "2026-10-15", "today", iso(at(2026, 10, 15, 6, 45))))
    assert set(PRIVATE_TABLES) == {"checkin_answers", "checkin_slots", "question_cap"}
    key = tmp_path / "k.key"
    key.write_bytes(b"k" * 32)
    enc = backup(env.path, str(tmp_path / "bk"), str(key))
    out = str(tmp_path / "restored.db")
    restore(enc, out, str(key))
    c = sqlite3.connect(out)
    for t in PRIVATE_TABLES:
        assert c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] == 0, t
    assert c.execute("SELECT COUNT(*) FROM runs").fetchone()[0] > 0                 # everything else is still there
    assert env.q("SELECT COUNT(*) n FROM checkin_answers")[0]["n"] == 1             # the live database is untouched


def test_the_privacy_page_says_what_check_ins_keep_and_for_how_long():
    page = open(__file__.rsplit("/companion-server/", 1)[0] + "/docs/privacy/index.html").read()
    low = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", page)).lower()
    for needle in ("check-in", "14 days", "sore", "ill", "never sent to openrouter"):
        assert needle in low, needle
    assert "at most one a week, and only inside a run note" not in low


# ================================================================= the app's read-only endpoint
def test_next_session_needs_the_device_token(client, env):
    assert client.get("/v1/me/next-session").status_code == 401
    assert client.get("/v1/me/next-session", headers=auth("nope")).status_code == 401
    assert client.get("/v1/me/next-session", headers={"Authorization": f"Bearer {TG_TOKEN}"}).status_code == 401


def test_next_session_returns_the_plan_then_the_moved_session_with_the_latest_coach_line(env, client):
    start = at(2026, 10, 13, 7, 0)
    r = client.get("/v1/me/next-session", headers=auth(env.token))
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    body = r.json()
    assert body["v"] == 1 and set(body) == {"v", "generated_at", "next_session", "coach_line"}
    assert body["coach_line"] is None
    # the endpoint reads the real clock for "today": pin it through the service for the dated assertions below
    n = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))["next_session"]
    assert n == {"date": "2026-10-15", "type": "quality", "minutes": None, "distance_m": 6000, "week": 3, "weeks": 4,
                 "moved": False, "original_date": None, "label": "Quality session, 6 km"}
    put(env, "today", "2026-10-15", "skip", at(2026, 10, 15, 7, 0))
    put(env, "why", "2026-10-15", "ill", at(2026, 10, 15, 7, 1))
    moved = env.svc.next_session(env.uid, at(2026, 10, 15, 8, 0))
    assert moved["next_session"]["date"] == "2026-10-23" and moved["next_session"]["moved"] is True
    assert moved["next_session"]["original_date"] == "2026-10-15"
    assert not re.search(r"\b(ill|tired|skip|sore|flat|why|reason)\b", json.dumps(moved), re.I)   # the move, never the reason
    # a sent run card is the latest coach line
    run_thursday(env)
    line = env.svc.next_session(env.uid, at(2026, 10, 15, 9, 0))["coach_line"]
    assert line["kind"] == "run" and line["headline"] and line["sent_at"]


def test_next_session_is_empty_without_a_plan_and_the_json_holds_no_answer(env):
    with db.tx(env.path) as c:
        c.execute("UPDATE runs SET plan_next_type=NULL, plan_next_day=NULL")
    out = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))
    assert out["next_session"] is None and out["coach_line"] is None


def test_next_session_is_the_same_resolver_the_questions_use(env):
    """The evening rule, the morning card and the app all read one answer: moved here means moved there."""
    put(env, "ready", "2026-10-15", "not_tomorrow", at(2026, 10, 14, 20, 0))
    now = at(2026, 10, 14, 20, 30)
    assert env.svc.next_session(env.uid, now)["next_session"]["date"] == "2026-10-16"
    assert env.step(at(2026, 10, 15, 6, 45)) == 0                    # nothing to check in on: the session is not today


# ================================================================= the Telegram client
def test_telegram_errors_carry_their_meaning(client):
    from companion.channels import ChannelError
    e = ChannelError("x", status=429, description="Too Many Requests: retry after 5", retry_after=5)
    assert e.rate_limited and e.retry_after == 5 and not e.cant_edit
    assert ChannelError("x", status=400, description="Bad Request: message is not modified: same").not_modified
    for d in ("Bad Request: message to edit not found", "Bad Request: message can't be edited",
              "Bad Request: there is no text in the message to edit"):
        assert ChannelError("x", status=400, description=d).cant_edit
    assert not ChannelError("x", status=403, description="Forbidden: bot was blocked by the user").cant_edit
