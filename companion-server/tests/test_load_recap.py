"""Weekly load on the Sunday recap and card (load batch C): what the server stores, when the recap speaks in load, and
the picture. With the gate off nothing changes, and a test below proves it."""
import hashlib
import re
import sqlite3
from datetime import date, datetime, timedelta, timezone

import pytest

from companion import db
from companion.convo import recap, voice
from companion.media import week_facts
from companion.service import RunIn
from conftest import auth, enrol, make_settings, run_payload
from render import protocol as P
from render.cards import fixtures as F
from render.cards.weekly import build_weekly_html

U = timezone.utc
SG = "Asia/Singapore"
SUN = datetime(2026, 10, 18, 11, 5, tzinfo=U)      # Sunday 19:05 in Singapore
MONDAY = datetime(2026, 10, 12)                    # that week's Monday, local


def mk(i, week, day, load="x", km=7.0, **kw):
    """One run in the Mon-Sun week `week` weeks before the recap week, on weekday `day` (0 = Monday), 10:00 SG."""
    start = (MONDAY - timedelta(days=7 * week) + timedelta(days=day, hours=2)).replace(tzinfo=U)
    r = {"run_id": f"r{i}", "start_utc": start, "type": "easy", "distance_m": int(km * 1000), "duration_s": int(km * 355),
         "pace_s_per_km": 355.0, "true_pace_s_per_km": 355.0, "zone_id": SG, "locality": None, "zone_min": {},
         "load_state": None, "pb": None, "verdict": None, "climb_m": None, "plan_weeks_to_race": None,
         "load": None, "load_basis": None}
    if load != "x":
        r["load"], r["load_basis"] = load, "hr"
    r.update(kw)
    return r


def history(loads_by_week, runs_per_week=2, flag=False):
    """`loads_by_week[w]` is the total load of the week `w` weeks before the recap week (0 = the recap week), split over
    `runs_per_week` runs; None = an empty week. Newest first, as the service holds them."""
    out, i = [], 0
    for w, total in enumerate(loads_by_week):
        if total is None:
            continue
        for d in range(runs_per_week):
            i += 1
            out.append(mk(i, w, d * 2, load=total / runs_per_week, load_state="high" if flag and w == 0 and d == 1 else None))
    return sorted(out, key=lambda r: r["start_utc"], reverse=True)


# a 4-week usual of 300, then the recap week on top
def week_of(this, usual=300.0, flag=False):
    return history([this, usual, usual, usual, usual, usual], flag=flag)


def facts_for(runs, paused=()):
    return recap.load_facts(runs, SG, MONDAY, paused)


# --- bands ------------------------------------------------------------------------------------

@pytest.mark.parametrize("this,band", [(239, "lighter"), (240, "usual"), (330, "usual"), (331, "stepUp"), (390, "stepUp"),
                                       (391, "bigJump"), (570, "bigJump")])
def test_band_edges_at_the_apps_ratios(this, band):
    f = facts_for(week_of(this, flag=True))
    assert f["band"] == band and f["load"] == this and f["usual_load"] == 300


def test_pct_is_whole_percent_either_way():
    assert facts_for(week_of(405, flag=True))["pct"] == 35
    assert facts_for(week_of(180))["pct"] == 40


def test_a_jump_without_the_in_week_warning_is_a_step_up_with_no_amber():
    """Over 1.3x but no run that week carried load_state high / very_high: the words are a step up, never a big jump."""
    f = facts_for(week_of(450))
    assert f["band"] == "stepUp" and f["pct"] == 50
    assert facts_for(week_of(450, flag=True))["band"] == "bigJump"
    only_very = history([450, 300, 300, 300, 300, 300])
    only_very[0]["load_state"] = "very_high"
    assert facts_for(only_very)["band"] == "bigJump"
    only_steady = history([450, 300, 300, 300, 300, 300])
    only_steady[0]["load_state"] = "steady"
    assert facts_for(only_steady)["band"] == "stepUp"
    # a flag on an earlier week does not count
    older = history([450, 300, 300, 300, 300, 300])
    older[-1]["load_state"] = "high"
    assert facts_for(older)["band"] == "stepUp"
    assert facts_for(week_of(240, flag=True))["band"] == "usual"       # a flag never changes the lower bands


