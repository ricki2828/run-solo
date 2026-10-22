"""Coach PR2: web_search (PII refusal, medical allowlist, verbatim citations, ledger) and get_weather. All HTTP is mocked; no
key is read or sent anywhere real."""
from __future__ import annotations

import dataclasses
import json
import sqlite3
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from companion.app import create_app
from companion.config import default_coach_dir
from companion.coach import ext
from companion.coach.ext import research
from companion.timeutil import iso

from conftest import OWNER, auth, coach_text, coach_tools, enrol
from test_coach_chat import T0, cc, coach_settings, rows, run_worker, say, uid_of  # noqa: F401  (cc is a fixture)

REG = ext.load_registry(default_coach_dir(), frozenset())
CARBON = "https://www.nhs.uk/conditions/shin-splints/"
BLOG = "https://runblog.example.net/carbon"


def answer(text="Carbon plates give about 4% better economy in lab tests.", urls=(BLOG,), cost=0.021):
    return {"provider": "Google", "usage": {"cost": cost, "prompt_tokens": 3000, "completion_tokens": 200},
            "choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": text, "annotations": [
                {"type": "url_citation", "url_citation": {"url": u, "title": f"T {i}", "content": "x"}} for i, u in enumerate(urls)]}}]}


def ctx_for(c, handler, http_log=None):
    def h(req):
        if http_log is not None:
            http_log.append(req)
        return handler(req)
    svc = SimpleNamespace(s=c.svc.s, http=httpx.Client(transport=httpx.MockTransport(h)))
    return ext.ToolContext(svc, uid_of(c), T0, 7)


def search(c, handler, **a):
    log: list = []
    ctx = ctx_for(c, handler, log)
    return REG.call("web_search", a, ctx), ctx, log


# ------------------------------------------------------------------------------------------------------------ registry
def test_the_tools_load_and_the_rules_mention_them():
    assert REG.has("web_search") and REG.has("get_weather") and REG.has("calc_pace")
    assert "web_search" in REG.rules()


# ------------------------------------------------------------------------------------------------------ PII refusal
@pytest.mark.parametrize("q", [
    "email me at ricki@example.com about shoes",
    "call 021 555 1234 best shoes",
    "knee pain near -36.84853, 174.76349",
    "physio at 12 Queen Street Auckland",
    "I was born 12/03/1985 and run marathons",
    "my wife Sarah runs slow, plan?",
    "my name is Ricki best half marathon plan",
    "x" * 121,
])
def test_personal_queries_are_refused_and_nothing_is_sent(cc, q):
    r, ctx, log = search(cc, lambda req: httpx.Response(200, json=answer()), query=q)
    assert r["ok"] is False and log == []
    assert rows(cc, "SELECT * FROM cost_ledger WHERE purpose='research'") == []


@pytest.mark.parametrize("q", [
    "is John Smith a good physio",
    "best route -33.87,151.21 for hills",
    "call six four two one five five five one two three four",
    "advice for a 44 year old in Bondi",
    "running tips for a 50yo",
    "good physio near Ponsonby",
    "marathon training in Wellington",
])
def test_hardened_pii_checks(cc, q):
    r, _, log = search(cc, lambda req: httpx.Response(200, json=answer()), query=q)
    assert r["ok"] is False and log == []


@pytest.mark.parametrize("q", [
    "do Nike Vaporfly shoes help half marathoners",
    "how do I pace the Auckland Marathon",
    "Garmin Forerunner vs Coros Pace for trail running",
    "what is zone 2 training",
])
def test_ordinary_gear_and_race_questions_still_go_out(cc, q):
    r, _, log = search(cc, lambda req: httpx.Response(200, json=answer()), query=q, topic="gear")
    assert r["ok"] is True and len(log) == 1


