"""Wire protocol between the companion (client) and the render worker (server) on a unix socket.

Pure stdlib, imported by both sides, and it imports nothing from the companion: the worker never sees tokens, the DB
or chat ids. One request per connection.

  request : 4-byte big-endian length, then JSON {"v": 1, "op": "card"|"video", "kind": str, "facts": {...}}
  response: 1 status byte (0 ok, 1 error), 4-byte big-endian length, then the payload.
            ok -> the PNG or MP4 bytes; error -> a short code from ERROR_CODES (never free text, never a path).
"""
from __future__ import annotations

import json
import socket
import struct
import time
from typing import Any

VERSION = 1
MAX_REQUEST_BYTES = 64 * 1024
PHOTO_MAX_BYTES = 10 * 1024 * 1024     # Telegram sendPhoto
VIDEO_MAX_BYTES = 50 * 1024 * 1024     # Telegram bot upload ceiling
OP_MAX_BYTES = {"card": PHOTO_MAX_BYTES, "video": VIDEO_MAX_BYTES}
OP_KINDS = {
    "card": frozenset({"light", "flood", "pb", "weekly_recap"}),
    "video": frozenset({"run", "weekly"}),
}
ERROR_CODES = frozenset({"bad_request", "timeout", "too_big", "render_failed"})

# Everything the companion may send. These are exactly the keys media.run_facts / week_facts build, i.e. what the
# card or video shows. No run id, user id, chat id, token or coordinates: a key outside this set is refused by both
# sides, so adding one is a deliberate change to this list and to the privacy page.
ALLOWED_FACT_KEYS = frozenset({
    "type", "start_local", "distance_km", "duration_s", "headline", "pace_s_per_km", "zone_s", "climb_m",
    "place_note", "verdict", "pb", "pb_detail",
    "week_label", "runs", "days", "score_moves", "best_moment",
})


class ProtocolError(Exception):
    """Carries one of ERROR_CODES."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def check_request(req: Any) -> tuple[str, str, dict]:
    """-> (op, kind, facts) or ProtocolError('bad_request')."""
    if not isinstance(req, dict) or req.get("v") != VERSION:
        raise ProtocolError("bad_request")
    op, kind, facts = req.get("op"), req.get("kind"), req.get("facts")
    if op not in OP_KINDS or kind not in OP_KINDS[op] or not isinstance(facts, dict):
        raise ProtocolError("bad_request")
    if not set(facts) <= ALLOWED_FACT_KEYS:
        raise ProtocolError("bad_request")
    return op, kind, facts


def encode_request(op: str, kind: str, facts: dict) -> bytes:
    check_request({"v": VERSION, "op": op, "kind": kind, "facts": facts})
    body = json.dumps({"v": VERSION, "op": op, "kind": kind, "facts": facts}, separators=(",", ":")).encode()
    if len(body) > MAX_REQUEST_BYTES:
        raise ProtocolError("bad_request")
    return struct.pack(">I", len(body)) + body


def _recv_exact(sock: socket.socket, n: int, deadline: float) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        left = deadline - time.monotonic()
        if left <= 0:
            raise ProtocolError("timeout")
        sock.settimeout(left)
        try:
            chunk = sock.recv(min(65536, n - len(buf)))
        except (socket.timeout, TimeoutError):
            raise ProtocolError("timeout") from None
        if not chunk:
            raise ProtocolError("bad_request")
        buf += chunk
    return bytes(buf)


def read_request(sock: socket.socket, timeout_s: float) -> dict:
    deadline = time.monotonic() + timeout_s
    (n,) = struct.unpack(">I", _recv_exact(sock, 4, deadline))
    if n == 0 or n > MAX_REQUEST_BYTES:
        raise ProtocolError("bad_request")
    try:
        return json.loads(_recv_exact(sock, n, deadline))
    except ValueError:
        raise ProtocolError("bad_request") from None


def send_ok(sock: socket.socket, data: bytes) -> None:
    sock.sendall(b"\x00" + struct.pack(">I", len(data)) + data)


def send_error(sock: socket.socket, code: str) -> None:
    body = (code if code in ERROR_CODES else "render_failed").encode()
    sock.sendall(b"\x01" + struct.pack(">I", len(body)) + body)


def read_response(sock: socket.socket, max_bytes: int, timeout_s: float) -> bytes:
    """The payload of an ok response; ProtocolError(code) for an error response, a timeout or an oversize payload."""
    deadline = time.monotonic() + timeout_s
    head = _recv_exact(sock, 5, deadline)
    status, (n,) = head[0], struct.unpack(">I", head[1:])
    if status == 1:
        code = _recv_exact(sock, min(n, 32), deadline).decode("ascii", "replace")
        raise ProtocolError(code if code in ERROR_CODES else "render_failed")
    if status != 0 or n == 0:
        raise ProtocolError("render_failed")
    if n > max_bytes:
        raise ProtocolError("too_big")
    return _recv_exact(sock, n, deadline)
