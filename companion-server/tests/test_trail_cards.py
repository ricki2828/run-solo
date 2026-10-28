"""Trail board and trail record cards: the protocol allow-list, the trigger rules, storage, the strict RunIn block, the
spoiler flag and its fallback. Nothing here needs Chromium (a recording worker stands in)."""
import copy
import json
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from companion import db
from companion import trail as T
from companion.channels import ChannelError
from companion.service import RunIn
from render import protocol as P
from render.cards import fixtures as F
from test_more_cards import NOW, UID, Env, Rec

UTC = timezone.utc


def board(rows, today):
    return [{"attempt": a, "time_s": t, **({"today": True} if a == today else {})} for a, t in rows]


def trail_block(rows, today, n=None, **extra):
    return {"n": n or len(rows), "board": board(rows, today), "profile": F._trail_profile(), "shape": "out_and_back", **extra}


# ---------------------------------------------------------------- protocol

@pytest.mark.parametrize("name", sorted(F.TRAIL_CARDS))
def test_every_fixture_passes_the_protocol(name):
    kind, fn = F.TRAIL_CARDS[name]
    P.check_request({"v": 1, "op": "card", "kind": kind, "facts": fn()})


@pytest.mark.parametrize("mutate", [
    lambda f: f.update(route_xy=[[0, 0], [255, 255]]),                        # a shape key on a trail card
    lambda f: f.update(trail_name="x" * 31),
    lambda f: f.update(elev_profile=[0.5, 1.5]),                              # floats cannot pass: no coordinates
    lambda f: f.update(elev_profile=list(range(65))),
    lambda f: f.update(elev_profile=[0, 99999]),
    lambda f: f.update(ghost_gap=[0, 5000]),
    lambda f: f.update(turn_idx=99),
    lambda f: f.update(trail_shape="figure_eight"),
    lambda f: f.update(trail_board=[{"attempt": 1, "time_s": 100, "date": "2026-10-01"}, {"attempt": 2, "time_s": 90, "today": True}]),
    lambda f: f.update(trail_board=[{"attempt": 1, "time_s": 100}, {"attempt": 2, "time_s": 90}]),           # no today row
    lambda f: f.update(trail_board=f["trail_board"] + [{"attempt": 40 + i, "time_s": 4000} for i in range(6)]),  # over 10
    lambda f: f.update(lat=1.0),
    lambda f: f.update(type="easy"),
])
def test_the_protocol_refuses_anything_off_the_list(mutate):
    f = F.trail_record_six()
    mutate(f)
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "trail_record", "facts": f})


def test_trail_keys_are_refused_on_other_cards():
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "pb", "facts": {"type": "trail", "distance_km": 5, "duration_s": 900,
                                                                       "elev_profile": [0, 1, 2]}})


# ---------------------------------------------------------------- trigger rules

def test_record_beats_board_and_board_starts_at_the_third_run():
    rec = T.parse(trail_block([(1, 4000), (2, 3900), (3, 3800)], 3)).model_dump()
    assert T.card_kind(rec) == "trail_record"
    third = T.parse(trail_block([(1, 4000), (2, 3800), (3, 3900)], 3)).model_dump()
    assert T.card_kind(third) == "trail_board"
    second = T.parse(trail_block([(1, 3900), (2, 4000)], 2)).model_dump()
    assert T.card_kind(second) is None        # the 2nd run, not a best, no card
    first_best = T.parse(trail_block([(1, 4000), (2, 3900)], 2)).model_dump()
    first_best["board"][1]["time_s"] = 3000
    assert T.card_kind(first_best) == "trail_record"
    tie = T.parse(trail_block([(1, 3800), (2, 4000), (3, 3800)], 3)).model_dump()
    assert T.card_kind(tie) == "trail_board"  # level with the best is not a record


def test_a_bad_trail_block_is_dropped_not_the_run():
    p = {"run_id": "r1", "type": "trail", "start_utc": "2026-10-13T08:00:00Z", "utc_offset_min": 0, "zone_id": "UTC",
         "duration_s": 3600, "distance_m": 9600}
    assert RunIn.model_validate(p | {"trail": {"n": 3, "board": []}}).trail is None
    assert RunIn.model_validate(p | {"trail": {**trail_block([(1, 1), (2, 2)], 2), "lat": 1.2}}).trail is None
    assert RunIn.model_validate(p | {"trail": trail_block([(1, 4000), (2, 3900)], 2)}).trail is not None
    assert RunIn.model_validate(p).trail is None


# ---------------------------------------------------------------- end to end

@pytest.fixture
def env(tmp_path):
    return Env(tmp_path, Rec())


def trail_run(e: Env, i, trail, start=None):
    start = start or datetime(2026, 10, 1 + i, 7, 0, tzinfo=UTC)
    return e.run(i, start, "trail", 9.6, climb_m=412, trail=trail)


