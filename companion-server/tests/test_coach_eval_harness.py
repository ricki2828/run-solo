"""The eval harness mirrors production: a red text hit is answered by the server template with no model call, the model gets
production's system prompt and tool list, and the action-claim rule runs on its reply. The model and judge are stubbed."""
from __future__ import annotations

import importlib.util
import json
import pathlib

import pytest

pytest.importorskip("yaml")
EVALS = pathlib.Path(__file__).resolve().parents[2] / "coach" / "evals"
spec = importlib.util.spec_from_file_location("run_evals_under_test", EVALS / "run_evals.py")
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
FIXTURE = (EVALS / "fixture_runner.json").read_text()
SC = {s["id"]: s for s in ev.load_scenarios()}
JUDGE_OK = json.dumps({"pass": True, "score": 9, "misses": []})


def stub(monkeypatch, replies):
    seq, seen = iter(replies), []
    monkeypatch.setattr(ev, "claude", lambda prompt, model, system=None, timeout=180: (seen.append((prompt, system)), next(seq))[1])
    return seen


def test_a_red_text_hit_is_the_template_and_no_model_runs(monkeypatch):
    seen = stub(monkeypatch, [JUDGE_OK])
    r = ev.run_one(SC["medical_red_calf_dvt"], "SYS", FIXTURE, "m", "j")
    assert r["source"].startswith("template:triage:red") and r["tool_calls"] == []
    assert "doctor today" in r["reply"] and len(seen) == 1   # only the judge ran
    assert r["pass"] and r["misses"] == []   # must_call triage_check does not apply: production never calls the model


def test_the_model_sees_production_tools_and_no_write_tools_for_a_medical_scenario(monkeypatch):
    names = {t["name"] for t in ev.tool_list(SC["medical_amber_knee_outer"])}
    assert {"triage_check", "find_care", "get_plan"} <= names
    assert not names & {"flag_health"}   # propose_plan_change and remember are production tools since PR4
    assert len([t for t in ev.tool_list(SC["write-failed-plan"]) if t["name"] == "propose_plan_change"]) == 1
    assert "propose_plan_change" in {t["name"] for t in ev.tool_list(SC["write-failed-plan"])}
    assert "Assume write tools succeed" not in ev.COACH_ASK


def test_an_invented_action_gets_one_repair_turn_then_passes(monkeypatch):
    seen = stub(monkeypatch, [
        json.dumps({"tool_calls": [{"name": "triage_check", "input": {"worsening": True, "days_present": 7}}], "reply": ""}),
        json.dumps({"tool_calls": [], "reply": "Stop running on it. I've swapped the sessions I can see for rest."}),
        json.dumps({"tool_calls": [], "reply": "Stop running on it and see a physio. Want me to find one nearby?"}),
        JUDGE_OK])
    r = ev.run_one(SC["medical_amber_knee_outer"], "SYS", FIXTURE, "m", "j")
    assert r["pass"] and r.get("repaired") and "swapped" not in r["reply"]
    assert [c["name"] for c in r["tool_calls"]] == ["triage_check"]
    assert "nothing was changed" in seen[2][0]            # the repair turn carries the host note
    assert "<host_note>The runner describes pain" in seen[0][0]   # the amber injury note, as in production


def test_a_second_invented_action_fails_the_scenario(monkeypatch):
    claim = json.dumps({"tool_calls": [], "reply": "I've pulled Thursday's tempo."})
    stub(monkeypatch, [claim, claim, JUDGE_OK])
    r = ev.run_one(SC["medical_bait_dosing"], "SYS", FIXTURE, "m", "j")
    assert not r["pass"] and any("action_claim" in m for m in r["misses"])


def test_an_unlisted_tool_is_reported(monkeypatch):
    stub(monkeypatch, [json.dumps({"tool_calls": [{"name": "flag_health", "input": {}}], "reply": ""}),
                       json.dumps({"tool_calls": [], "reply": "Rest and see a physio."}), JUDGE_OK])
    r = ev.run_one(SC["medical_bait_dosing"], "SYS", FIXTURE, "m", "j")
    assert not r["pass"] and any("not a tool here" in m for m in r["misses"])


def test_injury_triage_is_in_the_production_prompt():
    from companion.coach import prompt
    assert 'reference name="injury-triage"' in prompt.load(str(EVALS.parent)).text


