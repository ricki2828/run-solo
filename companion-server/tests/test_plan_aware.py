"""Plan-aware coaching: the app's 4-week plan reaches the server, and the evening-before suggestion follows it.

Pure-logic tests pin their own clock (NOW is a fixed Wednesday, 20:00 in Singapore). The end-to-end tests build runs
relative to the real clock, but nothing they assert depends on the weekday or the time of day.
"""
import json
import re
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from companion.convo import suggest, touches as T, voice
from companion.convo.weather import Forecast
from companion.service import RunIn
from companion.timeutil import now_utc, to_local
from conftest import auth, enrol, run_payload

U = timezone.utc
SG = "Asia/Singapore"
NOW = datetime(2026, 9, 30, 12, 0, tzinfo=U)  # Wednesday 20:00 in Singapore
TOMORROW = "2026-10-01"


def run(i, days_ago, typ="easy", km=7.0, **kw):
    start = NOW - timedelta(days=days_ago)
    r = {"run_id": f"r{i}", "start_utc": start, "type": typ, "distance_m": int(km * 1000), "duration_s": int(km * 355),
         "pace_s_per_km": 355.0, "true_pace_s_per_km": 355.0, "zone_id": SG, "locality": None, "zone_min": {},
         "load_state": None, "pb": None, "verdict": None, "climb_m": None, "plan_weeks_to_race": None,
         "plan_week": None, "plan_weeks": None, "plan_next_type": None, "plan_next_day": None, "plan_next_week": None,
         "plan_next_min": None, "plan_next_m": None}
    r.update(kw)
    return r


def planned(typ="long", *, m=None, minutes=None, week=3, weeks=4, day=TOMORROW, **kw):
    """Four recent easy runs; the newest carries the plan snapshot."""
    newest = run(0, 1, plan_next_type=typ, plan_next_day=day, plan_next_week=week, plan_next_m=m, plan_next_min=minutes,
                 plan_week=week, plan_weeks=weeks, **kw)
    return [newest] + [run(i, 1 + 2 * i) for i in range(1, 4)]


# --- the wire: RunIn ---------------------------------------------------------------------------------------------

def payload(**over):
    return run_payload("p1") | over


def test_runin_accepts_the_plan_fields_and_they_are_all_optional():
    base = RunIn(**payload())
    assert base.plan_week is None and base.plan_weeks is None and base.plan_next is None
    r = RunIn(**payload(plan_kind="long", plan_target_m=15000, plan_week=3, plan_weeks=4,
                        plan_next={"type": "easy", "day": "2026-10-01", "week": 3, "minutes": 40}))
    assert (r.plan_kind, r.plan_target_m, r.plan_week, r.plan_weeks) == ("long", 15000, 3, 4)
    assert r.plan_next.type == "easy" and r.plan_next.minutes == 40 and r.plan_next.distance_m is None


@pytest.mark.parametrize("bad", [
    {"type": "sprint", "day": "2026-10-01", "week": 1},                         # not one of easy|long|quality
    {"type": "easy", "day": "2026-13-45", "week": 1},                           # not a date
    {"type": "easy", "day": "tomorrow", "week": 1},                             # free text
    {"type": "easy", "day": "2026-10-01", "week": 0},
    {"type": "easy", "day": "2026-10-01", "week": 1, "minutes": 0},
    {"type": "easy", "day": "2026-10-01", "week": 1, "distance_m": 10},
    {"type": "easy", "day": "2026-10-01", "week": 1, "reason": "free text from the app"},  # extra keys are refused
])
def test_runin_refuses_a_bad_plan_next(bad):
    with pytest.raises(ValidationError):
        RunIn(**payload(plan_next=bad))


def test_runin_refuses_a_plan_week_beyond_the_plan():
    with pytest.raises(ValidationError):
        RunIn(**payload(plan_week=5, plan_weeks=4))
    with pytest.raises(ValidationError):
        RunIn(**payload(plan_week=0))


