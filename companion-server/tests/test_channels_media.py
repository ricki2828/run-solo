"""Telegram media + buttons, deep links, media fallbacks. Every network call is a MockTransport; no token is real."""
import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from companion import deeplink
from companion.app import create_app
from companion.channels import CAPTION_MAX, ChannelError, OutCard, TelegramChannel
from companion.media import Media, MediaError, MediaRenderer, run_facts, week_facts, _default_video_fns
from companion.service import RunIn
from companion.timeutil import now_utc
from conftest import OWNER, TG_TOKEN, auth, enrol, make_settings, run_payload

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64
MP4 = b"\x00\x00\x00\x18ftypmp42" + b"0" * 64
BASE = "https://links.example.test/l"


def feel_buttons():
    return [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]


@contextmanager
def media_client(tmp_path, fakes, card_fns=None, video_fns=None, **over):
    s = make_settings(tmp_path, **{"media_enabled": True, "deeplink_base": BASE, **over})
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    app.state.svc.media = MediaRenderer(
        card_fns if card_fns is not None else {k: (lambda f, m: PNG) for k in ("light", "flood", "pb", "weekly_recap")},
        video_fns if video_fns is not None else {})
    with TestClient(app) as c:
        c.svc = app.state.svc
        yield c


def sent(fakes):
    return [(m, b) for m, b in fakes.tg if m in ("sendPhoto", "sendVideo", "sendMessage")]


def markup(body):
    if "reply_markup" not in body:
        return None
    rm = body["reply_markup"]
    return (json.loads(rm) if isinstance(rm, str) else rm)["inline_keyboard"]


# --- adapter ---------------------------------------------------------------------------------

def adapter(tmp_path, fakes):
    from companion.channels import TelegramChannel
    s = make_settings(tmp_path)
    return TelegramChannel(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)))


