"""Heart vs hill: the hr series on a trail block. Health data, so: off by default, stored only while the runner's
"Heart rate on cards" switch is on, forgotten the moment it goes off, and sent to the worker only for the card that draws it."""
import json

import pytest

from companion import trail as T
from render import protocol as P
from render.cards import fixtures as F
from test_trail_cards import UID, board, env, trail_block, trail_run  # noqa: F401  (env is a fixture)

ROWS = [(1, 3900), (2, 3800), (3, 3700)]   # run 3 is the best: a record, not a board
BOARD_ROWS = [(1, 3700), (2, 3900), (3, 3800)]


def hr_block(rows=BOARD_ROWS, **extra):
    hr, z = F._heart_series(F._trail_profile(), True)
    return trail_block(rows, 3, n=3, hr=hr, hr_z=z, **extra)


def stored(env, rid="r01"):
    return json.loads(env.q("SELECT trail_json FROM run_shape WHERE run_id=?", rid)[0]["trail_json"])


# ---------------------------------------------------------------- the block

def test_the_app_block_parses_with_one_bpm_and_zone_per_profile_point():
    t = T.parse(hr_block())
    assert t is not None and len(t.hr) == len(t.hr_z) == len(t.profile) == 64


@pytest.mark.parametrize("mutate", [
    lambda b: b.update(hr=b["hr"][:-1]),                                   # not one per profile point
    lambda b: b.update(hr_z=b["hr_z"][:-1]),
    lambda b: b.pop("hr_z"),                                               # a series without the runner's zones
    lambda b: b.pop("hr"),
    lambda b: b.update(hr=[29] + b["hr"][1:]),
    lambda b: b.update(hr=[251] + b["hr"][1:]),
    lambda b: b.update(hr=[150.5] + b["hr"][1:]),
    lambda b: b.update(hr_z=[6] + b["hr_z"][1:]),
    lambda b: b.update(hr_z=[0] + b["hr_z"][1:]),
    lambda b: b.update(hr=[True] * 64),
    lambda b: b.pop("profile"),                                            # nothing to lay the heart over
    lambda b: b.update(hr_z=[1] * 63 + [5]),                               # the last, lowest bpm in the top zone, the rest low
    lambda b: b.update(hr=[100] + [170] * 63, hr_z=[5] + [1] * 63),        # a zone that falls as the bpm rises
])
def test_a_bad_hr_series_costs_only_the_heart_rate_never_the_block(mutate):
    b = hr_block()
    mutate(b)
    t = T.parse(b)
    assert t is not None and t.hr is None and t.hr_z is None and len(t.board) == 3   # the board still gets its card


def test_hr_is_kept_only_while_the_switch_is_on(env):
    trail_run(env, 1, hr_block())
    s = stored(env)
    assert "hr" not in s and "hr_z" not in s                               # off by default: the server drops it even if sent
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    assert env.svc.get_me(UID)["profile"]["heart_rate_on_cards"] is True
    trail_run(env, 2, hr_block())
    s = stored(env, "r02")
    assert len(s["hr"]) == 64 and len(s["hr_z"]) == 64


def test_switching_it_off_forgets_every_stored_series_now(env):
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block(name="The Saddle Trail"))
    env.svc.set_settings(UID, None, None, None, heart_rate=False)
    s = stored(env)
    assert "hr" not in s and "hr_z" not in s and s["board"] and s["profile"]   # only the heart goes; the rest of the block stays
    assert env.svc.get_me(UID)["profile"]["heart_rate_on_cards"] is False
    assert "hr" not in env.q("SELECT trail_json FROM run_shape")[0]["trail_json"].replace('"hr_', "")


def test_the_series_is_deleted_with_the_trail_block_after_30_days(env):
    from datetime import datetime, timezone
    from test_more_cards import NOW
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block(), start=datetime(2026, 8, 1, 7, 0, tzinfo=timezone.utc))
    assert "hr" in stored(env)
    env.svc.purge(NOW)
    assert env.q("SELECT trail_json FROM run_shape") == []