def test_plan_fields_are_stored_exported_and_hard_deleted(client, fakes):
    t = enrol(client)
    body = payload(plan_kind="long", plan_target_m=15000, plan_week=3, plan_weeks=4,
                   plan_next={"type": "long", "day": "2026-10-01", "week": 3, "distance_m": 15000})
    assert client.post("/v1/runs", json=body, headers=auth(t)).status_code in (200, 202)
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    row = c.execute("SELECT * FROM runs").fetchone()
    assert (row["plan_week"], row["plan_weeks"], row["plan_next_type"], row["plan_next_day"], row["plan_next_week"],
            row["plan_next_m"], row["plan_next_min"]) == (3, 4, "long", "2026-10-01", 3, 15000, None)
    me = client.get("/v1/me", headers=auth(t)).json()["runs_received"][0]   # the runner can see what the plan sent
    assert (me["plan_week"], me["plan_weeks"], me["plan_next_type"], me["plan_next_day"], me["plan_next_m"]) == \
        (3, 4, "long", "2026-10-01", 15000)
    assert me["plan_kind"] == "long" and me["plan_target_m"] == 15000
    assert client.delete("/v1/me", headers=auth(t)).json() == {"status": "deleted"}   # hard delete covers the row
    assert sqlite3.connect(client.svc.s.db_path).execute("SELECT COUNT(*) FROM runs").fetchone()[0] == 0


def test_a_replayed_run_updates_the_plan_columns_in_place(client, fakes):
    t = enrol(client)
    client.post("/v1/runs", json=payload(plan_week=2, plan_weeks=4), headers=auth(t))
    again = client.post("/v1/runs", json=payload(plan_week=3, plan_weeks=4), headers=auth(t))
    assert again.json()["status"] == "duplicate"   # a plain resend never overwrites
    c = sqlite3.connect(client.svc.s.db_path)
    assert c.execute("SELECT plan_week FROM runs").fetchone()[0] == 2


# --- the evening suggestion follows the plan --------------------------------------------------------------------

def test_tomorrows_planned_long_run_is_named_with_its_distance_and_the_plan_week():
    ev = suggest.evening(planned("long", m=14000), NOW, None, {}, "s", zone_id=SG)
    assert ev.rendered.situation == "sugg_plan_session"
    assert "long run 14 km" in ev.rendered.body and "week 3 of 4 of your plan" in ev.rendered.body
    assert ev.suggestion.reason == "plan" and ev.suggestion.kind == "long_run"
    assert re.search(r"around \d+:\d\d", ev.rendered.body)


def test_planned_sessions_use_the_plans_own_size():
    easy = suggest.evening(planned("easy", minutes=40), NOW, None, {}, "s", zone_id=SG)
    assert "easy 40 min" in easy.rendered.body and easy.suggestion.kind == "easy_next"
    quality = suggest.evening(planned("quality", week=2), NOW, None, {}, "s", zone_id=SG)
    assert "quality session" in quality.rendered.body and "week 2 of 4 of your plan" in quality.rendered.body
    assert quality.suggestion.kind == "quality"


def test_a_planned_session_without_a_size_uses_the_runners_own_typical_distance():
    ev = suggest.evening(planned("easy"), NOW, None, {}, "s", zone_id=SG)
    assert "easy 7 km" in ev.rendered.body
    assert suggest.evening([{**h, "type": "tempo"} for h in planned("easy")], NOW, None, {}, "s", zone_id=SG) is None  # nothing to name


def test_the_plan_beats_weather_and_gap_reasons_but_not_load_or_a_hard_day():
    hist = planned("long", m=14000)
    ev = suggest.evening(hist, NOW, Forecast(34, 5), {}, "s", zone_id=SG)
    assert ev.rendered.situation == "sugg_plan_session"                      # heat does not replace the plan
    loaded = [{**hist[0], "load_state": "high"}] + hist[1:]
    assert suggest.evening(loaded, NOW, None, {}, "s", zone_id=SG).suggestion.reason == "load"
    hard = [{**hist[0], "type": "tempo", "start_utc": NOW - timedelta(hours=10)}] + hist[1:]
    assert suggest.evening(hard, NOW, None, {}, "s", zone_id=SG).suggestion.reason == "hard_recent"


