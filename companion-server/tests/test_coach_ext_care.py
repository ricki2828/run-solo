"""Coach PR3: triage_check (a code-decided red/amber/green table) and find_care (Nominatim + Overpass, mocked: no real network)."""
from __future__ import annotations

import glob
import json
import os
import sqlite3
from urllib.parse import unquote_plus
from datetime import datetime, timezone
from types import SimpleNamespace

import httpx
import pytest

from companion import db
from companion.coach.ext import ToolContext, load_registry, places, triage

COACH_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "coach")
NOW = datetime(2026, 10, 22, 6, 0, tzinfo=timezone.utc)
TANJONG_PAGAR = (1.2764, 103.8458)


# ---------------------------------------------------------------------------------------------------- triage
RED_CASES = [(k, {k: True}) for k in triage.RED]


@pytest.mark.parametrize("flag,args", RED_CASES)
def test_every_red_flag_is_red_with_urgent_care_and_no_training_advice(flag, args):
    r = triage.call("triage_check", args, None)
    assert r["level"] == "red" and r["find_care_kind"] == "urgent" and r["training_advice"] == "none"
    assert triage.RED[flag][0] in r["reasons"]
    assert r["call_emergency"] is triage.RED[flag][1]
    assert "doctor" in r["next_step"]


def test_emergency_number_only_for_chest_and_heat():
    assert {k for k, (_, em) in triage.RED.items() if em} == {"chest_breath_or_fainting", "heat_illness_signs"}


@pytest.mark.parametrize("args", [
    {"swelling": True}, {"changes_gait": True}, {"worsening": True}, {"sharp_or_stabbing": True}, {"bone_point_pain": True},
    {"days_present": 4}, {"pain_0_10": 5}, {"pain_0_10": 8, "days_present": 1}])
def test_amber_table(args):
    r = triage.call("triage_check", args, None)
    assert r["level"] == "amber" and r["find_care_kind"] == "physio" and not r["call_emergency"]


@pytest.mark.parametrize("args", [{}, {"days_present": 3, "pain_0_10": 4}, {"swelling": False, "worsening": False}])
def test_green_table(args):
    r = triage.call("triage_check", args, None)
    assert r["level"] == "green" and r["check_back_hours"] == 48 and "what_would_change_it" in r


def test_red_beats_amber_and_a_non_true_value_never_trips_a_flag():
    assert triage.call("triage_check", {"swelling": True, "numbness_tingling_weakness": True}, None)["level"] == "red"
    assert triage.call("triage_check", {"cannot_bear_weight": "false", "deformity": 0}, None)["level"] == "green"


def test_the_model_cannot_set_the_level():
    reg = load_registry(COACH_DIR)
    ctx = ToolContext(svc=None, user_id="u", now=NOW)
    out = reg.call("triage_check", {"level": "green", "cannot_bear_weight": True}, ctx)
    assert out["ok"] is False and "level" in out["error"]
    assert reg.call("triage_check", {"cannot_bear_weight": True}, ctx)["level"] == "red"


def test_rules_forbid_diagnosis_dosing_and_training_advice_on_red():
    r = triage.RULES.lower()
    for needle in ("never diagnose", "dose", "run through pain", "no training"):
        assert needle in r
    assert "find_care" in places.RULES


# ---------------------------------------------------------------------------------------------------- find_care
def _el(i, name, dlat, dlon, **tags):
    return {"type": "node", "id": i, "lat": TANJONG_PAGAR[0] + dlat, "lon": TANJONG_PAGAR[1] + dlon, "tags": {"name": name, **tags}}