def test_photo_is_a_multipart_upload_of_the_bytes_never_a_url(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    card = OutCard("abc123", "Easy one", "7.0 km at 5:42.", feel_buttons(), Media(photo=PNG),
                   (("Open in app", f"{BASE}/run/r1"),))
    mid = ch.send_card(OWNER, card)
    assert mid
    (method, body), = fakes.tg
    assert method == "sendPhoto"
    name, data, ctype = body["_files"]["photo"]
    assert data == PNG and ctype == "image/png"
    assert body["caption"] == "Easy one\n7.0 km at 5:42."
    assert not any(isinstance(v, str) and v.startswith("http") for k, v in body.items() if k != "reply_markup")
    kb = markup(body)
    assert [b["text"] for b in kb[0]] == ["Easy", "Right", "Hard"]
    assert [b["callback_data"] for b in kb[0]] == ["abc123:0", "abc123:1", "abc123:2"]
    assert kb[1] == [{"text": "Open in app", "url": f"{BASE}/run/r1"}]


def test_video_is_streaming_sized_and_has_no_audio_field(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    ch.send_card(OWNER, OutCard("abc123", "PB", "21:41.", feel_buttons(), Media(photo=PNG, video=MP4, duration_s=13)))
    (method, body), = fakes.tg
    assert method == "sendVideo"
    assert body["supports_streaming"] == "true" and body["width"] == "1080" and body["height"] == "1350"
    assert body["duration"] == "13" and body["_files"]["video"][1] == MP4
    assert "audio" not in "".join(body["_files"])


def test_at_most_three_feel_buttons_and_no_question_on_a_media_card(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    buttons = feel_buttons() + [{"label": "Hmm", "action": "feel:easy", "row": 0},
                                {"label": "Sounds good", "action": "sugg:yes:recover", "row": 1},
                                {"label": "10k", "action": "ans:goal_type:10k", "row": 2}]
    ch.send_card(OWNER, OutCard("abc123", "h", "b", buttons, Media(photo=PNG)))
    kb = markup(fakes.tg[0][1])
    flat = [b["callback_data"] for row in kb for b in row]
    assert flat == ["abc123:0", "abc123:1", "abc123:2", "abc123:4"]   # fourth feel and the question are gone
    # the plain text card keeps every button it was given
    fakes.tg.clear()
    ch.send_card(OWNER, OutCard("abc123", "h", "b", buttons))
    assert sum(len(r) for r in markup(fakes.tg[0][1])) == 6


def test_long_caption_goes_as_follow_up_text_with_the_buttons(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    body = "x" * (CAPTION_MAX + 5)
    card = OutCard("abc123", "Head", body, feel_buttons(), Media(photo=PNG))
    ch.send_card(OWNER, card)
    assert fakes.tg_methods() == ["sendPhoto"] and ch.followups(card) == ["caption"]
    ch.send_followup(OWNER, card, "caption")
    assert fakes.tg_methods() == ["sendPhoto", "sendMessage"]
    photo, text = fakes.tg[0][1], fakes.tg[1][1]
    assert "caption" not in photo and "reply_markup" not in photo
    assert text["text"].startswith("Head\n") and len(text["reply_markup"]["inline_keyboard"][0]) == 3


def test_caption_at_exactly_the_limit_stays_a_caption(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    body = "x" * (CAPTION_MAX - len("Head\n"))
    ch.send_card(OWNER, OutCard("abc123", "Head", body, [], Media(photo=PNG)))
    assert fakes.tg_methods() == ["sendPhoto"] and len(fakes.tg[0][1]["caption"]) == CAPTION_MAX


def test_oversize_photo_is_refused_before_upload(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    with pytest.raises(ChannelError) as e:
        ch.send_card(OWNER, OutCard("abc123", "h", "b", [], Media(photo=b"0" * (10 * 1024 * 1024 + 1))))
    assert e.value.permanent and fakes.tg == []


def test_video_refused_by_telegram_falls_back_to_the_still(tmp_path, fakes):
    calls = []

    def handler(req):
        calls.append(req.url.path.rsplit("/", 1)[-1])
        if calls[-1] == "sendVideo":
            return httpx.Response(400, json={"ok": False, "description": "Bad Request: IMAGE_PROCESS_FAILED"})
        return httpx.Response(200, json={"ok": True, "result": {"message_id": 9}})
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client(transport=httpx.MockTransport(handler)))
    assert ch.send_card(OWNER, OutCard("abc123", "h", "b", [], Media(photo=PNG, video=MP4))) == "9"
    assert calls == ["sendVideo", "sendPhoto"]


def test_transport_error_is_retryable_not_permanent(tmp_path):
    def handler(req):
        raise httpx.ConnectError("down")
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client(transport=httpx.MockTransport(handler)))
    with pytest.raises(ChannelError) as e:
        ch.send_card(OWNER, OutCard("abc123", "h", "b", [], Media(photo=PNG)))
    assert not e.value.permanent


def test_error_text_never_carries_the_token(tmp_path):
    def handler(req):
        return httpx.Response(500, json={"ok": False})
    ch = TelegramChannel(make_settings(tmp_path), httpx.Client(transport=httpx.MockTransport(handler)))
    with pytest.raises(ChannelError) as e:
        ch.send_card(OWNER, OutCard("abc123", "h", "b", [], Media(photo=PNG)))
    assert TG_TOKEN not in str(e.value)


def test_non_https_link_buttons_are_dropped(tmp_path, fakes):
    ch = adapter(tmp_path, fakes)
    ch.send_card(OWNER, OutCard("abc123", "h", "b", feel_buttons(), None,
                                (("Open", "runsupreme://run/r1"), ("Open", "http://x.test/run/r1"))))
    assert len(markup(fakes.tg[0][1])) == 1  # only the feel row


# --- through the service ---------------------------------------------------------------------

def test_run_card_goes_out_as_a_photo_with_feel_buttons_and_a_deep_link(tmp_path, fakes):
    with media_client(tmp_path, fakes) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        photos = [b for m, b in fakes.tg if m == "sendPhoto"]
        assert len(photos) == 1 and photos[0]["_files"]["photo"][1] == PNG
        kb = markup(photos[0])
        assert [b["text"] for b in kb[0]] == ["Easy", "Right", "Hard"]
        assert kb[-1] == [{"text": "Open in app", "url": f"{BASE}/run/r1"}]
        assert len(kb) == 3
        assert all(len(row) <= 3 for row in kb)
        assert [b["text"] for b in kb[1]] == ["Add a note"]   # the note button rides the same photo keyboard, on its own row
        # the question is its own later text message, never on the photo
        acts = [x["action"] for x in json.loads(sqlite3.connect(c.svc.s.db_path).execute("SELECT buttons_json FROM cards").fetchone()[0])]
        assert acts == ["feel:easy", "feel:right", "feel:hard", "note:add"]
        assert not any(b["callback_data"].endswith(":4") for row in kb for b in row if "callback_data" in b)
        card_id = sqlite3.connect(c.svc.s.db_path).execute("SELECT card_id FROM cards").fetchone()[0]
        assert card_id in kb[0][0]["callback_data"]


def test_render_failure_falls_back_to_text_with_the_same_buttons(tmp_path, fakes):
    def boom(f, m):
        raise RuntimeError("chromium would not start")
    with media_client(tmp_path, fakes, card_fns={"light": boom, "flood": boom, "pb": boom}) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        assert "sendPhoto" not in fakes.tg_methods()
        text = [b for m, b in fakes.tg if m == "sendMessage"][-1]
        assert len(text["reply_markup"]["inline_keyboard"][0]) == 3
        assert text["reply_markup"]["inline_keyboard"][-1][0]["url"] == f"{BASE}/run/r1"
        assert sqlite3.connect(c.svc.s.db_path).execute("SELECT sent_at FROM cards").fetchone()[0]


def test_renderer_that_returns_nothing_or_too_much_is_a_render_failure(tmp_path, fakes):
    for bad in (b"", b"0" * (10 * 1024 * 1024 + 1)):
        fk = type(fakes)()
        with media_client(tmp_path / str(len(bad)), fk, card_fns={k: (lambda f, m, b=bad: b) for k in ("light", "flood", "pb")}) as c:
            t = enrol(c)
            c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
            c.svc.run_outbox(now_utc() + timedelta(seconds=1))
            assert "sendPhoto" not in fk.tg_methods() and fk.tg_texts()


def test_telegram_refusing_the_photo_falls_back_to_text_once(tmp_path, fakes):
    seen = []

    def handler(req):
        m = req.url.path.rsplit("/", 1)[-1]
        seen.append(m)
        if m == "sendPhoto":
            return httpx.Response(400, json={"ok": False, "description": "Bad Request: IMAGE_PROCESS_FAILED"})
        return fakes.handler(req)
    s = make_settings(tmp_path, media_enabled=True)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(handler)), run_worker=False)
    app.state.svc.media = MediaRenderer({k: (lambda f, m: PNG) for k in ("light", "flood", "pb")}, {})
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
        assert seen.count("sendPhoto") == 1 and seen[-1] == "sendMessage"


def test_media_off_by_default_keeps_text_cards(client, fakes):
    t = enrol(client)
    client.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
    client.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert "sendPhoto" not in fakes.tg_methods() and "sendVideo" not in fakes.tg_methods()


def test_no_deeplink_base_means_no_link_button(tmp_path, fakes):
    with media_client(tmp_path, fakes, deeplink_base=None) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        kb = markup([b for m, b in fakes.tg if m == "sendPhoto"][0])
        assert all("url" not in b for row in kb for b in row)


def test_pb_moment_gets_the_pb_card_and_a_still_when_the_server_has_no_splits(tmp_path, fakes):
    """A PB is a video moment, but a run video needs the route and per-km splits, which the server never holds."""
    called = []

    def pb(f, m):
        called.append(f)
        return PNG
    with media_client(tmp_path, fakes, card_fns={"pb": pb, "flood": pb, "light": pb},
                      video_fns=_default_video_fns()) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1", type="race", pb="5k", distance_m=5000, duration_s=1301,
                                            pace_s_per_km=260.2, zone_min={"z4": 10, "z5": 11.7}), headers=auth(t))
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        assert fakes.tg_methods().count("sendPhoto") == 1 and "sendVideo" not in fakes.tg_methods()
        f = called[0]
        assert f["pb"] == "5k" and f["pb_detail"] == {"label": "5 KM BEST"} and f["distance_km"] == 5.0
        assert f["zone_s"] == [0.0, 0.0, 0.0, 600.0, 702.0]


