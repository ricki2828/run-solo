"""The default coach week: a runner with no 4-week plan still gets a next session, from their own answers and runs."""
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from companion import db
from companion import default_week as dw
from companion.timeutil import iso
from test_checkins import Env, agree, at
from conftest import enrol

SGT = ZoneInfo("Asia/Singapore")


def sgt(y, mo, d, h=0, mi=0) -> datetime:
    return datetime(y, mo, d, h, mi, tzinfo=SGT).astimezone(timezone.utc)


# Ricki's last 11 runs: trail ~4.7 km in the evening, one 5.4 km, the newest an interval attempt on 17 Oct at 07:41.
RICKI = [
    ((9, 25, 17, 5), 4700, "tempo"), ((9, 27, 17, 0), 4700, "tempo"), ((9, 29, 17, 10), 4700, "tempo"),
    ((10, 1, 17, 0), 4600, "tempo"), ((10, 3, 17, 15), 5400, "tempo"), ((10, 6, 17, 0), 4700, "tempo"),
    ((10, 8, 17, 5), 4800, "tempo"), ((10, 10, 17, 0), 4700, "tempo"), ((10, 12, 17, 0), 4600, "tempo"),
    ((10, 14, 17, 10), 4700, "tempo"), ((10, 17, 7, 41), 4800, "interval"),
]
MEMORY = {"goal_type": "fitness", "usual_days": "weekdays"}


def history(rows=RICKI):
    return [{"start_utc": iso(sgt(2026, *d)), "zone_id": "Asia/Singapore", "distance_m": m, "type": t,
             "zone_min": {}, "feel": "hard" if t == "interval" else None,
             "true_pace_s_per_km": 330 if t == "tempo" else None} for d, m, t in reversed(rows)]


def week(today=date(2026, 10, 17), now=sgt(2026, 10, 17, 9, 0), memory=MEMORY, rows=RICKI):
    return dw.build_week(history(rows), memory=memory, zone_id="Asia/Singapore", today=today, now=now)


def test_rickis_week_is_three_weekday_runs_easy_quality_long_sized_from_his_own_runs():
    got = [(s.day.strftime("%a %d"), s.type, s.distance_m) for s in week()[:3]]
    assert got == [("Mon 19", "easy", 5000), ("Wed 21", "quality", 5000), ("Fri 23", "long", 6000)]
    q = week()[1]   # the quality day names the session and its pace, from his own tempo runs
    assert (q.name, q.pace_lo_s, q.pace_hi_s) == ("Tempo", 325, 335)
    assert dw.shape_line(week(), date(2026, 10, 19)) == "Next week: Mon easy 5 km, Wed tempo 5 km at 5:25-5:35/km, Fri long 6 km."


def test_a_built_in_interval_session_with_its_work_pace_is_named_when_there_are_no_tempos():
    rows = [(d, m, "easy") for d, m, _t in RICKI[:-1]] + [RICKI[-1]]
    h = history(rows)
    h[0].update(session_name="Norwegian 4x4", work_pace_s_per_km=257)
    w = dw.build_week(h, memory=MEMORY, zone_id="Asia/Singapore", today=date(2026, 10, 19), now=sgt(2026, 10, 19, 9, 0))
    q = next(s for s in w if s.type == "quality")
    assert (q.name, q.pace_lo_s, q.pace_hi_s) == ("Norwegian 4x4", 252, 262)


def test_no_pace_is_made_up_and_a_fresh_runner_gets_no_quality_day():
    rows = [(d, m, "easy") for d, m, _t in RICKI]
    q = next(s for s in week(rows=rows) if s.type == "quality")
    assert q.name == "Tempo" and q.pace_lo_s is None
    fresh = RICKI[-5:]   # 5 runs, all inside his first fortnight
    assert {s.type for s in week(rows=fresh)} <= {"easy", "long"}


def test_the_long_run_never_jumps_past_the_longest_recent_run_plus_a_fifth():
    rows = [r for r in RICKI]
    assert week(rows=rows)[2].distance_m <= int(5.4 * 1.2) * 1000


def test_quality_waits_when_a_hard_run_is_inside_48_hours():
    # a hard run on Monday evening makes Wednesday morning's quality session an easy one
    rows = RICKI + [((10, 19, 17, 0), 4800, "interval")]
    w = week(today=date(2026, 10, 20), now=sgt(2026, 10, 20, 9, 0), rows=rows)
    assert [(s.day.day, s.type) for s in w[:2]] == [(21, "easy"), (23, "long")]


