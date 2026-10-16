"""M6 follow-up: a brand-new runner's morning cards (plan from the first run) are honest, not empty, no history needed."""
from datetime import timedelta

import pytest

from conftest import enrol
from test_checkins import Env, agree, at

PLAN = lambda day, typ="easy", **kw: {"type": typ, "day": day, "week": 1, **kw}


@pytest.fixture
def fresh(client, fakes):
    t = enrol(client)
    e = Env(client, fakes, t)
    agree(client, t)
    return e


SESSIONS = [  # (run day, plan day, plan type, extras, expected title)
    (5, 7, "easy", {"distance_m": 4500}, "Today: Easy run, 5 km"),            # 4.5 km is five, not banker's four
    (7, 9, "quality", {"distance_m": 5000}, "Today: Quality session, 5 km"),
    (9, 12, "long", {"minutes": 50}, "Today: Long run, 50 min"),
]
HISTORY_WORDS = ("again", "as usual", "last time", "your usual", "streak", "best", "faster", "slower", "week of")


def test_a_new_runners_first_three_morning_cards_are_plain_and_honest(fresh):
    e = fresh
    seen = 0
    for i, (d, plan_day, typ, extra, title) in enumerate(SESSIONS):
        e.run(f"f{i}", at(2026, 10, d, 7, 0), plan_next=PLAN(f"2026-10-{plan_day:02d}", typ, **extra), plan_week=1,
              verdict=None)
        assert e.step(at(2026, 10, plan_day, 6, 0)) == 0          # before the start time the runner has given us
        assert e.step(at(2026, 10, plan_day, 6, 45)) == 1
        sent = e.sends()
        assert len(sent) == seen + 1, "exactly one morning card per planned day"
        text = sent[-1]["text"]
        seen += 1
        if i < 2:    # one or two runs are not a habit: no start time is stated
            assert text.startswith(title + "\nIt's on the plan for today. Run it, move it or skip it?"), text
        else:
            assert text.startswith(title + "\nPlanned for around 7:00. Run it, move it or skip it?"), text
        low = text.lower()
        assert not any(w in low for w in HISTORY_WORDS), text      # nothing that needs history the runner lacks
        assert "—" not in text and "{" not in text
        assert e.step(at(2026, 10, plan_day, 7, 30)) == 0          # and no second card the same day


def test_no_morning_card_without_a_plan_for_a_new_runner(fresh):
    e = fresh
    e.run("f0", at(2026, 10, 5, 7, 0), verdict=None)
    assert all(e.step(at(2026, 10, 6, h, 0)) == 0 for h in range(5, 11))
    assert e.sends() == []