def week_setup(c, tz="UTC"):
    """Five runs on five different days of ISO week 2026-W41 (Mon 5 Oct to Sun 11 Oct), zone data on each."""
    t = enrol(c)
    uid = sqlite3.connect(c.svc.s.db_path).execute("SELECT id FROM users").fetchone()[0]
    for i, d in enumerate((5, 7, 8, 10, 11)):
        start = datetime(2026, 10, d, 6, 0, tzinfo=timezone.utc)
        c.svc.ingest_run(uid, RunIn.model_validate(run_payload(
            f"w{i}", start_utc=start.isoformat(), zone_id=tz, utc_offset_min=0, duration_s=1800, distance_m=5000,
            zone_min={"z1": 3, "z2": 20, "z3": 7}, scores_delta={"aerobic": 1.0, "speed": -1.0})), start + timedelta(hours=1))
    con = sqlite3.connect(c.svc.s.db_path)
    con.execute("UPDATE users SET zone_id=?", (tz,))
    con.execute("UPDATE outbox SET state='done'")
    con.commit()
    return t, uid


def test_weekly_recap_goes_out_as_a_video_with_a_week_link(tmp_path, fakes):
    made = []

    def weekly(facts, out):
        made.append(facts)
        out.write_bytes(MP4)
    with media_client(tmp_path, fakes, video_fns={"weekly": weekly}) as c:
        week_setup(c)
        sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
        assert c.svc.plan_recap(sunday) == 1
        c.svc.run_outbox(sunday + timedelta(seconds=1))
        vids = [b for m, b in fakes.tg if m == "sendVideo"]
        assert len(vids) == 1 and vids[0]["_files"]["video"][1] == MP4 and vids[0]["supports_streaming"] == "true"
        assert markup(vids[0])[-1][0]["url"] == f"{BASE}/week/2026-W41"
        f = made[0]
        assert f["runs"] == 5 and abs(f["distance_km"] - 25.0) < 1e-9 and f["score_moves"]["aerobic"] == 5
        assert sum(1 for d in f["days"] if sum(d["zone_s"])) == 5