def test_a_week_that_is_done_waits_for_monday_and_today_is_skipped_once_run():
    rows = RICKI + [((10, 19, 17, 0), 4700, "easy"), ((10, 21, 17, 0), 4700, "easy"), ((10, 23, 17, 0), 6000, "easy")]
    w = week(today=date(2026, 10, 23), now=sgt(2026, 10, 23, 20, 0), rows=rows)
    assert w[0].day == date(2026, 10, 26)


def test_no_habit_no_week():
    assert week(rows=RICKI[-1:]) == []
    assert week(rows=RICKI[-2:]) == []   # two runs is not a habit yet
    assert week(rows=[]) == []


def test_runs_per_week_answer_wins_and_clamps():
    assert week(memory={**MEMORY, "runs_per_week": "2"})[0].type == "easy"
    assert len({s.day for s in week(memory={**MEMORY, "runs_per_week": "5"})[:4]}) == 4   # 5+ is capped at 4 runs


def test_no_stated_days_uses_the_weekdays_he_actually_runs():
    w = week(memory={"goal_type": "fitness"})
    assert {s.day.weekday() for s in w} <= {0, 1, 2, 3, 4, 5, 6} and w[0].day > date(2026, 10, 17)


# ------------------------------------------------------------------ through the check-in flow
def _env(client, fakes):
    t = enrol(client)
    e = Env(client, fakes, t)
    agree(client, t)
    with db.tx(e.path) as c:
        for k, v in MEMORY.items():
            c.execute("INSERT OR REPLACE INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)",
                      (e.uid, k, v, "2026-10-01T00:00:00Z"))
    return e


def _seed(e):
    for i, (d, m, t) in enumerate(RICKI):
        e.run(f"r{i}", at(2026, d[0], d[1], d[2], d[3]), type=t)
    with db.tx(e.path) as c:   # Env.run fixes the distance at 7 km: set the fixture's own
        for i, (_d, m, _t) in enumerate(RICKI):
            c.execute("UPDATE runs SET distance_m=?, true_pace_s_per_km=330 WHERE run_id=?", (m, f"r{i}"))


def test_the_evening_card_says_tomorrow_quality_with_buttons_and_home_gets_a_session(client, fakes):
    e = _env(client, fakes)
    _seed(e)
    # Rome clock, same shape: the newest run is on Sat 17 Oct, so Tuesday evening asks about Wednesday's quality run
    assert e.step(at(2026, 10, 20, 20, 5)) == 1
    [msg] = e.sends()
    assert msg["text"].startswith("Tempo, 5 km tomorrow · 5:30/km work pace")
    assert [b["text"] for row in msg["reply_markup"]["inline_keyboard"] for b in row][:3] == ["Fresh", "Normal", "Flat"]
    n = e.svc.next_session(e.uid, at(2026, 10, 18, 9, 0))["next_session"]
    assert n["derived"] is True and n["date"] == "2026-10-19" and n["label"] == "Easy run, 5 km"
    with db.ro(e.path) as c:
        facts = e.svc._ci_week_facts(c, {"id": e.uid, "zone_id": "Europe/Rome"}, date(2026, 10, 19), at(2026, 10, 18, 9, 0))
    assert [(d["type"], d["planned_km"]) for d in facts["days"] if d["planned_km"]] == [("easy", 5.0), ("tempo", 5.0), ("long", 6.0)]  # the week card draws quality as tempo


def test_a_real_plan_on_the_newest_run_beats_the_default_week(client, fakes):
    e = _env(client, fakes)
    _seed(e)
    e.run("planned", at(2026, 10, 18, 9, 0), plan_next={"type": "long", "day": "2026-10-22", "week": 2, "distance_m": 9000})
    n = e.svc.next_session(e.uid, at(2026, 10, 19, 9, 0))["next_session"]
    assert n["date"] == "2026-10-22" and n["type"] == "long" and "derived" not in n and n["week"] == 2


def test_a_stale_plan_falls_back_to_the_default_week(client, fakes):
    e = _env(client, fakes)
    _seed(e)
    e.run("planned", at(2026, 10, 17, 9, 0), plan_next={"type": "long", "day": "2026-10-17", "week": 2, "distance_m": 9000})
    n = e.svc.next_session(e.uid, at(2026, 10, 20, 9, 0))["next_session"]   # the plan's day has gone by
    assert n["derived"] is True and n["date"] == "2026-10-21" and n["label"] == "Tempo, 5 km"
    cid = e.svc._build_recap_card(e.uid, "2026-W42", at(2026, 10, 18, 19, 0))
    assert "Next week:" in e.q("SELECT body FROM cards WHERE card_id=?", cid)[0]["body"]


