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
def quiet_until_six(env):
    with db.tx(env.path) as c:
        c.execute("UPDATE users SET quiet_start=?, quiet_end=?", (21 * 60 + 30, 6 * 60))


def starts(*hm, weekday_dates=(27, 20, 13, 6, 29, 22)):
    return [{"start_utc": iso(at(2026, 10, d, h, m)), "zone_id": "Europe/Rome"} for d, (h, m) in zip(weekday_dates, hm)]


NOW, TUE = at(2026, 10, 28, 8, 0), at(2026, 10, 27).weekday()


def test_the_morning_lead_uses_the_early_end_of_the_starts_not_the_median():
    hist = starts((12, 30), (12, 25), (10, 45), (12, 0), weekday_dates=(20, 13, 6, 29))   # Tuesdays, 4 samples
    assert ci.usual_start_min(hist, TUE, "Europe/Rome", NOW) > 12 * 60
    assert ci.earliest_start_min(hist, TUE, "Europe/Rome", NOW) == 12 * 60      # 25th percentile of 10:45, 12:00, 12:25, 12:30


def test_one_early_outlier_among_12_to_13h_starts_does_not_drag_the_card_hours_early():
    hist = starts((12, 0), (12, 30), (13, 0), (12, 15), (6, 30), (12, 45), weekday_dates=(20, 13, 6, 29, 22, 15))
    got = ci.earliest_start_min(hist, TUE, "Europe/Rome", NOW)
    assert 11 * 60 + 45 <= got <= 12 * 60 + 15
    # with fewer than four samples the earliest is still used
    assert ci.earliest_start_min(starts((12, 0), (6, 30), weekday_dates=(20, 13)), TUE, "Europe/Rome", NOW) == 6 * 60 + 30


def test_a_spread_across_the_wrap_point_stays_in_order():
    hist = starts((6, 0), (20, 36), (20, 40), (20, 30), weekday_dates=(20, 13, 6, 29))
    assert ci.earliest_start_min(hist, TUE, "Europe/Rome", NOW) == 20 * 60 + 35     # 25th percentile; 06:00 is the late tail of the night, not the early end


def test_a_quiet_hours_outlier_does_not_stop_the_morning_card_with_four_samples(env):
    quiet_until_six(env)
    env.run("t-outlier", at(2026, 10, 8, 5, 30))
    env.run("t-sep24", at(2026, 9, 24, 7, 0))             # Thursdays: 05:30, 07:00 x3 -> 25th percentile 07:00
    env.step(at(2026, 10, 15, 6, 50))
    assert env.q("SELECT * FROM checkin_slots WHERE slot='today'")


def test_a_quiet_hours_outlier_with_few_samples_plans_nothing_and_says_so(env, caplog):
    quiet_until_six(env)
    env.run("t-outlier", at(2026, 10, 8, 5, 30))          # Thursdays: 05:30, 07:00, 07:00 -> three samples, the earliest wins
    with caplog.at_level(logging.INFO):
        env.step(at(2026, 10, 15, 6, 50))
        env.step(at(2026, 10, 15, 6, 51))
    assert env.q("SELECT * FROM checkin_slots WHERE slot='today'") == []
    lines = [r.getMessage() for r in caplog.records if "morning card not planned" in r.getMessage()]
    assert len(lines) == 1                                  # once a day, not every tick


def test_no_morning_card_once_a_run_for_that_day_has_arrived(env):
    start = at(2026, 10, 15, 6, 0)
    env.run("today", start, now=start + timedelta(minutes=40))
    env.step(at(2026, 10, 15, 6, 50))
    assert env.q("SELECT * FROM checkin_slots WHERE slot='today'") == []


# ---- review fixes
def test_a_tap_on_the_old_morning_buttons_after_the_result_is_handled_gracefully(env):
    env.step(at(2026, 10, 15, 6, 45))
    slot = env.slot()
    land(env, "thu", at(2026, 10, 15, 7, 0), type="tempo", verdict="faster")
    assert env.slot()["state"] == "consumed"
    after = env.tap("t.skip", at(2026, 10, 15, 8, 0), slot=slot, message_id=slot["message_id"], card_id=slot["card_id"])
    assert [m for m, _ in after].count("answerCallbackQuery") == 1                 # answered, no crash


def test_the_edited_morning_card_says_result_below_and_a_slot_bookkeeping_failure_never_resends(env, monkeypatch):
    env.svc.s = dataclasses.replace(env.svc.s, media_enabled=True)
    env.step(at(2026, 10, 15, 6, 45))
    monkeypatch.setattr(env.svc, "_render_media", lambda user, card, now: loop_media() if card["kind"] == "run" else None)
    monkeypatch.setattr(env.svc, "_ci_consume", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("db")))
    land(env, "thu", at(2026, 10, 15, 7, 0), type="tempo", verdict="faster")
    [(_, edit)] = [c for c in env.fakes.tg if c[0] in ("editMessageText", "editMessageCaption")]
    assert "Result below" in (edit.get("text") or edit.get("caption"))
    assert [m for m, _ in env.fakes.tg].count("sendAnimation") == 1
    assert env.q("SELECT state FROM outbox WHERE kind='run_card'")[0]["state"] == "done"
