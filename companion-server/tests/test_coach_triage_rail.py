"""Coach PR3, the enforcement half: the red/amber/green table runs on the runner's own words server-side, before any model call;
red gets a fixed reply and a 72 h training pause; amber gets rest-or-modify only; dosing and diagnosis are never sent."""
from __future__ import annotations

from datetime import timedelta

import pytest

from companion.coach import validator
from companion.coach.ext.triage import classify_text

from conftest import coach_text
from test_coach_chat import T0, cc, rows, run_worker, say, uid_of   # noqa: F401  (cc is a fixture)

# ------------------------------------------------------------------------------------------------ the text table
RED_TEXT = {
    "calf_swollen_hot_or_red": ["my calf is really swollen and hot", "calf feels swolen and warm since last night", "I think I have a DVT",
                                 "swollen red calf after the flight", "possible blood clot in my leg", "my calve is puffy and hot"],
    "numbness_tingling_weakness": ["my foot goes numb about 6k in", "numbness down my leg", "tingly toes the whole run", "foot drop on the left",
                                    "pins and needles in my shin", "sudden weakness in my leg", "my leg gave out"],
    "cannot_bear_weight": ["can't put any weight on it", "cant put any wieght on my ankle", "unable to walk after the trail", "I cannot bear weight",
                           "couldn't stand on it", "non weight bearing since sunday"],
    "bone_pain_at_night": ["I think it's a stress fracture", "possible stress reaction in my shin"],
    "severe_rest_or_night_pain": ["shin pain wakes me at night", "my foot aches at night and in bed", "pain keeps me awake", "it hurts at rest",
                                  "excruciating pain in my hip", "night pain in the heel"],
    "chest_breath_or_fainting": ["chest pain on the hill", "chets pain after the intervals", "I fainted at the finish", "nearly passed out",
                                  "i cant breathe properly", "tight chest and shortness of breath"],
    "heat_illness_signs": ["think I had heat stroke", "heat exhaustion at 10k", "stopped sweating and felt hot", "felt confused at the end",
                           "I was disoriented in the heat"],
    "head_injury": ["I hit my head on a low branch", "banged my head when I fell", "bumped my head", "head injury on the trail", "concussed myself",
                    "got knocked out"],
    "deformity": ["my ankle looks crooked", "heard a snap in my foot", "I dislocated my shoulder", "bone sticking out"],
    "fever_with_joint_pain": ["fever and my knee is killing me", "joint pain and a fever"],
    "after_fall_or_impact": ["I fell on the trail and my wrist hurts", "tripped on a kerb, knee is sore"],
}
NEGATED = ["no chest pain", "my calf isn't swollen", "no numbness or tingling", "never fainted", "didn't hit my head", "without any swelling or numbness",
           "I don't have a fever", "no stress fracture according to the scan", "no heat exhaustion", "my calf is not hot or red",
           "I wasn't confused", "no pain at night"]
GREEN_TEXT = ["legs tired after the long run", "calves a bit tight but loosen up when warm", "can I move my long run to Sunday?",
              "how fast should my easy runs be", "I'm confused about my plan", "chest fine, legs heavy", "feeling flat today"]
AMBER_TEXT = ["outside of my knee has been sore for 5 days", "my ankle is a bit swollen after the run", "I'm limping a bit on the left",
              "the pain is getting worse every run", "sharp pain in my knee from 5k", "I pulled a hamstring"]


@pytest.mark.parametrize("code,text", sorted((c, t) for c, ts in RED_TEXT.items() for t in ts))
def test_every_red_flag_phrasing_is_red(code, text):
    r = classify_text(text)
    assert r.level == "red" and code in r.codes, (text, r)


@pytest.mark.parametrize("text", NEGATED)
def test_negated_flags_are_not_red(text):
    assert classify_text(text).level != "red", text


@pytest.mark.parametrize("text", GREEN_TEXT)
def test_ordinary_training_talk_is_green(text):
    assert classify_text(text).level == "green", text


@pytest.mark.parametrize("text", AMBER_TEXT)
def test_injury_talk_without_a_red_flag_is_amber(text):
    assert classify_text(text).level == "amber", text


def test_a_negation_does_not_leak_across_clauses():
    assert classify_text("no chest pain, but my calf is swollen and hot").level == "red"
    assert classify_text("no sleep, fainted at work").level == "red"


def test_every_table_code_has_a_phrase_here():
    from companion.coach.ext.triage import TEXT_RED
    assert set(TEXT_RED) == set(RED_TEXT)


# ------------------------------------------------------------------------------------------------ the rail in the worker
def test_red_text_gets_the_fixed_reply_no_model_and_a_72h_pause(cc, fakes):
    say(cc, "my calf is really swollen and hot, long run tomorrow?")
    run_worker(cc)
    assert fakes.coach_calls == [] and fakes.screen_calls == []                  # no model of any kind
    j = rows(cc, "SELECT * FROM coach_jobs")[0]
    assert (j["kind"], j["reply_source"], j["triage"]) == ("safety", "safety", "red") and j["outcome"].startswith("triage:red")
    text = fakes.tg_texts()[-1]                                                   # the reply column is cleared once sent
    assert "doctor today" in text and "urgent care" in text and "call" in text
    assert "I won't suggest any training until you've been checked" in text
    assert "pace" not in text.lower() and "tempo" not in text.lower()
    flag = rows(cc, "SELECT * FROM health_flags WHERE user_id=?", uid_of(cc))[0]
    assert (flag["kind"], flag["state"], flag["source"]) == ("injury", "active", "triage")
    assert rows(cc, "SELECT text FROM coach_messages WHERE role='coach'")[0]["text"] == text


