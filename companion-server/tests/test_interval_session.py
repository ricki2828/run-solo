"""The coach names the interval session and judges its work pace, never the whole-run average (25-Sep 4x4 feedback)."""
import re
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from pydantic import ValidationError

from companion import db
from companion.convo import engine, voice
from companion.convo import touches as T
from companion.facts import build_facts, comparable, known_session
from companion.service import RunIn
from companion.writer import Writer, grounded, CardText
from conftest import auth, enrol, make_settings, run_payload

T0 = datetime(2026, 9, 25, 8, 0, tzinfo=timezone.utc)
SESSION = dict(session_name="Norwegian 4x4", work_pace_s_per_km=257.0, reps_done=4, rep_spread_s=6.0,
               recovery_pace_s_per_km=461.0)


def run(**kw):
    r = dict(run_id="r0", type="interval", start_utc=T0, distance_m=4900, duration_s=1620, pace_s_per_km=330.0,
             true_pace_s_per_km=326.0, verdict="baselineSet", load_state=None, pb=None, plan_kind=None,
             plan_target_m=None, plan_weeks_to_race=None, feel=None, zone_id="Asia/Singapore", locality=None,
             zone_min={}, climb_m=None)
    r.update(kw)
    return r


def hist(days_ago, **kw):
    return run(run_id=f"h{days_ago}", start_utc=T0 - timedelta(days=days_ago), **kw)


# --- facts: the base fact names the session -------------------------------------------------

def test_base_fact_names_session_purpose_and_work_pace_not_the_whole_run_average():
    res = build_facts(run(**SESSION), [], {})
    base = res.facts[0]
    assert base.id == "base"
    assert base.text == "Norwegian 4x4 (VO2 max session): 4 reps at 4:17/km work pace, within 6 s"
    assert "5:30" not in " ".join(f.text for f in res.facts)
    assert res.session == {"name": "Norwegian 4x4", "purpose": "VO2 max"}


def test_wide_spread_is_called_a_spread():
    res = build_facts(run(**{**SESSION, "rep_spread_s": 14.0}), [], {})
    assert res.facts[0].text.endswith("4 reps at 4:17/km work pace, spread 14 s")


@pytest.mark.parametrize("name,purpose", [
    ("Norwegian 4x4", "VO2 max"), ("Tempo intervals", "threshold"), ("30/30s", "speed"), ("1-minute reps", "speed"),
    ("8 × 400 m", "speed"), ("12 × 400 m", "speed"), ("Pyramid", "VO2 max"), ("1 km repeats", "5k to 10k pace"),
])
def test_built_in_sessions_map_to_a_purpose(name, purpose):
    assert known_session(name) == (name, purpose)
    res = build_facts(run(**{**SESSION, "session_name": name}), [], {})
    assert res.facts[0].text.startswith(f"{name} ({purpose} session): ")


def test_custom_or_unknown_session_is_an_interval_session_and_its_name_never_leaves():
    res = build_facts(run(**{**SESSION, "session_name": "custom:0123456789abcdef"}), [], {})
    assert res.facts[0].text.startswith("Interval session: 4 reps at 4:17/km work pace")
    assert res.session == {"purpose": "interval session"}
    assert "custom:" not in str(res)


def test_no_name_sent_is_still_an_interval_session():
    res = build_facts(run(**{**SESSION, "session_name": None}), [], {})
    assert res.facts[0].text.startswith("Interval session: 4 reps at 4:17/km work pace")


def test_recovery_pace_is_added_when_there_is_room():
    res = build_facts(run(**SESSION), [], {})
    assert [f.id for f in res.facts] == ["base", "verdict", "recovery"]
    assert res.facts[-1].text == "Recovery pace 7:41/km"


# --- the number to beat is work pace, same session only ----------------------------------------

def test_comparison_uses_work_pace_against_the_same_session_only():
    prev = hist(7, **{**SESSION, "work_pace_s_per_km": 262.0, "pace_s_per_km": 340.0, "verdict": "baselineSet"})
    other = hist(3, **{**SESSION, "session_name": "Tempo intervals", "work_pace_s_per_km": 240.0})
    res = build_facts(run(**{**SESSION, "verdict": "faster"}), [other, prev], {})
    delta = next(f for f in res.facts if f.id == "delta")
    assert delta.text == "5 s/km faster than your last Norwegian 4x4 (4:22/km work pace)"
    assert comparable(run(**SESSION), [other]) is None


