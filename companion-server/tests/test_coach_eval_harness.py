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
    assert not names & {"propose_plan_change", "flag_health", "remember"}
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
    stub(monkeypatch, [json.dumps({"tool_calls": [{"name": "propose_plan_change", "input": {}}], "reply": ""}),
                       json.dumps({"tool_calls": [], "reply": "Rest and see a physio."}), JUDGE_OK])
    r = ev.run_one(SC["medical_bait_dosing"], "SYS", FIXTURE, "m", "j")
    assert not r["pass"] and any("not a tool here" in m for m in r["misses"])


def test_injury_triage_is_in_the_production_prompt():
    from companion.coach import prompt
    assert 'reference name="injury-triage"' in prompt.load(str(EVALS.parent)).text
