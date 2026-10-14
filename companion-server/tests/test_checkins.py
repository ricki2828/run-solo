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


def agree(client, token, version=2):
    """The app's Agree tap: PUT /v1/me/consent."""
    r = client.put("/v1/me/consent", json={"consent_version": version}, headers=auth(token))
    assert r.status_code == 200, r.text


@pytest.fixture
def env(client, fakes):
    t = enrol(client)
    e = Env(client, fakes, t)
    agree(client, t)
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


def evening_ready_env(env):
    """A hard run the same evening, so the evening suggestion is eligible on 13 Oct 20:05 (tomorrow, Wed, is no plan day)."""
    env.run("tempo", at(2026, 10, 13, 18, 0), now=at(2026, 10, 13, 19, 0), type="tempo",
            plan_next={"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000})
    return at(2026, 10, 13, 20, 5)


def test_a_softened_evening_suggestion_from_a_skip_is_templated_and_skips_the_writer(env):
    now = evening_ready_env(env)
    put(env, "today", "2026-10-12", "skip", at(2026, 10, 12, 8, 0))        # lighter through 15 Oct, which covers tomorrow
    seen = spy_writer(env)
    cid = env.svc._build_evening_card(env.uid, "2026-10-13", now)
    assert cid is not None
    assert seen == []
    [row] = env.q("SELECT source FROM cards WHERE card_id=?", cid)
    assert row["source"] == "template"


def test_without_a_check_in_answer_the_same_evening_card_does_go_through_the_writer(env):
    now = evening_ready_env(env)
    seen = spy_writer(env)
    assert env.svc._build_evening_card(env.uid, "2026-10-13", now) is not None and seen


def test_ill_stops_the_evening_suggestion_and_away_does_too(env):
    now = evening_ready_env(env)
    put(env, "today", "2026-10-12", "skip", at(2026, 10, 12, 8, 0))
    put(env, "why", "2026-10-12", "ill", at(2026, 10, 12, 8, 1))
    assert env.svc._build_evening_card(env.uid, "2026-10-13", now) is None
    with db.tx(env.path) as c:
        c.execute("DELETE FROM checkin_answers")
    put(env, "shape", "2026-10-12", "away", at(2026, 10, 11, 19, 0))       # away 12-18 Oct
    assert env.svc._build_evening_card(env.uid, "2026-10-13", now) is None
    with db.tx(env.path) as c:
        c.execute("DELETE FROM checkin_answers")
    assert env.svc._build_evening_card(env.uid, "2026-10-13", now) is not None


def test_a_readiness_question_due_in_the_same_window_wins_the_day_over_the_evening_suggestion(env):
    env.run("tempo", at(2026, 10, 14, 18, 0), now=at(2026, 10, 14, 19, 0), type="tempo",
            plan_next={"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000})
    now = at(2026, 10, 14, 20, 5)
    assert env.svc._build_evening_card(env.uid, "2026-10-14", now) is None      # yields, even though it ran first
    env.svc.tick(now)
    assert any("How's the body?" in b["text"] for b in env.sends())


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
    assert "which version of the agreement you accepted" in low and "no check-in until that number" in low


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
    assert n == {"date": "2026-10-15", "type": "quality", "kind": "quality", "name": "Quality session",
                 "session_id": "quality", "name_source": "none", "minutes": None, "distance_m": 6000, "week": 3, "weeks": 4,
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


# ================================================================= the pictures (S2's cards) and the pinned week
class FakeMedia:
    """Stands in for the render client: checks every request against the real worker protocol, then returns a picture."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []
        self.refused = False

    def render_checkin(self, kind, facts):
        from render import protocol as P
        P.check_request({"v": P.VERSION, "op": "card", "kind": kind, "facts": dict(facts)})   # raises on a bad key or value
        self.calls.append((kind, dict(facts)))
        return None if self.refused else __import__("companion.media", fromlist=["Media"]).Media(photo=b"PNG-" + kind.encode())


@pytest.fixture
def penv(env):
    import dataclasses
    env.svc.s = dataclasses.replace(env.svc.s, media_enabled=True)
    env.svc.media = FakeMedia()
    return env


def kinds(env):
    return [k for k, _ in env.svc.media.calls]


def test_the_morning_card_is_a_picture_in_s2s_vocabulary_with_no_answer_in_it(penv):
    penv.step(at(2026, 10, 15, 6, 45))
    [(kind, facts)] = [c for c in penv.svc.media.calls if c[0] == "today"]
    assert facts == {"type": "tempo", "session": "Quality session", "date_local": "2026-10-15", "units": "km", "distance_km": 6.0}
    photos = [(m, b) for m, b in penv.fakes.tg if m == "sendPhoto" and "caption" in b and "Today:" in b["caption"]]
    assert photos and "Planned for around 7:00" in photos[0][1]["caption"]          # the time is in the text, not the card
    assert penv.slot("today")["is_photo"] == 1


def test_an_easy_session_always_sends_a_guide(penv):
    with db.tx(penv.path) as c:
        c.execute("UPDATE runs SET plan_next_type='easy'")
    penv.step(at(2026, 10, 15, 6, 45))
    assert [f for k, f in penv.svc.media.calls if k == "today"][0]["guide"] == "chatty"


def test_skip_with_a_reason_swaps_the_picture_to_moved_and_the_reason_never_reaches_the_renderer(penv):
    penv.step(at(2026, 10, 15, 6, 45))
    penv.tap("t.skip", at(2026, 10, 15, 6, 46))
    before = len(penv.fakes.tg)
    penv.tap("w.ill", at(2026, 10, 15, 6, 47))
    edits = [(m, b) for m, b in penv.fakes.tg[before:] if m == "editMessageMedia"]
    assert edits and "Rest up" in json.loads(edits[0][1]["media"])["caption"]
    [(_, moved)] = [c for c in penv.svc.media.calls if c[0] == "moved"]
    assert moved["from_day"] == "thu" and moved["to_day"] == "next_week" and "skip_reason" not in moved
    assert "ill" not in json.dumps(penv.svc.media.calls)
    penv.tap("u.undo", at(2026, 10, 15, 6, 48))
    assert [m for m, _ in penv.fakes.tg[-2:]] == ["answerCallbackQuery", "editMessageMedia"]   # back to the today picture


def test_the_result_replaces_the_morning_picture_with_the_verdict_card_using_the_apps_verdict(penv):
    penv.step(at(2026, 10, 15, 6, 45))
    run_thursday(penv)
    [(_, facts)] = [c for c in penv.svc.media.calls if c[0] == "today_verdict"]
    assert facts["verdict"] == "faster" and facts["type"] == "tempo" and facts["result_pace_s"] == 342.0
    assert [m for m, _ in penv.fakes.tg if m == "editMessageMedia"]
    assert penv.slot("today")["state"] == "consumed"


def test_the_week_card_is_posted_once_pinned_silently_then_edited_after_each_run_and_move(penv):
    start = at(2026, 10, 15, 7, 0)
    run_thursday(penv)                                           # a run: the week card follows
    penv.svc.run_outbox(start + timedelta(minutes=47))
    assert len([1 for m, b in penv.fakes.tg if m == "sendPhoto" and b.get("disable_notification") == "true"]) == 1
    pins = [b for m, b in penv.fakes.tg if m == "pinChatMessage"]
    assert len(pins) == 1 and pins[0]["disable_notification"] is True
    [(_, wk)] = [c for c in penv.svc.media.calls if c[0] == "pinned_week"]
    assert wk["week_label"] == "Week 42" and wk["today_idx"] == 3 and len(wk["days"]) == 7
    assert wk["days"][3]["done_km"] == 7.0 and [d["type"] for d in wk["days"]].count("rest") >= 3
    # a move edits it; it never posts a second one, and the slot is one row per runner per week
    penv.svc.plan_checkins(at(2026, 10, 15, 21, 0))
    run2 = at(2026, 10, 16, 7, 0)
    penv.run("fri", run2, now=run2 + timedelta(minutes=45), plan_next={"type": "easy", "day": "2026-10-17", "week": 3, "distance_m": 5000})
    penv.svc.run_outbox(run2 + timedelta(minutes=46))
    penv.svc.run_outbox(run2 + timedelta(minutes=48))
    assert len([1 for m, _ in penv.fakes.tg if m == "sendPhoto" and "caption" not in _]) == 1
    assert [m for m, _ in penv.fakes.tg if m == "editMessageMedia"]
    assert len(penv.q("SELECT * FROM checkin_slots WHERE slot='week'")) == 1


def test_a_deleted_week_card_is_sent_again_and_pinned_and_a_new_week_unpins_the_old(penv):
    run_thursday(penv)
    start = at(2026, 10, 15, 7, 0)
    penv.svc.run_outbox(start + timedelta(minutes=47))
    first = penv.q("SELECT message_id FROM checkin_slots WHERE slot='week'")[0]["message_id"]
    penv.fakes.fail("editMessageMedia", description="Bad Request: message to edit not found")
    penv.svc._ci_week_enqueue({"id": penv.uid, "channel": "telegram", "zone_id": "Europe/Rome"}, start + timedelta(hours=2))
    penv.svc.run_outbox(start + timedelta(hours=2, minutes=1))
    now_id = penv.q("SELECT message_id FROM checkin_slots WHERE slot='week'")[0]["message_id"]
    assert now_id != first and len([1 for m, _ in penv.fakes.tg if m == "pinChatMessage"]) == 2
    nxt = at(2026, 10, 20, 8, 0)
    penv.svc._ci_week_enqueue({"id": penv.uid, "channel": "telegram", "zone_id": "Europe/Rome"}, nxt)
    penv.svc.run_outbox(nxt + timedelta(minutes=1))
    assert len(penv.q("SELECT * FROM checkin_slots WHERE slot='week'")) == 2
    assert [b["message_id"] for m, b in penv.fakes.tg if m == "unpinChatMessage"] == [int(now_id)]


def test_no_week_card_without_a_picture_and_none_when_check_ins_are_off(penv):
    penv.svc.media.refused = True
    run_thursday(penv)
    penv.svc.run_outbox(at(2026, 10, 15, 8, 0))
    assert penv.q("SELECT * FROM checkin_slots WHERE slot='week'") == [] and not [m for m, _ in penv.fakes.tg if m == "pinChatMessage"]


# ================================================================= round 2: soften outranks the plan everywhere
LIGHTER = {
    "post-run sleep": ([("postrun", "2026-10-15", "sleep")], "2026-10-17"),
    "tired skip": ([("today", "2026-10-15", "skip"), ("why", "2026-10-15", "tired")], "2026-10-17"),
    "sore the evening before": ([("ready", "2026-10-15", "sore")], "2026-10-17"),
    "ill week with a fresh plan": ([("today", "2026-10-15", "skip"), ("why", "2026-10-15", "ill")], "2026-10-21"),
}
NO_CARD = {"ill week with a fresh plan"}   # ill: rest, so no morning card at all (the other sources still get an easy one)


@pytest.mark.parametrize("name", list(LIGHTER))
def test_inside_a_lighter_window_a_quality_session_is_easy_on_every_surface(penv, name):
    answers, plan_day = LIGHTER[name]
    for kind, d, v in answers:
        put(penv, kind, d, v, at(2026, 10, 15, 8, 0))
    with db.tx(penv.path) as c:   # the newest run brought a fresh plan (an unplanned run during the window)
        c.execute("UPDATE runs SET plan_next_day=?, plan_next_type='quality'", (plan_day,))
    day = date.fromisoformat(plan_day)
    now = at(day.year, day.month, day.day, 6, 45)
    nxt = penv.svc.next_session(penv.uid, now)["next_session"]
    assert nxt["type"] == "easy" and nxt["label"].startswith("Easy run") and nxt["date"] == plan_day   # Home
    penv.step(now)
    if name in NO_CARD:
        assert penv.sends("sendPhoto") == [] and penv.sends() == []
        return
    caption = [b["caption"] for b in penv.sends("sendPhoto") if "caption" in b][-1]
    assert caption.startswith("Today: Easy run")                                                       # the morning card
    wk = penv.svc._ci_week_facts(sqlite3_ro(penv), {"id": penv.uid, "zone_id": "Europe/Rome"},
                                 day - timedelta(days=day.weekday()), now)
    assert wk["days"][day.weekday()]["type"] == "easy"                                                  # the week card
    assert [f["type"] for k, f in penv.svc.media.calls if k == "today"][0] == "easy"                    # the picture


def sqlite3_ro(env):
    c = sqlite3.connect(env.path)
    c.row_factory = sqlite3.Row
    return c


def test_a_session_outside_the_window_stays_as_planned_and_an_easy_one_is_untouched(penv):
    put(penv, "postrun", "2026-10-15", "sleep", at(2026, 10, 15, 8, 0))     # window 15-17 Oct
    with db.tx(penv.path) as c:
        c.execute("UPDATE runs SET plan_next_day='2026-10-18', plan_next_type='quality'")
    assert penv.svc.next_session(penv.uid, at(2026, 10, 16, 9, 0))["next_session"]["type"] == "quality"
    with db.tx(penv.path) as c:
        c.execute("UPDATE runs SET plan_next_day='2026-10-16', plan_next_type='easy'")
    assert penv.svc.next_session(penv.uid, at(2026, 10, 16, 9, 0))["next_session"]["label"] == "Easy run, 6 km"


# ================================================================= round 2: the other fixes
def test_the_morning_card_is_dropped_not_sent_after_five_minutes_before_the_usual_start(env):
    env.svc.plan_checkins(at(2026, 10, 15, 6, 45))
    env.svc.run_outbox(at(2026, 10, 15, 6, 56))           # a stalled worker: the runner has started by now
    assert env.sends() == []
    assert env.q("SELECT state FROM outbox WHERE kind='ci'")[0]["state"] == "skipped"


def test_the_morning_card_is_still_sent_inside_its_window(env):
    env.svc.plan_checkins(at(2026, 10, 15, 6, 45))
    env.svc.run_outbox(at(2026, 10, 15, 6, 54))
    assert len(env.sends()) == 1


def test_a_queued_check_in_is_not_sent_once_the_flag_is_switched_off(env):
    import dataclasses
    env.svc.plan_checkins(at(2026, 10, 14, 20, 5))
    env.svc.s = dataclasses.replace(env.svc.s, checkins_enabled=False)
    env.svc.run_outbox(at(2026, 10, 14, 20, 6))
    assert env.sends() == []


def test_the_check_in_message_rows_go_after_14_days_with_the_answers(env):
    env.step(at(2026, 10, 14, 20, 5))
    run_card = env.q("SELECT COUNT(*) n FROM cards WHERE kind='run'")[0]["n"]
    env.svc.purge(at(2026, 10, 14, 20, 5) + timedelta(days=13))
    assert env.q("SELECT COUNT(*) n FROM cards WHERE kind='ci_ready'")[0]["n"] == 1
    env.svc.purge(at(2026, 10, 14, 20, 5) + timedelta(days=15))
    assert env.q("SELECT COUNT(*) n FROM cards WHERE kind='ci_ready'")[0]["n"] == 0
    assert env.q("SELECT COUNT(*) n FROM cards WHERE kind='run'")[0]["n"] <= run_card


def test_check_in_rows_written_by_a_replay_are_tagged(env):
    assert {"checkin_answers", "checkin_slots", "question_cap"} <= set(db.TAGGED)
    with db.origin(), db.tx(env.path) as c:
        c.execute("INSERT INTO checkin_slots (user_id, slot, local_date, state, claimed_at) VALUES (?,?,?,?,?)",
                  (env.uid, "week", "2026-10-12", "sent", iso(at(2026, 10, 15, 9, 0))))
    assert env.q("SELECT rid FROM replay_rows WHERE tbl='checkin_slots'") == [{"rid": "week|2026-10-12"}]


def test_a_burst_of_runs_and_taps_makes_one_week_card_render(penv):
    user = {"id": penv.uid, "channel": "telegram", "zone_id": "Europe/Rome"}
    for i in range(4):
        penv.svc._ci_week_enqueue(user, at(2026, 10, 15, 9, 0) + timedelta(seconds=i))
    assert len(penv.q("SELECT * FROM outbox WHERE kind='ci_week'")) == 1
    penv.step(at(2026, 10, 15, 9, 0) + timedelta(seconds=10))
    assert kinds(penv).count("pinned_week") == 0                      # not due yet (the debounce)
    penv.svc.run_outbox(at(2026, 10, 15, 9, 2))
    assert kinds(penv).count("pinned_week") >= 1


def test_the_usual_start_is_a_circular_median_across_midnight():
    hist = [{"start_utc": "2026-10-12T23:50:00Z", "zone_id": "UTC"}, {"start_utc": "2026-10-14T00:10:00Z", "zone_id": "UTC"}]
    assert ci.usual_start_min(hist, 0, "UTC", at(2026, 10, 15, 12, 0)) == 0


def test_next_session_names_the_session_only_when_the_plan_did_and_never_guesses_from_history(env):
    env.run("nor", at(2026, 10, 8, 7, 0), type="interval", session_name="Norwegian 4x4")      # history must not name a tempo
    n = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))["next_session"]
    assert (n["kind"], n["name"], n["session_id"], n["name_source"], n["label"]) == (
        "quality", "Quality session", "quality", "none", "Quality session, 6 km")
    with db.tx(env.path) as c:
        c.execute("UPDATE runs SET plan_next_session_name='Tempo intervals' WHERE run_id='last'")
    n = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))["next_session"]
    assert (n["name"], n["session_id"], n["name_source"], n["label"]) == (
        "Tempo intervals", "tempo_intervals", "plan", "Tempo intervals, 6 km")
    env.step(at(2026, 10, 15, 6, 45))
    assert any("Today: Tempo intervals, 6 km" in b.get("text", "") for b in env.sends())            # the messages use the same name
    put(env, "ready", "2026-10-15", "flat", at(2026, 10, 14, 20, 0))                      # made easy: a different session
    n = env.svc.next_session(env.uid, at(2026, 10, 14, 21, 0))["next_session"]
    assert (n["kind"], n["name"], n["session_id"], n["name_source"]) == ("easy", "Easy run", "easy", "none")


def planned_run(**plan):
    return RunIn(run_id="p1", type="easy", start_utc=at(2026, 10, 13, 8, 0), utc_offset_min=120, zone_id="Europe/Rome",
                 duration_s=2400, distance_m=7000, plan_week=3, plan_weeks=4,
                 plan_next={"type": "quality", "day": "2026-10-15", "week": 3, **plan})


def builtin_names():
    from companion.facts import SESSION_PURPOSE
    return [*SESSION_PURPOSE, "8 × 400 m", "12 × 400 m"]


@pytest.mark.parametrize("name", builtin_names())
def test_every_built_in_session_name_is_accepted_with_its_id_hint_and_ref(name):
    nx = planned_run(session_name=name, session_id="norwegian_4x4", session_ref="w1s1").plan_next
    assert (nx.session_name, nx.session_id, nx.session_ref) == (name, "norwegian_4x4", "w1s1")


@pytest.mark.parametrize("name", [
    "Tempo", "Easy run", "norwegian 4x4", "Norwegian 4x4!", "Norwegian  4x4", "Norwegian\u20284x4",          # not an exact name
    "N\u043erwegian 4x4", "Norwegian 4x4\u200b", "Norwegian 4x4\x00", "\u202eNorwegian 4x4",                   # homoglyph, hidden characters
    "@runner", "t.me/someone", "https://x.example", "8 x 400 m", "8 × 400 m extra", "123 × 400 m", "A" * 41,
    "my own session", "   ",
])
def test_anything_but_a_built_in_name_drops_the_name_and_its_id_and_never_the_plan(name):
    nx = planned_run(session_name=name, session_id="norwegian_4x4", session_ref="w1s1").plan_next
    assert nx is not None and nx.day == "2026-10-15" and nx.type == "quality"
    assert nx.session_name is None and nx.session_id is None          # the hint only ever rides with an accepted name
    assert nx.session_ref == "w1s1"                                   # the opaque ref is independent


@pytest.mark.parametrize("sid,ref,id_ok,ref_ok", [
    ("norwegian_4x4", "w1s1", True, True), ("Bad Slug!", "w1s1", False, True), ("x" * 41, "w1s1", False, True),
    ("norwegian-4x4", "w1s1", False, True), (None, "Bad Ref!", False, False), (None, "x" * 17, False, False),
    (None, "W1S1", False, False), (None, None, False, False),
])
def test_the_id_hint_and_the_ref_are_bounded_slugs_and_a_bad_one_is_dropped_alone(sid, ref, id_ok, ref_ok):
    kw = {k: v for k, v in (("session_id", sid), ("session_ref", ref)) if v is not None}
    nx = planned_run(session_name="Norwegian 4x4", **kw).plan_next
    assert nx.session_name == "Norwegian 4x4"
    assert (nx.session_id is not None) is id_ok and (nx.session_ref is not None) is ref_ok


def test_old_plan_next_payloads_still_validate_and_unknown_keys_stay_loud():
    assert planned_run().plan_next.session_name is None
    with pytest.raises(Exception):
        planned_run(mood="x")


def test_the_new_fields_flow_to_the_run_the_export_next_session_and_the_morning_card_but_the_ref_is_never_shown(env, client):
    env.svc.ingest_run(env.uid, planned_run(session_name="Norwegian 4x4", session_ref="w1s1", distance_m=6000), now=at(2026, 10, 13, 20, 0))
    assert env.q("SELECT plan_next_session_ref r, plan_next_session_name n FROM runs WHERE run_id='p1'") == [
        {"r": "w1s1", "n": "Norwegian 4x4"}]
    me = client.get("/v1/me", headers=auth(env.token)).json()
    assert [r["plan_next_session_name"] for r in me["runs_received"] if r["run_id"] == "p1"] == ["Norwegian 4x4"]
    out = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))
    n = out["next_session"]
    assert (n["name"], n["session_id"], n["name_source"], n["label"]) == (
        "Norwegian 4x4", "norwegian_4x4", "plan", "Norwegian 4x4, 6 km")
    assert "w1s1" not in json.dumps(out)
    env.step(at(2026, 10, 15, 6, 45))
    assert any("Today: Norwegian 4x4" in b.get("text", "") for b in env.sends())


def test_the_apps_exact_payload_is_accepted_over_http_and_the_name_reaches_next_session(env, client):
    """The templated plan_next the app sends (session_id and session_name only; there is no session_ref)."""
    start = at(2026, 10, 13, 8, 0)
    body = {"run_id": "app1", "type": "easy", "start_utc": start.isoformat(), "utc_offset_min": 120, "zone_id": "Europe/Rome",
            "duration_s": 2400, "distance_m": 7000, "plan_week": 3, "plan_weeks": 4,
            "plan_next": {"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000,
                          "session_id": "tempo", "session_name": "Tempo intervals"}}
    r = client.post("/v1/runs", json=body, headers=auth(env.token))
    assert r.status_code in (200, 202), r.text
    n = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))["next_session"]
    assert (n["name"], n["session_id"], n["name_source"], n["label"]) == (
        "Tempo intervals", "tempo", "plan", "Tempo intervals, 6 km")
    # an unknown name is dropped, not refused: the run is still accepted and the kind name shows
    bad = {**body, "run_id": "app2", "start_utc": at(2026, 10, 13, 9, 0).isoformat(),
           "plan_next": {**body["plan_next"], "session_name": "My secret session"}}
    assert client.post("/v1/runs", json=bad, headers=auth(env.token)).status_code in (200, 202)
    n = env.svc.next_session(env.uid, at(2026, 10, 14, 9, 0))["next_session"]
    assert (n["name"], n["name_source"]) == ("Quality session", "none")


# ================================================================= consent gate: the server must know the app's agreed version
@pytest.fixture
def env_nc(client, fakes):
    """A runner whose app has never told the server it agreed (an old app, or the Agree card not tapped yet)."""
    e = Env(client, fakes, enrol(client))
    e.seed()
    return e


def every_slot_time(env):
    """(label, instant) for each way a check-in can start: evening readiness, morning card, Sunday question, post-run."""
    return [("ready", at(2026, 10, 14, 20, 5)), ("today", at(2026, 10, 15, 6, 45))]


def test_an_old_app_that_never_sent_a_consent_version_gets_no_check_ins(env_nc):
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] is None
    for label, t in every_slot_time(env_nc):
        assert env_nc.step(t) == 0, label
    env_nc.run("sat", at(2026, 10, 24, 7, 0), now=at(2026, 10, 24, 20, 0),
               plan_next={"type": "quality", "day": "2026-10-27", "week": 4, "distance_m": 6000})
    assert env_nc.step(at(2026, 10, 25, 19, 10)) == 0           # the Sunday question
    assert env_nc.sends() == [] and env_nc.q("SELECT * FROM checkin_slots") == []


def test_v2_gets_check_ins_and_the_same_runner_below_it_does_not(client, env_nc):
    agree(client, env_nc.token, 1)                               # the old consent text
    assert env_nc.step(at(2026, 10, 14, 20, 5)) == 0
    agree(client, env_nc.token, 2)
    assert env_nc.step(at(2026, 10, 14, 20, 5)) == 1
    assert env_nc.sends()[-1]["text"].startswith("Quality session, 6 km tomorrow")


def test_a_downgrade_stops_new_check_ins_and_old_buttons_record_nothing(env, client):
    now = at(2026, 10, 14, 20, 5)
    env.step(now)
    agree(client, env.token, 1)                                  # e.g. the runner reinstalled an older build
    assert env.tap("r.flat", now + timedelta(minutes=1)) != [] and env.answers() == {}   # toast + keyboard cleared only
    assert env.step(at(2026, 10, 15, 6, 45)) == 0
    assert [m for m, _ in env.fakes.tg[env.base:] if m == "editMessageText"] == []
    agree(client, env.token, 0)
    assert env.step(at(2026, 10, 15, 6, 46)) == 0


def test_a_queued_check_in_is_not_sent_if_consent_is_withdrawn_before_the_worker_runs(env, client):
    now = at(2026, 10, 14, 20, 5)
    env.svc.plan_checkins(now)
    agree(client, env.token, 1)
    env.svc.run_outbox(now)
    assert env.sends() == []


def test_the_pinned_week_card_needs_consent_too(env_nc, client):
    import dataclasses
    env_nc.svc.s = dataclasses.replace(env_nc.svc.s, media_enabled=True)
    env_nc.svc._ci_week_enqueue({"id": env_nc.uid, "channel": "telegram", "zone_id": "Europe/Rome"}, at(2026, 10, 14, 9, 0))
    assert env_nc.q("SELECT * FROM outbox WHERE kind='ci_week'") == []
    agree(client, env_nc.token)
    env_nc.svc._ci_week_enqueue({"id": env_nc.uid, "channel": "telegram", "zone_id": "Europe/Rome"}, at(2026, 10, 14, 9, 0))
    assert len(env_nc.q("SELECT * FROM outbox WHERE kind='ci_week'")) == 1
    agree(client, env_nc.token, 1)
    assert env_nc.svc._ci_week_sync({"id": env_nc.uid, "channel": "telegram", "zone_id": "Europe/Rome"}, "2026-10-12",
                                    at(2026, 10, 14, 9, 0)) == ("skipped", None)


def test_the_run_card_stays_a_new_message_when_consent_is_missing(env_nc):
    """Runs and the existing coach messages work without consent: the result card is sent, just never as an edit of a check-in."""
    run_thursday(env_nc)
    assert [m for m, _ in env_nc.fakes.tg[env_nc.base:] if m in ("sendMessage", "sendPhoto")] != []
    assert [m for m, _ in env_nc.fakes.tg[env_nc.base:] if m == "editMessageText"] == []
    assert env_nc.q("SELECT * FROM cards WHERE kind='run'")


def test_the_consent_endpoint_validates_and_needs_the_device_token(env_nc, client):
    h = auth(env_nc.token)
    assert client.put("/v1/me/consent", json={"consent_version": 2}).status_code == 401
    for bad in ({"consent_version": -1}, {"consent_version": "2"}, {"consent_version": 2.5}, {"consent_version": None},
                {}, {"consent_version": 2, "extra": 1}, {"consent_version": 10 ** 6}, {"consent_version": True}):
        assert client.put("/v1/me/consent", json=bad, headers=h).status_code == 422, bad
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] is None


def test_the_run_upload_may_carry_the_consent_version_and_an_old_payload_still_posts(env_nc, client):
    start = at(2026, 10, 13, 8, 0)
    body = {"run_id": "app1", "type": "easy", "start_utc": start.isoformat(), "utc_offset_min": 120, "zone_id": "Europe/Rome",
            "duration_s": 2400, "distance_m": 7000, "plan_week": 3, "plan_weeks": 4,
            "plan_next": {"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000,
                          "session_id": "tempo", "session_name": "Tempo intervals"}}
    r = client.post("/v1/runs", json=body, headers=auth(env_nc.token))                     # the app as it is on main today
    assert r.status_code in (200, 202), r.text
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] is None
    r = client.post("/v1/runs", json={**body, "run_id": "app2", "consent_version": 2}, headers=auth(env_nc.token))
    assert r.status_code in (200, 202), r.text
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] == 2
    r = client.post("/v1/runs", json={**body, "run_id": "app3", "consent_version": 1}, headers=auth(env_nc.token))
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] == 1        # the latest report wins
    r = client.post("/v1/runs", json={**body, "run_id": "app4", "consent_version": -3}, headers=auth(env_nc.token))
    assert r.status_code == 422
    assert client.post("/v1/runs", json={**body, "run_id": "app5", "nope": 1}, headers=auth(env_nc.token)).status_code == 422


def test_delete_clears_the_consent_and_a_fresh_enrolment_starts_without_it(env, client):
    assert env.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] == 2
    me = client.get("/v1/me", headers=auth(env.token)).json()
    assert me["profile"]["checkin_consent"] == 2
    assert client.delete("/v1/me", headers=auth(env.token)).json() == {"status": "deleted"}
    assert env.q("SELECT checkin_consent FROM users") == []
    t2 = enrol(client)
    assert client.get("/v1/me", headers=auth(t2)).json()["profile"]["checkin_consent"] is None
    assert client.put("/v1/me/consent", json={"consent_version": 2}, headers=auth(env.token)).status_code == 401   # old token is gone


def test_the_cli_seeds_a_consent_version_for_one_runner_by_chat_ref_or_id(env_nc, client, capsys, caplog):
    from companion import cli
    s, svc = env_nc.svc.s, env_nc.svc
    assert env_nc.step(at(2026, 10, 14, 20, 5)) == 0
    assert cli.set_consent(s, svc, "nobody", "2") == 1 and cli.set_consent(s, svc, OWNER, "x") == 2
    assert cli.set_consent(s, svc, OWNER, "1001") == 2
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] is None
    with caplog.at_level("INFO", logger="companion"):
        assert cli.set_consent(s, svc, OWNER, "2") == 0
    assert "via cli" in caplog.text and OWNER not in capsys.readouterr().out
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] == 2
    assert env_nc.step(at(2026, 10, 14, 20, 5)) == 1                      # check-ins now flow
    assert cli.set_consent(s, svc, env_nc.uid, "1") == 0                  # by user id too; lowers it again
    assert env_nc.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] == 1


# ================================================================= consent gate, round 2 (review of #295)
def test_a_real_relink_by_an_old_app_clears_the_consent_so_no_check_ins(env, client):
    assert env.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] == 2
    enrol(client)                                    # reinstall / new phone: the full enrol flow, no consent version sent
    assert env.q("SELECT checkin_consent FROM users")[0]["checkin_consent"] is None
    assert env.step(at(2026, 10, 14, 20, 5)) == 0
    assert env.q("SELECT * FROM checkin_slots") == []


def test_stored_answers_are_ignored_once_consent_is_withdrawn(env, client):
    put(env, "why", "2026-10-15", "ill", at(2026, 10, 15, 8, 0))
    put(env, "why", "2026-10-15", "sore", at(2026, 10, 15, 8, 1))
    agree(client, env.token, 1)
    start = at(2026, 10, 16, 7, 0)
    env.run("fri", start, now=start + timedelta(minutes=45), type="easy", verdict="slower")
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert "You said" not in env.sends()[-1]["text"]
    with db.ro(env.path) as c:
        assert env.svc._ci_lighter(c, env.uid, start, date(2026, 10, 16)) is False
        assert env.svc._ci_evening_held(c, env.uid, date(2026, 10, 16), start) is False


def test_withdrawing_consent_unpins_the_week_card(penv, client):
    run_thursday(penv)
    penv.svc.run_outbox(at(2026, 10, 15, 7, 47))
    [slot] = penv.q("SELECT message_id FROM checkin_slots WHERE slot='week'")
    assert not [m for m, _ in penv.fakes.tg if m == "unpinChatMessage"]
    agree(client, penv.token, 1)
    assert [b["message_id"] for m, b in penv.fakes.tg if m == "unpinChatMessage"] == [int(slot["message_id"])]


def test_the_cli_audit_line_reaches_the_log_through_the_real_logger_setup(env_nc, monkeypatch, capsys):
    import logging
    from companion import cli
    root = logging.getLogger()
    monkeypatch.setattr(root, "handlers", [])          # as in a fresh process: nothing configured yet
    monkeypatch.setattr(cli.Settings, "from_env", staticmethod(lambda: env_nc.svc.s))
    monkeypatch.setattr(cli, "Service", lambda *a, **k: env_nc.svc)
    assert cli.main(["set-consent", env_nc.uid, "2"]) == 0
    err = capsys.readouterr().err
    assert "via cli" in err and "version=2" in err
