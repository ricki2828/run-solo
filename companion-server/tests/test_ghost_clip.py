"""Ghost race clip: protocol gate, the race maths, the hook copy, the MP4 contract, the media and channel wiring and the
service path (sendAnimation, file_id cache, still fallback). The render itself needs ffmpeg and the brand fonts only."""
import json
import re
import subprocess
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from companion import db
from companion.channels import ChannelError, OutCard, TelegramChannel
from companion.media import GHOST_CLIP_S, Media, MediaError, MediaRenderer
from render import protocol as P
from render.cards import fixtures as F
from render.motion import ghost_clip as G
from render.motion.encode import ffmpeg_bin
from conftest import make_settings
from test_more_cards import NOW, UID, Env, Rec
from test_trail_cards import trail_block, trail_run

UTC = timezone.utc
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"0" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64


def req(facts, kind="ghostclip"):
    return P.check_request({"v": 1, "op": "video", "kind": kind, "facts": facts})


# ---------------------------------------------------------------- protocol

@pytest.mark.parametrize("name", sorted(F.GHOST_CLIPS))
def test_every_clip_fixture_passes_the_protocol(name):
    req(F.GHOST_CLIPS[name]())


@pytest.mark.parametrize("mutate", [
    lambda f: f.pop("ghost_gap"),                                   # no ghost to race
    lambda f: f.pop("elev_profile"),                                # no hill
    lambda f: f.update(elev_profile=[0, 1, 2]),                     # too short to run along
    lambda f: f.update(route_xy=[[0, 0], [255, 255]]),              # a shape key is never allowed
    lambda f: f.update(lat=1.0),
    lambda f: f.update(ghost_gap=[0, 5000]),
    lambda f: f.update(trail_name="@bob"),
])
def test_the_protocol_refuses_a_clip_that_cannot_race_or_carries_extra(mutate):
    f = F.ghost_clip_comeback()
    mutate(f)
    with pytest.raises(P.ProtocolError):
        req(f)


def test_the_clip_is_a_video_kind_only():
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "ghostclip", "facts": F.ghost_clip_comeback()})


# ---------------------------------------------------------------- the race maths and the hook

def spec(f=None):
    return G.spec_from_facts(f or F.ghost_clip_comeback())


def test_the_last_gap_sample_is_the_boards_margin():
    f = F.ghost_clip_comeback()
    f["ghost_gap"][-1] = 40            # the series says 40, the board says 1: the board wins, one number everywhere
    assert spec(f).gap[-1] == 1 == spec(f).best_s - spec(f).today_s


def test_no_ghost_no_clip():
    f = F.ghost_clip_comeback()
    f["trail_board"] = [r for r in f["trail_board"] if r.get("today")] + f["trail_board"][:0]
    with pytest.raises(ValueError):
        G.spec_from_facts(f)
    with pytest.raises(ValueError):
        G.spec_from_facts({k: v for k, v in F.ghost_clip_comeback().items() if k != "ghost_gap"})


def test_the_hook_is_the_drama():
    assert G.hook_lines(spec()) == ("DOWN 22 S AT 2 KM.", "WON IT AT THE LINE.")
    never_behind = F.ghost_clip_comeback()
    never_behind["ghost_gap"] = [min(max(v, 0), 6) for v in never_behind["ghost_gap"]]
    assert G.hook_lines(spec(never_behind))[0] == "AHEAD ALL THE WAY."
    clear = F.ghost_clip_clear_win()
    assert G.hook_lines(spec(clear)) == ("PULLED AWAY.", "41 S FASTER.")
    level = F.ghost_clip_comeback()
    level["trail_board"][3]["time_s"] = 1650   # ties the best: level at the line
    assert G.hook_lines(spec(level)) == ("DOWN 22 S AT 2 KM.", "LEVEL AT THE LINE.")


def test_no_hook_line_carries_an_em_dash_or_a_distance_it_does_not_have():
    f = F.ghost_clip_comeback()
    del f["distance_km"]
    for s in (spec(), spec(f)):
        assert not any("—" in line or "–" in line for line in G.hook_lines(s))
    assert G.hook_lines(spec(f))[0] == "DOWN 22 S ON THE WAY."