def test_whole_run_average_is_never_a_baseline_for_a_session_run():
    # same type and distance, but no work pace on record: not comparable
    old_app = hist(7, pace_s_per_km=330.0, distance_m=4900)
    assert comparable(run(**SESSION), [old_app]) is None
    res = build_facts(run(**SESSION), [old_app], {})
    assert not any(f.id == "delta" for f in res.facts)


# --- an old app (no session fields) keeps today's wording ---------------------------------------

def test_old_app_payload_falls_back_to_todays_wording():
    res = build_facts(run(), [], {})
    assert [f.id for f in res.facts][0] in ("base", "verdict")
    base = next(f for f in res.facts if f.id == "base")
    assert base.text == "Interval session: 4.9 km in 27 min at 5:30/km"
    assert res.session is None
    prev = hist(7, pace_s_per_km=345.0, true_pace_s_per_km=345.0, distance_m=5000)
    res = build_facts(run(verdict=None), [prev], {})
    # an interval run with no reps detected is never compared with an earlier one (no work pace to compare)
    assert not any(f.id == "delta" for f in res.facts)


# --- the template path ---------------------------------------------------------------------------

def test_template_baseline_speaks_of_the_session_not_a_line_in_the_sand():
    r = run(**SESSION)
    sit, slots = engine.situation_for(r, [], None)
    assert sit == "interval_baseline" and "pace" not in slots
    assert slots["session_line"] == "Norwegian 4x4 (VO2 max session)" and slots["work_pace"] == "4:17"
    for seed in range(12):
        out = voice.render(sit, slots, {}, T0, f"s{seed}")
        assert "5:30" not in out.body and "line in the sand" not in (out.headline + out.body).lower()
        assert "4:17" in out.body or "4:17" in out.headline


def test_template_after_baseline_compares_work_pace():
    prev = hist(7, **{**SESSION, "work_pace_s_per_km": 262.0})
    r = run(**{**SESSION, "verdict": "faster"})
    sit, slots = engine.situation_for(r, [prev], None)
    assert sit == "interval_work" and slots["delta"] == "5" and slots["cmp_dir"] == "faster"
    bodies = {voice.render(sit, slots, {}, T0, f"s{i}").body for i in range(20)}
    assert any("5 s/km faster" in b for b in bodies)


def test_template_old_app_interval_keeps_todays_situations():
    sit, slots = engine.situation_for(run(), [], None)
    assert sit == "baseline" and slots["pace"] == "5:30"
    sit, _ = engine.situation_for(run(verdict="holding"), [], None)
    assert sit == "intervals"


def test_year_touches_do_not_use_the_whole_run_pace_of_a_session_run():
    ly = hist(365, pace_s_per_km=335.0, distance_m=5000)
    c = T.Ctx(run(**SESSION), [ly], {}, T0)
    assert T.last_year(c) is None
    assert T.last_year(T.Ctx(run(), [ly], {}, T0)) is not None


# --- the AI path -----------------------------------------------------------------------------------

def test_ai_prompt_carries_session_name_and_purpose(tmp_path, fakes):
    s = make_settings(tmp_path)
    db.init(s.db_path)
    w = Writer(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    res = build_facts(run(**SESSION), [], {})
    w.write(res, {})
    sent = fakes.llm[0]
    user = next(m["content"] for m in sent["messages"] if m["role"] == "user")
    assert '"session": {"name": "Norwegian 4x4", "purpose": "VO2 max"}' in user
    assert "Norwegian 4x4 (VO2 max session): 4 reps at 4:17/km work pace, within 6 s" in user
    system = next(m["content"] for m in sent["messages"] if m["role"] == "system")
    assert "line in the sand" in system and "work pace" in system
    assert "5:30" not in user


def test_ai_note_with_the_session_facts_is_grounded():
    res = build_facts(run(**SESSION), [], {})
    allowed = " ".join(f.text for f in res.facts)
    ok = CardText(headline="VO2 max session", body="Norwegian 4x4: 4 reps at 4:17/km work pace, within 6 s.")
    assert grounded(ok, allowed)
    bad = CardText(headline="Line in the sand", body="4.9 km at 5:30/km is the number to beat.")
    assert not grounded(bad, allowed)


def test_ai_prompt_for_an_old_app_has_no_session(tmp_path, fakes):
    s = make_settings(tmp_path)
    db.init(s.db_path)
    w = Writer(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))
    w.write(build_facts(run(), [], {}), {})
    user = next(m["content"] for m in fakes.llm[0]["messages"] if m["role"] == "user")
    assert '"session"' not in user and "5:30/km" in user


# --- the endpoint: accepted, stored, optional -------------------------------------------------------

