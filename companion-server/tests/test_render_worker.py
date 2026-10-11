"""The render worker (render/worker.py) and its socket client (companion/render_client.py), sec-review-225 F2.

The round-trip tests render for real through a real unix socket: they need Chromium, Pillow and ffmpeg, exactly
like the card and motion suites, and fail (never skip) when one is missing.
"""
import io
import json
import os
import socket
import stat
import struct
import tempfile
import threading
import time
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from companion.app import create_app
from companion.config import Settings
from companion.media import MediaError, MediaRenderer, run_facts, week_facts
from companion.render_client import RenderClient, RenderError
from companion.timeutil import now_utc
from conftest import OWNER, TG_TOKEN, auth, enrol, make_settings, run_payload
from render import protocol as P
from render.worker import Worker

RUN_ROW = {"run_id": "r-secret-id", "type": "easy", "start_utc": "2026-10-10T06:00:00+00:00",
           "zone_id": "Pacific/Auckland", "distance_m": 7000, "duration_s": 2400, "pace_s_per_km": 342.9,
           "climb_m": 40, "locality": "Takapuna", "verdict": "holding", "pb": None,
           "zone_min": {"z1": 5, "z2": 30, "z3": 5}}


@pytest.fixture
def sock_path(render_socket):
    return render_socket


@pytest.fixture
def worker(render_socket):
    return None


@pytest.fixture
def bare_sock():
    """A path for a fake server (no worker behind it)."""
    return os.path.join(tempfile.mkdtemp(prefix="rsw-"), "fake.sock")


def raw_call(sock_path, payload: bytes, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall(payload)
    try:
        return P.read_response(s, P.VIDEO_MAX_BYTES, timeout)
    finally:
        s.close()


def fake_server(sock_path, behave):
    """A server that accepts one connection and runs `behave(conn)`."""
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)

    def run():
        conn, _ = srv.accept()
        try:
            behave(conn)
        finally:
            conn.close()
    threading.Thread(target=run, daemon=True).start()
    return srv


# ---------------------------------------------------------------- real round trips

def test_card_round_trip_through_the_socket(worker, sock_path):
    facts = run_facts(RUN_ROW, "Steady one")
    png = RenderClient(sock_path).card("light", facts)
    img = Image.open(io.BytesIO(png))
    assert png[:8] == b"\x89PNG\r\n\x1a\n" and img.size == (1080, 1350)
    assert len(png) <= P.PHOTO_MAX_BYTES


def test_weekly_video_round_trip_through_the_socket(worker, sock_path):
    runs = [{**RUN_ROW, "start_utc": f"2026-10-{d:02d}T06:00:00+00:00", "scores_delta": '{"aerobic": 1}'}
            for d in (5, 7, 8, 10)]
    facts = week_facts("2026-W41", runs)
    facts["duration_s"] = sum(sum(d["zone_s"]) for d in facts["days"])
    mp4 = RenderClient(sock_path).video("weekly", facts)
    assert mp4[4:8] == b"ftyp" and 0 < len(mp4) <= P.VIDEO_MAX_BYTES


def test_socket_is_owner_only(worker, sock_path):
    assert stat.S_IMODE(os.stat(sock_path).st_mode) == 0o600


# ---------------------------------------------------------------- the worker refuses what it should

def test_worker_refuses_unknown_ops_kinds_and_fact_keys(worker, sock_path):
    def call(req):
        body = json.dumps(req).encode()
        return raw_call(sock_path, struct.pack(">I", len(body)) + body)
    good = {"v": 1, "op": "card", "kind": "light", "facts": {"headline": "x"}}
    for bad in ({**good, "op": "exec"}, {**good, "kind": "../../etc/passwd"}, {**good, "v": 2},
                {**good, "facts": {"headline": "x", "run_id": "r1"}},
                {**good, "facts": {"headline": "x", "token": "t"}}, {**good, "facts": []}):
        with pytest.raises(P.ProtocolError) as e:
            call(bad)
        assert e.value.code == "bad_request", bad