def test_chest_style_hits_use_the_existing_urgent_reply_and_flag(cc, fakes):
    say(cc, "I think I had heat exhaustion out there")
    run_worker(cc)
    assert fakes.coach_calls == []
    j = rows(cc, "SELECT * FROM coach_jobs")[0]
    assert j["reply_source"] == "safety" and j["triage"] == "red"
    assert rows(cc, "SELECT kind FROM health_flags WHERE user_id=?", uid_of(cc))[0]["kind"] == "urgent"


def test_red_reply_offers_the_known_place_only_when_there_is_one(cc, fakes):
    say(cc, "cant put any weight on it")
    run_worker(cc)
    assert "Tell me your suburb or town" in fakes.tg_texts()[-1]


def test_next_turn_within_72h_is_in_pause_mode_and_training_advice_is_refused(cc, fakes):
    say(cc, "numbness down my leg")
    run_worker(cc)
    fakes.coach_queue = [coach_text("Rest up. A physio or doctor can advise."), ]
    t1 = T0 + timedelta(hours=30)
    say(cc, "ok what should I do thursday?", now=t1)
    fakes.coach_queue = [coach_text("Do the tempo on Thursday, easy 30 min."), coach_text("Nothing on Thursday until you're checked.")]
    run_worker(cc, now=t1 + timedelta(seconds=10))
    j = rows(cc, "SELECT * FROM coach_jobs ORDER BY id DESC")[0]
    assert j["triage"] == "red" and j["outcome"] == "repaired"
    assert len(fakes.coach_calls) == 2 and "<host_note>" in str(fakes.coach_calls[0]["messages"][-1]["content"])
    assert "no paces" in str(fakes.coach_calls[1]["messages"][-1]["content"])
    assert fakes.tg_texts()[-1] == "Nothing on Thursday until you're checked."


def test_the_pause_lapses_after_72h(cc, fakes):
    say(cc, "numbness down my leg")
    run_worker(cc)
    later = T0 + timedelta(hours=73)
    cc.svc.coach.step(later)
    assert rows(cc, "SELECT state, cleared_by FROM health_flags WHERE user_id=?", uid_of(cc))[0] == {"state": "cleared", "cleared_by": "auto"}
    say(cc, "how was my week?", now=later)
    fakes.coach_queue = [coach_text("Solid week.")]
    run_worker(cc, now=later + timedelta(seconds=10))
    j = rows(cc, "SELECT * FROM coach_jobs ORDER BY id DESC")[0]
    assert j["triage"] is None and j["reply_source"] == "llm"


def test_amber_turn_is_marked_and_pace_or_intensity_advice_is_repaired(cc, fakes):
    say(cc, "outside of my knee is sore for 5 days now")
    fakes.coach_queue = [coach_text("Run an easy tempo session on Thursday."), coach_text("Take Thursday off and see a physio if it hangs around.")]
    run_worker(cc)
    j = rows(cc, "SELECT * FROM coach_jobs")[0]
    assert j["triage"] == "amber" and j["outcome"] == "repaired"
    assert fakes.tg_texts()[-1].startswith("Take Thursday off")


# ------------------------------------------------------------------------------------------------ dosing and diagnosis
@pytest.mark.parametrize("text", [
    "Take 400 mg of ibuprofen every 6 hours.", "Try two tablets of paracetamol before the race.", "A 200mg dose of naproxen will help.",
    "Pop some ibuprofen after the run.", "Voltaren gel twice daily is fine.", "Take one tablet with food.", "Cortisone 20 mg works well."])
def test_dosing_is_refused(text):
    assert validator.check(text, []) == "dosing", text


@pytest.mark.parametrize("text", [
    "You have ITB syndrome.", "It's a stress fracture.", "That's plantar fasciitis.", "This is shin splints.", "Sounds like runner's knee.",
    "You've got a torn meniscus.", "It is probably tendinitis.", "Looks like a calf strain.", "It's definitely a DVT."])
def test_diagnosis_is_refused(text):
    assert validator.check(text, []) == "diagnosis", text


@pytest.mark.parametrize("text", [
    "It could be an overuse thing, but I can't diagnose it. A physio can tell you.", "Ask a pharmacist or doctor about pain relief.",
    "Take Thursday off and keep it easy.", "That fits a big week."])
def test_hedged_or_ordinary_replies_pass(text):
    assert validator.check(text, []) is None, text


@pytest.mark.parametrize("text", [
    "Aim for 5:40 per km on Thursday.", "Do the tempo on Thursday.", "Keep the intervals but cut them short.", "Push through it for now.",
    "Build your mileage back slowly."])
def test_amber_mode_refuses_pace_and_intensity_advice(text):
    assert validator.medical_check(text, "amber") == "training_advice", text
    assert validator.medical_check(text, None) is None


def test_amber_mode_allows_rest_and_modify():
    for t in ["Skip Thursday's tempo and rest.", "Take a few days off and see a physio.", "Swap the run for a walk if it is pain-free."]:
        assert validator.medical_check(t, "amber") is None, t


def test_red72_mode_also_refuses_run_suggestions():
    assert validator.medical_check("Try an easy run tomorrow.", "red72") == "training_advice"
    assert validator.medical_check("Try an easy run tomorrow.", "amber") is None