def test_weekly_video_failure_still_sends_the_still_recap(tmp_path, fakes):
    def weekly(facts, out):
        raise RuntimeError("ffmpeg not found")
    with media_client(tmp_path, fakes, video_fns={"weekly": weekly}) as c:
        week_setup(c)
        sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
        c.svc.plan_recap(sunday)
        c.svc.run_outbox(sunday + timedelta(seconds=1))
        assert fakes.tg_methods().count("sendPhoto") == 1 and "sendVideo" not in fakes.tg_methods()


def test_recap_facts_come_from_rows_and_validate_against_the_real_video_spec(tmp_path, fakes):
    from render.motion.weekly_video import weekly_from_facts
    with media_client(tmp_path, fakes) as c:
        _, uid = week_setup(c)
        con = sqlite3.connect(c.svc.s.db_path)
        con.row_factory = sqlite3.Row
        rows = [dict(r) for r in con.execute("SELECT * FROM runs")]
        f = week_facts("2026-W41", rows)
        assert f["week_label"] == "Week 41" and f["runs"] == 5
        spec = weekly_from_facts({**f, "duration_s": sum(sum(d["zone_s"]) for d in f["days"])})
        assert spec.runs == 5 and abs(spec.total_km - 25.0) < 1e-9
        assert week_facts("2026-W40", rows)["runs"] == 0


def test_media_error_is_raised_for_unknown_run_or_bad_renderer():
    r = MediaRenderer({"light": lambda f, m: PNG}, {})
    with pytest.raises(MediaError):
        r.render({"card": "light", "video": False}, {"run_id": "nope", "headline": "h"}, [])
    assert r.render({"card": "none"}, {"run_id": "x", "headline": "h"}, []) is None


def test_run_facts_only_use_stored_numbers():
    row = {"run_id": "r", "type": "easy", "start_utc": "2026-10-10T20:00:00Z", "zone_id": "Asia/Singapore",
           "distance_m": 7000, "duration_s": 2400, "pace_s_per_km": 342.0, "zone_min": json.dumps({"z2": 30, "z3": 10}),
           "climb_m": None, "locality": "Kallang", "verdict": "bogus", "pb": None}
    f = run_facts(row, "Easy one")
    assert f["start_local"] == "2026-10-11T04:00" and f["distance_km"] == 7.0 and f["duration_s"] == 2400
    assert f["zone_s"] == [0.0, 1800.0, 600.0, 0.0, 0.0] and "verdict" not in f and "pb" not in f
    assert f["place_note"] == "Kallang" and "route" not in f and "splits" not in f


# --- deep links ------------------------------------------------------------------------------

def test_deep_link_scheme_and_parsing():
    assert deeplink.run_link("r1") == "runsupreme://run/r1"
    assert deeplink.run_link("a:b.c-d_e") == "runsupreme://run/a%3Ab.c-d_e"
    assert deeplink.week_link("2026-W41") == "runsupreme://week/2026-W41"
    assert deeplink.parse("runsupreme://run/a%3Ab.c-d_e") == ("run", "a:b.c-d_e")
    assert deeplink.parse("runsupreme://week/2026-W41") == ("week", "2026-W41")


@pytest.mark.parametrize("bad", ["", "r/1", "r 1", "x" * 65, "a?b", "../x"])
def test_deep_link_refuses_odd_run_ids(bad):
    assert deeplink.run_link(bad) is None