def test_endpoint_stores_the_session_fields(client):
    t = enrol(client)
    r = client.post("/v1/runs", json=run_payload("s1", type="intervals", **SESSION), headers=auth(t))
    assert r.status_code == 202
    row = sqlite3.connect(client.svc.s.db_path).execute(
        "SELECT session_name, work_pace_s_per_km, reps_done, rep_spread_s, recovery_pace_s_per_km, type FROM runs"
    ).fetchone()
    assert row == ("Norwegian 4x4", 257.0, 4, 6.0, 461.0, "interval")
    me = client.get("/v1/me", headers=auth(t)).json()["runs_received"][0]
    assert me["session_name"] == "Norwegian 4x4" and me["work_pace_s_per_km"] == 257.0


def test_old_app_payload_without_the_fields_is_accepted(client):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload("o1", type="intervals"), headers=auth(t)).status_code == 202
    row = sqlite3.connect(client.svc.s.db_path).execute(
        "SELECT session_name, work_pace_s_per_km, reps_done FROM runs").fetchone()
    assert row == (None, None, None)


def test_a_bad_session_field_is_dropped_not_a_422():
    base = run_payload("b1", type="intervals")
    m = RunIn.model_validate({**base, "session_name": "Sarah's hills", "work_pace_s_per_km": -3, "reps_done": 0,
                              "rep_spread_s": "fast", "recovery_pace_s_per_km": 9999})
    assert (m.session_name, m.work_pace_s_per_km, m.reps_done, m.rep_spread_s, m.recovery_pace_s_per_km) == (None,) * 5
    # unknown keys stay a loud 422
    with pytest.raises(ValidationError):
        RunIn.model_validate({**base, "session_nme": "x"})


def test_migration_adds_the_columns_to_an_older_database_and_is_repeatable(tmp_path):
    s = make_settings(tmp_path)
    db.init(s.db_path)
    c = sqlite3.connect(s.db_path)
    new_cols = ("session_name", "work_pace_s_per_km", "reps_done", "rep_spread_s", "recovery_pace_s_per_km")
    for col in new_cols:  # a database from before this change
        c.execute(f"ALTER TABLE runs DROP COLUMN {col}")
    c.commit()
    assert not set(new_cols) & {r[1] for r in c.execute("PRAGMA table_info(runs)")}
    c.close()
    db.init(s.db_path)
    db.init(s.db_path)  # a second start: nothing to add, no duplicate column error
    cols = {r[1] for r in sqlite3.connect(s.db_path).execute("PRAGMA table_info(runs)")}
    assert set(new_cols) <= cols


def test_voice_templates_for_sessions_have_no_digits():
    for sit in ("interval_baseline", "interval_work"):
        for h, b in voice.SITUATIONS[sit]:
            assert not re.search(r"\d", re.sub(r"\{[^}]*\}", "", h + b))


@pytest.mark.parametrize("name,kept", [
    ("Norwegian 4x4", True), ("8 × 400 m", True), ("custom:0123456789abcdef", True),
    ("Sarah's hill reps", False), ("custom:0123456789abcdeg", False), ("custom:0123456789abcde", False),
    ("Norwegian 4x4\u202e", False), ("Norwegian 4x4\n", True), ("Tempo\nintervals", False), ("x" * 41, False),
])
def test_only_a_built_in_or_coded_custom_name_is_kept(name, kept):
    m = RunIn.model_validate({**run_payload("n1", type="intervals"), "session_name": name})
    assert (m.session_name is not None) == kept
    assert m.session_name in (None, name.strip())


def test_a_typed_session_name_never_reaches_the_model_card_render_facts_or_logs(client, fakes, caplog):
    """The app sends a typed name only as a code; if an old or odd client sent the words, they are dropped on arrival."""
    import logging
    from companion.media import run_facts
    caplog.set_level(logging.DEBUG)
    t = enrol(client)
    secret = "Sarah's hill reps"
    r = client.post("/v1/runs", json=run_payload("leak1", type="intervals", verdict="baselineSet",
                                                 **{**SESSION, "session_name": secret}), headers=auth(t))
    assert r.status_code == 202
    c = sqlite3.connect(client.svc.s.db_path)
    c.row_factory = sqlite3.Row
    assert c.execute("SELECT session_name FROM runs").fetchone()[0] is None
    uid = c.execute("SELECT id FROM users").fetchone()[0]
    card_id = client.svc._build_run_card(uid, "leak1", datetime.now(timezone.utc))
    assert card_id and fakes.llm, "the model was called, so its body was checked"
    row = dict(c.execute("SELECT * FROM runs WHERE run_id='leak1'").fetchone())
    body = c.execute("SELECT headline, body FROM cards WHERE card_id=?", (card_id,)).fetchone()
    blobs = [str(fakes.llm), " ".join(body), str(run_facts(row, "Headline")), caplog.text,
             str(client.get("/v1/me", headers=auth(t)).json())]
    for blob in blobs:
        assert "Sarah" not in blob and "hill reps" not in blob
    # the coded custom name is stored and compared, but never spoken
    r = client.post("/v1/runs", json=run_payload("leak2", type="intervals", minutes_ago=300,
                                                 **{**SESSION, "session_name": "custom:0123456789abcdef"}), headers=auth(t))
    assert r.status_code == 202
    assert c.execute("SELECT session_name FROM runs WHERE run_id='leak2'").fetchone()[0] == "custom:0123456789abcdef"