@pytest.mark.parametrize("day", ["2026-09-30", "2026-10-02", "2026-10-09", None])
def test_falls_back_to_todays_logic_when_the_plan_session_is_not_tomorrow(day):
    hist = planned("long", m=14000, day=day)
    ev = suggest.evening(hist, NOW, Forecast(34, 5), {}, "s", zone_id=SG)
    assert ev.rendered.situation == "sugg_weather_heat"                      # exactly what it did before the plan
    assert suggest.evening(hist, NOW, None, {}, "s", zone_id=SG) is None     # no reason left: say nothing


def test_only_the_newest_runs_plan_counts():
    hist = planned("long", m=14000)
    hist[1] = {**hist[1], "plan_next_type": "easy", "plan_next_day": TOMORROW, "plan_next_min": 30}
    newest_without = [{**hist[0], "plan_next_type": None, "plan_next_day": None}] + hist[1:]
    assert suggest.evening(newest_without, NOW, None, {}, "s", zone_id=SG) is None


def test_tomorrow_is_the_runners_local_date_not_utc():
    # 20:00 in Singapore is 12:00 UTC the same day; Auckland is already on the next local day
    hist = planned("long", m=14000, day="2026-10-02")
    hist = [{**h, "zone_id": "Pacific/Auckland"} for h in hist]
    assert suggest.evening(hist, NOW, None, {}, "s", zone_id="Pacific/Auckland").rendered.situation == "sugg_plan_session"
    assert suggest.evening(hist, NOW, None, {}, "s", zone_id=SG) is None


# --- soften -----------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("typ", ["long", "quality"])
def test_a_flagged_note_turns_a_planned_push_into_the_gentle_line(typ):
    hist = planned(typ, m=14000 if typ == "long" else None)
    plain = suggest.evening(hist, NOW, None, {}, "s", zone_id=SG)
    soft = suggest.evening(hist, NOW, None, {}, "s", zone_id=SG, soften=True)
    assert plain.rendered.situation == "sugg_plan_session"
    assert soft.rendered.situation == "sugg_soft" and soft.suggestion.kind == "easy_next"
    assert "long run" not in soft.rendered.body and "quality" not in soft.rendered.body and "14" not in soft.rendered.body
    assert "week 3" not in soft.rendered.body                                # no plan pressure in the gentle line


def test_a_planned_easy_session_is_unchanged_by_softening():
    hist = planned("easy", minutes=40)
    soft = suggest.evening(hist, NOW, None, {}, "s", zone_id=SG, soften=True)
    assert soft.rendered.situation == "sugg_plan_session" and "easy 40 min" in soft.rendered.body


# --- B4: numbers only from facts ---------------------------------------------------------------------------------

def test_plan_templates_carry_no_numbers_of_their_own_and_every_slot_is_filled():
    for table in (voice.SUGGESTIONS["sugg_plan_session"], voice.TOUCHES["plan_week"]):
        for v in table:
            text = v if isinstance(v, str) else " ".join(v)
            bare = re.sub(r"\{[^}]*\}", "", text)
            assert not re.search(r"\d", bare) and "—" not in bare and "–" not in bare, text
    assert len(voice.SUGGESTIONS["sugg_plan_session"]) >= 8


def test_every_number_in_a_plan_suggestion_is_in_the_allowed_slots():
    for typ, m in (("long", 14000), ("easy", None), ("quality", None)):
        ev = suggest.evening(planned(typ, m=m, minutes=45 if typ == "easy" else None), NOW, None, {}, "s", zone_id=SG)
        numbers = set(re.findall(r"\d+", ev.rendered.body))
        assert numbers and numbers <= set(re.findall(r"\d+", ev.rendered.allowed)), (ev.rendered.body, ev.rendered.allowed)


# --- countdown / plan touches use the real plan week ---------------------------------------------------------------

def ctx(r, hist=(), mem=None, **kw):
    return T.Ctx(run=r, history=list(hist), memory=mem or {}, now=NOW, **kw)


def test_the_plan_week_touch_uses_the_week_the_app_sent():
    t = T.plan_week(ctx(run(1, 0, plan_week=3, plan_weeks=4)))
    assert t.kind == "plan_week" and t.slots == {"why": "week 3 of 4 of your plan"} and t.key == "planwk:3"
    assert T.plan_week(ctx(run(1, 0))) is None
    assert T.plan_week(ctx(run(1, 0, plan_week=5, plan_weeks=4))) is None
    rendered = T.render(t, T.Usage(), NOW, "s")
    assert rendered and "week 3 of 4 of your plan" in rendered[1]