def test_percent_rounding_matches_the_app_half_away_from_zero():
    assert recap._r(12.5) == 13 and recap._r(0.5) == 1 and recap._r(2.5) == 3 and recap._r(12.4) == 12
    assert recap.vs_usual(1.125) == "13% more than your usual week"
    assert facts_for(week_of(337.5))["pct"] == 13                     # 337.5 / 300 = 1.125
    assert recap._r(345 * 1.1 / 10) * 10 == 380                        # the cap, to the nearest ten


def test_words_never_show_a_ratio_and_follow_the_apps_phrase():
    assert recap.load_words("stepUp", 1.15) == "15% more than your usual week"
    assert recap.load_words("bigJump", 1.9) == "About double your usual week"
    assert recap.load_words("stepUp", 2.2) == "About double your usual week"
    assert recap.load_words("bigJump", 2.3) == "About 2.5 times your usual week"
    assert recap.load_words("bigJump", 3.0) == "About 3 times your usual week"
    assert recap.load_words("lighter", 0.72) == "28% less than your usual week"
    assert recap.load_words("usual", 1.02) == "About your usual week"
    assert recap.over_phrase(1.35) == "35% over" and recap.over_phrase(1.95) == "about double"


def test_six_weeks_come_back_oldest_first_with_shares_that_add_up():
    f = facts_for(week_of(352))
    assert [w["monday"] for w in f["weeks"]] == [(MONDAY - timedelta(days=7 * k)).date().isoformat() for k in range(5, -1, -1)]
    assert f["weeks"][-1]["load"] == 352
    for w in f["weeks"]:
        assert abs(sum(w["zone_share"]) + w["nohr_share"] - 1) < 0.01


def test_a_run_with_zones_splits_its_load_by_zone_and_one_without_is_no_hr():
    runs = week_of(300)
    runs[0]["zone_min"] = {"z1": 10, "z2": 30}
    f = facts_for(runs)
    last = f["weeks"][-1]
    assert last["zone_share"][1] > last["zone_share"][0] > 0 and 0 < last["nohr_share"] < 1


# --- the gate and the states that stay on km ---------------------------------------------------

def test_the_gate_needs_every_run_of_the_last_five_weeks_to_carry_the_apps_load():
    runs = week_of(300)               # 2 runs a week: 10 in the window (this week and the 4 before)
    window = [r for r in runs if r["start_utc"] >= (MONDAY - timedelta(days=28)).replace(tzinfo=U) - timedelta(hours=8)]
    assert len(window) == 10
    assert facts_for(runs) is not None
    runs[0]["load"] = None            # 9 of 10: a server estimate would sit in the usual, so the km recap stays
    assert facts_for(runs) is None
    assert recap.build(runs, SUN, SG, {}, "w").rendered.situation in ("recap_up", "recap_down", "recap_flat")


def test_the_cap_comes_from_the_raw_usual_like_the_app():
    runs = history([450, 340, 341, 340, 341, 300], flag=True)   # usual 340.5
    f = facts_for(runs)
    assert f["usual_load"] == 341
    rc = recap.build(runs, SUN, SG, {}, "w")
    assert rc.rendered.situation == "recap_load_jump" and "370" in rc.rendered.body and "380" not in rc.rendered.body


def test_runs_older_than_the_window_do_not_count_toward_the_gate():
    runs = week_of(300)
    for r in runs:
        if r["start_utc"] < (MONDAY - timedelta(days=28)).replace(tzinfo=U) - timedelta(hours=8):
            r["load"] = None                          # the 5th week back is not in the gate
    assert facts_for(runs) is not None


def test_no_runs_this_week_is_not_a_load_week():
    assert facts_for(history([None, 300, 300, 300, 300, 300])) is None


