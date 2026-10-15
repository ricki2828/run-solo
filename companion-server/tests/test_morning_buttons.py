"""The morning card's Run / Move / Skip buttons and the "Hot one" line (Runna teardown item 4).

Builds on the check-in fixtures: the buttons are the day's one question (taps never open a second), a tap edits the
answer and the card in place, and every word is a template (eng-review A2). Clocks are pinned."""
import json
import re
from datetime import date, timedelta

import pytest

from companion import checkins as ci
from companion import db, heat
from companion.convo.weather import Forecast
from test_checkins import at, edited_text, env, spy_writer  # noqa: F401  (env is a fixture)

STEP = at(2026, 10, 15, 6, 45)
TAP = at(2026, 10, 15, 6, 50)
DAY = "2026-10-15"


def labels(markup):
    return [[b["text"] for b in row] for row in markup["inline_keyboard"]]


class FakeWx:
    def __init__(self, fc):
        self.fc, self.calls = fc, []

    def tomorrow(self, lat, lon, zone_id, day):
        self.calls.append((lat, lon, zone_id, day))
        return self.fc

    def at_run(self, *a, **k):
        return None


def hot_env(env, fc=Forecast(30, 5, 24), area=(1.3, 103.8)):
    env.svc.weather = FakeWx(fc)
    env.svc._area = lambda c, uid, run_id=None, now=None: area
    return env


# ---------------------------------------------------------------- the buttons
def test_the_card_has_run_move_and_skip_and_skip_opens_the_five_reasons(env):
    env.step(STEP)
    [msg] = env.sends()
    assert labels(msg["reply_markup"]) == [["Run", "Move", "Skip"]]
    calls = env.tap("t.skip", TAP)
    [(_, edit)] = [c for c in calls if c[0] == "editMessageText"]
    assert labels(edit["reply_markup"]) == [["Tired", "Sore", "Ill"], ["Busy", "Weather"]]


def test_run_confirms_todays_session_and_is_the_days_one_answer(env):
    env.step(STEP)
    text = edited_text(env.tap("t.go", TAP))[0]
    assert text.startswith("Go well\nQuality session, 6 km is on.")
    assert env.answers() == {("today", DAY): "going"}
    assert len(env.sends()) == 1 and len(env.q("SELECT * FROM question_cap")) == 1   # no second question


def test_move_swaps_the_run_for_a_walk_strength_or_mobility_and_the_run_waits_a_day(env):
    env.step(STEP)
    text = edited_text(env.tap("t.move", TAP))[0]
    assert text.startswith("Move it\n") and "walk" in text and "strength" in text and "mobility" in text
    assert "moves to Fri 16" in text
    assert env.answers() == {("today", DAY): "move"}
    nxt = env.svc.next_session(env.uid, TAP)["next_session"]
    assert nxt["date"] == "2026-10-16" and nxt["moved"]
    assert ci.lighter_until(ci.Answers().with_("today", date(2026, 10, 15), "move"), date(2026, 10, 15)) is None


@pytest.mark.parametrize("reason, needles, new_day, lighter", [
    ("tired", ["Moved", "moves to Mon 19", "next 3 days light"], "2026-10-19", True),
    ("sore", ["Moved", "moves to Mon 19", "get it looked at"], "2026-10-19", True),
    ("ill", ["Rest up", "a week", "see a doctor", "Fri 23"], "2026-10-23", True),
    ("busy", ["Moved", "moves to Fri 16", "20 easy minutes still counts"], "2026-10-16", False),
    ("weather", ["Moved", "moves to Fri 16", "weather can wait"], "2026-10-16", False),
])
def test_each_skip_reason_has_its_own_templated_line_and_effect(env, reason, needles, new_day, lighter):
    env.step(STEP)
    env.tap("t.skip", TAP)
    text = edited_text(env.tap(f"w.{reason}", TAP))[0]
    for n in needles:
        assert n in text, (n, text)
    assert env.answers() == {("today", DAY): "skip", ("why", DAY): reason}
    assert env.svc.next_session(env.uid, TAP)["next_session"]["date"] == new_day
    a = ci.Answers().with_("today", date(2026, 10, 15), "skip").with_("why", date(2026, 10, 15), reason)
    assert (ci.lighter_until(a, date(2026, 10, 15)) is not None) is lighter
    assert ("light" in text) is lighter or reason == "ill"


# ---------------------------------------------------------------- idempotent, editable
def test_a_second_tap_edits_the_answer_and_the_card_never_duplicating_it(env):
    env.step(STEP)
    env.tap("t.go", TAP)
    env.tap("t.go", TAP)                                                     # a double tap
    assert env.answers() == {("today", DAY): "going"}
    assert "Fri 16" in edited_text(env.tap("t.move", TAP))[0]               # changed her mind
    assert env.answers() == {("today", DAY): "move"}
    env.tap("t.skip", TAP)
    env.tap("w.busy", TAP)
    env.tap("w.busy", TAP)
    assert "weather can wait" in edited_text(env.tap("w.weather", TAP))[0]  # a different reason replaces it
    assert env.answers() == {("today", DAY): "skip", ("why", DAY): "weather"}
    rows = env.q("SELECT kind, local_date FROM checkin_answers")
    assert len(rows) == 2 and len({(r["kind"], r["local_date"]) for r in rows}) == 2
    assert env.tap("t.go", TAP) and env.answers() == {("today", DAY): "going"}   # Run after Skip drops the stale reason
    assert len(env.sends()) == 1 and len(env.q("SELECT * FROM question_cap")) == 1


