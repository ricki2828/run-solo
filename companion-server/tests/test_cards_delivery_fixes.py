"""Run-card delivery fixes (B1-B4), replaying the 26-Oct and 27-Oct sequences from the cards report with fixtures only:
a goal run silenced by the morning check-in, a loop dropped by the morning edit, a morning card landing mid-run, and a
log line for every skipped outbox row."""
import dataclasses
import logging
from datetime import timedelta

from companion import checkins as ci
from companion import db
from companion.media import Media
from companion.timeutil import iso
from test_checkins import at, env  # noqa: F401  (the fixture)


def loop_media():
    return Media(photo=b"PNG", video=b"MP4", animation=True, duration_s=6)


def land(env, run_id, start, minutes_after=45, **over):
    env.run(run_id, start, now=start + timedelta(minutes=minutes_after), **over)
    env.svc.run_outbox(start + timedelta(minutes=minutes_after + 1))


def old_run_card(env, start):
    with db.tx(env.path) as c:
        c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at, sent_at) "
                  "VALUES ('old', ?, 'last', 'run', 'h', 'b', '[]', 'template', ?, ?)",
                  (env.uid, iso(start - timedelta(hours=3)), iso(start - timedelta(hours=2))))


# ---- B1: 27-Oct
def test_27_oct_goal_run_gets_its_card_although_the_morning_check_in_went_out_earlier(env):
    env.step(at(2026, 10, 15, 6, 45))                          # the morning card (ci_today) is out and open
    assert env.slot()["state"] == "sent"
    land(env, "goal", at(2026, 10, 15, 7, 0), type="long", verdict=None,
         session_name="7K goal", goal_reached=True)
    assert env.q("SELECT sent_at FROM cards WHERE run_id='goal'")[0]["sent_at"]
    assert env.q("SELECT state FROM outbox WHERE kind='run_card'")[0]["state"] == "done"


def test_an_open_morning_slot_never_makes_the_run_card_a_skip_even_after_a_recent_run_card(env):
    env.step(at(2026, 10, 15, 6, 45))
    start = at(2026, 10, 15, 7, 0)
    old_run_card(env, start)                                   # normally "nothing new" for a plain run
    land(env, "plain", start, type="long", verdict=None)
    assert env.q("SELECT sent_at FROM cards WHERE run_id='plain'")[0]["sent_at"]
    assert env.slot()["state"] == "consumed"


def test_a_check_in_is_not_a_run_card_for_the_quiet_gap(env):
    env.step(at(2026, 10, 15, 6, 45))
    assert env.q("SELECT kind FROM cards WHERE kind='ci_today'")        # a recent card exists, but it is a check-in
    with db.tx(env.path) as c:
        c.execute("UPDATE checkin_slots SET state='consumed'")          # no open slot: only the gap rule decides
    land(env, "plain", at(2026, 10, 15, 7, 0), type="long", verdict=None)
    assert env.q("SELECT sent_at FROM cards WHERE run_id='plain'")[0]["sent_at"]


def test_an_ordinary_run_after_a_recent_run_card_with_no_open_slot_is_still_nothing_new_and_logged(env, caplog):
    start = at(2026, 10, 17, 7, 0)
    old_run_card(env, start)
    with caplog.at_level(logging.INFO):
        land(env, "plain", start, type="long", verdict=None)
    assert env.q("SELECT 1 FROM cards WHERE run_id='plain'") == []
    lines = [r.getMessage() for r in caplog.records if r.getMessage().startswith("outbox skipped")]   # B4
    assert len(lines) == 1 and "kind=run_card" in lines[0] and "nothing_new" in lines[0]


# ---- B2: 26-Oct
def test_26_oct_the_loop_goes_out_as_a_new_animation_and_the_morning_card_becomes_a_one_line_result(env, monkeypatch):
    env.svc.s = dataclasses.replace(env.svc.s, media_enabled=True)
    env.step(at(2026, 10, 15, 6, 45))
    morning = env.slot()["message_id"]
    monkeypatch.setattr(env.svc, "_render_media", lambda user, card, now: loop_media() if card["kind"] == "run" else None)
    before = len(env.fakes.tg)
    land(env, "thu", at(2026, 10, 15, 7, 0), type="tempo", verdict="faster")
    new = env.fakes.tg[before:]
    methods = [m for m, _ in new]
    assert methods.count("sendAnimation") == 1 and "editMessageMedia" not in methods
    [(_, edit)] = [c for c in new if c[0] in ("editMessageText", "editMessageCaption")]
    assert edit["message_id"] == int(morning) and edit["reply_markup"] == {"inline_keyboard": []}
    text = edit.get("text") or edit.get("caption")
    assert text.strip() and "\n" not in text.strip()
    slot = env.slot()
    assert slot["state"] == "consumed" and slot["message_id"] != morning


def test_a_rate_limited_morning_edit_after_the_loop_never_sends_a_second_loop(env, monkeypatch):
    env.svc.s = dataclasses.replace(env.svc.s, media_enabled=True)
    env.step(at(2026, 10, 15, 6, 45))
    monkeypatch.setattr(env.svc, "_render_media", lambda user, card, now: loop_media() if card["kind"] == "run" else None)
    for m in ("editMessageText", "editMessageCaption"):
        env.fakes.fail(m, status=429, description="Too Many Requests: retry after 30", retry_after=30)
    land(env, "thu", at(2026, 10, 15, 7, 0), type="tempo", verdict="faster")
    assert [m for m, _ in env.fakes.tg].count("sendAnimation") == 1
    assert env.slot()["state"] == "consumed" and env.q("SELECT state FROM outbox WHERE kind='run_card'")[0]["state"] == "done"


def test_with_no_loop_the_morning_edit_is_unchanged(env):
    env.step(at(2026, 10, 15, 6, 45))
    land(env, "thu", at(2026, 10, 15, 7, 0), type="tempo", verdict="faster")
    methods = [m for m, _ in env.fakes.tg]
    assert methods.count("editMessageText") == 1 and "sendAnimation" not in methods


# ---- B3
def test_the_morning_card_leads_from_the_earliest_recent_start_not_the_median():
    hist = [{"start_utc": iso(at(2026, 10, d, h, m)), "zone_id": "Europe/Rome"} for d, h, m in
            [(20, 12, 30), (13, 12, 25), (6, 10, 45), (29, 12, 0)]]
    now, weekday = at(2026, 10, 28, 8, 0), at(2026, 10, 27).weekday()
    assert ci.usual_start_min(hist, weekday, "Europe/Rome", now) > 12 * 60
    assert ci.earliest_start_min(hist, weekday, "Europe/Rome", now) == 10 * 60 + 45


def test_no_morning_card_once_a_run_for_that_day_has_arrived(env):
    start = at(2026, 10, 15, 6, 0)
    env.run("today", start, now=start + timedelta(minutes=40))
    env.step(at(2026, 10, 15, 6, 50))
    assert env.q("SELECT * FROM checkin_slots WHERE slot='today'") == []
