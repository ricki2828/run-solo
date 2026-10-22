"""Coach chat PR1: a validator miss gets one repair turn with the reason, only a second miss is the template; the typing
heartbeat runs for the whole job; the cost footer is for the operator's runner only."""
from __future__ import annotations

import time
from datetime import timedelta

import pytest

from companion.coach import chat as coach_chat
from companion.config import Settings

from conftest import coach_text, coach_tools
from test_coach_chat import T0, cc, coach_settings, rows, run_worker, say  # noqa: F401  (cc is a fixture)


def job(c):
    return rows(c, "SELECT * FROM coach_jobs")[0]


def sent_texts(fakes):
    return [b["text"] for m, b in fakes.tg if m == "sendMessage"]


def test_a_validator_miss_is_repaired_with_the_reason_and_the_runner_never_sees_the_miss(cc, fakes):
    fakes.coach_queue = [coach_text("Aim for 4:05/km, you'll fly."), coach_text("Aim for an even effort and see how it feels.")]
    say(cc, "what pace for sunday?")
    run_worker(cc)
    j = job(cc)
    assert (j["reply_source"], j["outcome"]) == ("llm", "repaired")
    assert len(fakes.coach_calls) == 2
    msgs = fakes.coach_calls[1]["messages"]
    assert msgs[-2] == {"role": "assistant", "content": "Aim for 4:05/km, you'll fly."}
    note = msgs[-1]
    assert note["role"] == "user" and note["content"].startswith("<host_note>Your reply was not sent:")
    assert "4:05" in note["content"] and "calc_pace" in note["content"]
    assert sent_texts(fakes)[-1] == "Aim for an even effort and see how it feels."
    assert [m["text"] for m in rows(cc, "SELECT text FROM coach_messages WHERE role='coach'")] == ["Aim for an even effort and see how it feels."]


def test_the_reason_never_grounds_the_second_attempt(cc, fakes):
    # the host note names 4:05; repeating it must still fail
    fakes.coach_queue = [coach_text("Aim for 4:05/km."), coach_text("OK, 4:05/km it is.")]
    say(cc, "what pace for sunday?")
    run_worker(cc)
    j = job(cc)
    assert (j["reply_source"], j["outcome"]) == ("template", "rejected:ungrounded")
    assert sent_texts(fakes)[-1] == coach_chat.FALLBACK_TEXT
    assert len(fakes.coach_calls) == 2   # one repair, no more


def test_fallback_is_warm_and_carries_chips(cc, fakes):
    fakes.coach_queue = ["timeout"]
    say(cc, "how am I going?")
    run_worker(cc)
    assert "Sorry" not in coach_chat.FALLBACK_TEXT
    send = [b for m, b in fakes.tg if m == "sendMessage"][-1]
    assert send["text"] == coach_chat.FALLBACK_TEXT
    labels = [b["text"] for row in send["reply_markup"]["inline_keyboard"] for b in row]
    assert labels == list(coach_chat.FALLBACK_CHIPS)


def test_repair_turns_can_be_switched_off(tmp_path, fakes):
    import dataclasses
    s = dataclasses.replace(coach_settings(tmp_path), coach_repair_turns=0)
    assert s.coach_repair_turns == 0
    assert Settings.from_env({"COMPANION_PEPPER": "x" * 20}).coach_repair_turns == 1
    assert Settings.from_env({"COMPANION_PEPPER": "x" * 20, "COMPANION_COACH_REPAIR_TURNS": "9"}).coach_repair_turns == 2


def test_a_repair_turn_may_call_calc_pace_and_then_pass(cc, fakes):
    fakes.coach_queue = [
        coach_text("Run 5:40/km."),
        coach_tools(("calc_pace", {"mode": "pace", "distance_km": 10, "time": "56:40"})),
        coach_text("56:40 for 10 km is <b>5:40/km</b>."),
    ]
    say(cc, "what pace for a 56:40 10k?")   # the runner's own words ground 56:40 and 10 only, not 5:40
    run_worker(cc)
    j = job(cc)
    assert (j["reply_source"], j["outcome"]) == ("llm", "repaired")
    assert sent_texts(fakes)[-1] == "56:40 for 10 km is <b>5:40/km</b>."


def test_calls_are_bounded_even_when_every_reply_is_bad(cc, fakes):
    fakes.coach_queue = [coach_text("Do 33 km.")] * 10
    say(cc, "plan?")
    run_worker(cc)
    assert len(fakes.coach_calls) == 2


def test_typing_runs_for_the_whole_job(cc, fakes, monkeypatch):
    monkeypatch.setattr(coach_chat, "TYPING_EVERY_S", 0.05)
    fakes.coach_queue = [lambda body: (time.sleep(0.4), coach_text("Easy does it."))[1]]
    say(cc, "legs are cooked")
    before = fakes.tg_methods().count("sendChatAction")
    run_worker(cc)
    beats = fakes.tg_methods().count("sendChatAction") - before
    assert beats >= 4   # one at the claim and one every 50 ms of the 400 ms call
    stopped = fakes.tg_methods().count("sendChatAction")
    time.sleep(0.2)
    assert fakes.tg_methods().count("sendChatAction") == stopped   # the heartbeat ends with the job


def test_cost_footer_only_for_the_operators_runner(tmp_path, fakes):
    import dataclasses, httpx
    from fastapi.testclient import TestClient
    from companion.app import create_app
    from companion.channels import TelegramChannel
    from conftest import OWNER, auth, enrol

    def reply_for(show):
        s = dataclasses.replace(coach_settings(tmp_path / ("s" if show else "n")), coach_show_cost=frozenset({f"telegram:{OWNER}"}) if show else frozenset())
        app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
        with TestClient(app) as c:
            c.svc = app.state.svc
            tok = enrol(c)
            c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(tok))
            fakes.coach_queue = [coach_text("Keep it easy.", cost=0.034)]
            say(c, "hi", uid=900_000 + show)
            run_worker(c)
            return rows(c, "SELECT text FROM coach_messages WHERE role='coach'")[0]["text"], sent_texts(fakes)[-1]

    stored, shown = reply_for(True)
    assert stored == "Keep it easy."                        # history never carries the footer
    assert shown.startswith("Keep it easy.\n\n<i>· 3.4¢ · 1 call · ") and shown.endswith(" s</i>")
    stored, shown = reply_for(False)
    assert shown == "Keep it easy."