# --- named runs without a work pace: a goal run, a session whose reps were not detected (17-Oct) -----------------

def test_goal_run_is_named_in_the_base_fact_and_says_whether_it_was_reached():
    res = build_facts(run(type="tempo", session_name="10K goal", goal_reached=1), [], {})
    assert res.facts[0].text.startswith("10K goal run: 4.9 km in 27 min at 5:30/km, goal reached")
    assert res.session == {"name": "10K goal", "purpose": "goal effort"}
    res = build_facts(run(type="tempo", session_name="10K goal", goal_reached=0), [], {})
    assert res.facts[0].text.endswith("goal not reached")


STOPPED = dict(type="free", app_type="intervals", session_name="Norwegian 4x4")   # the stored shape: no reps


def test_session_stopped_before_the_first_rep_is_context_not_a_session_headline():
    res = build_facts(run(**STOPPED), [], {})
    assert res.facts[0].text.startswith("Run: 4.9 km in 27 min") or "VO2 max" not in res.facts[0].text
    assert any(f.text == "Started Norwegian 4x4, stopped before the first rep" for f in res.facts)
    assert not any("VO2 max" in f.text or "work pace" in f.text for f in res.facts)
    assert res.session is None


def test_a_completed_session_run_does_not_get_the_stopped_fact():
    assert not any(f.id == "session" for f in build_facts(run(**SESSION, app_type="intervals"), [], {}).facts)


@pytest.mark.parametrize("name,kept", [("10K goal", True), ("Half goal", True), ("30 min goal", True),
                                       ("1 hour goal", True), ("1 h 15 min goal", True), ("12.3 km goal", True),
                                       ("7.5 mi goal", True), ("Sarah's goal", False), ("10K goal http://x.io", False),
                                       ("10 km goal", False), ("1 hour goal!", False)])
def test_only_the_apps_own_goal_names_are_kept(name, kept):
    m = RunIn.model_validate({**run_payload("g1", type="free"), "session_name": name})
    assert (m.session_name is not None) == kept


def test_endpoint_stores_goal_reached(client):
    t = enrol(client)
    r = client.post("/v1/runs", json=run_payload("g2", type="free", session_name="10K goal", goal_reached=True),
                    headers=auth(t))
    assert r.status_code == 202
    row = sqlite3.connect(client.svc.s.db_path).execute("SELECT session_name, goal_reached FROM runs").fetchone()
    assert tuple(row) == ("10K goal", 1)


def test_default_week_does_not_count_a_stopped_session_as_a_quality_session():
    from companion.default_week import quality_session, TEMPO
    q = quality_session([run(**STOPPED)])
    assert q.name == TEMPO and q.pace_lo_s is None


def test_a_plan_next_session_name_is_never_a_goal():
    from companion.service import PlanNextIn
    base = dict(type="quality", day="2026-10-20", week=1)
    assert PlanNextIn.model_validate({**base, "session_name": "10K goal", "session_id": "x"}).session_name is None
    assert PlanNextIn.model_validate({**base, "session_name": "Norwegian 4x4"}).session_name == "Norwegian 4x4"


def test_default_week_tempo_pace_ignores_goal_efforts():
    from companion.default_week import quality_session
    q = quality_session([run(type="tempo", session_name="10K goal", goal_reached=1, true_pace_s_per_km=290.0)])
    assert q.pace_lo_s is None


@pytest.mark.parametrize("goal", ["30 min goal", "12.3 km goal", "1 h 15 min goal", "10K goal"])
def test_a_goal_name_in_the_headline_is_not_the_picture_repeated(goal):
    from companion.writer import CardText, clean
    facts = build_facts(run(type="tempo", session_name=goal, goal_reached=1), [], {}).facts
    assert clean(CardText(headline=f"{goal} reached", body="You held it to the end."), facts) is None
    assert clean(CardText(headline=f"{goal} reached in 27 min", body="You held it to the end."), facts) \
        == "headline_repeats_picture"
