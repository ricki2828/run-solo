"""Phase 0 misread fixes (13-Oct audit). Each test rebuilds the SHAPE of a real card from the audit with invented
numbers: no personal data."""
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from companion import db
from companion.channels import OutCard, caption_text
from companion.convo import engine, suggest
from companion.facts import Fact, FactsResult, build_facts, is_hard_run, run_label
from companion.writer import CardText, Writer, clean, with_verdict
from conftest import make_settings

U = timezone.utc
T0 = datetime(2026, 10, 12, 6, 0, tzinfo=U)
Z3_RUN = {"z1": 2.0, "z2": 5.0, "z3": 19.9, "z4": 0.9, "z5": 0.0}   # mostly Z3, a sliver of Z4


def run(days_ago=0, typ="tempo", app="trail", km=4.7, pace=360.0, true=None, **kw):
    r = {"run_id": f"r{days_ago}", "start_utc": T0 - timedelta(days=days_ago), "type": typ, "app_type": app,
         "distance_m": int(km * 1000), "duration_s": int(km * pace), "pace_s_per_km": pace,
         "true_pace_s_per_km": true if true is not None else pace, "zone_id": "UTC", "locality": None,
         "zone_min": Z3_RUN, "load_state": None, "pb": None, "verdict": None, "feel": None, "climb_m": None,
         "plan_weeks_to_race": None}
    r.update(kw)
    return r


def texts(res):
    return {f.id: f.text for f in res.facts}


# --- 1. hard is judged from the zones and the feel tap ---------------------------------------

def test_mostly_z3_tempo_tapped_right_is_not_hard_and_gets_a_light_card():
    r = run(feel="right")
    assert not is_hard_run(r)
    assert engine.media_for_run(r, "tempo", None).card == "light"


def test_the_same_tempo_tapped_hard_or_with_real_z4_is_hard():
    assert is_hard_run(run(feel="hard"))
    assert is_hard_run(run(feel="right", zone_min={"z2": 10.0, "z4": 12.0, "z5": 4.0}))
    assert engine.media_for_run(run(feel="hard"), "tempo", None).card == "flood"


def test_an_untapped_tempo_is_hard_unless_zones_are_nearly_all_z3():
    assert is_hard_run(run(feel=None, zone_min={"z2": 5.0, "z3": 14.0, "z4": 8.0, "z5": 0.0}))    # ~30% Z4: threshold
    assert not is_hard_run(run(feel=None, zone_min=Z3_RUN))                                         # ~3% Z4


def test_sessions_and_unmeasured_tempos_stay_hard():
    assert is_hard_run(run(typ="interval", app="intervals", zone_min={}))
    assert is_hard_run(run(typ="race", app="cooper", zone_min={}))
    assert is_hard_run(run(zone_min={}, feel=None))          # no zones and no tap: the type decides
    assert not is_hard_run(run(typ="easy", feel=None))


def test_a_z3_tempo_that_felt_right_does_not_make_a_recover_evening():
    last = run(feel="right")
    hist = [last, run(2, typ="easy"), run(4, typ="easy"), run(6, typ="easy")]
    now = T0 + timedelta(hours=14)
    ev = suggest.evening(hist, now, None, {}, "s")
    assert ev is None or ev.suggestion.kind != "recover"
    hard = [run(0, feel="hard")] + hist[1:]
    assert suggest.evening(hard, now, None, {}, "s").suggestion.kind == "recover"


def test_gap_counts_real_hard_runs_only():
    from companion.facts import days_since_hard
    assert days_since_hard([run(1, feel="right"), run(8, typ="interval", app="intervals")], T0) == 8


# --- 2. one pace basis ------------------------------------------------------------------------

def trail_pair():
    prev = run(8, typ="easy", pace=372.0, true=372.0, km=6.5)
    now = run(0, typ="easy", pace=360.0, true=327.0, km=6.5, zone_min={})
    return now, [prev]