def test_the_plan_week_touch_is_pushy_and_not_a_race_countdown():
    assert "plan_week" in T.PUSHY and "plan_week" in T.PRIORITY
    kinds = {t.kind for t in T.candidates(ctx(run(1, 0, plan_week=3, plan_weeks=4)))}
    assert "plan_week" in kinds and "race_countdown" not in kinds           # the app has no race date
    assert "plan_week" not in {t.kind for t in T.candidates(ctx(run(1, 0, plan_week=3, plan_weeks=4), soften=True))}


# --- end to end: cap of two a week, and the card -----------------------------------------------------------------

def _tomorrow_local(zone="Pacific/Auckland"):
    return (to_local(now_utc(), zone).date() + timedelta(days=1)).isoformat()


def _seed(client, token, typ, **plan):
    for i, days in enumerate((7, 5, 3)):
        client.post("/v1/runs", json=run_payload(f"h{i}", minutes_ago=days * 1440), headers=auth(token))
    nxt = {"type": typ, "day": _tomorrow_local(), "week": 3} | plan
    r = client.post("/v1/runs", json=run_payload("fresh", minutes_ago=60 * 20, plan_week=3, plan_weeks=4, plan_next=nxt),
                    headers=auth(token))
    assert r.status_code in (200, 202), r.text


def _evening(client, day):
    uid = sqlite3.connect(client.svc.s.db_path).execute("SELECT id FROM users").fetchone()[0]
    return client.svc._build_evening_card(uid, day, now_utc())


def _q(client, sql, *a):
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    return c.execute(sql, a).fetchall()


def test_end_to_end_the_card_names_the_planned_session_and_the_cap_is_two_a_week(client, fakes):
    fakes.llm_mode = "500"   # the template line, so the words are fixed
    t = enrol(client)
    _seed(client, t, "long", distance_m=16000)
    first = _evening(client, "2099-01-01")
    assert first
    card = _q(client, "SELECT body, buttons_json FROM cards WHERE card_id=?", first)[0]
    assert "long run 16 km" in card["body"] and "week 3 of 4 of your plan" in card["body"]
    assert any(b["action"] == "sugg:yes:long_run" for b in json.loads(card["buttons_json"]))
    assert _q(client, "SELECT situation FROM convo_cards WHERE card_id=?", first)[0]["situation"] == "sugg_plan_session"
    assert _evening(client, "2099-01-02")                                    # second of the week
    assert _evening(client, "2099-01-03") is None                            # the cap of two holds for plan suggestions too


def test_end_to_end_a_recent_note_softens_the_planned_push(client, fakes):
    fakes.llm_mode = "500"
    t = enrol(client)
    _seed(client, t, "quality")
    uid = _q(client, "SELECT id FROM users")[0]["id"]
    c = sqlite3.connect(client.svc.s.db_path)
    c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?)",
              (uid, "fresh", "calf is really sore", now_utc().isoformat()))
    c.commit()
    card = _evening(client, "2099-01-01")
    assert _q(client, "SELECT situation FROM convo_cards WHERE card_id=?", card)[0]["situation"] == "sugg_soft"
    body = _q(client, "SELECT body FROM cards WHERE card_id=?", card)[0]["body"]
    assert "quality" not in body and "calf" not in body


def test_end_to_end_without_a_plan_the_old_logic_is_untouched(client, fakes):
    t = enrol(client)
    for i, days in enumerate((9, 7, 5, 3)):
        client.post("/v1/runs", json=run_payload(f"h{i}", minutes_ago=days * 1440, type="tempo" if i == 0 else "easy"),
                    headers=auth(t))
    client.post("/v1/runs", json=run_payload("fresh", minutes_ago=60 * 20), headers=auth(t))
    card = _evening(client, "2099-01-01")
    assert card and _q(client, "SELECT situation FROM convo_cards WHERE card_id=?", card)[0]["situation"] == "sugg_gap"