def test_three_usual_weeks_are_needed():
    assert facts_for(history([300, 300])) is None
    assert facts_for(history([300, 300, 300])) is None         # two usual weeks, the older ones predate the first run
    assert facts_for(history([300, 300, 300, 300])) is not None
    assert facts_for(history([300, 300, 300, 300, 300])) is not None
    assert facts_for(history([300, 300, None, None, None, None])) is None


def test_the_first_runs_part_week_is_left_out_of_the_usual():
    def with_first_on_wednesday(n):
        runs = history([300] * n)
        runs[-1]["start_utc"] += timedelta(days=2)             # the first run was on a Wednesday: its week is a part week
        return runs
    assert facts_for(with_first_on_wednesday(4)) is None       # only 2 full weeks before this one
    assert facts_for(with_first_on_wednesday(5))["usual_load"] == 300   # 3 full weeks, the part week left out


def test_a_rest_week_is_left_out_of_the_usual_not_counted_as_zero():
    f = facts_for(history([300, 300, None, 300, 300, 300]))
    assert f["usual_load"] == 300 and f["band"] == "usual"     # one sick week must not make a normal week a jump


def test_a_returner_compares_with_nothing():
    assert facts_for(history([300, None, None, 300, 300, 300])) is None
    assert facts_for(history([300, None, 300, 300, 300, 300])) is not None   # one empty week is a rest week


def test_weeks_before_the_first_run_are_not_rest_weeks():
    assert facts_for(history([300, 300, 300, 300, 300])) is not None   # the 6th week back predates the first run


def test_a_paused_week_is_left_out_and_not_a_return():
    pw = (MONDAY - timedelta(days=14)).date()
    f = facts_for(history([300, 300, None, 300, 300, 300]), paused=[pw])
    assert f["usual_load"] == 300
    assert f["weeks"][3]["paused"] is True
    p2 = history([300, 300, 600, 300, 300, 300])
    assert facts_for(p2)["usual_load"] == 375
    assert facts_for(p2, paused=[(MONDAY - timedelta(days=14)).date()])["usual_load"] == 300


def test_a_usual_week_under_60_is_too_small():
    assert facts_for(week_of(100, usual=50)) is None


def test_a_missing_load_falls_back_to_the_zone_minutes_then_to_2_5_a_minute():
    zoned = mk(1, 1, 0, zone_min={"z2": 30, "z3": 10})
    assert recap.run_load(zoned) == (30 * 2 + 10 * 3, "server_estimate")
    bare = mk(2, 1, 0, km=6.0)
    assert recap.run_load(bare) == (bare["duration_s"] / 60 * 2.5, "server_estimate")
    assert recap.run_load(mk(3, 1, 0, load=120.0)) == (120.0, "hr")


# --- the recap text --------------------------------------------------------------------------

@pytest.mark.parametrize("this,sit", [(100, "recap_load_light"), (300, "recap_load_usual"), (350, "recap_load_step"),
                                      (450, "recap_load_jump")])
def test_build_speaks_in_load_when_the_gate_is_open(this, sit):
    rc = recap.build(week_of(this, flag=True), SUN, SG, {}, "w")
    assert rc.rendered.situation == sit and rc.media.card == "weekly_recap" and rc.media.video
    assert str(this) in rc.rendered.body and "300" in rc.rendered.body
    assert rc.media.facts["load"] == this and rc.media.facts["band"] == recap.load_band(this / 300)
    if sit == "recap_load_jump":
        assert "330" in rc.rendered.body        # the cap: the usual week x 1.1, to the nearest ten


def test_build_with_the_gate_off_is_exactly_the_km_recap():
    """The same weeks with no load anywhere: the situation, text and plan are what they were before load existed."""
    plain = [{**r, "load": None, "load_basis": None} for r in week_of(450)]
    rc = recap.build(plain, SUN, SG, {}, "w")
    assert rc.rendered.situation in ("recap_up", "recap_down", "recap_flat") and rc.media.facts is None
    assert "load" not in rc.rendered.body.lower()
    assert rc.media.to_json() == '{"card": "weekly_recap", "reason": "weekly_recap", "touch_card": null, "video": true}'
    # the same call before the change gave the same body: build it once more without the keys at all
    bare = [{k: v for k, v in r.items() if k not in ("load", "load_basis")} for r in plain]
    assert recap.build(bare, SUN, SG, {}, "w").rendered == rc.rendered