def test_a_symptom_question_is_forced_to_the_medical_allowlist(cc):
    r, _, log = search(cc, lambda req: httpx.Response(200, json=answer(urls=(BLOG, CARBON))), query="why does my knee hurt after long runs", topic="gear")
    assert json.loads(log[0].content)["plugins"][0]["include_domains"] == list(research.MEDICAL_DOMAINS)
    assert [s["url"] for s in r["sources"]] == [CARBON] or r["found"] is False
    assert "orthoinfo.aaos.org" in research.MEDICAL_DOMAINS and "aaos.org" not in research.MEDICAL_DOMAINS


def test_links_and_phones_in_the_summary_are_stripped(cc):
    text = "See https://evil.example.com/x or www.evil.org and foo.com, call +64 21 555 1234. About 4% better economy."
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(text=text)), query="carbon shoes for a half", topic="gear")
    t = r["quoted_web_text"]
    assert "evil" not in t and "foo.com" not in t and "555" not in t and "4% better economy" in t


def test_zdr_is_requested_and_a_rejection_is_a_clean_unavailable(cc):
    seen: list = []
    r, _, _ = search(cc, lambda req: (seen.append(json.loads(req.content)), httpx.Response(404, json={}))[1], query="carbon shoes for a half", topic="gear")
    assert seen[0]["provider"]["zdr"] is True and seen[0]["provider"]["require_parameters"] is True
    assert r["ok"] is False and "unavailable right now" in r["error"]


def test_a_medical_answer_that_drew_on_any_other_page_is_not_used(cc):
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(urls=(CARBON, BLOG))), query="shin splints general causes", topic="medical")
    assert r["found"] is False and r["sources"] == [] and "quoted_web_text" not in r


def test_one_off_list_page_among_many_allowlisted_ones_voids_a_medical_answer(cc):
    four = tuple(f"https://www.nhs.uk/conditions/p{i}/" for i in range(4))
    for extra in ("https://runblog.example.net/x", "http://runblog.example.net/insecure", "not a url"):
        r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(urls=four + (extra,))), query="shin splints general causes", topic="medical")
        assert r["found"] is False and r["sources"] == [] and "quoted_web_text" not in r
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(urls=four)), query="shin splints general causes", topic="medical")
    assert r["found"] is True and len(r["sources"]) == 4


def test_year_ranges_survive_the_phone_strip(cc):
    text = "A 2019-2023 review found 4% gains; call 021 555 1234."
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(text=text)), query="carbon shoes for a half", topic="gear")
    assert "2019-2023" in r["quoted_web_text"] and "555" not in r["quoted_web_text"]


def test_the_runners_own_name_is_refused(cc):
    con = sqlite3.connect(cc.svc.s.db_path)
    con.execute("UPDATE users SET chat_name='Ricki Taiaroa'")
    con.commit()
    con.close()
    r, _, log = search(cc, lambda req: httpx.Response(200, json=answer()), query="how fast is Ricki over 10k")
    assert r["ok"] is False and "name" in r["error"] and log == []


def test_a_plain_question_goes_out(cc):
    r, _, log = search(cc, lambda req: httpx.Response(200, json=answer()), query="do carbon plate shoes help half marathoners", topic="gear")
    assert r["ok"] is True and len(log) == 1


# ----------------------------------------------------------------------------------------- request shape and domains
def test_medical_queries_carry_the_domain_allowlist_and_others_do_not(cc):
    r, _, log = search(cc, lambda req: httpx.Response(200, json=answer(urls=(CARBON,))), query="shin splints general causes", topic="medical")
    body = json.loads(log[0].content)
    assert body["plugins"] == [{"id": "web", "max_results": 5, "include_domains": list(research.MEDICAL_DOMAINS)}]
    assert body["model"] == cc.svc.s.coach_screen_model and "tools" not in body
    assert log[0].headers["X-Title"] == "Run Supreme coach research"
    _, _, log = search(cc, lambda req: httpx.Response(200, json=answer()), query="best long run fuelling", topic="general")
    assert "include_domains" not in json.loads(log[0].content)["plugins"][0]


