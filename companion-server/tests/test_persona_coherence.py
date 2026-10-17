"""The coach speaks with one voice: four weeks x 3 personas through the real Service, check-ins ON (tests/persona_sim.py).

Regression for the 17-Oct readiness sim: no day carries more than two non-run messages, every message that names a
session agrees with Home about it, and a question that was answered is never asked again.
"""
import re
import shutil
from collections import Counter, defaultdict
from datetime import timedelta

import pytest

from persona_sim import simulate

PERSONAS = ("trail", "fresh", "lapsed")
WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
TYPE_WORDS = (("quality session", "quality"), ("norwegian", "quality"), ("tempo", "quality"), ("long run", "long"),
              ("easy", "easy"))   # first one found in the claim wins; "steady" names no type


@pytest.fixture(scope="module", params=PERSONAS)
def sim(request):
    s = simulate(request.param)
    yield s
    shutil.rmtree(s.wd, ignore_errors=True)


def claim(x):
    """-> (the local date the message says the next session is on, its type or None), or None when it names no session."""
    d = x.local.date()
    if x.kind == "run":
        text = next((ln for ln in x.body.splitlines() if ln.startswith("Next:")), None)
        if text is None:
            return None
    elif x.kind in ("ci_ready", "evening"):
        text = f"{x.headline}. {x.body}" if x.kind == "ci_ready" else x.body
    elif x.kind == "ci_today":
        return d, next((t for w, t in TYPE_WORDS if w in x.headline.lower()), None)
    else:
        return None
    low = text.lower()
    typ = next((t for w, t in TYPE_WORDS if w in low), None)
    if "tomorrow" in low:
        return d + timedelta(days=1), typ
    m = re.search(r"\bon (" + "|".join(WEEKDAYS) + r")\b", low)
    if m:
        want = WEEKDAYS.index(m.group(1))
        return d + timedelta(days=(want - d.weekday()) % 7 or 7), typ
    return None


def test_the_sim_ran_clean_and_said_something(sim):
    assert sim.log, "the persona got no messages at all"
    assert [x.error for x in sim.log if x.error] == []


def test_no_day_has_more_than_two_non_run_messages(sim):
    per_day = Counter(x.local.date() for x in sim.log if x.kind != "run")
    assert {str(d): n for d, n in per_day.items() if n > 2} == {}


def test_next_evening_morning_and_home_agree_on_the_session(sim):
    wrong = []
    for x in sim.log:
        c = claim(x)
        if c is None:
            continue
        day, typ = c
        home = x.home
        ok = home is not None and home["date"] == day.isoformat() and (typ is None or home["type"] == typ)
        if not ok:
            wrong.append(f"{x.local:%a %d %b %H:%M} [{x.kind}] says {day} {typ}; Home says "
                         f"{(home['date'], home['type']) if home else None}: {x.body[-70:]!r}")
    assert wrong == []


def test_a_question_that_was_answered_is_not_asked_again(sim):
    if not sim.persona["taps"]:
        pytest.skip("this persona taps nothing")
    asked = defaultdict(list)
    for x in sim.log:
        if x.kind in ("question", "ci_shape", "trust", "ellis"):
            asked[(x.kind, x.body)].append(f"{x.local:%d %b}")
    assert {k: v for k, v in asked.items() if len(v) > 1} == {}


def test_no_message_about_tomorrow_lands_on_a_day_the_runner_does_not_run(sim):
    """The evening card and the readiness question speak of tomorrow only when the coach week has a session then."""
    bad = [f"{x.local:%a %d %b} [{x.kind}] {x.body[:80]!r}" for x in sim.log
           if x.kind in ("evening", "ci_ready") and (x.home is None or x.home["date"] != (x.local.date() + timedelta(days=1)).isoformat())]
    assert bad == []


def test_fresh_and_lapsed_runners_see_a_next_line_only_when_home_has_a_session(sim):
    if sim.persona["name"] == "trail":
        pytest.skip("covered by the agreement test")
    for x in sim.log:
        if x.kind == "run" and "Next:" in x.body:
            assert x.home is not None, f"{x.local:%d %b}: Next line with nothing on Home: {x.body!r}"