def test_a_reason_tap_without_a_skip_is_stale_and_records_nothing(env):
    env.step(STEP)
    env.tap("t.move", TAP)
    calls = env.tap("w.weather", TAP)
    assert env.answers() == {("today", DAY): "move"} and calls[0][1]["text"] == "That one has moved on."


def test_the_old_later_button_on_an_earlier_message_still_works(env):
    env.step(STEP)
    assert edited_text(env.tap("t.later", TAP))[0].startswith("Later it is")


def test_undo_returns_to_the_buttons(env):
    env.step(STEP)
    env.tap("t.move", TAP)
    [(_, edit)] = [c for c in env.tap("u.undo", TAP) if c[0] == "editMessageText"]
    assert labels(edit["reply_markup"]) == [["Run", "Move", "Skip"]] and env.answers() == {}


def test_every_new_code_fits_telegrams_64_bytes():
    for code in ("t.move", "w.weather"):
        assert code in ci.CODES and len(f"ci1:{'0' * 32}:{code}".encode()) <= 64


# ---------------------------------------------------------------- the heat line
def test_a_hot_forecast_adds_one_line_with_the_extra_seconds_per_km(env):
    hot_env(env)
    env.step(STEP)
    [msg] = env.sends()
    extra = heat.extra_s_per_km(338.0, 30, 24)
    assert extra == 22
    assert msg["text"].endswith(f"\nHot one: about +{extra} s/km on easy pace.")
    assert msg["text"].count("Hot one") == 1
    assert env.svc.weather.calls and env.svc.weather.calls[0][3] == date(2026, 10, 15)


def test_the_line_is_only_on_the_unanswered_card_and_comes_back_with_undo(env):
    hot_env(env)
    env.step(STEP)
    assert "Hot one" not in edited_text(env.tap("t.go", TAP))[0]
    assert "Hot one" in edited_text(env.tap("u.undo", TAP))[0]


@pytest.mark.parametrize("fc, area", [
    (Forecast(21, 5, 14), (1.3, 103.8)),     # mild: a 1.5% slowdown is under the 2% threshold
    (Forecast(30, 5, None), (1.3, 103.8)),   # no dew point from the source: no guess
    (Forecast(45, 5, 30), (1.3, 103.8)),     # too hot to compare: the app does not adjust, so no number
    (None, (1.3, 103.8)),                    # the forecast failed
    (Forecast(30, 5, 24), (None, None)),     # no stored area (weather switch off): the weather service is never asked
])
def test_no_line_when_it_is_mild_unknown_or_the_runner_has_no_weather(env, fc, area):
    hot_env(env, fc, area)
    env.step(STEP)
    assert "Hot one" not in env.sends()[0]["text"]
    if area == (None, None):
        assert env.svc.weather.calls == []


def test_no_line_without_two_easy_runs_to_take_a_pace_from(env):
    hot_env(env)
    with db.tx(env.path) as c:
        c.execute("UPDATE runs SET type='tempo' WHERE run_id != 'last'")
    env.step(STEP)
    assert "Hot one" not in env.sends()[0]["text"]


def test_the_threshold_and_the_numbers_mirror_the_apps_heat_model():
    f = lambda sum_f: heat.slowdown_fraction((sum_f - 64) * 5 / 9, 0)   # a dew point of 0 C is 32 F
    assert f(100) == 0 and f(130) == pytest.approx(0.02) and f(140) == pytest.approx(0.03)
    assert f(150) == pytest.approx(0.045) and f(160) == pytest.approx(0.06) and f(180) == pytest.approx(0.10)
    assert f(180.5) is None and f(115.5) == pytest.approx(0.0075, abs=1e-4)   # halfway through the 111-120 band
    assert heat.slowdown_fraction(-5, -10) == 0                                  # never a cold bonus
    # the line shows from a 2% slowdown (130 F) and not below it
    assert heat.extra_s_per_km(300, (129.9 - 64) * 5 / 9, 0) is None
    assert heat.extra_s_per_km(300, (130 - 64) * 5 / 9, 0) == round(300 * (1 / 0.98 - 1))
    assert heat.extra_s_per_km(300, (150 - 64) * 5 / 9, 0) == round(300 * (1 / 0.955 - 1))


# ---------------------------------------------------------------- A2 and the budget
def test_no_button_value_or_heat_line_reaches_the_writer(env):
    hot_env(env)
    env.step(STEP)
    seen = spy_writer(env)
    for code in ("t.move", "t.skip", "w.weather", "w.busy", "w.tired", "t.go"):
        env.tap(code, TAP)
    start = at(2026, 10, 15, 7, 0)
    env.run("thu", start, now=start + timedelta(minutes=45), type="easy", verdict="slower")
    env.svc.run_outbox(start + timedelta(minutes=46))
    assert seen, "the writer ran for the run card"
    blob = " ".join(seen) + json.dumps(env.fakes.llm)
    assert not re.search(r"\b(weather|busy|move|skip|going)\b", blob, re.I), blob
    assert "Hot one" not in blob and "s/km on easy" not in blob


def test_buttons_add_no_stored_field():
    """New answer values reuse the same two kinds in the same table, so nothing new is kept and the 14 day purge, backup
    exclusion and export already cover them."""
    assert set(ci.VALUES) == {"ready", "today", "why", "postrun", "shape"}
    assert {"move"} <= set(ci.TODAY) and {"weather"} <= set(ci.WHY)