def test_worker_refuses_oversize_and_garbage_requests(worker, sock_path):
    with pytest.raises(P.ProtocolError) as e:
        raw_call(sock_path, struct.pack(">I", P.MAX_REQUEST_BYTES + 1))
    assert e.value.code == "bad_request"
    with pytest.raises(P.ProtocolError) as e:
        raw_call(sock_path, struct.pack(">I", 5) + b"not{j")
    assert e.value.code == "bad_request"


def test_worker_output_cap_is_enforced(worker, sock_path, monkeypatch):
    monkeypatch.setitem(P.OP_MAX_BYTES, "card", 100)  # a real PNG is far bigger than 100 bytes
    import render.worker as W
    monkeypatch.setitem(W.OP_MAX_BYTES, "card", 100)
    with pytest.raises(RenderError) as e:
        RenderClient(sock_path).card("light", run_facts(RUN_ROW, "x"))
    assert e.value.code == "too_big"


def test_worker_kills_a_render_that_overruns(bare_sock):
    w = Worker(bare_sock, card_timeout_s=0.05)  # Chromium cannot start that fast
    with pytest.raises(P.ProtocolError) as e:
        w.render("card", "light", run_facts(RUN_ROW, "x"))
    assert e.value.code == "timeout"


def test_failed_render_is_a_code_not_a_message(worker, sock_path):
    # a weekly video from facts with no days: the child raises, the response carries only the code
    with pytest.raises(RenderError) as e:
        RenderClient(sock_path).video("weekly", {"week_label": "Week 41"})
    assert e.value.code == "render_failed"


# ---------------------------------------------------------------- the client falls back cleanly

def test_missing_socket_is_unavailable(tmp_path):
    c = RenderClient(str(tmp_path / "nope.sock"))
    with pytest.raises(RenderError) as e:
        c.card("light", {"headline": "x"})
    assert e.value.code == "unavailable"


def test_slow_worker_times_out_and_the_breaker_skips_the_next_call(bare_sock):
    srv = fake_server(bare_sock, lambda conn: time.sleep(3))
    c = RenderClient(bare_sock, card_timeout_s=0.4, breaker_s=30)
    t0 = time.monotonic()
    with pytest.raises(RenderError) as e:
        c.card("light", {"headline": "x"})
    assert e.value.code == "timeout" and time.monotonic() - t0 < 2
    t1 = time.monotonic()
    with pytest.raises(RenderError) as e:
        c.card("light", {"headline": "x"})
    assert e.value.code == "unavailable" and time.monotonic() - t1 < 0.1
    srv.close()


def test_client_rejects_an_oversize_response_without_reading_it(bare_sock):
    def behave(conn):
        P.read_request(conn, 5)
        conn.sendall(b"\x00" + struct.pack(">I", P.PHOTO_MAX_BYTES + 1) + b"x" * 1000)
    srv = fake_server(bare_sock, behave)
    with pytest.raises(RenderError) as e:
        RenderClient(bare_sock).card("light", {"headline": "x"})
    assert e.value.code == "too_big"
    srv.close()


def test_client_rejects_garbage_and_error_responses(bare_sock):
    def behave(conn):
        P.read_request(conn, 5)
        conn.sendall(b"\x09\x00\x00\x00\x02hi")
    srv = fake_server(bare_sock, behave)
    with pytest.raises(RenderError) as e:
        RenderClient(bare_sock).card("light", {"headline": "x"})
    assert e.value.code == "render_failed"
    srv.close()


def test_client_will_not_send_a_key_outside_the_facts_list(sock_path):
    with pytest.raises(RenderError) as e:
        RenderClient(sock_path).card("light", {"headline": "x", "run_id": "r1"})
    assert e.value.code == "bad_request"


def test_media_renderer_turns_every_worker_failure_into_media_error(tmp_path):
    r = MediaRenderer(client=RenderClient(str(tmp_path / "nope.sock")))
    plan, card = {"card": "light", "video": False}, {"run_id": "r-secret-id", "headline": "Steady"}
    with pytest.raises(MediaError):
        r.render(plan, card, [RUN_ROW])


# ---------------------------------------------------------------- end to end through the service

def test_service_sends_the_text_card_when_the_worker_is_down(tmp_path, fakes):
    s = make_settings(tmp_path, media_enabled=True, render_socket=str(tmp_path / "nope.sock"))
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert "sendPhoto" not in fakes.tg_methods() and fakes.tg_texts()