def test_trail_best_sends_the_record_card_with_a_spoiler_and_stores_the_block(env):
    trail_run(env, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3, ghost_gap=F._trail_gap()))
    env.quiet_outbox()
    cid = env.svc._build_run_card(UID, "r01", NOW)
    plan = json.loads(env.q("SELECT media_json FROM convo_cards WHERE card_id=?", cid)[0]["media_json"])
    assert plan["card"] == "trail_record" and plan["video"] is False and plan["reason"] == "trail_pb"
    assert env.svc._send_card(env.user(), cid, NOW)
    kind, facts = env.rec.sent[-1]
    assert kind == "trail_record" and facts["type"] == "trail" and len(facts["elev_profile"]) == 64
    assert "route_xy" not in facts and "start_local" not in facts
    (photo,) = env.photos()
    assert photo["has_spoiler"] == "true"
    stored = env.q("SELECT trail_json FROM run_shape WHERE run_id='r01'")[0]["trail_json"]
    assert "profile" in json.loads(stored)


def test_board_card_after_three_runs_and_once_per_run(env):
    trail_run(env, 1, trail_block([(1, 3700), (2, 3900), (3, 3800)], 3, n=3))
    env.quiet_outbox()
    cid = env.svc._build_run_card(UID, "r01", NOW)
    assert json.loads(env.q("SELECT media_json FROM convo_cards WHERE card_id=?", cid)[0]["media_json"])["card"] == "trail_board"
    assert env.svc._build_run_card(UID, "r01", NOW) == cid          # idempotent: never a second card for the run
    assert len(env.q("SELECT 1 FROM cards WHERE run_id='r01' AND kind='run'")) == 1


def test_the_switch_turns_the_trail_cards_off(tmp_path):
    e = Env(tmp_path, Rec(), trail_cards=False)
    trail_run(e, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3))
    e.quiet_outbox()
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert json.loads(e.q("SELECT media_json FROM convo_cards WHERE card_id=?", cid)[0]["media_json"])["card"] != "trail_record"


def test_spoiler_can_be_switched_off(tmp_path):
    e = Env(tmp_path, Rec(), trail_spoiler=False)
    trail_run(e, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3))
    e.quiet_outbox()
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    assert "has_spoiler" not in e.photos()[0]


def test_a_road_run_never_gets_a_spoiler(env):
    env.run(1, datetime(2026, 10, 2, 7, 0, tzinfo=UTC), "easy", 7.0)
    env.quiet_outbox()
    cid = env.svc._build_run_card(UID, "r01", NOW)
    if cid and env.svc._send_card(env.user(), cid, NOW) and env.photos():
        assert "has_spoiler" not in env.photos()[0]


def test_the_route_switch_off_keeps_the_trail_block_for_the_own_chat(env):
    trail_run(env, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3))
    env.svc.set_settings(UID, None, None, None, route_shape=False)
    assert env.q("SELECT trail_json FROM run_shape WHERE run_id='r01'")[0]["trail_json"]


def test_the_export_shows_the_trail_block(env):
    trail_run(env, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3))
    shapes = env.svc.get_me(UID)["run_shapes"]
    assert shapes[0]["trail"]["board"][2]["today"] is True


def test_a_refused_spoiler_falls_back_to_the_plain_photo(tmp_path):
    from companion.channels import OutCard, TelegramChannel
    from companion.media import Media
    import httpx
    from conftest import make_settings
    calls = []

    def fake(self, method, payload, files=None):
        calls.append((method, dict(payload)))
        if "has_spoiler" in payload:
            raise ChannelError("bad request: spoiler", permanent=True)
        return {"result": {"message_id": 7}}
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client())
    ch._call = fake.__get__(ch)
    out = OutCard("c1", "h", "b", [], Media(photo=b"png", spoiler=True), ())
    assert ch._send_media("123", out, "caption") == "7"
    assert ["has_spoiler" in p for _, p in calls] == [True, False]


def test_the_cards_render_at_full_size_when_chromium_is_present():
    pytest.importorskip("playwright")
    from render.cards import _engine
    from render.cards.trail import render_trail_board, render_trail_heart, render_trail_record
    try:
        _engine._ensure_browser()
    except Exception:
        pytest.skip("no chromium")
    for name, (kind, fn) in F.TRAIL_CARDS.items():
        png = {"trail_board": render_trail_board, "trail_heart": render_trail_heart}.get(kind, render_trail_record)(fn(), {})
        assert png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) < 10 * 1024 * 1024, name


