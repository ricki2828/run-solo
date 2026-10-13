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
    "card": frozenset({"light", "flood", "pb", "weekly_recap", "suggestion", "milestone", "race_countdown", "monthly",
                       "today", "today_verdict", "moved", "pinned_week"}),
    "video": frozenset({"run", "weekly"}),
}
ROUTE_GRID, ROUTE_MAX_POINTS, SPLITS_MAX, REPS_MAX, TITLE_MAX = 255, 120, 100, 60, 24
ERROR_CODES = frozenset({"bad_request", "timeout", "too_big", "render_failed"})

# Everything the companion may send. These are exactly the keys media.run_facts / week_facts build, i.e. what the
# card or video shows. No run id, user id, chat id, token or coordinates: a key outside this set is refused by both
# sides, so adding one is a deliberate change to this list and to the privacy page. `route_xy` is the app's route
# SHAPE (whole numbers on a 0..255 unit-box grid, no latitude, longitude, scale or north); `route` (lat/lon) is
# deliberately not here. `splits` and `reps` are per-km paces and rep times, each with an HR zone.
# `work_pace_s_per_km` is an interval run's mean work-rep pace (the verdict's number), drawn as "/KM WORK".
ALLOWED_FACT_KEYS = frozenset({
    "type", "start_local", "distance_km", "duration_s", "headline", "pace_s_per_km", "zone_s", "climb_m",
    "place_note", "verdict", "pb", "pb_detail",
    "title", "route_xy", "splits", "reps", "work_pace_s_per_km",
    "week_label", "runs", "days", "score_moves", "best_moment", "quickest_pace_s_per_km",
    # suggestion / milestone / race_countdown / monthly cards (persisted in convo_cards.media_json when the coach
    # decides to send them; each one is something the card's own text already says, see KIND_FACT_KEYS)
    "session", "reason", "date_local",
    "kind", "value", "line",
    "weeks_to_race", "race_name",
    "month_label", "month_start", "run_count",
    # coach cards (today, today_verdict, moved, pinned_week): numbers, fixed enums and short labels only
    "target_pace_lo_s", "target_pace_hi_s", "target_kind", "result_pace_s", "units",
    "to_day", "from_day", "skip_reason", "today_idx", "guide", "hr_ceiling_bpm",
})

# Every kind is held to its own list on top of ALLOWED_FACT_KEYS: a suggestion card has no business carrying a place, a
# milestone no pace, and a run card no suggestion reason, however wide the shared list grows. The older kinds' lists are
# exactly what media.run_facts / week_facts build.
RUN_KEYS = frozenset({"type", "start_local", "distance_km", "duration_s", "headline", "pace_s_per_km", "zone_s",
                      "climb_m", "place_note", "verdict", "pb", "pb_detail",
                      "title", "route_xy", "splits", "reps", "work_pace_s_per_km"})   # the shape facts: run cards and run videos only
WEEK_KEYS = frozenset({"week_label", "distance_km", "runs", "duration_s", "days", "score_moves", "best_moment",
                       "pace_s_per_km", "quickest_pace_s_per_km"})
NEW_KINDS = frozenset({"suggestion", "milestone", "race_countdown", "monthly"})   # these also get value-shape checks
# Coach cards. The session name is a short label the plan owns; the reason is a fixed enum, never free text.
COACH_KINDS = frozenset({"today", "today_verdict", "moved", "pinned_week"})
TODAY_KEYS = frozenset({"type", "session", "distance_km", "duration_s", "date_local", "target_pace_lo_s", "target_pace_hi_s",
                        "target_kind", "units", "guide", "hr_ceiling_bpm"})
RUN_TYPES = frozenset({"easy", "long", "tempo", "interval", "race", "cooper", "trail", "rest"})
DAY_NAMES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
SKIP_REASONS = frozenset({"tired", "busy", "sore", "travelling", "ill", "weather", "missed"})
VERDICTS = ("faster", "slower", "in_range", "pb")   # the app's verdict, scored with the engine's per-session floor
SESSION_MAX = 32
WEEK_DAY_KEYS = frozenset({"type", "planned_km", "done_km"})
COACH_REQUIRED = {"today": {"type", "session"}, "today_verdict": {"type", "session"}, "moved": {"type", "session", "to_day"},
                  "pinned_week": {"days"}}
KIND_FACT_KEYS = {
    "light": RUN_KEYS, "flood": RUN_KEYS, "pb": RUN_KEYS, "weekly_recap": WEEK_KEYS,
    "run": RUN_KEYS, "weekly": WEEK_KEYS,   # the videos
    "suggestion": frozenset({"type", "session", "distance_km", "date_local", "reason"}),
    "milestone": frozenset({"kind", "value", "line"}),
    "race_countdown": frozenset({"weeks_to_race", "race_name"}),
    "monthly": frozenset({"month_label", "month_start", "distance_km", "run_count", "duration_s", "climb_m", "runs"}),
    "today": TODAY_KEYS, "today_verdict": TODAY_KEYS | {"result_pace_s", "pb", "verdict"},
    "moved": frozenset({"type", "session", "distance_km", "duration_s", "units", "to_day", "from_day", "skip_reason"}),
    "pinned_week": frozenset({"week_label", "days", "duration_s", "units", "today_idx"}),
}
MONTHLY_RUN_KEYS = frozenset({"date", "type", "distance_km", "duration_s"})   # no route, no zones, no place, no run id
MONTHLY_MAX_RUNS = 62
TEXT_LIMIT = 200


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
    if not set(facts) <= ALLOWED_FACT_KEYS or not _shapes_ok(facts):
        raise ProtocolError("bad_request")
    if kind in KIND_FACT_KEYS:
        if not set(facts) <= KIND_FACT_KEYS[kind] or (kind in NEW_KINDS and not _kind_values_ok(kind, facts)):
            raise ProtocolError("bad_request")
        if kind in COACH_KINDS and not (COACH_REQUIRED[kind] <= set(facts) and _coach_values_ok(facts)):
            raise ProtocolError("bad_request")
    return op, kind, facts