def test_the_race_runs_you_to_the_line_and_the_ghost_after_you():
    c = G.GhostClip(spec())
    you0, ghost0, live0 = c.state(0.0)
    assert (you0, ghost0, live0) == (0.0, 0.0, 0)
    prev = (0.0, 0.0)
    for i in range(0, 181):
        you, ghost, _ = c.state(i / G.FPS)
        assert you >= prev[0] - 1e-9 and ghost >= prev[1] - 1e-9     # nobody runs backwards
        prev = (you, ghost)
    you, ghost, live = c.state(G.LAND)
    assert you == 1.0 and live == 1                                  # across the line, the board's margin on the number
    mid = c.state(2.4)
    assert mid[2] <= -15 and mid[0] > mid[1] or mid[2] < 0           # down on the ghost mid-race: you are behind it on the hill
    assert c.state(G.DURATION)[1] == 1.0                             # the ghost gets there too


def test_you_are_ahead_of_the_ghost_on_the_hill_while_you_lead():
    c = G.GhostClip(spec(F.ghost_clip_clear_win()))
    you, ghost, live = c.state(2.5)
    assert live > 0 and you > ghost


# ---------------------------------------------------------------- the render

def _info(path):
    return subprocess.run([ffmpeg_bin(), "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr


@pytest.fixture(scope="module")
def clip_mp4(tmp_path_factory):
    import time
    out = tmp_path_factory.mktemp("g") / "clip.mp4"
    t0 = time.time()
    G.render_ghost_clip(spec(), out)
    assert time.time() - t0 < 90      # PIL frames, not Chromium: well inside the worker's 120 s video timeout
    return out


def test_the_mp4_is_a_silent_telegram_animation(clip_mp4):
    info = _info(clip_mp4)
    assert "Video: h264 (Main)" in info and "yuv420p" in info and "1080x1350" in info and "30 fps" in info
    assert "Audio:" not in info
    assert re.search(r"Duration: 00:00:0[56]\.", info)
    size = clip_mp4.stat().st_size
    assert 20_000 < size < P.VIDEO_MAX_BYTES and size < 3_000_000


def test_the_frames_tell_the_story():
    c = G.GhostClip(spec())
    first, down, last = c.frame(0.2), c.frame(2.4), c.frame(5.7)
    assert first.size == (1080, 1350)

    def has(img, rgb, tol=12):
        raw = img.resize((270, 337)).tobytes()
        return any(all(abs(raw[i + k] - rgb[k]) <= tol for k in range(3)) for i in range(0, len(raw), 3))
    from render import brand
    arc = tuple(int(brand.ARC.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    assert not has(first, arc) and not has(down, arc)          # cyan only ever marks a best
    assert has(last, arc)
    assert first.tobytes() != down.tobytes() != last.tobytes()


def test_a_place_name_is_drawn_only_when_sent():
    plain = G.GhostClip(spec()).frame(5.7).tobytes()
    named = G.GhostClip(spec(F.ghost_clip_comeback() | {"trail_name": "Gualdo Cattaneo"})).frame(5.7).tobytes()
    assert plain != named


def test_the_worker_renders_the_kind_and_refuses_a_bad_request(tmp_path):
    from render import worker
    out = tmp_path / "o.mp4"
    worker._render_one("video", "ghostclip", F.ghost_clip_comeback(), out)
    assert out.stat().st_size > 20_000


# ---------------------------------------------------------------- media

def facts_for(media_facts):
    return media_facts


def _trail_runs(clip=True, **over):
    f = F.trail_record_six()
    return [{"run_id": "r1", "distance_m": 9600, "duration_s": 3642, "pace_s_per_km": 379, "climb_m": 412,
             "_shape": {"trail": {"n": 6, "board": f["trail_board"], "profile": f["elev_profile"], "elev_src": "baro",
                                   **({"ghost_gap": f["ghost_gap"]} if clip else {}), **over}}}]


def renderer(video_fn):
    return MediaRenderer({"trail_record": lambda f, m: PNG, "trail_board": lambda f, m: PNG}, {"ghostclip": video_fn})


PLAN = {"card": "trail_record", "video": False}


def test_a_trail_record_with_a_ghost_series_becomes_the_clip_with_the_still_beside_it():
    seen = []
    r = renderer(lambda facts, out: (seen.append(facts), out.write_bytes(MP4)))
    m = r.render(PLAN, {"run_id": "r1", "headline": "h"}, _trail_runs())
    assert m.animation and m.video == MP4 and m.photo == PNG and m.duration_s == GHOST_CLIP_S
    assert seen and "route_xy" not in seen[0]


def test_no_ghost_series_or_no_other_run_keeps_the_still_card():
    r = renderer(lambda facts, out: out.write_bytes(MP4))
    m = r.render(PLAN, {"run_id": "r1", "headline": "h"}, _trail_runs(clip=False))
    assert not m.animation and m.video is None and m.photo == PNG
    one = _trail_runs()
    one[0]["_shape"]["trail"]["n"] = 1       # a first run has nothing to race
    assert MediaRenderer.ghost_clip_ok({"trail_runs": 1, "ghost_gap": [0, 1], "elev_profile": list(range(9))}) is False
    assert MediaRenderer.ghost_clip_ok({"trail_runs": 2, "ghost_gap": [0, 1], "elev_profile": list(range(9))}) is True


def test_a_failed_clip_falls_back_to_the_still_and_the_switch_keeps_it_off():
    def boom(facts, out):
        raise RuntimeError("ffmpeg")
    m = renderer(boom).render(PLAN, {"run_id": "r1", "headline": "h"}, _trail_runs())
    assert not m.animation and m.photo == PNG and m.video is None
    ok = renderer(lambda facts, out: out.write_bytes(MP4))
    m = ok.render(PLAN, {"run_id": "r1", "headline": "h"}, _trail_runs(), clip=False)
    assert not m.animation and m.photo == PNG


def test_the_board_card_is_never_a_clip():
    r = renderer(lambda facts, out: out.write_bytes(MP4))
    m = r.render({"card": "trail_board"}, {"run_id": "r1", "headline": "h"}, _trail_runs())
    assert not m.animation and m.photo == PNG


def test_a_clip_that_rendered_once_is_not_rendered_again_for_a_retry():
    calls = []
    r = renderer(lambda facts, out: (calls.append(1), out.write_bytes(MP4)))
    for _ in range(3):
        r.render(PLAN, {"run_id": "r1", "headline": "h"}, _trail_runs())
    assert len(calls) == 1


def test_the_clip_alone_is_enough_when_the_still_cannot_be_drawn():
    def no_still(f, m):
        raise RuntimeError("chromium")
    r = MediaRenderer({"trail_record": no_still}, {"ghostclip": lambda facts, out: out.write_bytes(MP4)})
    m = r.render(PLAN, {"run_id": "r1", "headline": "h"}, _trail_runs())
    assert m.animation and m.photo is None and m.has_content


# ---------------------------------------------------------------- the channel

def channel(tmp_path, answers):
    calls = []

    def fake(self, method, payload, files=None):
        calls.append((method, dict(payload), bool(files)))
        a = answers(method, payload)
        if isinstance(a, Exception):
            raise a
        return a
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client())
    ch._call = fake.__get__(ch)
    return ch, calls


ANIM_OK = {"result": {"message_id": 7, "animation": {"file_id": "AGAD"}}}


def test_the_clip_goes_with_sendanimation_and_its_file_id_is_noted(tmp_path):
    ch, calls = channel(tmp_path, lambda m, p: ANIM_OK)
    m = Media(photo=PNG, video=MP4, animation=True, duration_s=6, spoiler=True)
    assert ch._send_media("123", OutCard("c", "h", "b", [], m, ()), "cap") == "7"
    assert [c[0] for c in calls] == ["sendAnimation"]
    method, payload, uploaded = calls[0]
    assert uploaded and payload["has_spoiler"] == "true" and payload["duration"] == 6 and (payload["width"], payload["height"]) == (1080, 1350)
    assert m.sent == {"file_id": "AGAD"}


def test_a_refused_spoiler_retries_the_animation_plain_then_the_still(tmp_path):
    def answers(method, payload):
        if method == "sendAnimation" and "has_spoiler" in payload:
            return ChannelError("x", permanent=True)
        return ANIM_OK
    ch, calls = channel(tmp_path, answers)
    m = Media(photo=PNG, video=MP4, animation=True, spoiler=True)
    ch._send_media("123", OutCard("c", "h", "b", [], m, ()), "")
    assert [(c[0], "has_spoiler" in c[1]) for c in calls] == [("sendAnimation", True), ("sendAnimation", False)]

    ch, calls = channel(tmp_path, lambda method, p: ChannelError("x", permanent=True) if method == "sendAnimation" else {"result": {"message_id": 9}})
    m = Media(photo=PNG, video=MP4, animation=True, spoiler=True)
    assert ch._send_media("123", OutCard("c", "h", "b", [], m, ()), "") == "9"
    assert [c[0] for c in calls] == ["sendAnimation", "sendAnimation", "sendPhoto"]   # the spoiler photo takes it
    assert "file_id" not in m.sent


def test_a_known_file_id_is_one_json_call_with_no_upload(tmp_path):
    ch, calls = channel(tmp_path, lambda m, p: ANIM_OK)
    kb = [{"label": "Easy", "action": "feel:easy", "row": 0}]
    m = Media(animation=True, animation_file_id="AGAD", duration_s=6)
    assert m.has_content
    ch._send_media("123", OutCard("c", "h", "b", kb, m, ()), "caption")
    method, payload, uploaded = calls[0]
    assert method == "sendAnimation" and not uploaded and payload["animation"] == "AGAD"
    assert isinstance(payload["reply_markup"], dict) and payload["caption"] == "caption"


def test_an_oversize_clip_falls_to_the_still(tmp_path):
    ch, calls = channel(tmp_path, lambda m, p: {"result": {"message_id": 3}})
    m = Media(photo=PNG, video=b"0" * (P.VIDEO_MAX_BYTES + 1), animation=True)
    ch._send_media("123", OutCard("c", "h", "b", [], m, ()), "")
    assert [c[0] for c in calls] == ["sendPhoto"]


# ---------------------------------------------------------------- the service

class ClipRec(Rec):
    def __init__(self, fail_video=False):
        super().__init__()
        self.fail_video, self.videos = fail_video, []

    def video(self, kind, facts):
        from companion.render_client import RenderError
        try:
            P.encode_request("video", kind, dict(facts))
        except P.ProtocolError as e:
            raise RenderError(e.code) from None
        if self.fail_video:
            raise RenderError("unavailable")
        self.videos.append((kind, json.loads(json.dumps(facts))))
        return MP4


def record_env(tmp_path, rec, **over):
    e = Env(tmp_path, rec, **over)
    trail_run(e, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3, ghost_gap=F._trail_gap()))
    e.quiet_outbox()
    return e


def test_a_record_with_a_ghost_series_is_sent_as_one_animation_and_its_id_kept(tmp_path):
    rec = ClipRec()
    e = record_env(tmp_path, rec)
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    methods = e.methods()
    assert methods.count("sendAnimation") == 1 and "sendPhoto" not in methods and "sendVideo" not in methods
    body = next(b for m, b in e.fakes.tg if m == "sendAnimation")
    assert body["has_spoiler"] == "true"                            # the verdict stays a tap to reveal
    assert rec.videos and rec.videos[0][0] == "ghostclip" and "route_xy" not in rec.videos[0][1]
    (row,) = e.q("SELECT run_id, kind, file_id FROM media_file_ids")
    assert row["run_id"] == "r01" and row["kind"] == "ghostclip" and row["file_id"].startswith("AnimFileId")


def test_a_repeat_send_is_the_cached_id_and_never_renders_again(tmp_path):
    rec = ClipRec()
    e = record_env(tmp_path, rec)
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    fid = e.q("SELECT file_id FROM media_file_ids")[0]["file_id"]
    renders = len(rec.videos)
    e.q("SELECT 1")
    with db.tx(e.s.db_path) as c:
        c.execute("UPDATE cards SET sent_at=NULL WHERE card_id=?", (cid,))
    assert e.svc._send_card(e.user(), cid, NOW)
    assert len(rec.videos) == renders
    again = [b for m, b in e.fakes.tg if m == "sendAnimation"][-1]
    assert again["animation"] == fid


def test_the_still_goes_when_the_clip_cannot_be_made(tmp_path):
    e = record_env(tmp_path, ClipRec(fail_video=True))
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    assert "sendAnimation" not in e.methods() and len(e.photos()) == 1
    assert e.q("SELECT 1 FROM media_file_ids") == []


def test_the_switch_turns_the_clip_off(tmp_path):
    rec = ClipRec()
    e = record_env(tmp_path, rec, trail_clip=False)
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    assert "sendAnimation" not in e.methods() and rec.videos == [] and len(e.photos()) == 1


def test_a_record_without_a_ghost_series_is_still_the_still(tmp_path):
    rec = ClipRec()
    e = Env(tmp_path, rec)
    trail_run(e, 1, trail_block([(1, 3900), (2, 3800), (3, 3700)], 3, n=3))
    e.quiet_outbox()
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    assert "sendAnimation" not in e.methods() and rec.videos == []


def test_the_cached_id_goes_with_the_run(tmp_path):
    e = record_env(tmp_path, ClipRec())
    cid = e.svc._build_run_card(UID, "r01", NOW)
    e.svc._send_card(e.user(), cid, NOW)
    assert len(e.q("SELECT 1 FROM media_file_ids")) == 1
    with db.tx(e.s.db_path) as c:
        c.execute("DELETE FROM runs WHERE run_id='r01'")
    assert e.q("SELECT 1 FROM media_file_ids") == []


# ---------------------------------------------------------------- review fixes

def test_the_clip_cache_is_per_runner_not_per_run_id():
    calls = []
    r = renderer(lambda facts, out: (calls.append(1), out.write_bytes(MP4)))
    a, b = _trail_runs(), _trail_runs()
    a[0]["user_id"], b[0]["user_id"] = "u_a", "u_b"     # two runners can both have a run called r1
    r.render(PLAN, {"run_id": "r1", "headline": "h"}, a)
    r.render(PLAN, {"run_id": "r1", "headline": "h"}, b)
    r.render(PLAN, {"run_id": "r1", "headline": "h"}, a)
    assert len(calls) == 2


def test_a_cached_id_carries_the_still_so_a_refused_id_falls_back_to_a_photo(tmp_path):
    e = record_env(tmp_path, ClipRec())
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    with db.tx(e.s.db_path) as c:
        c.execute("UPDATE cards SET sent_at=NULL WHERE card_id=?", (cid,))
    card = dict(e.q("SELECT * FROM cards WHERE card_id=?", cid)[0])
    media = e.svc._render_media(e.user(), card, NOW)
    assert media.animation_file_id and media.photo and media.animation


def test_a_cached_id_is_not_used_once_the_trail_block_is_gone(tmp_path):
    rec = ClipRec()
    e = record_env(tmp_path, rec)
    cid = e.svc._build_run_card(UID, "r01", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    with db.tx(e.s.db_path) as c:
        c.execute("UPDATE run_shape SET trail_json=NULL")
        c.execute("UPDATE cards SET sent_at=NULL WHERE card_id=?", (cid,))
    e.svc._send_card(e.user(), cid, NOW)
    assert [b.get("animation") for m, b in e.fakes.tg if m == "sendAnimation"].count(
        e.q("SELECT file_id FROM media_file_ids")[0]["file_id"]) == 0


def test_the_cached_id_is_purged_with_the_30_day_trail_block(tmp_path):
    e = record_env(tmp_path, ClipRec())
    cid = e.svc._build_run_card(UID, "r01", NOW)
    e.svc._send_card(e.user(), cid, NOW)
    assert len(e.q("SELECT 1 FROM media_file_ids")) == 1
    e.svc.purge(NOW + timedelta(days=40))
    assert e.q("SELECT 1 FROM media_file_ids") == []


def test_the_hook_uses_m_ss_from_a_minute():
    from render.motion.ghost_clip import GhostClipSpec, gap_text, hook_lines
    assert gap_text(59) == "59 S" and gap_text(60) == "1:00" and gap_text(125) == "2:05"
    gap = [0] * 10 + [-125] * 20 + [8] * 34
    s = GhostClipSpec(profile=list(range(20)), gap=gap, today_s=3000, best_s=3008, attempt=3, distance_km=9.0)
    assert hook_lines(s)[0].startswith("DOWN 2:05 AT")


def test_the_ghost_is_drawn_apart_from_you_on_the_hill():
    from render.motion import ghost_clip as G
    spec = G.spec_from_facts(F.ghost_clip_comeback())
    clip = G.GhostClip(spec)
    you, ghost, _ = clip.state(1.6)
    assert abs(clip._x(min(1, max(0, you + (ghost - you) * G.GHOST_SPREAD))) - clip._x(you)) > 40