@pytest.mark.parametrize("name", ["12345", "@rickirun", "see www.trails.com", "https://x.io/a", "trail.com", "a@b", " lead", "+64 21 555 1234", "insta: bobruns",
                                  "0211234567", "call 021 555", "tiktok: bob", "strava", "ig@bob", "bob\uff20gmail\uff0ecom", "\uff57\uff57\uff57\uff0ebob\uff0ecom", "go:bobruns", "line\nbreak", "x\u202eevil"])
def test_a_trail_name_that_is_a_handle_a_link_or_digits_is_refused(name):
    f = F.trail_record_six()
    f["trail_name"] = name
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "trail_record", "facts": f})
    t = T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "name": name})
    assert t is not None and t.name is None          # the server keeps the trail and drops only the name


def test_good_names_pass():
    for name in ("The Saddle Trail", "Mt Eden loop", "Parkrun 5k"):
        assert T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "name": name}).name == name


def test_elev_src_is_an_enum_and_reaches_the_card_facts():
    assert T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "elev_src": "radar"}) is None
    t = T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "elev_src": "gps"}).model_dump(exclude_none=True)
    run = {"duration_s": 3600, "distance_m": 9600, "pace_s_per_km": 375, "climb_m": 100}
    assert T.card_facts(run, t)["elev_src"] == "gps"


def test_ghost_gap_positive_means_ahead_on_the_card():
    from render.cards.trail import _halves
    f = F.trail_record_six()
    first, second = _halves(f, f["ghost_gap"], f["elev_profile"])
    assert first[0] > 0 and second[0] > 0 and f["ghost_gap"][-1] == 41


def test_trail_block_is_deleted_30_days_after_the_run(env):
    trail_run(env, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3), start=datetime(2026, 8, 1, 7, 0, tzinfo=UTC))
    assert env.q("SELECT trail_json FROM run_shape")[0]["trail_json"]
    env.svc.purge(NOW)
    assert env.q("SELECT trail_json FROM run_shape") == []


def test_a_float_metre_label_renders_as_a_whole_number():
    from render.cards.trail import profile_svg
    prof = [0, 40, 120, 250, 381.8666666666667, 300, 200, 100, 20]
    svg = profile_svg(prof, 5000, 936, 232, turn_idx=4, baro=True)
    assert "382 M" in svg and "381.86" not in svg


def test_a_gap_in_the_ranks_gets_a_spacer_row():
    from render.cards.trail import build_trail_board_html
    gapped = build_trail_board_html(F.trail_board_many_runs())
    assert "···" in gapped
    assert "···" not in build_trail_board_html(F.trail_board_five())


def test_a_spoilered_photo_keeps_the_verdict_out_of_the_caption(env):
    env.svc.set_settings(UID, None, None, None, place_names=True)
    trail_run(env, 1, trail_block([(1, 3700), (2, 3900), (3, 3800)], 3, n=3, name="The Saddle Trail"))
    env.quiet_outbox()
    cid = env.svc._build_run_card(UID, "r01", NOW)
    card = env.q("SELECT headline, body FROM cards WHERE card_id=?", cid)[0]
    assert env.svc._send_card(env.user(), cid, NOW)
    (photo,) = env.photos()
    assert photo["has_spoiler"] == "true"
    assert photo["caption"] == "Trail run 3 on The Saddle Trail. Tap to see how it went."
    assert card["headline"] not in photo["caption"] and card["body"] not in photo["caption"]
    with db.ro(env.s.db_path) as c:
        refs = [r["ref"] for r in c.execute("SELECT ref FROM outbox WHERE kind='followup'")]
    assert f"{cid}:coach_line" in refs
    env.svc._send_followup(env.user(), f"{cid}:coach_line", NOW)
    import html
    sent = [b for m, b in env.fakes.tg if m == "sendMessage"][-1]
    assert sent["parse_mode"] == "HTML"
    assert sent["text"] == "<tg-spoiler>" + html.escape(f"{card['headline']}\n{card['body']}", quote=False) + "</tg-spoiler>"


def test_board_rank_with_more_than_ten_runs():
    from render.cards.trail import build_trail_board_html
    rows = [(1, 3600), (17, 3650), (18, 3700), (19, 3750), (20, 3720)]
    f = F.trail_board_five() | {"trail_runs": 20, "trail_board": board(rows, 20)}
    for r in f["trail_board"]:
        r["rank"] = {1: 1, 17: 12, 18: 14, 19: 16, 20: 15}[r["attempt"]]
    P.check_request({"v": 1, "op": "card", "kind": "trail_board", "facts": f})
    html_ = build_trail_board_html(f)
    assert "15TH FASTEST" in html_ and "···" in html_
    for r in f["trail_board"]:
        del r["rank"]
    P.check_request({"v": 1, "op": "card", "kind": "trail_board", "facts": f})
    bare = build_trail_board_html(f)
    assert "FASTEST" not in bare and "JOINT BEST" not in bare and "···" not in bare
    assert "TWENTY TIMES UP." in bare