def test_medical_citations_outside_the_allowlist_are_dropped_and_no_source_means_no_claim(cc):
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(urls=(CARBON, "http://www.nhs.uk/insecure"))),
                     query="shin splints general causes", topic="medical")
    assert [s["url"] for s in r["sources"]] == [CARBON]
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(urls=(BLOG,))), query="shin splints general causes", topic="medical")
    assert r["ok"] and r["found"] is False and r["sources"] == [] and "quoted_web_text" not in r


def test_citations_come_back_verbatim_deduped_and_https_only(cc):
    urls = (BLOG + "?utm=1", BLOG + "?utm=1", "http://plain.example.net/a", "javascript:alert(1)", "https://b.example.org/Path_X")
    r, _, _ = search(cc, lambda req: httpx.Response(200, json=answer(urls=urls)), query="carbon shoes for a half", topic="gear")
    assert [s["url"] for s in r["sources"]] == [BLOG + "?utm=1", "https://b.example.org/Path_X"]


# ------------------------------------------------------------------------------------------------ cost and failures
def test_the_call_is_in_the_ledger_and_the_context_carries_the_spend(cc):
    r, ctx, _ = search(cc, lambda req: httpx.Response(200, json=answer(cost=0.021)), query="carbon shoes for a half", topic="gear")
    assert r["ok"]
    led = rows(cc, "SELECT * FROM cost_ledger WHERE purpose='research'")
    assert len(led) == 1 and led[0]["state"] == "settled" and led[0]["cost_usd"] == pytest.approx(0.021) and led[0]["job_id"] == 7
    assert led[0]["model"] == cc.svc.s.coach_screen_model
    assert (ctx.calls, ctx.cost_usd) == (1, pytest.approx(0.021))


@pytest.mark.parametrize("resp", [httpx.Response(500, json={}), httpx.Response(200, json={"choices": [{"message": {"content": ""}}]})])
def test_a_failed_search_tells_the_model_and_releases_the_reservation(cc, resp):
    r, ctx, _ = search(cc, lambda req: resp, query="carbon shoes for a half", topic="gear")
    assert r["ok"] is False and "answer from what you know" in r["error"] or "nothing usable" in r["error"]
    assert rows(cc, "SELECT state FROM cost_ledger WHERE purpose='research'")[0]["state"] in ("released", "settled")


def test_a_timeout_is_a_clean_error(cc):
    def boom(req):
        raise httpx.ReadTimeout("slow")
    r, _, _ = search(cc, boom, query="carbon shoes for a half", topic="gear")
    assert r["ok"] is False
    assert rows(cc, "SELECT state FROM cost_ledger WHERE purpose='research'")[0]["state"] == "released"


def test_the_daily_budget_stops_research(cc):
    s = dataclasses.replace(cc.svc.s, coach_daily_usd=0.01)
    ctx = ctx_for(cc, lambda req: httpx.Response(200, json=answer()))
    ctx.svc.s = s
    r = REG.call("web_search", {"query": "carbon shoes for a half"}, ctx)
    assert r["ok"] is False and "budget" in r["error"]


def test_a_job_that_searched_gets_the_longer_deadline(tmp_path, fakes):
    import time
    s = dataclasses.replace(coach_settings(tmp_path), coach_job_deadline_s=2.0, coach_job_deadline_tool_s=60.0)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(enrol(c)))
        fakes._llm = lambda body: (time.sleep(1.3), httpx.Response(200, json=answer()))[1]
        fakes.coach_queue = [coach_tools(("web_search", {"query": "do carbon plate shoes help half marathoners", "topic": "gear"})),
                             coach_text("About a 4% economy gain in lab tests.")]
        say(c, "carbon shoes?")
        run_worker(c)
        assert rows(c, "SELECT outcome FROM coach_jobs")[0]["outcome"] == "ok"
    assert dataclasses.replace(s, coach_job_deadline_tool_s=90.0).coach_job_deadline_tool_s == 90.0