def test_first_week_return_and_missed_stay_as_they_are():
    first = [mk(1, 0, 1, load=100.0)]
    assert recap.build(first, SUN, SG, {}, "w").rendered.situation == "recap_first"
    back = [mk(1, 0, 1, load=100.0), mk(2, 5, 1, load=100.0)]
    assert recap.build(back, SUN, SG, {}, "w").rendered.situation == "recap_return"
    old = [mk(1, 3, 1, load=100.0)]
    assert recap.build(old, SUN, SG, {}, "w").rendered.situation == "missed_week"


def test_all_four_load_situations_have_three_variants_and_known_slots():
    slots = {"runs_txt", "km", "min", "load", "usual", "pct", "more", "cap", "moment"}
    for sit in ("recap_load_usual", "recap_load_step", "recap_load_jump", "recap_load_light"):
        vs = voice.RECAPS[sit]
        assert len(vs) == 3 and len({b for _, b in vs}) == 3
        for h, b in vs:
            assert voice.slots_of(h + b) <= slots and "{load}" in b + h


def test_paused_weeks_reach_the_usual_week_through_build():
    pw = (MONDAY - timedelta(days=14)).date()
    runs = history([300, 300, 600, 300, 300, 300])
    assert recap.build(runs, SUN, SG, {}, "w", paused_weeks=[pw]).media.facts["usual_load"] == 300
    assert recap.build(runs, SUN, SG, {}, "w").media.facts["usual_load"] == 375


# --- storing the load ------------------------------------------------------------------------

def _rows(client):
    c = sqlite3.connect(client.svc.s.db_path)
    return c.execute("SELECT run_id, load, load_basis FROM runs ORDER BY id").fetchall()


def test_an_upload_stores_load_and_basis(client, fakes):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload("l1", load=187.5, load_basis="hr"), headers=auth(t)).status_code == 202
    assert client.post("/v1/runs", json=run_payload("l2"), headers=auth(t)).status_code == 202
    assert _rows(client) == [("l1", 187.5, "hr"), ("l2", None, None)]


@pytest.mark.parametrize("over", [{"load": -1}, {"load": 99999}, {"load": "lots"}, {"load": 120, "load_basis": "guess"}])
def test_a_bad_load_drops_the_field_never_the_run(client, fakes, over):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload("b1", **over), headers=auth(t)).status_code == 202
    (_rid, load, basis), = _rows(client)
    assert (load, basis) == ((120.0, None) if over.get("load") == 120 else (None, None))


def test_a_basis_alone_is_dropped():
    m = RunIn.model_validate({**run_payload("a1"), "load_basis": "hr"})
    assert m.load is None and m.load_basis is None


def test_the_load_range_is_0_to_5000():
    for ok in (0, 2100, 5000):
        assert RunIn.model_validate({**run_payload("a1"), "load": ok}).load == ok
    assert RunIn.model_validate({**run_payload("a1"), "load": 5000.5}).load is None


def test_migration_adds_load_columns_to_an_older_database_and_is_repeatable(tmp_path):
    s = make_settings(tmp_path)
    db.init(s.db_path)
    c = sqlite3.connect(s.db_path)
    for col in ("load", "load_basis"):
        c.execute(f"ALTER TABLE runs DROP COLUMN {col}")
    c.commit()
    assert not {"load", "load_basis"} & {r[1] for r in c.execute("PRAGMA table_info(runs)")}
    c.close()
    db.init(s.db_path)
    db.init(s.db_path)
    assert {"load", "load_basis"} <= {r[1] for r in sqlite3.connect(s.db_path).execute("PRAGMA table_info(runs)")}


# --- the picture ----------------------------------------------------------------------------

LOAD_KEYS = ("load", "usual_load", "band", "pct", "words", "weeks")