def test_ordinals_and_n_against_the_board():
    from render.cards.trail import _ordinal
    assert [_ordinal(x) for x in (4, 11, 12, 21, 22, 103)] == ["4TH", "11TH", "12TH", "21ST", "22ND", "103RD"]
    assert T.parse(trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=2)) is None
    f = F.trail_record_six() | {"trail_runs": 2}
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "trail_record", "facts": f})


def test_the_name_is_dropped_unless_the_place_opt_in_is_on(env):
    trail_run(env, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3, name="The Saddle Trail"))
    assert "name" not in json.loads(env.q("SELECT trail_json FROM run_shape WHERE run_id='r01'")[0]["trail_json"])
    env.svc.set_settings(UID, None, None, None, place_names=True)
    trail_run(env, 2, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3, name="The Saddle Trail"))
    assert json.loads(env.q("SELECT trail_json FROM run_shape WHERE run_id='r02'")[0]["trail_json"])["name"] == "The Saddle Trail"
    env.svc.set_settings(UID, None, None, None, place_names=False)       # switching it off forgets stored names now
    assert "name" not in json.loads(env.q("SELECT trail_json FROM run_shape WHERE run_id='r02'")[0]["trail_json"])
    assert env.svc.get_me(UID)["profile"]["place_names_on_cards"] is False


@pytest.mark.parametrize("name", ["Te Araroa: Section 4", "Snap Hill Track", "Big Ig Loop", "Strava Hill", "Tiktok Ridge"])
def test_honest_trail_names_are_not_refused(name):
    f = F.trail_record_six() | {"trail_name": name}
    P.check_request({"v": 1, "op": "card", "kind": "trail_record", "facts": f})
    assert T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "name": name}).name == name


def test_a_fullwidth_name_is_normalised_before_it_is_filtered():
    assert T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "name": "bob\uff20gmail\uff0ecom"}).name is None
    assert T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "name": "\uff57\uff57\uff57\uff0ebob\uff0ecom"}).name is None
    assert T.parse({**trail_block([(1, 3900), (2, 3800)], 2), "name": "Ｔｈｅ Ｓａｄｄｌｅ"}).name == "The Saddle"


def test_the_spoiler_line_falls_back_to_plain_text_on_a_parse_error(tmp_path):
    from companion.channels import OutCard, TelegramChannel
    import httpx
    from conftest import make_settings
    calls = []

    def fake(self, method, payload, files=None):
        calls.append(dict(payload))
        if payload.get("parse_mode") == "HTML":
            raise ChannelError("bad", status=400, description="Bad Request: can't parse entities")
        return {"result": {"message_id": 9}}
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client())
    ch._call = fake.__get__(ch)
    assert ch.send_followup("123", OutCard("c1", "Head", "Body <b>", [], None, ()), "coach_line") == "9"
    assert calls[0]["text"].startswith("<tg-spoiler>") and "parse_mode" not in calls[1] and calls[1]["text"] == "Head\nBody <b>"

def test_tied_times_do_not_draw_a_spacer_but_a_real_skip_does():
    from render.cards.trail import _rows_html
    row = lambda a, t, **k: {"attempt": a, "time_s": t, **k}  # noqa: E731
    tied = [(1, row(1, 3600)), (2, row(2, 3650)), (2, row(3, 3650)), (4, row(4, 3700, today=True))]
    assert "···" not in _rows_html(tied, 3600, 900, 66)
    skipped = [(1, row(1, 3600)), (2, row(2, 3650)), (5, row(5, 3900, today=True))]
    assert "···" in _rows_html(skipped, 3600, 900, 66)


def test_a_zero_distance_run_and_a_gone_block_do_not_break_the_card():
    t = T.parse(trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3)).model_dump(exclude_none=True)
    facts = T.card_facts({"duration_s": 60, "distance_m": 0, "pace_s_per_km": None, "climb_m": None}, t)
    assert "distance_km" not in facts
    P.check_request({"v": 1, "op": "card", "kind": "trail_record", "facts": facts})


def test_a_dropped_trail_block_is_logged_without_its_values(caplog):
    p = {"run_id": "r1", "type": "trail", "start_utc": "2026-10-13T08:00:00Z", "utc_offset_min": 0, "zone_id": "UTC",
         "duration_s": 3600, "distance_m": 9600}
    with caplog.at_level("WARNING", logger="companion"):
        assert RunIn.model_validate(p | {"trail": {"n": 3, "board": []}}).trail is None
    assert any("trail block dropped" in r.getMessage() for r in caplog.records)
    caplog.clear()
    with caplog.at_level("WARNING", logger="companion"):
        assert RunIn.model_validate(p | {"trail": trail_block([(1, 4000), (2, 3900)], 2)}).trail is not None
    assert not caplog.records
