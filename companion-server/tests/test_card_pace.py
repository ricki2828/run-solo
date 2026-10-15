"""The work pace on the morning card: the app's plan_next carries it, the server validates and stores it, the message
and the picture show it, and an older app (no field) or a bad value changes nothing else."""
import json
import math
from datetime import date
from pathlib import Path

import pytest
from pydantic import ValidationError

from companion import db
from companion.service import PlanNextIn
from render import protocol as PR
from test_checkins import at, env  # noqa: F401  (env is a fixture)

STEP = at(2026, 10, 15, 6, 45)
FIXTURE = Path(__file__).parent / "fixtures" / "app_plan_next_pace.json"
BASE = {"type": "quality", "day": "2026-10-15", "week": 3, "distance_m": 6000}
PACE = {"target_pace_lo_s": 288.0, "target_pace_hi_s": 288.0, "target_pace_method": "vdot"}


def newest(env, plan_next):
    """The fixture already seeded a plan; a newer run carries this one."""
    env.run("newest", at(2026, 10, 14, 7, 0), plan_next=plan_next)


def card_facts(env):
    with db.ro(env.path) as c:
        user = {"id": env.uid, "channel": "telegram", "zone_id": "Europe/Rome"}
        return env.svc._ci_card_facts(c, user, date(2026, 10, 15), STEP)


def test_the_apps_own_json_passes_the_validator():
    nx = PlanNextIn(**json.loads(FIXTURE.read_text()))
    assert (nx.target_pace_lo_s, nx.target_pace_hi_s, nx.target_pace_method) == (288.0, 288.0, "moved")
    assert nx.session_name == "Norwegian 4x4"


def test_with_a_pace_the_message_and_the_picture_carry_it(env):
    newest(env, BASE | PACE)
    env.step(STEP)
    [msg] = env.sends()
    assert msg["text"].startswith("Today: Quality session, 6 km · 4:48/km work pace")
    facts = card_facts(env)
    assert (facts["target_pace_lo_s"], facts["target_pace_hi_s"], facts["target_kind"]) == (288.0, 288.0, "work")
    PR.check_request({"v": 1, "op": "card", "kind": "today", "facts": facts})   # the renderer's own contract


def test_without_a_pace_nothing_extra_shows(env):
    newest(env, BASE)
    env.step(STEP)
    [msg] = env.sends()
    assert msg["text"].startswith("Today: Quality session, 6 km\n") or "work pace" not in msg["text"]
    assert "work pace" not in msg["text"]
    facts = card_facts(env)
    assert "target_pace_lo_s" not in facts and "target_kind" not in facts


def test_an_old_build_sends_no_field_and_the_run_is_accepted():
    nx = PlanNextIn(**BASE)
    assert nx.target_pace_lo_s is None and nx.target_pace_hi_s is None and nx.target_pace_method is None


@pytest.mark.parametrize("bad", [
    {"target_pace_lo_s": 300.0, "target_pace_hi_s": 290.0, "target_pace_method": "vdot"},   # backwards
    {"target_pace_lo_s": 288.0, "target_pace_method": "vdot"},                               # half a range
    {"target_pace_lo_s": 60.0, "target_pace_hi_s": 60.0, "target_pace_method": "vdot"},      # faster than anyone
    {"target_pace_lo_s": 5000.0, "target_pace_hi_s": 5000.0, "target_pace_method": "vdot"},  # a walk
    {"target_pace_lo_s": "fast", "target_pace_hi_s": 288.0, "target_pace_method": "vdot"},   # not a number
    {"target_pace_lo_s": math.inf, "target_pace_hi_s": math.inf, "target_pace_method": "vdot"},
    {"target_pace_lo_s": 288.0, "target_pace_hi_s": 288.0, "target_pace_method": "<b>x</b>"},  # not an enum value
])
def test_a_bad_pace_is_dropped_and_never_fails_the_plan(bad):
    nx = PlanNextIn(**(BASE | bad))
    assert (nx.target_pace_lo_s, nx.target_pace_hi_s, nx.target_pace_method) == (None, None, None)
    assert nx.type == "quality" and nx.distance_m == 6000


def test_unknown_extra_fields_are_still_refused():
    with pytest.raises(ValidationError):
        PlanNextIn(**(BASE | {"surprise": 1}))


def test_flat_legs_make_it_easy_and_the_work_pace_goes(env):
    newest(env, BASE | PACE)
    env.step(at(2026, 10, 14, 20, 5))
    env.tap("r.flat", at(2026, 10, 14, 20, 6))
    env.step(STEP)
    facts = card_facts(env)
    assert "target_pace_lo_s" not in facts



def test_the_data_export_shows_the_stored_pace(env):
    newest(env, BASE | PACE)
    me = env.svc.get_me(env.uid)
    row = [r for r in me["runs_received"] if r["run_id"] == "newest"][0]
    assert (row["plan_next_pace_lo"], row["plan_next_pace_hi"], row["plan_next_pace_method"]) == (288.0, 288.0, "vdot")
    old = [r for r in me["runs_received"] if r["run_id"] == "last"][0]
    assert old["plan_next_pace_lo"] is None
