"""GET /v1/me/next-session carries the app's briefing match key and what it needs to start the session (session_ref,
fingerprint, reps, pace_lo, pace_hi), from the SAME spec the briefing uses (coach/briefing.py spec_from), for a plan session
and for the coach week alike. The contract test: what the endpoint says equals what the briefing stored for that runner/day."""
from __future__ import annotations

from datetime import timedelta

import pytest

from companion import checkin_service, db
from companion.coach import briefing as bf

from conftest import auth, coach_text
from test_coach_briefing import GOOD, PLAN, T0, cc, checkin, jobs, ready, rows, upload, work  # noqa: F401  (cc is a fixture)

NOW = T0 + timedelta(minutes=1)
NEW_KEYS = {"session_ref", "fingerprint", "reps", "pace_lo", "pace_hi"}


def session(c, now=NOW):
    return c.svc.next_session(c.uid, now)["next_session"]


def spec(c, now=NOW):
    with db.ro(c.svc.s.db_path) as con:
        user = dict(con.execute("SELECT * FROM users WHERE id=?", (c.uid,)).fetchone())
        return c.svc.coach.briefing.spec_for(con, user, now)


def coach_week_history(c):
    for i in range(6):   # enough runs for the default coach week, and no plan_next anywhere
        upload(c, f"h{i}", plan=None, now=T0 - timedelta(days=12 - 2 * i), type="easy")


def test_a_plan_session_matches_the_stored_briefing_exactly(cc, fakes):
    ready(cc, fakes)
    ns = session(cc)
    row = rows(cc, "SELECT * FROM coach_briefings")[0]
    assert ns["session_ref"] == row["session_ref"] == "w3s2"
    assert ns["fingerprint"] == row["fingerprint"] == bf.fingerprint("quality", 30, None, 4, 288.0, 292.0)
    assert ns["reps"] == 4 and ns["pace_lo"] == 288.0 and ns["pace_hi"] == 292.0
    assert "derived" not in ns and ns["name"] == "Norwegian 4x4" and ns["type"] == "quality"


def test_the_coach_week_matches_the_stored_briefing_exactly(cc, fakes):
    coach_week_history(cc)
    fakes.coach_queue = [coach_text("Easy run today. Keep it relaxed and chatty, and finish feeling like you could go again.")]
    cc.svc.coach.briefing.enqueue(cc.uid, T0)
    work(cc)
    ns = session(cc)
    row = rows(cc, "SELECT * FROM coach_briefings")[0]
    assert ns["derived"] is True
    assert ns["session_ref"] == row["session_ref"] and ns["session_ref"].startswith("cw2026")
    assert ns["session_ref"] == f"cw{ns['date'].replace('-', '')}{ns['type'][0]}"
    assert ns["fingerprint"] == row["fingerprint"]


def test_every_new_field_is_the_briefing_specs_for_both_sources(cc, fakes):
    coach_week_history(cc)
    ns = session(cc)
    s = spec(cc)
    assert (ns["session_ref"], ns["fingerprint"], ns["reps"], ns["pace_lo"], ns["pace_hi"]) == \
        (s.ref, bf.spec_fingerprint(s), s.reps, s.pace_lo, s.pace_hi)
    upload(cc, "p1", now=T0)   # now a plan session, same runner
    ns, s = session(cc), spec(cc)
    assert "derived" not in ns
    assert (ns["session_ref"], ns["fingerprint"], ns["reps"], ns["pace_lo"], ns["pace_hi"]) == \
        (s.ref, bf.spec_fingerprint(s), s.reps, s.pace_lo, s.pace_hi)
    assert (ns["minutes"], ns["distance_m"]) == (s.minutes, s.distance_m)


def test_pace_and_reps_are_null_outside_a_quality_session_with_a_pace(cc, fakes):
    upload(cc, plan={"type": "easy", "day": "2026-10-22", "week": 3, "minutes": 40, "session_ref": "w3s3"})
    ns = session(cc)
    assert ns["session_ref"] == "w3s3" and ns["reps"] is None and ns["pace_lo"] is None and ns["pace_hi"] is None
    upload(cc, "r2", now=T0 + timedelta(minutes=5), plan={"type": "quality", "day": "2026-10-22", "week": 3, "minutes": 30,
                                                       "session_ref": "w3s4"})   # quality, but the app sent no pace
    ns = session(cc, T0 + timedelta(minutes=6))
    assert ns["session_ref"] == "w3s4" and ns["pace_lo"] is None and ns["pace_hi"] is None and ns["reps"] is None


def test_a_session_made_easy_by_a_checkin_has_no_pace_and_the_easy_fingerprint(cc, fakes):
    upload(cc)
    checkin(cc, "ready", "2026-10-22", "flat")
    ns = session(cc)
    assert ns["type"] == "easy" and ns["minutes"] is None and ns["pace_lo"] is None and ns["reps"] is None
    assert ns["fingerprint"] == bf.fingerprint("easy") == bf.spec_fingerprint(spec(cc))
    assert ns["session_ref"] == "w3s2"


def test_a_plan_session_without_a_ref_has_a_fingerprint_but_no_session_ref(cc, fakes):
    plan = {k: v for k, v in PLAN.items() if k != "session_ref"}
    upload(cc, plan=plan)
    ns = session(cc)
    assert ns["session_ref"] is None and ns["fingerprint"] == bf.fingerprint("quality", 30, None, 4, 288.0, 292.0)
    assert spec(cc) is None   # the briefing itself still has nothing to match without a ref


def test_no_session_has_no_new_fields(cc, fakes):
    assert cc.svc.next_session(cc.uid, NOW)["next_session"] is None


def test_the_route_serves_the_fields_and_keeps_the_old_ones(cc, fakes, monkeypatch):
    monkeypatch.setattr(checkin_service, "now_utc", lambda: NOW)
    ready(cc, fakes)
    r = cc.get("/v1/me/next-session", headers=auth(cc.token))
    assert r.status_code == 200
    ns = r.json()["next_session"]
    assert NEW_KEYS <= set(ns)
    assert {"date", "type", "kind", "name", "session_id", "name_source", "minutes", "distance_m", "week", "weeks", "moved",
            "original_date", "label"} <= set(ns)
    assert ns["session_ref"] == "w3s2" and ns["fingerprint"] == rows(cc, "SELECT fingerprint FROM coach_briefings")[0]["fingerprint"]
