"""Render worker: facts JSON in, PNG or MP4 bytes out, over a unix socket.

Runs as its own unprivileged systemd unit (deploy/companion-render.service), apart from the companion: Chromium and
ffmpeg cannot run inside the companion's hardened unit (sec-review-225 F2), and the process that holds the bot token and
the DB must not be weakened to host them. This process has no network, no DB and no secrets; it only reads the app
dir, the assets and the Chromium and ffmpeg binaries, and writes to its private tmp dir and its socket.

    python -m render.worker --socket ~/companion-data/render/render.sock

Each render runs in a child process (`--one`) in its own process group, so a hung Chromium or ffmpeg is killed at the
timeout and nothing leaks into the next render. Renders are serial: one at a time, the host is memory-tight.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from .protocol import OP_MAX_BYTES, ProtocolError, check_request, read_request, send_error, send_ok

log = logging.getLogger("render-worker")

REQUEST_READ_TIMEOUT_S = 5.0
CARD_TIMEOUT_S = 30.0
VIDEO_TIMEOUT_S = 120.0


def _render_one(op: str, kind: str, facts: dict, out: Path) -> None:
    """Runs inside the child. Raises on any failure."""
    if op == "card":
        from .cards import render_pb, render_post_run, render_weekly_recap
        fn = {"light": render_post_run, "flood": render_post_run, "pb": render_pb,
              "weekly_recap": render_weekly_recap}[kind]
        out.write_bytes(fn(facts, {}))  # no memory: nothing here draws a name
    elif kind == "run":
        from .motion import render_run_video
        from .motion.run_video import spec_from_facts
        render_run_video(spec_from_facts(facts), out)
    else:
        from .motion.weekly_video import render_weekly_video, weekly_from_facts
        render_weekly_video(weekly_from_facts(facts), out)


def child_main(out_path: str) -> int:
    try:
        op, kind, facts = check_request(json.load(sys.stdin))
        _render_one(op, kind, facts, Path(out_path))
    except Exception as e:  # the parent only learns "render_failed"; the type name is enough for the journal
        print(f"render failed: {type(e).__name__}: {str(e)[:600]}", file=sys.stderr)  # journal only; never sent to the client
        return 1
    return 0


class Worker:
    def __init__(self, sock_path: str, card_timeout_s: float = CARD_TIMEOUT_S, video_timeout_s: float = VIDEO_TIMEOUT_S):
        self.sock_path = sock_path
        self.timeouts = {"card": card_timeout_s, "video": video_timeout_s}

    def bind(self) -> socket.socket:
        p = Path(self.sock_path)
        p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if p.exists() or p.is_symlink():
            p.unlink()  # stale from a previous run; systemd guarantees a single instance
        old = os.umask(0o177)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.bind(self.sock_path)
        finally:
            os.umask(old)
        s.listen(8)
        return s

    def render(self, op: str, kind: str, facts: dict) -> bytes:
        """-> the bytes, or ProtocolError(code)."""
        with tempfile.TemporaryDirectory(prefix="rs-render-") as d:
            out = Path(d) / ("out.png" if op == "card" else "out.mp4")
            env = {k: v for k, v in os.environ.items() if k in (
                "PATH", "LANG", "HOME", "LD_LIBRARY_PATH", "RS_CHROMIUM_PATH", "FFMPEG", "COMPANION_ASSETS_DIR", "PLAYWRIGHT_BROWSERS_PATH")}
            env.setdefault("PLAYWRIGHT_BROWSERS_PATH", str(Path.home() / ".cache" / "ms-playwright"))
            env["TMPDIR"] = d  # the browser profile and ffmpeg scratch land here; the unit gives HOME a private tmp too
            p = subprocess.Popen([sys.executable, "-m", "render.worker", "--one", str(out)], stdin=subprocess.PIPE,
                                 env=env, start_new_session=True, cwd=str(Path(__file__).resolve().parent.parent))
            try:
                p.communicate(json.dumps({"v": 1, "op": op, "kind": kind, "facts": facts}).encode(),
                              timeout=self.timeouts[op])
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)  # the browser and ffmpeg are in the child's group
                except ProcessLookupError:
                    pass
                p.wait()
                raise ProtocolError("timeout") from None
            finally:
                try:
                    os.killpg(p.pid, signal.SIGKILL)  # stragglers (a browser that outlived its parent)
                except (ProcessLookupError, PermissionError):
                    pass
            if p.returncode != 0 or not out.is_file():
                raise ProtocolError("render_failed")
            size = out.stat().st_size
            if size == 0:
                raise ProtocolError("render_failed")
            if size > OP_MAX_BYTES[op]:
                raise ProtocolError("too_big")
            return out.read_bytes()

    def handle(self, conn: socket.socket) -> None:
        try:
            op, kind, facts = check_request(read_request(conn, REQUEST_READ_TIMEOUT_S))
            send_ok(conn, self.render(op, kind, facts))
        except ProtocolError as e:
            log.warning("refused: %s", e.code)
            send_error(conn, e.code)
        except Exception as e:
            log.warning("render error: %s", type(e).__name__)
            try:
                send_error(conn, "render_failed")
            except OSError:
                pass

    def serve_forever(self, srv: socket.socket) -> None:
        while True:
            conn, _ = srv.accept()
            with conn:
                try:
                    self.handle(conn)
                except OSError as e:  # the client went away mid-response
                    log.warning("connection dropped: %s", type(e).__name__)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", help="unix socket path to listen on")
    ap.add_argument("--one", metavar="OUT", help="internal: render the request on stdin to OUT")
    a = ap.parse_args(argv)
    if a.one:
        return child_main(a.one)
    if not a.socket:
        ap.error("--socket is required")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    w = Worker(a.socket,
               float(os.environ.get("RENDER_CARD_TIMEOUT_S", CARD_TIMEOUT_S)),
               float(os.environ.get("RENDER_VIDEO_TIMEOUT_S", VIDEO_TIMEOUT_S)))
    srv = w.bind()
    log.info("render worker listening")
    try:
        w.serve_forever(srv)
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
        Path(a.socket).unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