def test_the_recap_ends_with_one_shape_of_next_week_line(client, fakes):
    e = _env(client, fakes)
    _seed(e)
    now = at(2026, 10, 18, 19, 0)   # Sunday evening, after the week's last run
    cid = e.svc._build_recap_card(e.uid, "2026-W42", now)
    body = e.q("SELECT body FROM cards WHERE card_id=?", cid)[0]["body"]
    assert body.endswith("Next week: Mon easy 5 km, Wed tempo 5 km at 5:25-5:35/km, Fri long 6 km.")
    assert "—" not in body


def test_no_shape_line_when_the_newest_run_carries_a_real_plan(client, fakes):
    e = _env(client, fakes)
    _seed(e)
    e.run("planned", at(2026, 10, 18, 9, 0), plan_next={"type": "long", "day": "2026-10-22", "week": 2, "distance_m": 9000})
    cid = e.svc._build_recap_card(e.uid, "2026-W42", at(2026, 10, 18, 19, 0))
    assert "Next week:" not in e.q("SELECT body FROM cards WHERE card_id=?", cid)[0]["body"]


def test_an_unchanged_shape_is_not_repeated_the_next_sunday(client, fakes):
    e = _env(client, fakes)
    _seed(e)
    first = e.svc._build_recap_card(e.uid, "2026-W42", at(2026, 10, 18, 19, 0))
    second = e.svc._build_recap_card(e.uid, "2026-W43", at(2026, 10, 25, 19, 0))
    assert "Next week:" in e.q("SELECT body FROM cards WHERE card_id=?", first)[0]["body"]
    assert "Next week:" not in e.q("SELECT body FROM cards WHERE card_id=?", second)[0]["body"]


def test_the_run_card_next_line_agrees_with_the_evening_card_and_home(client, fakes):
    """Ricki's fixture, no plan: the card after Saturday's run, the Tuesday evening card and Home name the same session."""
    e = _env(client, fakes)
    _seed(e)
    e.svc.run_outbox(at(2026, 10, 18, 9, 0))
    with db.tx(e.path) as c:
        c.execute("DELETE FROM cards WHERE kind='run'")
    cid = e.svc._build_run_card(e.uid, "r10", at(2026, 10, 17, 8, 0))
    body = e.q("SELECT body FROM cards WHERE card_id=?", cid)[0]["body"] if cid else ""
    home = e.svc.next_session(e.uid, at(2026, 10, 17, 8, 0))["next_session"]
    assert home["label"] == "Easy run, 5 km" and home["date"] == "2026-10-19"
    assert "Next: easy 5 km on Monday" in body
    from companion.convo.questions import ORDER
    with db.tx(e.path) as c:   # every weekly question answered, so the day's one question slot is free for the check-in
        for k in ORDER:
            c.execute("INSERT OR IGNORE INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (e.uid, k, "x", "2026-10-01T00:00:00Z"))
    e.step(at(2026, 10, 20, 20, 5))
    assert e.sends()[-1]["text"].startswith("Tempo, 5 km tomorrow · 5:30/km work pace")


def test_quality_pace_ignores_trail_runs_and_easy_tapped_tempos():
    runs = [
        {"type": "tempo", "app_type": "trail", "true_pace_s_per_km": 330, "distance_m": 4700, "feel": "hard"},
        {"type": "tempo", "app_type": "free", "true_pace_s_per_km": 340, "distance_m": 4700, "feel": "right"},
    ]
    q = dw.quality_session(runs)
    assert (q.pace_lo_s, q.pace_hi_s) == (None, None)
    real = runs + [{"type": "tempo", "app_type": "free", "true_pace_s_per_km": 300, "distance_m": 5000, "feel": "hard"}]
    q = dw.quality_session(real)
    assert (q.pace_lo_s, q.pace_hi_s) == (295, 305)


def test_quality_falls_back_to_the_named_session_when_all_tempos_were_trail():
    runs = [{"type": "tempo", "app_type": "trail", "true_pace_s_per_km": 330, "distance_m": 4700},
            {"type": "interval", "session_name": "Norwegian 4x4", "work_pace_s_per_km": 290, "distance_m": 6000}]
    q = dw.quality_session(runs)
    assert q.name == "Norwegian 4x4" and q.pace_lo_s == 285
