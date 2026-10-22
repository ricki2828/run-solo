"""Cards v4 PR 2: a run, the weekly recap and a milestone go out as moment loops (sendAnimation), the still card riding
beside as thumbnail and fallback. Fakes stand in for the worker, as in test_ghost_clip.py."""
import io
import json

import httpx
import pytest
from PIL import Image

from companion.channels import OutCard, TelegramChannel
from companion.media import LOOP_S, Media, MediaRenderer, loop_facts, score_line, thumbnail
from conftest import make_settings

MP4 = b"\x00\x00\x00\x18ftypmp42" + b"0" * 64


def png() -> bytes:
    b = io.BytesIO()
    Image.new("RGB", (1080, 1350), "#223344").save(b, "PNG")
    return b.getvalue()


PNG = png()
ROUTE = [[0, 0], [100, 60], [200, 200], [255, 255]]
SPLITS = [{"dist_km": 1.0, "pace_s": 340, "zone": 2}] * 5
ROW = {"run_id": "r1", "user_id": "u1", "type": "easy", "start_utc": "2026-10-10T06:00:00+00:00", "zone_id": "Pacific/Auckland",
       "distance_m": 5000, "duration_s": 1800, "pace_s_per_km": 360, "climb_m": 20, "verdict": "holding",
       "zone_min": {"z1": 5, "z2": 20, "z3": 5}, "_shape": {"route": ROUTE, "splits": SPLITS}}
CARD = {"run_id": "r1", "headline": "5.0 km"}


def renderer(seen=None, fail=False):
    def video(facts, out):
        if fail:
            raise RuntimeError("ffmpeg")
        (seen if seen is not None else []).append(facts)
        out.write_bytes(MP4)
    still = lambda f, m: PNG   # noqa: E731
    return MediaRenderer({k: still for k in ("light", "flood", "pb", "share", "weekly_recap", "milestone")},
                         {"run_loop": video, "week_loop": video, "milestone_loop": video})


def test_an_easy_run_with_splits_is_a_loop_even_when_no_video_was_planned():
    seen = []
    m = renderer(seen).render({"card": "light", "video": False}, CARD, [ROW])
    assert m.animation and m.video == MP4 and m.duration_s == LOOP_S and m.clip_kind == "run_loop"
    assert m.photo == PNG and m.thumbnail and Image.open(io.BytesIO(m.thumbnail)).format == "JPEG"
    assert max(Image.open(io.BytesIO(m.thumbnail)).size) <= 320


def test_a_run_without_a_route_shape_still_gets_the_loop():
    row = {**ROW, "_shape": {"route": None, "splits": SPLITS}}
    seen = []
    m = renderer(seen).render({"card": "light", "video": False}, CARD, [row])
    assert m.animation and "route_xy" not in seen[0] and seen[0]["splits"]


def test_a_run_with_no_splits_stays_a_still():
    row = {**ROW, "_shape": {"route": ROUTE, "splits": None}}
    m = renderer().render({"card": "light", "video": False}, CARD, [row])
    assert not m.animation and m.video is None and m.photo == PNG


def test_a_failed_loop_falls_back_to_the_still():
    m = renderer(fail=True).render({"card": "flood", "video": True}, CARD, [ROW])
    assert not m.animation and m.photo == PNG and m.thumbnail is None


def test_loop_off_keeps_the_still():
    m = renderer().render({"card": "light", "video": False}, CARD, [ROW], loop=False)
    assert not m.animation and m.photo == PNG


def test_a_loop_that_rendered_once_is_not_rendered_again_for_a_retry():
    seen = []
    r = renderer(seen)
    for _ in range(3):
        r.render({"card": "light", "video": False}, CARD, [ROW])
    assert len(seen) == 1


def test_loop_facts_carry_only_run_keys():
    from render import protocol as P
    f = loop_facts({"type": "easy", "distance_km": 5, "duration_s": 1800, "splits": SPLITS, "pb": "5k",
                    "pb_detail": {"label": "5 KM BEST", "previous_s": 1500}}, None, None)
    assert f and set(f) <= P.RUN_KEYS and f["pb"] == "5k" and f["pb_detail"] == {"label": "5 KM BEST"}
    assert loop_facts({"type": "easy", "distance_km": 5}, None, None) is None


def test_the_weekly_lane_scores_move_into_the_caption():
    assert score_line({"aerobic": 3, "speed": 5, "mid": 0, "long": -2}) == "Aerobic +3 · Speed +5 · Mid 0 · Long -2"
    assert score_line(None) == ""


def test_a_milestone_touch_is_a_loop_with_its_still_beside_it():
    plan = {"touch_card": "milestone", "touch_facts": {"kind": "distance_km", "value": 1000, "line": "A lot of early mornings."}}
    m = renderer().render_touch(plan)
    assert m.animation and m.video == MP4 and m.photo == PNG and m.clip_kind == "milestone_loop"
    assert not renderer(fail=True).render_touch(plan).animation   # the still alone


def test_thumbnail_survives_garbage():
    assert thumbnail(b"not a png") is None and thumbnail(None) is None


def test_the_animation_goes_up_with_its_thumbnail_and_falls_back_to_the_photo(tmp_path):
    calls = []

    def fake(self, method, payload, files=None):
        calls.append((method, sorted(files or {})))
        if method == "sendAnimation":
            from companion.channels import ChannelError
            raise ChannelError("bad", status=400, permanent=True)
        return {"result": {"message_id": 7}}
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client())
    ch._call = fake.__get__(ch)
    m = Media(photo=PNG, video=MP4, animation=True, duration_s=LOOP_S, thumbnail=thumbnail(PNG))
    assert ch.send_card("5", OutCard("c1", "h", "b", [], m)) == "7"
    assert calls == [("sendAnimation", ["animation", "thumbnail"]), ("sendPhoto", ["photo"])]