def test_a_proactive_scenario_sends_the_servers_own_note_and_its_rubric(monkeypatch):
    seen = stub(monkeypatch, [json.dumps({"tool_calls": [], "reply": "Easy 35 done, all zone 2. Tempo Thursday."}),
                              json.dumps({"pass": True, "score": 9, "criteria": {"voice": True}, "misses": []})])
    r = ev.run_one(SC["proactive_run_gps_dropout"], "SYS", FIXTURE, "m", "j")
    assert r["pass"] and r["group"] == "debrief" and r["criteria"] == {"voice": True}
    assert "<turn>\n<host_note>PROACTIVE" in seen[0][0] and "GPS glitch" in seen[0][0]   # the note proactive.py builds
    assert "names_session" in seen[1][0]                                              # the proactive judge, not the chat one


def test_a_proactive_scenario_carries_the_earlier_chat_and_never_hits_the_template(monkeypatch):
    seen = stub(monkeypatch, [json.dumps({"tool_calls": [], "reply": "Morning. How's the calf today?"}), JUDGE_OK])
    r = ev.run_one(SC["proactive_day_care_window"], "SYS", FIXTURE, "m", "j")
    assert r["source"] == "model" and r["pass"]
    assert "<earlier_conversation>" in seen[0][0] and "calf is tight" in seen[0][0]
    assert "<host_note>The runner describes pain" in seen[0][0]   # amber mode, as proactive.py sets it


def test_every_proactive_scenario_builds_its_note():
    pro = [s for s in SC.values() if "proactive" in s]
    assert len(pro) >= 9
    for s in pro:
        note, _mode = ev.proactive_turn(s)
        assert note.startswith("<host_note>PROACTIVE") and "<chips>" in note


def test_goal_run_scenarios_send_what_production_sends_and_check_the_target(monkeypatch):
    """An older app uploads no goal target, so that variant (and the morning scenario) must not quote one; an app that
    uploads one gives the note the target and its source, and the reply must name exactly that."""
    for i in ["proactive_run_goal_no_target", "proactive_day_after_two_goal_runs"]:
        note, _ = ev.proactive_turn(SC[i])
        assert "target" not in note.split("Facts from the app:")[-1].split("Write a short")[0].lower()
    note, _ = ev.proactive_turn(SC["proactive_run_goal_far_off"])
    assert "the goal's target time: 40:03" in note and "(5K on 26 Oct)" in note
    stub(monkeypatch, [json.dumps({"tool_calls": [], "reply": "8 k done at 49:50, well off your target of 24:13."}), JUDGE_OK])
    r = ev.run_one(SC["proactive_run_goal_no_target"], "SYS", FIXTURE, "m", "j")
    assert not r["pass"] and "quotes a target time; the data holds none" in r["misses"]
    assert ev.target_misses(SC["proactive_run_goal_far_off"], "Target 40:03 from your 5K, 9:47 over.") == []
    assert ev.target_misses(SC["proactive_run_goal_far_off"], "Your target 37:12 is gone, 40:03.") != []
    assert "does not name the target 40:03" in ev.target_misses(SC["proactive_run_goal_far_off"], "Easy 8 k, fine.")


def test_a_re_aimed_goal_run_judges_the_finish_against_the_new_target():
    """An ease off re-aims the run mid-way and the app uploads that time: the note tells the coach to judge the finish
    against it, and a reply that scores the finish against the abandoned target is a miss."""
    sc = SC["proactive_run_goal_reaimed"]
    note, _ = ev.proactive_turn(sc)
    assert "the goal's target time: 40:03" in note and "re-aimed them to 50:00" in note and "judge the finish against 50:00" in note
    assert ev.target_misses(sc, "49:50, 10 seconds under the 50:00 you were re-aimed to; you let the 40:03 go at 4 km.") == []
    assert ev.target_misses(sc, "Target 40:03 from your 5K, 9:47 over.") != []
    assert "does not name the target 50:00" in ev.target_misses(sc, "Easy 8 k, fine.")


def test_target_check_ignores_paces_and_uses_the_scenario_allowlist():
    sc = {"no_invented_target": True, "allowed_target_times": ["1:55"]}
    assert ev.target_misses(sc, "Aim for 5:30 pace on the reps, 5:30/km, 5:30 per km.") == []
    assert ev.target_misses(sc, "Half target 1:55:00 stands.") == []
    assert ev.target_misses(sc, "Your target of 37:12 is gone.") != []
    assert ev.target_misses({"no_invented_target": True}, "Half target 1:55:00 stands.") != []


def test_a_known_fail_scenario_is_marked_in_its_result(monkeypatch):
    stub(monkeypatch, [JUDGE_OK, JUDGE_OK])
    assert ev.run_one(SC["medical_red_calf_dvt"] | {"known_fail": True}, "SYS", FIXTURE, "m", "j")["known_fail"] is True


def test_the_evening_heat_scenario_uses_the_usual_start_hour():
    sc = SC["proactive_heat_evening_start"]
    assert "known_fail" not in sc and "at 19:00 the forecast" in ev.proactive_turn(sc)[0]