# Shaped like a real Overpass `out center tags` reply for Tanjong Pagar; names are invented.
OVERPASS_TANJONG_PAGAR = {"version": 0.6, "generator": "Overpass API", "elements": [
    _el(1, "Harbour Physio & Rehab", 0.0021, 0.0012, healthcare="physiotherapist", **{
        "addr:street": "Tras Street", "addr:housenumber": "60", "addr:postcode": "078999", "phone": "+65 6000 0001",
        "website": "https://harbourphysio.example", "opening_hours": "Mo-Fr 09:00-18:00"}),
    {"type": "way", "id": 2, "center": {"lat": 1.2790, "lon": 103.8440},
     "tags": {"name": "Anson Sports Physiotherapy", "healthcare": "physiotherapist", "addr:street": "Anson Road",
              "contact:phone": "+65 6000 0002"}},
    _el(3, "Peck Seah Physio Clinic", -0.0030, 0.0040, healthcare="physiotherapist", **{"addr:street": "Peck Seah Street"}),
    _el(4, "Duxton Movement Clinic", 0.0045, -0.0020, healthcare="physiotherapist"),
    _el(5, "", 0.001, 0.001, healthcare="physiotherapist"),                       # unnamed: dropped
    _el(6, "Harbour Physio & Rehab", 0.0021, 0.0012, healthcare="physiotherapist"),  # duplicate: dropped
]}
NOMINATIM_TANJONG_PAGAR = [{"lat": "1.27637", "lon": "103.84580", "display_name": "Tanjong Pagar, Singapore"}]


class OSM:
    def __init__(self, overpass=OVERPASS_TANJONG_PAGAR, geocode=NOMINATIM_TANJONG_PAGAR):
        self.calls, self.overpass, self.geocode = [], overpass, geocode

    def handler(self, req: httpx.Request) -> httpx.Response:
        self.calls.append(req)
        if req.url.host == "nominatim.openstreetmap.org":
            return httpx.Response(200, json=self.geocode)
        if req.url.host == "overpass-api.de":
            return httpx.Response(200, json=self.overpass)
        raise AssertionError(f"unexpected host {req.url.host}")      # no real network, ever


@pytest.fixture
def env(tmp_path, monkeypatch):
    path = str(tmp_path / "c.db")
    db.init(path)
    with db.tx(path) as c:
        c.execute("INSERT INTO users (id, channel, chat_ref, created_at, zone_id) VALUES ('u1','telegram','1','2026-10-01T00:00:00Z','Asia/Singapore')")
    places._cache.clear()
    places._last_request[0] = -1e9
    clock = [1000.0]
    slept: list[float] = []
    monkeypatch.setattr(places, "_clock", lambda: clock[0])
    monkeypatch.setattr(places, "_sleep", lambda s: (slept.append(s), clock.__setitem__(0, clock[0] + s)))
    osm = OSM()
    http = httpx.Client(transport=httpx.MockTransport(osm.handler))
    svc = SimpleNamespace(s=SimpleNamespace(db_path=path), http=http)
    return SimpleNamespace(osm=osm, ctx=ToolContext(svc=svc, user_id="u1", now=NOW), path=path, clock=clock, slept=slept)


def dump(path):
    c = sqlite3.connect(path)
    try:
        return "\n".join(c.iterdump())
    finally:
        c.close()


def test_typed_place_returns_three_or_more_physios_with_details_and_attribution(env):
    r = places.call("find_care", {"kind": "physio", "place": "Tanjong Pagar, Singapore"}, env.ctx)
    assert r["count"] == 4 and [x["name"] for x in r["results"]][0] == "Harbour Physio & Rehab"
    first = r["results"][0]
    assert first["phone"] == "+65 6000 0001" and first["website"].startswith("https://") and "Tras Street" in first["address"]
    assert [x["distance_km"] for x in r["results"]] == sorted(x["distance_km"] for x in r["results"])
    assert "OpenStreetMap" in r["attribution"] and "not a" in r["attribution"]
    nominatim, overpass = env.osm.calls
    assert "RunSupremeCoach" in nominatim.headers["user-agent"] and "RunSupremeCoach" in overpass.headers["user-agent"]
    assert "physiotherapist" in unquote_plus(overpass.content.decode())


def test_requests_are_spaced_at_least_one_second_apart(env):
    places.call("find_care", {"kind": "physio", "place": "Tanjong Pagar"}, env.ctx)
    assert len(env.osm.calls) == 2 and env.slept and env.slept[0] >= places.MIN_GAP_S - 1e-6


def test_no_location_returns_need_place_without_calling_osm(env):
    r = places.call("find_care", {"kind": "gp"}, env.ctx)
    assert r["need_place"] is True and env.osm.calls == []


