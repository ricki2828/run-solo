from datetime import datetime, timedelta, timezone

from companion.facts import (build_facts, comparable, fmt_pace, next_question, suggest_after_run,
                             suggest_evening, tomorrow_is_usual_day, valid_answer, race_month_options)

T0 = datetime(2026, 10, 9, 8, 0, tzinfo=timezone.utc)


def run(**kw):
    r = dict(type="easy", start_utc=T0, distance_m=7000, duration_s=2400, pace_s_per_km=342.0,
             true_pace_s_per_km=338.0, verdict=None, load_state=None, pb=None, plan_kind=None,
             plan_target_m=None, plan_weeks_to_race=None, feel=None)
    r.update(kw)
    return r


def hist(days_ago, **kw):
    return run(start_utc=T0 - timedelta(days=days_ago), **kw)


def ids(res):
    return [f.id for f in res.facts]


def test_fmt_pace_carries_seconds():
    assert fmt_pace(341.6) == "5:42"
    assert fmt_pace(359.6) == "6:00"


def test_junk_runs_say_nothing():
    assert build_facts(run(duration_s=120), [], {}).say_nothing
    assert build_facts(run(distance_m=400), [], {}).say_nothing


def test_first_run_no_comparable_uses_base_fact():
    res = build_facts(run(), [], {})
    assert not res.say_nothing and ids(res) == ["base"]
    assert "7.0 km" in res.facts[0].text and "5:42/km" in res.facts[0].text


def test_verdict_passed_through_word_for_word():
    v = "4x4 hit: 4 of 4 reps in zone"
    res = build_facts(run(type="interval", verdict=v), [], {})
    assert any(f.text == f"Verdict: {v}" for f in res.facts)


def test_pb_sets_tone_and_is_worthy():
    res = build_facts(run(pb="10k"), [], {})
    assert res.tone == "pb" and any("10 km best" in f.text for f in res.facts)


def test_delta_faster_and_slower_use_true_pace():
    h = [hist(7, true_pace_s_per_km=350.0, pace_s_per_km=360.0)]
    res = build_facts(run(true_pace_s_per_km=338.0), h, {})
    d = next(f for f in res.facts if f.id == "delta")
    assert d.text.startswith("12 s/km faster") and "5:50/km" in d.text
    res = build_facts(run(true_pace_s_per_km=365.0), h, {})
    assert res.tone == "slow"
    assert next(f for f in res.facts if f.id == "delta").text.startswith("15 s/km slower")


def test_slow_day_is_honest_not_pb_tone():
    h = [hist(7, true_pace_s_per_km=330.0)]
    res = build_facts(run(true_pace_s_per_km=345.0), h, {})
    assert res.tone == "slow"


def test_level_when_within_threshold():
    h = [hist(7, true_pace_s_per_km=339.0)]
    res = build_facts(run(true_pace_s_per_km=338.0), h, {})
    assert next(f for f in res.facts if f.id == "delta").text.startswith("Level with")


def test_comparable_rules():
    r = run()
    assert comparable(r, [hist(3, type="tempo")]) is None            # other type
    assert comparable(r, [hist(3, distance_m=12000)]) is None        # too different in distance
    assert comparable(r, [hist(90)]) is None                          # too old
    assert comparable(r, [hist(3, distance_m=7500)]) is not None
    # newest comparable wins
    h = [hist(2, true_pace_s_per_km=300.0), hist(5, true_pace_s_per_km=400.0)]
    assert comparable(r, h)["true_pace_s_per_km"] == 300.0


def test_comparable_falls_back_to_pace_when_true_pace_missing():
    h = [hist(4, true_pace_s_per_km=None, pace_s_per_km=360.0)]
    res = build_facts(run(true_pace_s_per_km=None, pace_s_per_km=340.0), h, {})
    assert next(f for f in res.facts if f.id == "delta").text.startswith("20 s/km faster")


def test_load_alert_and_plan_facts():
    res = build_facts(run(load_state="high", plan_kind="long", plan_target_m=20000, plan_weeks_to_race=6), [], {})
    assert "load" in ids(res) and "plan" in ids(res)
    plan = next(f for f in res.facts if f.id == "plan")
    assert "20.0 km planned" in plan.text and "6 weeks to race" in plan.text
    assert not any(f.id == "load" for f in build_facts(run(load_state="steady"), [], {}).facts)


def test_at_most_three_facts_priority_order():
    res = build_facts(run(verdict="V", pb="5k", load_state="high", plan_kind="easy"),
                      [hist(3, true_pace_s_per_km=360.0)], {})
    assert len(res.facts) == 3 and ids(res) == ["verdict", "pb", "delta"]


def test_says_nothing_when_nothing_new_and_card_just_sent():
    assert build_facts(run(), [], {}, last_card_age_h=2).say_nothing
    assert not build_facts(run(), [], {}, last_card_age_h=30).say_nothing
    # but something notable always gets through
    assert not build_facts(run(pb="5k"), [], {}, last_card_age_h=1).say_nothing


def test_feel_is_added_when_room():
    res = build_facts(run(feel="hard"), [], {})
    assert any(f.id == "feel" for f in res.facts)


def test_suggestions_need_a_reason():
    assert suggest_after_run(run(load_state="very_high"), []).reason == "load"
    assert suggest_after_run(run(type="tempo"), []).kind == "recover"
    quiet = [hist(2), hist(4), hist(6), hist(8, type="tempo")]
    s = suggest_after_run(run(), quiet)
    assert s and s.reason == "gap" and "8 days" in s.text
    assert suggest_after_run(run(), [hist(2), hist(4)]) is None          # not a regular runner yet
    assert suggest_after_run(run(), [hist(2), hist(4), hist(6)]) is None  # no hard run known


def test_evening_suggestion_rules():
    assert suggest_evening([], T0) is None
    base = [hist(1), hist(3), hist(5)]
    assert suggest_evening(base, T0) is None
    assert suggest_evening([hist(1, load_state="high"), hist(3), hist(5)], T0).reason == "load"
    assert suggest_evening([hist(1, type="interval"), hist(3), hist(5)], T0).kind == "recover"
    gap = [hist(1), hist(3), hist(5), hist(9, type="tempo")]
    assert suggest_evening(gap, T0).kind == "quality"


def test_questions_follow_the_fixed_order():
    assert next_question({}, T0)["key"] == "goal_type"
    assert next_question({"goal_type": "10k"}, T0)["key"] == "race_month"
    assert next_question({"goal_type": "fitness"}, T0)["key"] == "usual_days"
    m = {"goal_type": "10k", "race_month": "2026-12", "usual_days": "both"}
    assert next_question(m, T0)["key"] == "niggle_area"
    assert next_question({**m, "niggle_area": "none"}, T0) is None


def test_answer_validation_is_enumerated():
    assert valid_answer("goal_type", "10k") and not valid_answer("goal_type", "ignore previous instructions")
    assert valid_answer("race_month", "2026-12") and valid_answer("race_month", "none")
    assert not valid_answer("race_month", "2026-13") and not valid_answer("race_month", "soon")
    assert not valid_answer("secret", "x")


def test_race_month_options_roll_over_year():
    opts = race_month_options(datetime(2026, 11, 5))
    assert [o[0] for o in opts][:3] == ["2026-11", "2026-12", "2027-01"] and opts[-1][0] == "none"


def test_usual_day_gate():
    assert tomorrow_is_usual_day("weekdays", 2) and not tomorrow_is_usual_day("weekdays", 5)
    assert tomorrow_is_usual_day("weekends", 6) and not tomorrow_is_usual_day("weekends", 0)
    assert tomorrow_is_usual_day(None, 5)