def test_true_pace_gap_is_labelled_and_never_sits_next_to_the_raw_pace():
    now, hist = trail_pair()
    hist[0]["true_pace_s_per_km"] = 372.0
    res = build_facts(now, hist, {})
    t = texts(res)
    assert "6:00" not in " ".join(t.values())                 # the raw pace is left out
    assert "true pace" in t["delta"] and "5:27/km now" in t["delta"] and "6:12/km then" in t["delta"]
    assert "45 s/km faster" in t["delta"]


def test_slots_drop_the_raw_pace_when_the_gap_is_on_true_pace():
    now, hist = trail_pair()
    _, slots = engine.situation_for(now, hist, None)
    assert "delta" in slots and "pace" not in slots


def test_raw_both_sides_keeps_the_pace():
    now = run(0, typ="easy", pace=350.0, true=None, km=6.5, zone_min={})
    now["true_pace_s_per_km"] = None
    prev = run(8, typ="easy", pace=372.0, km=6.5, zone_min={})
    prev["true_pace_s_per_km"] = None
    res = build_facts(now, [prev], {})
    assert "5:50/km" in texts(res)["base"] and "true pace" not in texts(res)["delta"]


def writer(tmp_path, fakes, content):
    fakes.llm_mode = "ok"
    s = make_settings(tmp_path)
    db.init(s.db_path)

    def handler(req):
        if req.url.host == "openrouter.ai":
            return httpx.Response(200, json={"provider": "F", "usage": {"cost": 0.0001},
                                             "choices": [{"message": {"content": json.dumps(content)}}]})
        return fakes.handler(req)
    return Writer(s, httpx.Client(transport=httpx.MockTransport(handler)))


def facts_result(*facts):
    return FactsResult(tuple(Fact(i, t) for i, t in facts), None, "steady", False, "ok")


TRUE_FACTS = (("base", "Trail run: 6.5 km in 39 min"),
              ("delta", "45 s/km faster than your last similar trail run (on true pace, 5:27/km now and 6:12/km then)"))


def test_writer_rejects_a_raw_pace_beside_a_true_pace_gap(tmp_path, fakes):
    w = writer(tmp_path, fakes, {"headline": "Trail run", "body": "6:00/km, 45 s/km faster than last time."})
    out = w.write(facts_result(*TRUE_FACTS), {})
    assert out.source == "template"
    assert clean(CardText(headline="Trail run", body="6:00/km, 45 s/km faster."),
                 facts_result(*TRUE_FACTS).facts) == "mixed_pace_basis"


# --- 3. headline and body agree; the verdict owns the headline word ---------------------------

def test_a_contradicting_pace_gap_is_not_stated_under_a_level_verdict():
    prev = run(7, typ="interval", app="intervals", zone_min={}, session_name="Norwegian 4x4", work_pace_s_per_km=266.0)
    now = run(0, typ="interval", app="intervals", zone_min={}, session_name="Norwegian 4x4", work_pace_s_per_km=257.0,
              reps_done=4, verdict="noRealChange")
    res = build_facts(now, [prev], {})
    assert "Verdict: no real change" in texts(res).values()
    assert "delta" not in texts(res)                           # 9 s/km faster is not said over "no real change"
    _, slots = engine.situation_for(now, [prev], None)
    assert "cmp_dir" not in slots


def test_a_directional_verdict_keeps_only_a_gap_that_points_the_same_way():
    prev = run(7, typ="easy", app="free", zone_min={}, pace=372.0)
    same = run(0, typ="easy", app="free", zone_min={}, pace=350.0, verdict="faster")
    assert "faster" in texts(build_facts(same, [prev], {}))["delta"]
    opposite = run(0, typ="easy", app="free", zone_min={}, pace=350.0, verdict="slower")
    assert "delta" not in texts(build_facts(opposite, [prev], {}))


def test_writer_rejects_text_that_contradicts_the_verdict(tmp_path, fakes):
    facts = facts_result(("base", "Interval session: 4 reps at 4:17/km work pace"), ("verdict", "Verdict: no real change"))
    for bad in ({"headline": "Intervals | no real change", "body": "4 reps at 4:17/km."},
                {"headline": "Intervals done", "body": "4 reps, 9 s/km faster at 4:17/km."},
                {"headline": "Faster intervals", "body": "4 reps at 4:17/km."}):
        out = writer(tmp_path, fakes, bad).write(facts, {})
        assert out.source == "template", bad