def test_the_export_carries_the_series(env):
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block())
    me = env.svc.get_me(UID)                                               # the runner's own data export: what we hold, they can see
    assert len(me["run_shapes"][0]["trail"]["hr"]) == 64


# ---------------------------------------------------------------- which card

def test_a_board_run_with_a_series_is_the_heart_card_and_a_record_stays_a_record():
    assert T.card_kind(T.load(json.dumps(hr_block()))) == "trail_heart"
    rec = hr_block(ROWS)
    assert T.card_kind(T.load(json.dumps(rec))) == "trail_record"
    plain = trail_block(BOARD_ROWS, 3, n=3)
    assert T.card_kind(T.load(json.dumps(plain))) == "trail_board"


def test_the_worker_gets_the_series_only_on_the_heart_card(env):
    from test_more_cards import NOW
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block())
    env.quiet_outbox()
    cid = env.svc._build_run_card(UID, "r01", NOW)
    plan = json.loads(env.q("SELECT media_json FROM convo_cards WHERE card_id=?", cid)[0]["media_json"])
    assert plan["card"] == "trail_heart"
    assert env.svc._send_card(env.user(), cid, NOW)
    kind, facts = env.rec.sent[-1]
    assert kind == "trail_heart" and len(facts["hr_series"]) == len(facts["hr_zones"]) == len(facts["elev_profile"])
    assert "route_xy" not in facts and "start_local" not in facts


def test_a_record_with_a_series_never_sends_it_to_the_worker(env):
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block(ROWS))
    env.quiet_outbox()
    from test_more_cards import NOW
    cid = env.svc._build_run_card(UID, "r01", NOW)
    assert env.svc._send_card(env.user(), cid, NOW)
    kind, facts = env.rec.sent[-1]
    assert kind == "trail_record" and "hr_series" not in facts and "hr_zones" not in facts


# ---------------------------------------------------------------- the render protocol

@pytest.mark.parametrize("name", ["trail_heart_outlasts", "trail_heart_peaked_early"])
def test_the_heart_fixtures_pass_the_protocol(name):
    kind, fn = F.TRAIL_CARDS[name]
    P.check_request({"v": 1, "op": "card", "kind": kind, "facts": fn()})


@pytest.mark.parametrize("mutate", [
    lambda f: f.update(hr_series=f["hr_series"][:-1]),
    lambda f: f.update(hr_zones=f["hr_zones"][:-1]),
    lambda f: f.update(hr_series=[300] * 64),
    lambda f: f.update(hr_zones=[7] * 64),
    lambda f: f.update(hr_series=[150.2] * 64),
    lambda f: f.pop("hr_zones"),
    lambda f: f.pop("hr_series"),
    lambda f: f.pop("elev_profile"),
    lambda f: f.update(avg_hr=150),
])
def test_the_protocol_refuses_a_malformed_heart_card(mutate):
    f = F.trail_heart_outlasts()
    mutate(f)
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "trail_heart", "facts": f})


@pytest.mark.parametrize("kind", ["trail_board", "trail_record"])
def test_the_series_is_refused_on_the_other_trail_cards(kind):
    f = F.trail_heart_outlasts()
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": kind, "facts": f})


# ---------------------------------------------------------------- the hook

def test_the_hook_line_is_only_claimed_when_the_heart_outlasted_the_hill():
    from render.cards.trail import _heart_hook
    hot = F.trail_heart_outlasts()
    line, top, peak = _heart_hook(hot["elev_profile"], hot["hr_series"])
    assert line.startswith("THE HILL STOPPED AT 98 M.") and "DIDN'T" in line and peak >= top
    early = F.trail_heart_peaked_early()
    line, top, peak = _heart_hook(early["elev_profile"], early["hr_series"])
    assert "DIDN'T" not in line and "THE HEART PEAKED FIRST" in line and "176" not in line and peak < top


def test_a_flat_trail_gets_no_hill_line():
    from render.cards.trail import _heart_hook
    assert _heart_hook([0, 2, 3, 2, 1, 0, 1, 0], [140, 150, 160, 158, 155, 150, 149, 148])[0] == "HOW YOUR HEART RAN IT."