def test_week_facts_adds_the_load_block_only_when_given_one(tmp_path):
    runs = week_of(352)
    rows = [{**r, "start_utc": r["start_utc"].isoformat()} for r in runs]
    plain = week_facts("2026-W42", rows)
    assert not set(LOAD_KEYS) & set(plain)
    lf = facts_for(runs)
    with_load = week_facts("2026-W42", rows, lf)
    assert {k: v for k, v in with_load.items() if k not in LOAD_KEYS} == plain
    assert {k: with_load[k] for k in LOAD_KEYS} == lf
    P.check_request({"v": 1, "op": "card", "kind": "weekly_recap", "facts": with_load})


def test_the_loop_and_the_video_never_get_the_load_block():
    f = week_facts("2026-W42", [], F.weekly_recap_load_usual())
    for kind, op in (("week_loop", "video"), ("weekly", "video")):
        with pytest.raises(P.ProtocolError):
            P.check_request({"v": 1, "op": op, "kind": kind, "facts": {**f, "duration_s": 1}})


@pytest.mark.parametrize("name", ["weekly_recap_load_usual", "weekly_recap_load_bigjump", "weekly_recap_load_stepup", "weekly_recap_load_nohr"])
def test_the_load_fixtures_pass_the_worker_check(name):
    P.check_request({"v": 1, "op": "card", "kind": "weekly_recap", "facts": getattr(F, name)()})


@pytest.mark.parametrize("bad", [
    {"band": "huge"}, {"load": -1}, {"usual_load": "x"}, {"pct": True}, {"weeks": []}, {"weeks": [{"monday": "2026-10-05", "load": 1}] * 5},
    {"weeks": [{"monday": "2026-10-05", "load": 1, "zone_share": [0.5, 0.5, 0, 0], "nohr_share": 0}] * 6},
    {"weeks": [{"monday": "2026-10-05", "load": 1, "zone_share": [0.2] * 5, "nohr_share": 0, "route": "x"}] * 6},
])
def test_a_malformed_load_block_is_refused(bad):
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "weekly_recap", "facts": {**F.weekly_recap_load_usual(), **bad}})


def test_a_partial_load_block_is_refused():
    f = {k: v for k, v in F.weekly_recap_load_usual().items() if k != "weeks"}
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "weekly_recap", "facts": f})


# What origin/main drew for the two older weekly fixtures (sha256 of the HTML). The no-load card must not move by a
# byte; change these only with a deliberate change to the card, and regenerate both goldens in the same PR.
OLD_HTML = {"weekly_recap": "7daad0918b51cac8c9d62bc033f43da5823a48df6e447da8dd15b19fa5b75488",
            "weekly_recap_big": "f89e39a367d6faab4fe7eb6a42aaf41086336dfb42cf39f977f6ff3e9813e522"}


@pytest.mark.parametrize("name", sorted(OLD_HTML))
def test_without_load_the_weekly_card_is_byte_identical_to_before(name):
    html = build_weekly_html(getattr(F, name)(), {})
    assert hashlib.sha256(html.encode()).hexdigest() == OLD_HTML[name]


def test_stripping_the_load_block_gives_the_plain_card_back():
    f = F.weekly_recap_load_bigjump()
    plain = {k: v for k, v in f.items() if k not in LOAD_KEYS}
    assert build_weekly_html(plain, {}) == build_weekly_html(F.weekly_recap(), {})
    assert build_weekly_html(f, {}) != build_weekly_html(plain, {})


def test_the_load_card_says_load_in_words_and_marks_a_big_jump():
    html = build_weekly_html(F.weekly_recap_load_bigjump(), {})
    assert "LOAD 470" in html and "38% more than your usual week" in html and "USUAL 340" in html and "PAUSED" in html
    assert "14 SEP" in html and "5 OCT" in html
    assert not re.search(r"\d\.\d+x|ratio", html)
    assert "stroke=\"%s\"" % "#D9A21B" in html                     # the amber outline on a big jump
    assert "stroke=\"#D9A21B\"" not in build_weekly_html(F.weekly_recap_load_usual(), {})
    assert "#C8401E" not in html.split('class="abs loadbars"', 1)[1].split("</svg>", 1)[0]   # never vermillion in the panel


