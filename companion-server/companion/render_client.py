"""Client for the render worker (render/worker.py): facts in, PNG or MP4 bytes out, over a unix socket.

The companion never imports Chromium, Playwright, Pillow or ffmpeg. Every failure (no socket, slow worker, refused
request, oversize output) surfaces as RenderError, which the media layer turns into the text card.
"""
from __future__ import annotations

import logging
import socket
import time
from typing import Any, Mapping

from render import protocol as P

log = logging.getLogger("companion")

BREAKER_S = 60.0   # after a timeout, skip the worker for a while: a hung renderer must not stall every send


class RenderError(Exception):
    """The worker could not produce the media. `code` is one of protocol.ERROR_CODES or 'unavailable'."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class RenderClient:
    def __init__(self, sock_path: str, card_timeout_s: float = 35.0, video_timeout_s: float = 125.0,
                 breaker_s: float = BREAKER_S):
        # Slightly above the worker's own per-render timeouts, so the worker reports first.
        self.sock_path, self.timeouts, self.breaker_s = sock_path, {"card": card_timeout_s, "video": video_timeout_s}, breaker_s
        self._open_until = 0.0

    def _call(self, op: str, kind: str, facts: Mapping[str, Any]) -> bytes:
        if time.monotonic() < self._open_until:
            raise RenderError("unavailable")
        try:
            req = P.encode_request(op, kind, dict(facts))
        except P.ProtocolError as e:
            raise RenderError(e.code) from None
        budget = self.timeouts[op]
        t0 = time.monotonic()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(min(budget, 5.0))
            try:
                s.connect(self.sock_path)
                s.settimeout(budget)
                s.sendall(req)
                return P.read_response(s, P.OP_MAX_BYTES[op], max(0.1, budget - (time.monotonic() - t0)))
            except P.ProtocolError as e:
                if e.code == "timeout":
                    self._open_until = time.monotonic() + self.breaker_s
                raise RenderError(e.code) from None
            except (socket.timeout, TimeoutError):
                self._open_until = time.monotonic() + self.breaker_s
                raise RenderError("timeout") from None
            except OSError:  # no socket, refused, reset: the worker is down
                raise RenderError("unavailable") from None
        finally:
            s.close()

    def card(self, kind: str, facts: Mapping[str, Any]) -> bytes:
        return self._call("card", kind, facts)

    def video(self, kind: str, facts: Mapping[str, Any]) -> bytes:
        return self._call("video", kind, facts)