@pytest.mark.parametrize("bad", ["2026-W00", "2026-W54", "2026-41", "26-W41", "2026-W4", "2026-W41/x", ""])
def test_deep_link_refuses_odd_weeks(bad):
    assert deeplink.week_link(bad) is None


@pytest.mark.parametrize("uri", ["runsupreme://run/", "runsupreme://run/a/b", "runsupreme://other/x", "http://run/x",
                                 "runsupreme://week/2026-W99", "runsupreme://run/a?x=1", "runsupreme://run/a#f"])
def test_deep_link_parse_rejects_foreign_uris(uri):
    assert deeplink.parse(uri) is None


def test_web_twin_needs_an_https_base():
    assert deeplink.web_twin(BASE, "runsupreme://run/r1") == f"{BASE}/run/r1"
    assert deeplink.web_twin(BASE + "/", "runsupreme://week/2026-W41") == f"{BASE}/week/2026-W41"
    assert deeplink.web_twin("http://x.test", "runsupreme://run/r1") is None
    assert deeplink.web_twin(None, "runsupreme://run/r1") is None
    assert deeplink.web_twin(BASE, "runsupreme://run/a/b") is None


def test_deeplink_base_setting_must_be_https():
    from companion.config import Settings
    base = {"COMPANION_PEPPER": "p" * 20}
    assert Settings.from_env({**base, "COMPANION_DEEPLINK_BASE": "https://a.test/l/"}).deeplink_base == "https://a.test/l"
    for bad in ("http://a.test", "ftp://a", "https://a.test/l?x=1", "https://", "javascript:alert(1)"):
        assert Settings.from_env({**base, "COMPANION_DEEPLINK_BASE": bad}).deeplink_base is None
    assert Settings.from_env({**base, "COMPANION_MEDIA": "1"}).media_enabled


# --- privacy -------------------------------------------------------------------------------

def test_sending_media_stores_no_bytes_and_leaves_the_export_unchanged(tmp_path, fakes):
    with media_client(tmp_path, fakes) as c:
        t = enrol(c)
        before = c.get("/v1/me", headers=auth(t)).json()
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        c.svc.run_outbox(now_utc() + timedelta(seconds=1))
        import os
        raw = b"".join(open(p, "rb").read() for p in (c.svc.s.db_path, c.svc.s.db_path + "-wal") if os.path.exists(p))
        assert PNG not in raw
        me = c.get("/v1/me", headers=auth(t)).json()
        assert set(me) == set(before)
        assert set(me["messages_sent_30d"][0]) == {"kind", "headline", "body", "sent_at", "situation", "touch_kind"}


# --- real renderers, end to end (Chromium and ffmpeg are required: a missing one fails, never skips) ----------

def test_real_run_card_renders_through_the_service_as_a_1080x1350_png(tmp_path, fakes, render_socket):
    import io
    from PIL import Image
    s = make_settings(tmp_path, media_enabled=True, render_socket=render_socket)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1", zone_min={"z2": 30, "z3": 10}, locality="Kallang"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    photo = [b for m, b in fakes.tg if m == "sendPhoto"][0]["_files"]["photo"][1]
    im = Image.open(io.BytesIO(photo))
    assert im.format == "PNG" and im.size == (1080, 1350) and len(photo) < 10 * 1024 * 1024


def test_real_weekly_video_is_h264_without_audio_and_telegram_sized(tmp_path, fakes, render_socket):
    import shutil
    import subprocess
    from pathlib import Path
    s = make_settings(tmp_path, media_enabled=True, render_socket=render_socket)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        c.svc = app.state.svc
        week_setup(c)
        sunday = datetime(2026, 10, 11, 19, 30, tzinfo=timezone.utc)
        c.svc.plan_recap(sunday)
        c.svc.run_outbox(sunday + timedelta(seconds=1))
    vid = [b for m, b in fakes.tg if m == "sendVideo"]
    assert len(vid) == 1, fakes.tg_methods()
    data = vid[0]["_files"]["video"][1]
    assert data[4:8] == b"ftyp" and len(data) < 4 * 1024 * 1024
    ffprobe = shutil.which("ffprobe") or str(Path(shutil.which("ffmpeg")).with_name("ffprobe"))
    out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height,pix_fmt",
                          "-of", "json", "-i", "pipe:0"], input=data, capture_output=True, check=True).stdout
    streams = json.loads(out)["streams"]
    assert [x["codec_type"] for x in streams] == ["video"]
    assert streams[0]["codec_name"] == "h264" and (streams[0]["width"], streams[0]["height"]) == (1080, 1350)
    assert streams[0]["pix_fmt"] == "yuv420p"