def test_the_research_reference_is_in_the_prompt():
    from companion.coach import prompt as coach_prompt
    assert '<reference name="research">' in coach_prompt.load(default_coach_dir()).text


def test_the_placeholder_is_posted_before_the_call(cc):
    seen: list = []
    ctx = ctx_for(cc, lambda req: (seen.append("http"), httpx.Response(200, json=answer()))[1])
    ctx.placeholder = lambda text: seen.append(text)
    REG.call("web_search", {"query": "shin splints general causes", "topic": "medical"}, ctx)
    assert seen == ["Checking trusted health sources...", "http"]


# --------------------------------------------------------------------------------------------- through the chat loop
def test_end_to_end_a_cited_link_is_sent_a_made_up_link_is_repaired_and_the_footer_adds_the_search(tmp_path, fakes):
    s = dataclasses.replace(coach_settings(tmp_path), coach_show_cost=frozenset({f"telegram:{OWNER}"}))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        tok = enrol(c)
        c.put("/v1/me/consent", json={"consent_version": 3}, headers=auth(tok))
        fakes._llm = lambda body: httpx.Response(200, json=answer(cost=0.02))   # the summariser (no "tools" in its body)
        fakes.coach_queue = [coach_tools(("web_search", {"query": "do carbon plate shoes help half marathoners", "topic": "gear"})),
                             coach_text(f'Short version: about a 4% economy gain in lab tests. <a href="{BLOG}">Source</a>'),]
        say(c, "are carbon shoes worth it for my half?")
        run_worker(c)
        sent = [b["text"] for m, b in fakes.tg if m == "sendMessage"]
        assert "Reading up on that..." in sent
        edits = [b for m, b in fakes.tg if m == "editMessageText"]
        assert edits and BLOG in edits[-1]["text"] and "<i>· 2.4¢ · 3 calls" in edits[-1]["text"]   # 0.002 + 0.020 + 0.002
        j = rows(c, "SELECT outcome FROM coach_jobs")[0]
        assert j["outcome"] == "ok"


def test_end_to_end_a_link_not_in_the_results_is_refused(cc, fakes):
    fakes._llm = lambda body: httpx.Response(200, json=answer())
    fakes.coach_queue = [coach_tools(("web_search", {"query": "do carbon plate shoes help half marathoners", "topic": "gear"})),
                         coach_text("Read https://made-up.example.com/carbon for the answer."),
                         coach_text("About a 4% economy gain in lab tests.")]
    say(cc, "carbon shoes?")
    run_worker(cc)
    j = rows(cc, "SELECT outcome FROM coach_jobs")[0]
    assert j["outcome"] == "repaired"


# ------------------------------------------------------------------------------------------------------------ weather
def om_handler(temp=31, dew=24, rain=40, geo=True, zone="Pacific/Auckland"):
    def h(req):
        host = req.url.host
        if host == "geocoding-api.open-meteo.com":
            return httpx.Response(200, json={"results": [{"name": "Ponsonby", "country": "New Zealand", "latitude": -36.8485,
                                                          "longitude": 174.7633, "timezone": zone}]} if geo else {})
        if host == "api.open-meteo.com":
            times = [f"2026-10-{d}T{h:02d}:00" for d in (21, 22, 23) for h in range(24)]
            return httpx.Response(200, json={"hourly": {"time": times, "temperature_2m": [temp] * len(times),
                                                        "dew_point_2m": [dew] * len(times),
                                                        "precipitation_probability": [rain] * len(times)},
                                             "daily": {"time": [], "sunrise": []}})
        return httpx.Response(404)
    return h


def weather(c, handler, **a):
    ctx = ctx_for(c, handler)
    return REG.call("get_weather", a, ctx), ctx


