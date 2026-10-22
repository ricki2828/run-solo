"""Cards v4 PR 2: a run, the weekly recap and a milestone go out as moment loops (sendAnimation), the still card riding
beside as thumbnail and fallback. Fakes stand in for the worker, as in test_ghost_clip.py."""
import io

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