def test_the_card_draws_the_zone_colours_the_app_sent():
    from render.cards.trail import build_trail_heart_html
    from render import brand
    html_ = build_trail_heart_html(F.trail_heart_outlasts())
    assert "HEART VS HILL" in html_ and brand.ZONE_RAMP[4] in html_ and "STOPPED AT 98" in html_


# ---------------------------------------------------------------- the app's wire example

def test_the_apps_json_fixtures_pass_the_server_validator():
    """test/fixtures/*.json are the blocks the app's tests check against the same rules; the server must keep them whole."""
    from pathlib import Path
    root = Path(__file__).resolve().parents[2] / "test" / "fixtures"
    plain = T.parse(json.loads((root / "trail_block_sample.json").read_text()))
    assert plain is not None and plain.hr is None
    heart = T.parse(json.loads((root / "trail_block_hr_sample.json").read_text()))
    assert heart is not None and len(heart.hr) == len(heart.hr_z) == len(heart.profile) == 64
    stored = json.loads(T.dump(heart, keep_hr=True))
    assert stored["hr"] == heart.hr and stored["hr_z"] == heart.hr_z
    assert "hr" not in json.loads(T.dump(heart))                           # the second lock: no switch, no series
    facts = T.card_facts({"duration_s": 2310, "distance_m": 6000, "pace_s_per_km": 385}, json.loads(T.dump(heart, keep_hr=True)))
    P.check_request({"v": 1, "op": "card", "kind": "trail_heart", "facts": facts})


# ---------------------------------------------------------------- review fixes

def test_the_hook_metres_are_the_climb_stat_when_the_app_sent_one():
    from render.cards.trail import _heart_hook
    f = F.trail_heart_outlasts()
    assert _heart_hook(f["elev_profile"], f["hr_series"], 143)[0].startswith("THE HILL STOPPED AT 143\u00a0M")


def test_the_peak_label_stays_on_the_card():
    import re
    from render.cards.trail import heart_svg
    f = F.trail_heart_outlasts()
    top = max(range(64), key=lambda i: f["hr_series"][i])
    svg = heart_svg(f["elev_profile"], f["hr_series"], f["hr_zones"], 936, 392, 31, top)
    ys = [float(y) for y in re.findall(r'<text [^>]*y="(-?[\d.]+)"', svg)]
    assert ys and min(ys) >= 30


def test_hr_is_stored_only_for_a_board_run(env):
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block(ROWS))                                       # a record: its card never draws the heart
    assert "hr" not in stored(env) and "hr_z" not in stored(env)
    trail_run(env, 2, hr_block())
    assert "hr" in stored(env, "r02")


def test_the_nightly_backup_leaves_the_heart_rate_out(env, tmp_path):
    from companion.backup import backup, restore
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block())
    assert "hr" in stored(env)
    key = tmp_path / "k"
    key.write_text("0123456789abcdef0123456789abcdef")
    enc = backup(env.s.db_path, str(tmp_path / "bk"), str(key))
    out = tmp_path / "restored.db"
    restore(enc, str(out), str(key))
    import sqlite3
    t = json.loads(sqlite3.connect(out).execute("SELECT trail_json FROM run_shape WHERE run_id='r01'").fetchone()[0])
    assert "hr" not in t and "hr_z" not in t and t["board"] and t["profile"]
    assert "hr" in stored(env)                                              # the live copy is untouched


def test_a_switch_off_while_the_card_is_queued_sends_the_board_not_text(env):
    from test_more_cards import NOW
    env.svc.set_settings(UID, None, None, None, heart_rate=True)
    trail_run(env, 1, hr_block())
    env.quiet_outbox()
    cid = env.svc._build_run_card(UID, "r01", NOW)
    env.svc.set_settings(UID, None, None, None, heart_rate=False)           # the card is already planned as trail_heart
    assert env.svc._send_card(env.user(), cid, NOW)
    kind, facts = env.rec.sent[-1]
    assert kind == "trail_board" and "hr_series" not in facts