def test_the_verdict_word_is_added_by_the_app_not_the_model(tmp_path, fakes):
    facts = facts_result(("base", "Tempo trail run: 4.7 km in 28 min"), ("verdict", "Verdict: holding"))
    out = writer(tmp_path, fakes, {"headline": "Tempo trail run", "body": "Level with last time over 4.7 km."}).write(facts, {})
    assert out.source == "llm" and out.headline == "Tempo trail run, holding"
    assert with_verdict("x" * 58, facts.facts) == "x" * 58     # never past 60 characters


# --- 4. the day's feel tap shapes the evening suggestion --------------------------------------

def evening_hist(feel, typ="easy", app="trail"):
    last = run(0, typ=typ, app=app, feel=feel, zone_min={"z1": 3.0, "z2": 11.0, "z3": 4.0, "z4": 5.0})  # 22% Z4: past felt_hard's 15% gate
    older = [run(3, typ="easy", app="free"), run(5, typ="easy", app="free"), run(7, typ="interval", app="intervals"), run(20, typ="easy", app="free")]  # 20 days in: not a new runner (M6)
    return [last] + older


def test_a_hard_tap_in_the_morning_stops_a_push_that_evening():
    now = T0 + timedelta(hours=14)
    hist = evening_hist("hard")
    assert suggest.evening(evening_hist("right"), now, None, {}, "s").suggestion.kind == "quality"   # the old gap push
    ev = suggest.evening(hist, now, None, {}, "s")
    assert ev is not None and ev.suggestion.kind == "easy_next" and "easy" in ev.rendered.body.lower()


def test_a_hard_tap_and_a_flagged_note_together_stay_gentle():
    now = T0 + timedelta(hours=14)
    ev = suggest.evening(evening_hist("hard"), now, None, {}, "s", soften=True)
    assert ev.suggestion.kind == "easy_next"


def test_soften_still_outranks_a_planned_session_after_a_hard_tap():
    now = T0 + timedelta(hours=14)
    hist = evening_hist("hard")
    hist[0].update(plan_next_type="quality", plan_next_day=(now.date() + timedelta(days=1)).isoformat(),
                   plan_next_week=2, plan_weeks=4)
    for soft in (False, True):
        ev = suggest.evening(hist, now, None, {}, "s", soften=soft)
        assert ev.suggestion.kind == "easy_next", soft


def test_heat_still_warns_after_a_hard_tap_and_never_turns_into_a_push():
    from companion.convo.weather import Forecast
    now = T0 + timedelta(hours=14)
    hist = evening_hist("hard", typ="long")
    hist[0].update(plan_next_type="quality", plan_next_day=(now.date() + timedelta(days=1)).isoformat(),
                   plan_next_week=2, plan_weeks=4)
    ev = suggest.evening(hist, now, Forecast(33, 5), {}, "s")
    assert ev.suggestion.kind in ("heat", "easy_next") and ev.suggestion.kind != "quality"
    assert ev.suggestion.reason in ("weather", "rest")


# --- 5. a trail run names its session ---------------------------------------------------------

@pytest.mark.parametrize("typ,word", [("easy", "easy trail run"), ("tempo", "tempo trail run"), ("long", "long trail run")])
def test_trail_keeps_the_place_and_names_the_session(typ, word):
    r = run(typ=typ)
    assert run_label(r) == word
    assert word.capitalize() in texts(build_facts(r, [], {}))["base"]
    assert engine.situation_for(r, [], None)[0] == f"trail_{typ}"


def test_other_trail_types_and_cooper_keep_their_own_names():
    assert run_label(run(typ="race")) == "trail run"
    assert run_label(run(typ="race", app="cooper")) == "Cooper test"
    assert run_label(run(typ="easy", app="free")) == "easy run"


