"""Run-card coaching fixes (17-Oct audit): a fixed Next line, like-with-like comparisons, no invented advice."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone

from companion import notes
from companion.facts import Fact, build_facts, comparable, next_line
from companion.writer import CardText, clean
from conftest import enrol, run_payload
from test_interval_session import hist, run
from test_notes import q, send_run

T0 = datetime(2026, 10, 17, 7, 0, tzinfo=timezone.utc)


def ago(days, **kw):
    """A prior run `days` before T0 (hist() counts back from the interval tests' own date)."""
    return hist(days, **kw) | {"start_utc": T0 - timedelta(days=days)}


# --- fix 2: the Next line -------------------------------------------------------------------------

def test_next_line_after_a_hard_run_is_easy_tomorrow():
    r = run(type="tempo", start_utc=T0, feel="hard")
    easy = [hist(d, type="easy", distance_m=5000) for d in (2, 4, 6)]
    assert next_line(r, easy) == "Next: easy 5 km tomorrow"


def test_next_line_uses_the_apps_plan_when_it_names_the_next_session():
    r = run(type="easy", start_utc=T0, plan_next_type="long", plan_next_day="2026-10-18", plan_next_m=12000)
    assert next_line(r, []) == "Next: long run 12.0 km tomorrow"


def test_next_line_with_no_plan_and_a_long_gap_since_hard_asks_for_quality_tomorrow():
    # same gap (5+ days) and same day as the evening suggestion, so the two never disagree
    r = run(type="easy", start_utc=T0)
    h = [ago(2, type="easy", distance_m=5000), ago(5, type="easy", distance_m=5000),
         ago(8, type="tempo", distance_m=6000, feel="hard"), ago(30, type="easy", distance_m=5000)]
    assert next_line(r, h) == "Next: tempo 6 km tomorrow"


def test_next_line_no_push_in_the_first_fortnight_or_back_after_a_break():
    r = run(type="easy", start_utc=T0)
    new = [ago(2, type="easy", distance_m=5000), ago(8, type="tempo", distance_m=6000)]
    assert next_line(r, new) == "Next: easy 5 km tomorrow"
    back = [ago(12, type="easy", distance_m=5000), ago(20, type="tempo", distance_m=6000),
            ago(40, type="easy", distance_m=5000)]
    assert next_line(r, back) == "Next: easy 5 km tomorrow"


def test_a_planned_push_tomorrow_turns_easy_after_a_hard_run_or_a_flagged_note():
    h = [ago(2, type="easy", distance_m=5000)]
    plan = dict(plan_next_type="quality", plan_next_day="2026-10-18")
    assert next_line(run(type="tempo", start_utc=T0, **plan), h) == "Next: easy 5 km tomorrow"
    assert next_line(run(type="easy", start_utc=T0, **plan), h, soften=True) == "Next: easy 5 km tomorrow"
    assert next_line(run(type="easy", start_utc=T0, **plan), h) == "Next: quality session tomorrow"
    later = dict(plan_next_type="quality", plan_next_day="2026-10-20")   # a push later in the week stays
    assert next_line(run(type="tempo", start_utc=T0, **later), h) == "Next: quality session on Tuesday"


def test_a_stale_plan_day_is_ignored():
    r = run(type="tempo", start_utc=T0, plan_next_type="long", plan_next_day="2026-10-10")
    assert next_line(r, [ago(2, type="easy", distance_m=5000)]) == "Next: easy 5 km tomorrow"


def test_next_line_without_history_never_invents_a_distance():
    assert next_line(run(type="easy", start_utc=T0), []) == "Next: an easy run tomorrow"


def test_next_line_is_deterministic_and_softened_by_a_note():
    r, h = run(type="easy", start_utc=T0), [hist(2, type="easy", distance_m=5000)]
    assert next_line(r, h, soften=True) == next_line(r, h, soften=True) == "Next: easy 5 km tomorrow"


def test_every_run_card_ends_with_a_next_line(client, fakes):
    t = enrol(client)
    send_run(client, t)
    body = q(client, "SELECT body FROM cards WHERE run_id='r1' AND kind='run'")[0]["body"]
    assert body.rstrip().splitlines()[-1].startswith("Next: ")


# --- fix 3: like with like, and the note keywords -------------------------------------------------

def test_17_oct_interval_without_reps_gets_no_pace_comparison():
    # no session name, no work pace: the app detected no reps
    r = run(run_id="r17", start_utc=T0, distance_m=5400, duration_s=1860, pace_s_per_km=344.0, true_pace_s_per_km=329.7,
            verdict=None)
    prev = hist(19, type="interval", distance_m=5300, pace_s_per_km=310.0, true_pace_s_per_km=300.2)
    assert comparable(r, [prev]) is None
    res = build_facts(r, [prev], {})
    assert not any(f.id == "delta" for f in res.facts)


def test_trail_is_only_compared_with_trail():
    r = run(type="tempo", app_type="trail", start_utc=T0, distance_m=5000)
    road = hist(3, type="tempo", distance_m=5000, true_pace_s_per_km=300.0)
    trail = hist(6, type="tempo", app_type="trail", distance_m=5000, true_pace_s_per_km=330.0)
    assert comparable(r, [road]) is None
    assert comparable(r, [road, trail]) is trail
    assert comparable(run(type="tempo", start_utc=T0, distance_m=5000), [trail, road]) is road


def test_note_keywords_for_travel_and_conditions_soften():
    for text in ("Lots of haze and first day back after 12 hours flight", "jet lag", "jetlag", "so much smoke",
                 "hot, heat", "steep hills", "long travel day"):
        assert notes.flagged(text), text
    assert not notes.flagged("felt good")


# --- fix 4: the writer may not invent advice ------------------------------------------------------

FACTS_17 = [Fact("base", "Interval session: 5.4 km in 31 min at 5:44/km"),
            Fact("delta", "30 s/km slower than your last similar interval session (on true pace, 5:30/km now and 5:00/km then)")]


def test_17_oct_bad_line_is_rejected():
    out = CardText(headline="Slower on the day",
                   body="5.4 km in 31 min, 30 s/km slower than last time on true pace. Work the pace back up next week.")
    assert clean(out, FACTS_17) == "unbacked_advice"


def test_advice_is_allowed_when_a_fact_states_it():
    facts = FACTS_17 + [Fact("suggestion", "That was a hard session, so an easy day tomorrow lets it land.")]
    ok = CardText(headline="Slower on the day", body="30 s/km slower than last time. Easy tomorrow.")
    assert clean(ok, facts) is None


def test_plain_description_still_passes():
    ok = CardText(headline="Slower on the day", body="30 s/km slower than your last similar interval session.")
    assert clean(ok, FACTS_17) is None


# --- narrowed guards -------------------------------------------------------------------------------

def test_descriptive_phrases_are_not_advice():
    for body in ("Third run this week, 5.4 km.", "Didn't push it, 5.4 km.", "Exactly what an easy day should be, 5.4 km.",
                 "Everything from here gets compared to it, 5.4 km.", "Got it done in 31 min."):
        assert clean(CardText(headline="Steady one", body=body), FACTS_17) is None, body


def test_real_advice_is_still_rejected():
    for body in ("30 s/km slower. Work the pace back up next week.", "You should push harder, 5.4 km.",
                 "Try to go faster, 5.4 km.", "Easy tomorrow, 5.4 km."):
        assert clean(CardText(headline="Steady one", body=body), FACTS_17) == "unbacked_advice", body


def test_note_flags_are_less_blunt():
    for text in ("hill reps felt strong", "smoked it", "heated up nicely", "hills felt easier"):
        assert not notes.flagged(text), text
    for text in ("hills killed me", "heat was brutal", "smoke and haze", "hazy", "steep hills", "long flight",
                 "hills were a grind", "so hot", "humid", "jet lagged", "legs dead on the climbs", "heatwave",
                 "struggled up the hills", "hot and sticky"):
        assert notes.flagged(text), text


def test_every_run_card_style_exemplar_passes_the_advice_guard():
    from companion.convo.voice import SITUATIONS
    from companion.writer import ADVICE_RE
    recap_only = {"missed_week"}   # weekly recap lines never go through the card writer
    hits = [(k, b) for k, vs in SITUATIONS.items() if k not in recap_only for h, b in vs if ADVICE_RE.search(h + " " + b)]
    assert hits == []