# ---------------------------------------------------------------- the Share button, the file_id cache

import sqlite3
from datetime import timedelta

from fastapi.testclient import TestClient

from companion.app import create_app
from companion.timeutil import now_utc
from conftest import auth, enrol, post_tg, run_payload, shape_payload, tg_callback


def _q(c, sql, *a):
    con = sqlite3.connect(c.svc.s.db_path)
    con.row_factory = sqlite3.Row
    return [dict(r) for r in con.execute(sql, a)]


FAIL_FIRST_POSTER = False


@pytest.fixture
def loop_client(tmp_path, fakes):
    """A service whose renderer is fake: every still is PNG, every loop MP4, and `shares` counts poster renders."""
    shares = []

    def share(f, m):
        shares.append(f)
        if len(shares) == 1 and FAIL_FIRST_POSTER:
            raise RuntimeError("chromium")
        return PNG
    s = make_settings(tmp_path, media_enabled=True)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    app.state.svc.media = MediaRenderer(
        {**{k: (lambda f, m: PNG) for k in ("light", "flood", "pb", "weekly_recap")}, "share": share},
        {"run_loop": lambda facts, out: out.write_bytes(MP4), "week_loop": lambda facts, out: out.write_bytes(MP4)})
    with TestClient(app) as c:
        c.svc, c.shares = app.state.svc, shares
        yield c
    globals()["FAIL_FIRST_POSTER"] = False


def _send_run(c):
    t = enrol(c)
    c.post("/v1/runs", json=run_payload("r1", **shape_payload(5000, 1800)), headers=auth(t))
    c.svc.run_outbox(now_utc() + timedelta(seconds=1))
    return t


def _share_idx(c, card_id):
    import json
    buttons = json.loads(_q(c, "SELECT buttons_json FROM cards WHERE card_id=?", card_id)[0]["buttons_json"])
    return next(i for i, b in enumerate(buttons) if b["action"] == "share:poster")


def test_the_loop_message_carries_a_share_button_that_sends_the_poster_once(loop_client, fakes):
    c = loop_client
    _send_run(c)
    anim = [b for m, b in fakes.tg if m == "sendAnimation"]
    assert len(anim) == 1 and c.shares == []   # the poster is not rendered, let alone sent, with the loop
    card_id = _q(c, "SELECT card_id FROM cards WHERE kind='run'")[0]["card_id"]
    kb = anim[0]["reply_markup"]
    kb = json.loads(kb) if isinstance(kb, str) else kb
    labels = [b["text"] for row in kb["inline_keyboard"] for b in row]
    assert "Share" in labels
    idx = _share_idx(c, card_id)
    assert any(b.get("callback_data") == f"{card_id}:{idx}" for row in kb["inline_keyboard"] for b in row)
    post_tg(c, tg_callback(7001, f"{card_id}:{idx}"))
    photos = [b for m, b in fakes.tg if m == "sendPhoto"]
    assert len(photos) == 1 and photos[0]["caption"] == "Your run, ready to share." and len(c.shares) == 1
    post_tg(c, tg_callback(7002, f"{card_id}:{idx}"))   # a double tap
    assert len([1 for m, _ in fakes.tg if m == "sendPhoto"]) == 1 and len(c.shares) == 1


def test_a_poster_that_could_not_be_made_can_be_asked_for_again(loop_client, fakes):
    globals()["FAIL_FIRST_POSTER"] = True
    c = loop_client
    _send_run(c)
    card_id = _q(c, "SELECT card_id FROM cards WHERE kind='run'")[0]["card_id"]
    idx = _share_idx(c, card_id)
    post_tg(c, tg_callback(7011, f"{card_id}:{idx}"))
    assert not [1 for m, _ in fakes.tg if m == "sendPhoto"]
    post_tg(c, tg_callback(7012, f"{card_id}:{idx}"))
    assert len([1 for m, _ in fakes.tg if m == "sendPhoto"]) == 1


def test_a_refused_cached_file_id_is_purged_and_the_still_goes(loop_client, fakes):
    c = loop_client
    _send_run(c)
    assert _q(c, "SELECT kind FROM media_file_ids") == [{"kind": "run_loop"}]
    card = _q(c, "SELECT * FROM cards WHERE kind='run'")[0]
    user = _q(c, "SELECT * FROM users")[0]
    con = sqlite3.connect(c.svc.s.db_path)
    con.execute("UPDATE cards SET sent_at=NULL WHERE card_id=?", (card["card_id"],))
    con.commit()
    fakes.fail("sendAnimation", 400, "Bad Request: wrong file identifier")
    assert c.svc._send_card(user, card["card_id"], now_utc()) is True
    assert _q(c, "SELECT * FROM media_file_ids") == []        # purged: the next retry uploads fresh
    assert [m for m, _ in fakes.tg][-1] == "sendPhoto"        # and the still went meanwhile


def test_the_weekly_loop_does_not_try_to_cache_a_file_id(tmp_path, fakes):
    from test_channels_media import media_client, week_setup
    from datetime import datetime, timezone
    with media_client(tmp_path, fakes, video_fns={"week_loop": lambda f, out: out.write_bytes(MP4)}) as c:
        week_setup(c)
        sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
        c.svc.plan_recap(sunday)
        c.svc.run_outbox(sunday + timedelta(seconds=1))
        assert "sendAnimation" in [m for m, _ in fakes.tg]
        assert _q(c, "SELECT * FROM media_file_ids") == []