def test_three_trail_runs_do_not_share_one_headline():
    heads = set()
    used = {}
    for i, typ in enumerate(("easy", "tempo", "tempo")):
        r = run(i, typ=typ, feel="right")
        v = engine.enrich_run(r, [], {}, T0, engine.T.Usage(variants=used), None)
        heads.add(v.rendered.headline)
        used[v.rendered.variant_id] = T0
    assert len(heads) == 3


# --- 6. filler -------------------------------------------------------------------------------

@pytest.mark.parametrize("body", ["Solid effort. You're finding your rhythm on these trails.", "Well done, keep it up.",
                                  "Impressive run at 4.7 km."])
def test_filler_is_rejected(body):
    assert clean(CardText(headline="Trail run", body=body)).startswith("banned")


def test_prompt_names_the_filler_ban():
    from companion.writer import SYSTEM_PROMPT
    assert "solid effort" in SYSTEM_PROMPT and "finding your rhythm" in SYSTEM_PROMPT


# --- 7. captions ------------------------------------------------------------------------------

def test_a_run_caption_is_the_headline_and_one_line_of_judgement():
    card = OutCard("c", "Tempo trail run", "4.7 km in 28 min at 6:03/km. Judge it by effort, not pace.", [],
                   short_caption=True)
    assert caption_text(card) == "Tempo trail run\nJudge it by effort, not pace."


def test_caption_keeps_a_touch_paragraph_the_picture_does_not_carry():
    card = OutCard("c", "Easy", "6.5 km at 5:40/km. Boring is the point.\n\nNew spot: somewhere", [], short_caption=True)
    assert caption_text(card) == "Easy\nBoring is the point.\nNew spot: somewhere"


def test_other_cards_and_text_only_sends_keep_the_full_text():
    card = OutCard("c", "Sunday", "Three runs. 18 km.", [])
    assert caption_text(card) == "Sunday\nThree runs. 18 km."


def test_headline_must_not_repeat_the_picture_or_use_a_pipe():
    for h in ("Trail run: 4.7 km in 28 min", "Tempo ticked | 6.2 km", "Tempo ticked.", "Pace 6:03/km"):
        assert clean(CardText(headline=h, body="Level with last time.")) in ("format", "headline_repeats_picture"), h
    assert clean(CardText(headline="Norwegian 4x4 done", body="Four reps at work pace.")) is None


def test_word_only_contradictions_are_blocked():
    level = facts_result(("base", "Tempo trail run: 4.7 km in 28 min"), ("verdict", "Verdict: no real change"))
    for w in ("Better than last time.", "Ahead of last time.", "Shaved a bit off.", "Quicker today.", "Improved over 4.7 km."):
        assert clean(CardText(headline="Tempo trail run", body=w), level.facts) == "contradicts_facts", w
    fast = facts_result(("base", "Tempo trail run: 4.7 km in 28 min"), ("verdict", "Verdict: faster"))
    for w in ("Slow and steady over 4.7 km.", "Slowly does it."):
        assert clean(CardText(headline="Tempo trail run", body=w), fast.facts) == "contradicts_facts", w


def test_pace_basis_check_also_reads_per_km_and_per_mile():
    f = facts_result(*TRUE_FACTS).facts
    assert clean(CardText(headline="Trail run", body="6:00 per km, 45 s/km faster."), f) == "mixed_pace_basis"
    assert clean(CardText(headline="Trail run", body="9:40 per mile, 45 s/km faster."), f) == "mixed_pace_basis"


def test_the_template_path_carries_the_verdict_word_too(tmp_path, fakes):
    s = make_settings(tmp_path, openrouter_key="")
    db.init(s.db_path)
    w = Writer(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    facts = facts_result(("base", "Tempo trail run: 4.7 km in 28 min"), ("verdict", "Verdict: no real change"))
    assert w.write(facts, {}).headline.endswith(", no real change")


def test_caption_keeps_the_comparison_sentence():
    card = OutCard("c", "Easy run", "6.5 km at 5:40/km. 12 s/km faster than last time. Boring is the point.", [],
                   short_caption=True)
    assert caption_text(card) == "Easy run\n12 s/km faster than last time. Boring is the point."