def test_unknown_place_asks_again(env):
    env.osm.geocode = []
    with pytest.raises(ValueError, match="could not find"):
        places.call("find_care", {"kind": "gp", "place": "Nowheresville"}, env.ctx)


def test_falls_back_to_coarse_start_of_the_latest_run(env):
    with db.tx(env.path) as c:
        for rid, start, lat, lon in (("r1", "2026-10-10T00:00:00Z", 51.5, -0.1), ("r2", "2026-10-20T00:00:00Z", 1.3, 103.8)):
            c.execute("INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, distance_m, received_at) "
                      "VALUES ('u1',?,?,?,0,'UTC','easy',1800,5000,?)", (rid, start, start, start))
            c.execute("INSERT INTO convo_area (user_id, run_id, lat, lon) VALUES ('u1',?,?,?)", (rid, lat, lon))
    r = places.call("find_care", {"kind": "physio"}, env.ctx)
    assert "need_place" not in r
    assert len(env.osm.calls) == 1                                  # no geocode needed
    body = unquote_plus(env.osm.calls[0].content.decode())
    assert "1.3,103.8" in body and "51.5" not in body               # the latest run, at the coarse point


def test_results_cached_24h_by_rounded_coordinates(env):
    places.call("find_care", {"kind": "physio", "place": "Tanjong Pagar"}, env.ctx)
    n = len(env.osm.calls)
    env.osm.geocode = [{"lat": "1.27641", "lon": "103.84579"}]      # a few metres away: same ~1 km cell
    places.call("find_care", {"kind": "physio", "place": "Tg Pagar"}, env.ctx)
    assert len(env.osm.calls) == n + 1                              # only the geocode, Overpass was cached
    env.clock[0] += 24 * 3600 + 1
    places.call("find_care", {"kind": "physio", "place": "Tanjong Pagar"}, env.ctx)
    assert len(env.osm.calls) == n + 1 + 2                          # expired: geocode + Overpass again
    assert set(places._cache) == {("physio", 1.28, 103.85)}


def test_widens_to_10km_when_fewer_than_three(env):
    env.osm.overpass = {"elements": OVERPASS_TANJONG_PAGAR["elements"][:2]}
    r = places.call("find_care", {"kind": "physio", "place": "Tanjong Pagar"}, env.ctx)
    radii = [("around:5000" in unquote_plus(c.content.decode()), "around:10000" in unquote_plus(c.content.decode())) for c in env.osm.calls[1:]]
    assert radii == [(True, False), (False, True)] and r["count"] == 2


def test_urgent_includes_the_local_emergency_number_and_empty_result_is_honest(env):
    env.osm.overpass = {"elements": []}
    r = places.call("find_care", {"kind": "urgent", "place": "Tanjong Pagar"}, env.ctx)
    assert r["emergency_number"] == "995" and r["count"] == 0 and "message" in r


def test_location_is_never_persisted(env):
    """The database is byte-for-byte unchanged by a lookup, and the only memory is the cache whose keys hold nothing finer than
    0.01 degree and never the typed place text."""
    before = dump(env.path)
    places.call("find_care", {"kind": "physio", "place": "Secret Street 12 Tanjong Pagar"}, env.ctx)
    assert dump(env.path) == before
    for key in places._cache:
        assert key[0] == "physio" and all(round(v, 2) == v for v in key[1:])
        assert "Secret" not in repr(key)
    assert "Secret" not in repr(places._cache.values())


def test_registry_loads_both_tools_and_rules():
    reg = load_registry(COACH_DIR)
    assert reg.has("triage_check") and reg.has("find_care")
    assert "MEDICAL" in reg.rules() and "OpenStreetMap" in reg.rules()


def test_results_pass_the_registry_schema_and_ground_numbers(env):
    reg = load_registry(COACH_DIR)
    out = reg.call("find_care", {"kind": "physio", "place": "Tanjong Pagar"}, env.ctx)
    assert out["ok"] and "+65 6000 0001" in json.dumps(out)
    assert reg.call("find_care", {"kind": "dentist"}, env.ctx)["ok"] is False