# --- end to end: the stored runs -> the recap text -> the card the text is about -----------------------------

def test_the_sunday_recap_text_and_card_carry_the_same_load(tmp_path, fakes):
    from test_channels_media import MP4, PNG, media_client
    from companion.timeutil import iso
    cards, loops = [], []

    def card(facts, memory=None):
        cards.append(facts)
        return PNG

    def loop(facts, out):
        loops.append(facts)
        out.write_bytes(MP4)
    with media_client(tmp_path, fakes, card_fns={"weekly_recap": card}, video_fns={"week_loop": loop}) as c:
        t = enrol(c)
        con = sqlite3.connect(c.svc.s.db_path)
        uid = con.execute("SELECT id FROM users").fetchone()[0]
        for wk, per_run in ((0, 225.0), (1, 150.0), (2, 150.0), (3, 150.0), (4, 150.0), (5, 150.0)):
            for d in (0, 2):
                start = datetime(2026, 10, 12 + d, 6, 0, tzinfo=U) - timedelta(days=7 * wk)
                c.svc.ingest_run(uid, RunIn.model_validate(run_payload(
                    f"w{wk}{d}", start_utc=start.isoformat(), zone_id="UTC", utc_offset_min=0, duration_s=1800, distance_m=5000,
                    zone_min={"z2": 25, "z3": 5}, load=per_run, load_basis="hr",
                    load_state="high" if wk == 0 else None)), start + timedelta(hours=1))
        con.execute("UPDATE users SET zone_id='UTC'")
        con.execute("UPDATE outbox SET state='done'")
        con.commit()
        sunday = datetime(2026, 10, 18, 19, 30, tzinfo=U)
        assert c.svc.plan_recap(sunday) == 1
        c.svc.run_outbox(sunday + timedelta(seconds=1))
        body, media_json = con.execute(
            "SELECT c.body, v.media_json FROM cards c JOIN convo_cards v ON v.card_id=c.card_id WHERE c.kind='recap'").fetchone()
        assert "450" in body and "50%" in body and "usual 300" in body and "330" in body
    f = cards[0]
    assert (f["load"], f["usual_load"], f["band"], f["pct"]) == (450, 300, "bigJump", 50)
    assert [w["load"] for w in f["weeks"]] == [300, 300, 300, 300, 300, 450]
    assert not set(LOAD_KEYS) & set(loops[0])            # the moment loop is the older facts
    P.check_request({"v": 1, "op": "card", "kind": "weekly_recap", "facts": f})
    assert '"load": 450' in media_json                   # decided once, stored with the card: text and picture cannot drift


def test_a_runner_with_no_load_gets_the_km_recap_and_the_plain_card(tmp_path, fakes):
    from test_channels_media import MP4, PNG, media_client, week_setup
    cards = []
    with media_client(tmp_path, fakes, card_fns={"weekly_recap": lambda f, m=None: (cards.append(f), PNG)[1]},
                      video_fns={"week_loop": lambda f, out: out.write_bytes(MP4)}) as c:
        week_setup(c)
        sunday = datetime(2026, 10, 11, 19, 30, tzinfo=U)
        assert c.svc.plan_recap(sunday) == 1
        c.svc.run_outbox(sunday + timedelta(seconds=1))
        body = sqlite3.connect(c.svc.s.db_path).execute("SELECT body FROM cards WHERE kind='recap'").fetchone()[0]
        assert "load" not in body.lower()
    assert not set(LOAD_KEYS) & set(cards[0])


# --- the app's fixture, the contract flag, and old apps ------------------------------------------