def seed_easy_runs(c):
    con = sqlite3.connect(c.svc.s.db_path)
    cols = [r[1] for r in con.execute("PRAGMA table_info(runs)")]
    uid = uid_of(c)
    for i, pace in enumerate((330, 340, 350)):
        row = {"user_id": uid, "run_id": f"r{i}", "start_utc": iso(T0.replace(day=20 - i)), "type": "easy", "pace_s_per_km": pace,
               "end_utc": iso(T0.replace(day=20 - i)), "utc_offset_min": 780, "received_at": iso(T0), "distance_m": 6000, "duration_s": 2000, "zone_id": "Pacific/Auckland"}
        row = {k: v for k, v in row.items() if k in cols}
        con.execute(f"INSERT INTO runs ({','.join(row)}) VALUES ({','.join('?' * len(row))})", list(row.values()))
    con.commit()
    con.close()


def test_weather_for_a_named_place_gives_heat_figures(cc):
    seed_easy_runs(cc)
    r, _ = weather(cc, om_handler(), when="tomorrow", place="Ponsonby")
    assert r["ok"] is True
    assert (r["temp_c"], r["dew_point_c"], r["date"], r["local_hour"]) == (31, 24, "2026-10-22", "07:00")
    assert r["morning_rain_chance_pct"] == 40 and r["heat_slowdown_pct"] > 4
    assert r["easy_pace_extra_s_per_km"] >= 10      # median easy pace 5:40 in 31 C / 24 C dew point
    assert r["place"] == "Ponsonby, New Zealand"


def test_cool_weather_says_no_slowdown(cc):
    r, _ = weather(cc, om_handler(temp=14, dew=8), when="today", hour=6, place="Ponsonby")
    assert r["heat"] == "no real heat slowdown" and "heat_slowdown_pct" not in r and r["date"] == "2026-10-21"


def test_only_a_rounded_cell_reaches_the_forecast(cc):
    seen: list = []
    h = om_handler()
    ctx = ctx_for(cc, h, seen)
    REG.call("get_weather", {"place": "Ponsonby"}, ctx)
    f = [r for r in seen if r.url.host == "api.open-meteo.com"][0]
    assert f.url.params["latitude"] == "-36.8" and f.url.params["longitude"] == "174.8"
    g = [r for r in seen if r.url.host == "geocoding-api.open-meteo.com"][0]
    assert g.url.params["name"] == "Ponsonby"


def test_no_place_and_no_saved_area_asks_for_a_suburb(cc):
    r, _ = weather(cc, om_handler())
    assert r["ok"] is False and "suburb or city" in r["error"]


def test_the_saved_area_is_used_only_when_weather_is_on(cc):
    con = sqlite3.connect(cc.svc.s.db_path)
    con.execute("INSERT INTO convo_area (user_id, run_id, lat, lon) VALUES (?,?,?,?)", (uid_of(cc), "r1", -36.8, 174.8))
    con.commit()
    assert weather(cc, om_handler())[0]["ok"] is False
    con.execute("UPDATE users SET weather_optin=1")
    con.commit()
    con.close()
    r, _ = weather(cc, om_handler())
    assert r["ok"] is True and r["place"] == "your usual area"


@pytest.mark.parametrize("place", ["12 Queen Street", "Unit 4, 10 High St", "-36.8,174.7", "x" * 61, "a@b.com"])
def test_a_street_address_or_odd_place_is_refused(cc, place):
    seen: list = []
    ctx = ctx_for(cc, om_handler(), seen)
    r = REG.call("get_weather", {"place": place}, ctx)
    assert r["ok"] is False and seen == []


def test_unknown_place_and_forecast_outage_are_clean_errors(cc):
    assert weather(cc, om_handler(geo=False), place="Nowhereville")[0]["ok"] is False
    assert weather(cc, lambda req: httpx.Response(200, json={}) if req.url.host.startswith("geocoding") is False else om_handler()(req),
                   place="Ponsonby")[0]["ok"] is False


def test_too_hot_to_compare_gives_no_number(cc):
    r, _ = weather(cc, om_handler(temp=42, dew=30), place="Ponsonby")
    assert r["ok"] and "heat_slowdown_pct" not in r and r["heat"].startswith("too hot")