def _int_in(v: Any, lo: int, hi: int) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def _shapes_ok(facts: dict) -> bool:
    """The worker is the last stop before pixels, so it checks the shape facts itself: a route is only a short list of
    whole-number grid points (a latitude or longitude, being a float, cannot pass), and splits and reps are bounded."""
    t = facts.get("title")
    if t is not None and not (isinstance(t, str) and 1 <= len(t) <= TITLE_MAX):
        return False
    r = facts.get("route_xy")
    if r is not None and not (isinstance(r, list) and 2 <= len(r) <= ROUTE_MAX_POINTS and all(
            isinstance(p, list) and len(p) == 2 and all(_int_in(c, 0, ROUTE_GRID) for c in p) for p in r)):
        return False
    bounds = {"km": (0.0, 1.0, False), "pace_s": (60.0, 3600.0, True), "time_s": (0.0, 3600.0, False)}

    def num_ok(x: Any, f: str) -> bool:
        lo, hi, closed_lo = bounds[f]
        return (isinstance(x, (int, float)) and not isinstance(x, bool) and x == x and (x >= lo if closed_lo else x > lo)
                and x <= hi)
    for key, cap, fields in (("splits", SPLITS_MAX, ("km", "pace_s")), ("reps", REPS_MAX, ("time_s",))):
        v = facts.get(key)
        if v is None:
            continue
        if not (isinstance(v, list) and 1 <= len(v) <= cap and all(
                isinstance(x, dict) and set(x) <= {*fields, "zone"} and all(num_ok(x.get(f), f) for f in fields)
                and (x.get("zone") is None or _int_in(x["zone"], 1, 5)) for x in v)):
            return False
    wp = facts.get("work_pace_s_per_km")
    if wp is not None and not (isinstance(wp, (int, float)) and not isinstance(wp, bool) and 60 <= wp <= 3600):
        return False
    return True


def _num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) < 1e7


def _text(v: Any) -> bool:
    return isinstance(v, str) and len(v) <= TEXT_LIMIT


def _kind_values_ok(kind: str, facts: dict) -> bool:
    """Value shapes for the new kinds. Cheap and strict: anything nested must be exactly what the card draws."""
    for k, v in facts.items():
        if k in ("distance_km", "duration_s", "climb_m", "value", "weeks_to_race", "run_count"):
            if not _num(v):
                return False
        elif k == "runs":
            if (kind != "monthly" or not isinstance(v, list) or len(v) > MONTHLY_MAX_RUNS
                    or not all(isinstance(r, dict) and set(r) <= MONTHLY_RUN_KEYS and _text(r.get("date", ""))
                               and _text(r.get("type", "")) and _num(r.get("distance_km", 0))
                               and _num(r.get("duration_s", 0)) for r in v)):
                return False
        elif not _text(v):
            return False
    return True


def _in(v: Any, allowed: Any) -> bool:
    """Membership for an enum, False (never a TypeError) for an unhashable value such as a list or a dict."""
    return isinstance(v, str) and v in allowed


def _coach_values_ok(facts: dict) -> bool:
    """Value shapes for the coach cards: a number in range, a member of a fixed set, or a short string. Nothing else."""
    def rng(v: Any, lo: float, hi: float) -> bool:
        return _num(v) and lo <= v <= hi
    for k, v in facts.items():
        if k in ("session", "week_label"):
            ok = isinstance(v, str) and 1 <= len(v) <= (SESSION_MAX if k == "session" else TITLE_MAX)
        elif k == "date_local":
            ok = isinstance(v, str) and len(v) <= 32
        elif k == "type":
            ok = _in(v, RUN_TYPES)
        elif k == "distance_km":
            ok = rng(v, 0.01, 500)
        elif k == "duration_s":
            ok = rng(v, 1, 1_000_000)
        elif k in ("target_pace_lo_s", "target_pace_hi_s", "result_pace_s"):
            ok = rng(v, 60, 3600)
        elif k == "target_kind":
            ok = _in(v, ("work", "pace"))
        elif k == "guide":
            ok = _in(v, ("chatty", "recovery", "steady"))
        elif k == "hr_ceiling_bpm":
            ok = _int_in(v, 80, 220)
        elif k == "verdict":
            ok = _in(v, VERDICTS)
        elif k == "units":
            ok = _in(v, ("km", "mi"))
        elif k == "pb":
            ok = isinstance(v, bool)
        elif k == "skip_reason":
            ok = _in(v, SKIP_REASONS)
        elif k == "from_day":
            ok = _in(v, DAY_NAMES)
        elif k == "to_day":
            ok = _in(v, DAY_NAMES) or v == "next_week"
        elif k == "today_idx":
            ok = _int_in(v, 0, 6)
        elif k == "days":
            ok = isinstance(v, list) and 1 <= len(v) <= 7 and all(
                isinstance(d, dict) and set(d) <= WEEK_DAY_KEYS and _in(d.get("type"), RUN_TYPES)
                and rng(d.get("planned_km", 0), 0, 1000) and rng(d.get("done_km", 0), 0, 1000) for d in v)
        else:
            ok = False
        if not ok:
            return False
    lo, hi = facts.get("target_pace_lo_s"), facts.get("target_pace_hi_s")
    return lo is None or hi is None or lo <= hi


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