def test_the_apps_load_fixture_validates_and_is_stored(client, fakes):
    import json
    from pathlib import Path
    body = json.loads((Path(__file__).parent / "fixtures" / "app_load_fields.json").read_text())
    m = RunIn.model_validate(body)
    assert (m.load, m.load_basis, m.load_state) == (118.4, "hr", "high")
    t = enrol(client)
    body = {**body, "start_utc": (datetime.now(U) - timedelta(hours=3)).isoformat()}
    assert client.post("/v1/runs", json=body, headers=auth(t)).status_code == 202
    c = sqlite3.connect(client.svc.s.db_path)
    assert c.execute("SELECT load, load_basis, load_state FROM runs").fetchone() == (118.4, "hr", "high")


def test_an_old_app_with_no_load_fields_still_uploads(client, fakes):
    t = enrol(client)
    assert client.post("/v1/runs", json=run_payload("old1", load_state="steady"), headers=auth(t)).status_code == 202
    assert _rows(client) == [("old1", None, None)]


def test_a_two_hour_run_at_a_high_weight_is_not_a_range_error():
    assert RunIn.model_validate({**run_payload("a1"), "load": 2100.0, "load_basis": "assumed"}).load == 2100.0


# --- a stale load_state steers nothing -------------------------------------------------------------

def test_the_evening_suggestion_honours_load_state_only_within_48_hours():
    from datetime import timezone as tz
    from companion.facts import suggest_evening
    from companion.convo import suggest
    t0 = datetime(2026, 10, 9, 20, 0, tzinfo=tz.utc)

    def h(hours_ago, **kw):
        r = mk(int(hours_ago), 0, 0, load_state=kw.pop("load_state", None))
        r["start_utc"] = t0 - timedelta(hours=hours_ago)
        return r
    fresh = [h(30, load_state="high"), h(80), h(130)]
    stale = [h(70, load_state="high"), h(120), h(170)]
    assert suggest_evening(fresh, t0).reason == "load"
    got = suggest_evening(stale, t0)
    assert got is None or got.reason != "load"
    assert suggest.evening(fresh, t0, None, {}, "s").suggestion.reason == "load"
    got = suggest.evening(stale, t0, None, {}, "s")
    assert got is None or got.suggestion is None or got.suggestion.reason != "load"


def _coach_tools(client, uid, now):
    from companion.coach.tools import ReadTools
    return ReadTools(client.svc, [], uid, now)


def _seed_runs(client, specs):
    """specs: (run_id, days_ago, load_state) against a fixed 'now'."""
    now = datetime(2026, 10, 20, 8, 0, tzinfo=U)
    t = enrol(client)
    c = sqlite3.connect(client.svc.s.db_path)
    uid = c.execute("SELECT id FROM users").fetchone()[0]
    for rid, days, ls in specs:
        start = now - timedelta(days=days)
        client.svc.ingest_run(uid, RunIn.model_validate(run_payload(
            rid, start_utc=start.isoformat(), zone_id="UTC", utc_offset_min=0, load_state=ls)), start + timedelta(hours=1))
    return uid, now


def test_get_stats_reports_only_the_newest_runs_state_and_only_within_7_days(client, fakes):
    uid, now = _seed_runs(client, [("a", 20, "high"), ("b", 2, None)])
    assert _coach_tools(client, uid, now).get_stats()["load_state"] is None     # newest is null: an old flag is not carried over


def test_get_stats_load_state_expires_after_7_days(client, fakes):
    uid, now = _seed_runs(client, [("a", 10, "high")])
    assert _coach_tools(client, uid, now).get_stats()["load_state"] is None
    assert _coach_tools(client, uid, now - timedelta(days=5)).get_stats()["load_state"] == "high"


def test_get_stats_keeps_a_fresh_newest_state(client, fakes):
    uid, now = _seed_runs(client, [("a", 9, None), ("b", 1, "very_high")])
    assert _coach_tools(client, uid, now).get_stats()["load_state"] == "very_high"


def test_the_run_list_hides_an_old_load_state(client, fakes):
    uid, now = _seed_runs(client, [("a", 12, "high"), ("b", 1, "high")])
    out = _coach_tools(client, uid, now).get_recent_runs(days=30)
    by_id = {r["run_id"]: r.get("load_state") for r in out["runs"]}
    assert by_id == {"a": None, "b": "high"}


# --- the words ------------------------------------------------------------------------------

