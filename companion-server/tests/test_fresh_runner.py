"""M6 fresh-runner QA: what a brand-new runner's first runs, first recap and first fortnight say, and that two new runners
sharing one database never see each other. Each test locks a finding from ~/ai/state/run-supreme-auto-oct16/freshqa.md."""
from datetime import datetime, timedelta, timezone

import httpx

from companion import db, facts as F
from companion.convo import recap, suggest
from companion.service import RunIn, Service
from companion.timeutil import iso
from companion.writer import Fact, with_verdict

from conftest import Fakes, make_settings
from test_convo import NOW, SG, SUN, run

UTC = timezone.utc


# --- a run the app could not compare is not compared by the server either -------------------------

def _two_runs(verdict):
    prev = run(1, 3, pace=400.0)
    cur = run(2, 0, pace=395.0, verdict=verdict)
    return cur, [prev]


def test_no_gap_is_stated_when_the_app_said_it_could_not_compare():
    for v in ("noVerdict", "baselineSet", "indoorRun"):
        cur, hist = _two_runs(v)
        assert F.verdict_delta(cur, -5) is None
    cur, hist = _two_runs(None)                      # an older app sends no verdict: the server's own match stands
    assert F.verdict_delta(cur, -5) == -5
    cur, hist = _two_runs("noRealChange")
    assert F.verdict_delta(cur, -2) == -2 and F.verdict_delta(cur, -5) is None


# --- the headline never says the direction twice ---------------------------------------------------

def test_a_headline_that_already_says_faster_or_slower_is_not_told_again():
    faster = [Fact("verdict", "Verdict: faster")]
    slower = [Fact("verdict", "Verdict: slower")]
    level = [Fact("verdict", "Verdict: no real change")]
    assert with_verdict("That's quicker", faster) == "That's quicker"
    assert with_verdict("Down a touch", slower) == "Down a touch, slower"      # "touch" is not a direction word
    assert with_verdict("Slow on purpose", slower) == "Slow on purpose"
    assert with_verdict("Base work", faster) == "Base work, faster"
    assert with_verdict("Base work", level) == "Base work, no real change"


# --- the weekly recap does not measure a runner against a part week --------------------------------

def _runs_on(*offsets_days):
    out = []
    for i, d in enumerate(offsets_days):
        r = run(i, 0)
        r["start_utc"] = SUN - timedelta(days=d)
        out.append(r)
    return out                                       # newest first


def test_second_recap_after_a_thursday_start_is_not_up_on_last_week():
    # SUN is Sunday 18 Oct (Singapore). First run Thursday 8 Oct... one week earlier is Thu 11 Oct -> use Fri 9 Oct
    this_week = [0.5, 2]                              # Sun, Fri(16th): two runs this week
    first_week = [9.0, 8.0]                           # Fri 9 Oct and Sat 10 Oct: a part week
    rc = recap.build(_runs_on(*this_week, *first_week), SUN, SG, {}, "w")
    assert rc.rendered.situation == "recap_first_full"
    assert "more than" not in rc.rendered.body and "less than" not in rc.rendered.body
    assert "last week" not in rc.rendered.body.lower() or "part" in rc.rendered.body.lower() or "few days" in rc.rendered.body


def test_second_recap_after_a_monday_start_still_compares():
    this_week = [0.5, 2]
    first_week = [12.0, 10.0]                         # Tue 6 Oct and Thu 8 Oct: the first run was on Tuesday
    rc = recap.build(_runs_on(*this_week, *first_week), SUN, SG, {}, "w")
    assert rc.rendered.situation in ("recap_up", "recap_down", "recap_flat")


# --- no tempo push in a runner's first fortnight ---------------------------------------------------

def test_no_quality_nudge_for_a_runner_under_two_weeks_in():
    tempo = run(9, 8, typ="tempo")
    newbie = [run(i, 1 + 2 * i) for i in range(3)] + [tempo]            # first run 8 days ago
    assert suggest.evening(newbie, NOW, None, {}, "s") is None
    veteran = newbie + [run(10, 30)]
    ev = suggest.evening(veteran, NOW, None, {}, "s")
    assert ev is not None and ev.suggestion.reason == "gap"


def test_a_planned_session_still_reaches_a_new_runner():
    newbie = [run(i, 1 + 2 * i) for i in range(3)]
    newbie[0].update(plan_next_type="easy", plan_next_day=(NOW + timedelta(days=1)).date().isoformat(),
                     plan_next_m=4500)
    ev = suggest.evening(newbie, NOW, None, {}, "s")
    assert ev is not None and ev.suggestion.reason == "plan"
    assert "5 km" in ev.rendered.body                 # a 4.5 km plan is five, not banker's four


def test_whole_km_rounds_halves_up():
    assert [suggest.whole_km(m) for m in (400, 1499, 1500, 4500, 5500, 7012)] == [1, 1, 2, 5, 6, 7]


# --- two new runners, one database ------------------------------------------------------------------

TWO = {"A": ("7001", "Pacific/Auckland", "Mission Bay"), "B": ("7002", "Europe/London", "Hackney Marshes")}


def _body(user, i, start, km, pace, verdict):
    return {"run_id": f"{user}{i}", "type": "easy", "start_utc": start.isoformat(),
            "utc_offset_min": 0, "zone_id": TWO[user][1], "duration_s": round(km * pace), "distance_m": round(km * 1000),
            "pace_s_per_km": float(pace), "locality": TWO[user][2], "verdict": verdict}


def test_two_new_runners_never_see_each_others_cards(tmp_path):
    fakes = Fakes()
    s = make_settings(tmp_path, openrouter_key=None, weather_enabled=False, checkins_enabled=False,
                      allowed_ids=frozenset(f"telegram:{c}" for c, _, _ in TWO.values()))
    svc = Service(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    t0 = datetime(2026, 10, 12, 6, 0, tzinfo=UTC)
    with db.tx(s.db_path) as c:
        for u, (chat, zone, _) in TWO.items():
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, "
                      "utc_offset_min, last_inbound_at) VALUES (?,?,?,?,?,?,?,?,?)",
                      (f"u_{u}", "telegram", chat, iso(t0), "2", iso(t0), zone, 0, iso(t0)))
    verdicts = ["baselineSet", "noRealChange", "faster"]
    for i in range(3):                                # interleaved, as two runners finishing on the same mornings
        for u, pace in (("A", 400 - 6 * i), ("B", 340 - 9 * i)):
            start = t0 + timedelta(days=2 * i, hours=1 if u == "B" else 0)
            now = start + timedelta(minutes=40)
            svc.ingest_run(f"u_{u}", RunIn.model_validate(_body(u, i, start, 5.0, pace, verdicts[i])), now)
            svc.run_outbox(now)
    sent = [(b["chat_id"], b["text"]) for m, b in fakes.tg if m == "sendMessage"]
    assert {str(c) for c, _ in sent} == {"7001", "7002"}
    for chat, text in sent:
        other = "Hackney Marshes" if str(chat) == "7001" else "Mission Bay"
        assert other not in text, text
    with db.ro(s.db_path) as c:
        for u in TWO:
            rows = c.execute("SELECT run_id FROM cards WHERE user_id=? AND kind='run'", (f"u_{u}",)).fetchall()
            assert sorted(r[0] for r in rows) == [f"{u}0", f"{u}1", f"{u}2"]


# --- a faster headline never reads as a pace number going up -------------------------------------------

def test_no_faster_headline_says_up():
    from companion.convo import voice
    for head, _body in voice.SITUATIONS["faster"]:
        assert "up" not in head.lower().split(), head      # "Pace is up, faster": a pace number going up is slower