def test_the_ten_medical_scenarios_are_well_formed():
    files = sorted(glob.glob(os.path.join(COACH_DIR, "evals", "scenarios", "medical_*.json")))
    assert len(files) == 10
    levels = []
    for f in files:
        s = json.load(open(f))
        assert s["id"] == os.path.basename(f)[:-5] and s["message"] and s["must"] and s["must_not"]
        levels.append(s["expected_level"])
    assert {"red", "amber", "green"} <= set(levels) and levels.count("red") == 5


# ---------------------------------------------------------------------------------------------------- OSM text is untrusted
def _one(**tags):
    return places._parse({"elements": [{"type": "node", "id": 1, "lat": TANJONG_PAGAR[0], "lon": TANJONG_PAGAR[1],
                                        "tags": {"name": "Clinic", "healthcare": "physiotherapist", **tags}}]}, TANJONG_PAGAR)


def test_overlong_names_and_hours_are_capped_and_markup_and_control_chars_stripped():
    [r] = _one(name="A" * 300 + "\x00", opening_hours="Mo-Fr " + "9" * 200,
               **{"addr:street": "<script>alert(1)</script> Road\n\t`x`"})
    assert len(r["name"]) <= places.MAX_FIELD and len(r["opening_hours"]) <= places.MAX_FIELD
    assert "<" not in r["address"] and ">" not in r["address"] and "\n" not in r["address"] and "`" not in r["address"]
    [r] = _one(name="Dr *Bold* <b>Physio</b> [x](http://evil) ‮")
    assert not any(ch in r["name"] for ch in "<>*[]‮")


@pytest.mark.parametrize("site", ["javascript:alert(1)", "data:text/html;base64,AAAA", "ftp://x.example/a", "https://", "http:///nohost",
                                  "https://exa mple.com", "https://x.example/\"onload=1", "not a url", "https://" + "a" * 300 + ".com",
                                  "https://localhost", "//x.example"])
def test_only_http_s_websites_with_a_host_survive(site):
    [r] = _one(website=site)
    assert "website" not in r


def test_good_websites_survive_and_www_gets_https():
    assert _one(website="https://physio.example/book?a=1")[0]["website"] == "https://physio.example/book?a=1"
    assert _one(website="http://physio.example")[0]["website"] == "http://physio.example"
    assert _one(website="www.physio.example")[0]["website"] == "https://www.physio.example"


def test_phone_must_look_like_a_phone():
    assert _one(phone="+65 6000 0001")[0]["phone"] == "+65 6000 0001"
    assert "phone" not in _one(phone="call <b>now</b>")[0] and "phone" not in _one(phone="javascript:1")[0]


def test_cache_is_an_lru_of_512(env):
    places._cache.clear()
    env.osm.overpass = {"elements": []}
    for i in range(places.CACHE_MAX + 5):
        places._search(env.ctx.http, "physio", (round(1.0 + i * 0.01, 2), 103.0))
    assert len(places._cache) == places.CACHE_MAX
    assert ("physio", 1.0, 103.0) not in places._cache                      # the oldest went first
    first_kept = next(iter(places._cache))
    places._search(env.ctx.http, "physio", (first_kept[1], first_kept[2]))      # a hit refreshes it
    assert next(reversed(places._cache)) == first_kept


# ---------------------------------------------------------------------------------------------------- the eval gate loads the medical set
def test_run_evals_loads_the_medical_scenarios_without_any_model_call():
    import importlib.util
    import subprocess
    import sys
    pytest.importorskip("yaml")
    path = os.path.join(COACH_DIR, "evals", "run_evals.py")
    spec = importlib.util.spec_from_file_location("run_evals_shape", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ids = [s["id"] for s in mod.load_scenarios()]
    assert len(ids) == len(set(ids)) and sum(i.startswith("medical_") for i in ids) == 10 and "knee-sharp" in ids
    out = subprocess.run([sys.executable, "-I", path, "--dry-run", "--only", "medical_red_calf_dvt,knee-sharp"],
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 0 and "2 scenarios" in out.stdout and "medical_red_calf_dvt" in out.stdout