ALARM = re.compile(r"too much load|fumes|pull the reins|back off|ease off|easing off|tired legs|training load|very high|nothing more|"
                   r"pay-back|stacked a lot|fix is boring|lost fitness|\bkeep\b|\bhold\b|back to\b|\bmust\b|\bshould\b|\bneed to\b", re.I)


def test_load_copy_is_descriptive_not_alarmist():
    from companion import facts as fx
    texts = []
    for sit in ("slower_load",):
        texts += [(sit, h, b) for h, b in voice.SITUATIONS[sit]]
    texts += [("sugg_easy_load", h, b) for h, b in voice.SUGGESTIONS["sugg_easy_load"]]
    for sit in ("recap_load_usual", "recap_load_step", "recap_load_jump", "recap_load_light"):
        texts += [(sit, h, b) for h, b in voice.RECAPS[sit]]
    for sit, h, b in texts:
        assert not ALARM.search(h + " " + b), (sit, h, b)
        if sit in ("slower_load", "sugg_easy_load") or sit.startswith("recap_load_") and sit != "recap_load_usual":
            assert "usual" in b, (sit, h, b)       # it names its reference
        if sit == "sugg_easy_load":
            assert re.search(r"rest|day off|your call|option|if you prefer|would fit", b), (sit, h, b)   # a choice, not an order
    run = {**mk(1, 0, 0, load_state="very_high"), "feel": None, "plan_kind": None, "plan_target_m": None,
           "verdict": None, "pb": None, "true_pace_s_per_km": 355.0}
    strings = [f.text for f in fx.build_facts(run, [], {}).facts if f.id == "load"]
    strings.append(fx.suggest_after_run(run, []).text)
    t0 = run["start_utc"] + timedelta(hours=20)
    strings.append(fx.suggest_evening([run, mk(2, 0, 0), mk(3, 0, 0)], t0).text)
    assert strings[0] == "Your last 7 days are well above your usual week"
    for t in strings:
        assert not ALARM.search(t), t
        assert "usual" in t


def test_build_with_unknown_pauses_stays_on_km():
    runs = week_of(450, flag=True)
    assert recap.build(runs, SUN, SG, {}, "w", paused_weeks=[]).rendered.situation == "recap_load_jump"
    rc = recap.build(runs, SUN, SG, {}, "w", paused_weeks=None)
    assert rc.rendered.situation in ("recap_up", "recap_down", "recap_flat") and rc.media.facts is None


def test_a_failing_care_week_lookup_gives_the_km_recap_not_a_missing_recap(tmp_path, fakes, monkeypatch):
    from test_channels_media import PNG, media_client
    import companion.service as svc_mod
    monkeypatch.setattr(svc_mod, "ci_care_weeks", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    with media_client(tmp_path, fakes, card_fns={"weekly_recap": lambda f, m=None: PNG}) as c:
        enrol(c)
        con = sqlite3.connect(c.svc.s.db_path)
        uid = con.execute("SELECT id FROM users").fetchone()[0]
        con.execute("UPDATE users SET checkin_consent=?, zone_id='UTC'", (c.svc.s.checkin_consent_required,))
        con.commit()
        for wk in range(6):
            for d in (0, 2):
                start = datetime(2026, 10, 12 + d, 6, 0, tzinfo=U) - timedelta(days=7 * wk)
                c.svc.ingest_run(uid, RunIn.model_validate(run_payload(
                    f"f{wk}{d}", start_utc=start.isoformat(), zone_id="UTC", utc_offset_min=0, duration_s=1800, distance_m=5000,
                    load=150.0 if wk else 225.0, load_basis="hr", load_state="high" if wk == 0 else None)), start + timedelta(hours=1))
        con.execute("UPDATE outbox SET state='done'")
        con.commit()
        cid = c.svc._build_recap_card(uid, "2026-W42", datetime(2026, 10, 18, 19, 30, tzinfo=U))
        assert cid
        body = con.execute("SELECT body FROM cards WHERE card_id=?", (cid,)).fetchone()[0]
        assert "load" not in body.lower()