def test_service_sends_a_real_photo_through_the_worker(tmp_path, fakes, sock_path):
    s = make_settings(tmp_path, media_enabled=True, render_socket=sock_path)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    photos = [b for m, b in fakes.tg if m == "sendPhoto"]
    assert len(photos) == 1
    name, data, ctype = photos[0]["_files"]["photo"]
    assert data[:8] == b"\x89PNG\r\n\x1a\n" and Image.open(io.BytesIO(data)).size == (1080, 1350)


class Recorder:
    """A stand-in for RenderClient that records exactly what the companion would put on the socket."""

    def __init__(self):
        self.sent = []

    def card(self, kind, facts):
        self.sent.append(P.encode_request("card", kind, dict(facts)))
        return b"\x89PNG\r\n\x1a\n" + b"0" * 64

    def video(self, kind, facts):
        raise RenderError("unavailable")


def test_the_payload_carries_no_tokens_or_ids(tmp_path, fakes):
    s = make_settings(tmp_path, media_enabled=True)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    rec = Recorder()
    app.state.svc.media = MediaRenderer(client=rec)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("run-id-12345", locality="Takapuna"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
        uid = app.state.svc.authenticate(t)
    assert len(rec.sent) == 1
    blob = rec.sent[0][4:]
    req = json.loads(blob)
    assert set(req["facts"]) <= P.ALLOWED_FACT_KEYS
    assert req["facts"]["place_note"] == "Takapuna"          # what the card shows is there ...
    for secret in (t, TG_TOKEN, OWNER, uid, "run-id-12345", "p" * 32, "or-test-key", "watoken"):
        assert secret.encode() not in blob, secret            # ... and nothing else is


def test_run_and_week_facts_use_only_allowed_keys():
    assert set(run_facts(RUN_ROW, "Steady")) <= P.ALLOWED_FACT_KEYS
    runs = [{**RUN_ROW, "scores_delta": '{"aerobic": 1}'}]
    f = week_facts("2026-W41", runs)
    f["duration_s"] = 1
    assert set(f) <= P.ALLOWED_FACT_KEYS


# ---------------------------------------------------------------- config

def test_media_is_off_by_default_and_the_socket_is_configurable(tmp_path):
    base = {"COMPANION_PEPPER": "p" * 20}
    d = Settings.from_env(base)
    assert d.media_enabled is False
    assert d.render_socket == os.path.expanduser("~/companion-data/render/render.sock")
    on = Settings.from_env({**base, "COMPANION_MEDIA": "1", "COMPANION_RENDER_SOCKET": str(tmp_path / "r.sock")})
    assert on.media_enabled and on.render_socket == str(tmp_path / "r.sock")


def test_media_off_never_touches_the_socket(tmp_path, fakes):
    s = make_settings(tmp_path, media_enabled=False)
    app = create_app(s, httpx.Client(transport=httpx.MockTransport(fakes.handler)), run_worker=False)
    rec = Recorder()
    app.state.svc.media = MediaRenderer(client=rec)
    with TestClient(app) as c:
        t = enrol(c)
        c.post("/v1/runs", json=run_payload("r1"), headers=auth(t))
        app.state.svc.run_outbox(now_utc() + timedelta(seconds=1))
    assert rec.sent == [] and "sendPhoto" not in fakes.tg_methods()


def test_kill_tree_reaches_a_descendant_in_its_own_process_group():
    """Playwright starts Chromium in a process group of its own; the timeout kill must still reach it."""
    import subprocess
    from render.worker import kill_tree
    # sh -> setsid sleep: the sleep is a new session and group leader, like a detached browser
    p = subprocess.Popen(["sh", "-c", "setsid sleep 60 & wait"], start_new_session=True)
    time.sleep(0.5)
    from render.worker import _descendants
    kids = _descendants(p.pid)
    assert kids, "expected the setsid sleep below the shell"
    kill_tree(p.pid)
    p.wait(timeout=5)
    time.sleep(0.3)
    for k in kids:
        assert not os.path.exists(f"/proc/{k}") or open(f"/proc/{k}/stat").read().rsplit(")", 1)[1].split()[0] == "Z"
