"""Wire protocol between the companion (client) and the render worker (server) on a unix socket.

Pure stdlib, imported by both sides, and it imports nothing from the companion: the worker never sees tokens, the DB
or chat ids. One request per connection.

  request : 4-byte big-endian length, then JSON {"v": 1, "op": "card"|"video", "kind": str, "facts": {...}}
  response: 1 status byte (0 ok, 1 error), 4-byte big-endian length, then the payload.
            ok -> the PNG or MP4 bytes; error -> a short code from ERROR_CODES (never free text, never a path).
"""
from __future__ import annotations

import json
import re
import unicodedata
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
    "card": frozenset({"light", "flood", "pb", "share", "weekly_recap", "suggestion", "milestone", "race_countdown", "monthly",
                       "today", "today_verdict", "moved", "pinned_week", "trail_board", "trail_record", "trail_heart"}),
    "video": frozenset({"run", "weekly", "ghostclip", "run_loop", "week_loop", "milestone_loop"}),
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
    "title", "route_xy", "splits", "reps", "work_pace_s_per_km", "share",
    "week_label", "runs", "days", "score_moves", "best_moment", "quickest_pace_s_per_km",
    "load", "usual_load", "band", "pct", "weeks",   # weekly_recap only: this week's load against the usual week, and 6 weeks of bars
    # suggestion / milestone / race_countdown / monthly cards (persisted in convo_cards.media_json when the coach
    # decides to send them; each one is something the card's own text already says, see KIND_FACT_KEYS)
    "session", "reason", "date_local",
    "kind", "value", "line",
    "weeks_to_race", "race_name",
    "month_label", "month_start", "run_count",
    # coach cards (today, today_verdict, moved, pinned_week): numbers, fixed enums and short labels only
    "target_pace_lo_s", "target_pace_hi_s", "target_kind", "result_pace_s", "units",
    "to_day", "from_day", "skip_reason", "today_idx", "guide", "hr_ceiling_bpm",
    # trail cards (trail_board, trail_record): whole numbers and fixed enums only. `elev_profile` is metres RELATIVE to the
    # start (start = 0, no absolute altitude); `ghost_gap` is signed seconds along the same progress (POSITIVE = ahead of the old best, as the app's aheadBestMs); `elev_src` says whether the profile is barometer or GPS; `trail_board` rows
    # are an attempt number, a pace-normalised time and a today flag. No coordinates, no dates. `trail_name` is a place,
    # so the caller sends it only with the runner's place opt-in.
    "trail_runs", "trail_board", "elev_profile", "elev_src", "ghost_gap", "turn_idx", "trail_shape", "trail_name",
    # trail_heart only: the runner's heart rate along the profile (bpm, <= 64 points, one per profile point) and the runner's own
    # zone (1-5) of each. Health data: the caller sends it only with the "Heart rate on cards" switch on.
    "hr_series", "hr_zones",
})

TRAIL_KINDS = frozenset({"trail_board", "trail_record", "ghostclip"})
TRAIL_KEYS = frozenset({"type", "distance_km", "duration_s", "pace_s_per_km", "climb_m", "trail_runs", "trail_board", "elev_profile", "elev_src",
                        "ghost_gap", "turn_idx", "trail_shape", "trail_name"})
HEART_KIND = "trail_heart"
HEART_KEYS = TRAIL_KEYS | {"hr_series", "hr_zones"}
TRAIL_SHAPES = frozenset({"out_and_back", "loop", "one_way"})
ELEV_SRCS = frozenset({"baro", "gps"})


def normalize_trail_name(v: Any) -> Any:
    """NFKC, so a fullwidth "＠" or "．" cannot hide an @ or a dot from the filter below."""
    return unicodedata.normalize("NFKC", v) if isinstance(v, str) else v


SOCIAL_WORDS = r"(?:insta|instagram|ig|tiktok|strava|fb|facebook|whatsapp|snap|snapchat)"


def trail_name_ok(v: Any) -> bool:
    """A trail name is a short label that must not carry a handle, a phone number or a link. Checked on the NFKC form,
    which the name must already be in. A social-media word is refused only as the whole name or when a ':' or '@' follows it
    ("Snap Hill Track" and "Big Ig Loop" are trails); "word:handle" is refused only with no space after the colon
    ("Te Araroa: Section 4" is a trail)."""
    if not (isinstance(v, str) and 1 <= len(v.strip()) <= 30 and v == v.strip() and v == normalize_trail_name(v)):
        return False
    low = v.lower()
    if any(unicodedata.category(ch)[0] == "C" for ch in v):    # control and format characters (newlines, RTL overrides)
        return False
    if sum(ch.isdigit() for ch in v) >= 5 or re.search(r"\+\s*\d", v):    # a phone number, however it is spaced
        return False
    if "@" in v or "://" in low or "www." in low or "http" in low:
        return False
    if re.fullmatch(SOCIAL_WORDS, low.strip()) or re.search(r"\b" + SOCIAL_WORDS + r"\s*[:@]", low) or re.search(r":[a-z0-9_.]{3,}", low):
        return False
    return not re.search(r"\.(com|net|org|io|co|nz|au|app|me|ly|xyz)\b", low)


TRAIL_PROFILE_MAX, TRAIL_BOARD_MAX, TRAIL_NAME_MAX = 64, 10, 30

# Every kind is held to its own list on top of ALLOWED_FACT_KEYS: a suggestion card has no business carrying a place, a
# milestone no pace, and a run card no suggestion reason, however wide the shared list grows. The older kinds' lists are
# exactly what media.run_facts / week_facts build.
RUN_KEYS = frozenset({"type", "start_local", "distance_km", "duration_s", "headline", "pace_s_per_km", "zone_s",
                      "climb_m", "place_note", "verdict", "pb", "pb_detail",
                      "title", "route_xy", "splits", "reps", "work_pace_s_per_km"})   # the shape facts: run cards and run videos only
WEEK_KEYS = frozenset({"week_label", "distance_km", "runs", "duration_s", "days", "score_moves", "best_moment",
                       "pace_s_per_km", "quickest_pace_s_per_km"})
LOAD_KEYS = frozenset({"load", "usual_load", "band", "pct", "weeks"})   # the weekly card's load panel; not the loop's
LOAD_BANDS = ("lighter", "usual", "stepUp", "bigJump")
NEW_KINDS = frozenset({"suggestion", "milestone", "milestone_loop", "race_countdown", "monthly"})   # these also get value-shape checks
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
    "light": RUN_KEYS, "flood": RUN_KEYS, "pb": RUN_KEYS, "share": RUN_KEYS | {"share"}, "weekly_recap": WEEK_KEYS | LOAD_KEYS,
    "run": RUN_KEYS, "weekly": WEEK_KEYS,   # the videos
    "run_loop": RUN_KEYS, "week_loop": WEEK_KEYS,   # the v4 moment loops: the same facts, no new key
    "milestone_loop": frozenset({"kind", "value", "line"}),
    "suggestion": frozenset({"type", "session", "distance_km", "date_local", "reason"}),
    "milestone": frozenset({"kind", "value", "line"}),
    "race_countdown": frozenset({"weeks_to_race", "race_name"}),
    "monthly": frozenset({"month_label", "month_start", "distance_km", "run_count", "duration_s", "climb_m", "runs"}),
    "today": TODAY_KEYS, "today_verdict": TODAY_KEYS | {"result_pace_s", "pb", "verdict"},
    "moved": frozenset({"type", "session", "distance_km", "duration_s", "units", "to_day", "from_day", "skip_reason"}),
    "pinned_week": frozenset({"week_label", "days", "duration_s", "units", "today_idx"}),
    "trail_board": TRAIL_KEYS, "trail_record": TRAIL_KEYS,
    "ghostclip": TRAIL_KEYS,   # the ghost race clip: the trail record card's facts, played as a race
    "trail_heart": HEART_KEYS,   # the heart against the hill: the board's facts plus the hr series
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
        if (kind in TRAIL_KINDS or kind == HEART_KIND) and not _trail_values_ok(facts):
            raise ProtocolError("bad_request")
        if kind == "weekly_recap" and not _load_ok(facts):
            raise ProtocolError("bad_request")
        if kind == "share" and not _share_ok(facts.get("share")):
            raise ProtocolError("bad_request")
        if kind == HEART_KIND and not _heart_ok(facts):
            raise ProtocolError("bad_request")
        if kind == "ghostclip" and not (isinstance(facts.get("elev_profile"), list) and len(facts["elev_profile"]) >= 8
                                        and "ghost_gap" in facts and len(facts["trail_board"]) >= 2):
            raise ProtocolError("bad_request")   # a race needs a hill to run along and a ghost to run against
    return op, kind, facts


def _load_ok(facts: dict) -> bool:
    """The weekly card's load block is all or nothing: a bounded load and usual, a known band, a percent, and exactly 6
    weeks of a Monday date, a load, a paused flag and the zone and no-heart-rate shares of that week's load."""
    have = LOAD_KEYS & set(facts)
    if not have:
        return True
    if have != LOAD_KEYS or not (_int_in(facts["load"], 0, 50000) and _int_in(facts["usual_load"], 0, 50000)
                                 and _int_in(facts["pct"], 0, 100000) and facts["band"] in LOAD_BANDS):
        return False
    wk = facts["weeks"]

    def share(x: Any) -> bool:
        return _num(x) and 0 <= x <= 1.0001
    return isinstance(wk, list) and len(wk) == 6 and all(
        isinstance(w, dict) and set(w) <= {"monday", "load", "paused", "zone_share", "nohr_share"} and _text(w.get("monday", ""))
        and len(w["monday"]) == 10 and _int_in(w.get("load"), 0, 50000) and isinstance(w.get("paused", False), bool)
        and isinstance(w.get("zone_share"), list) and len(w["zone_share"]) == 5 and all(share(x) for x in w["zone_share"])
        and share(w.get("nohr_share", 0)) for w in wk)


SHARE_FLAGS = frozenset({"route", "place", "time", "climb", "hr", "reps", "pace", "name", "date"})


def _share_ok(v: Any) -> bool:
    """The share image's opt-ins: a small dict of known flags, each a bool. Free text (a headline) is not accepted."""
    return v is None or (isinstance(v, dict) and set(v) <= SHARE_FLAGS and all(isinstance(x, bool) for x in v.values()))


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


def _trail_values_ok(facts: dict) -> bool:
    """Value shapes for the trail cards. A board needs at least two rows and exactly one is today. Every number is a bounded whole number, nothing is free text but the opt-in name."""
    def ints(v: Any, cap: int, lo: int, hi: int) -> bool:
        return isinstance(v, list) and 2 <= len(v) <= cap and all(_int_in(x, lo, hi) for x in v)
    board = facts.get("trail_board")
    if not (isinstance(board, list) and 2 <= len(board) <= TRAIL_BOARD_MAX and all(
            isinstance(r, dict) and set(r) <= {"attempt", "time_s", "today", "rank"} and _int_in(r.get("attempt"), 1, 999)
            and (r.get("rank") is None or _int_in(r["rank"], 1, 999))
            and _int_in(r.get("time_s"), 1, 86400) and isinstance(r.get("today", False), bool) for r in board)):
        return False
    if sum(1 for r in board if r.get("today")) != 1 or len({r["attempt"] for r in board}) != len(board):
        return False
    for k, v in facts.items():
        if k == "type":
            ok = v == "trail"
        elif k == "distance_km":
            ok = _num(v) and 0.01 <= v <= 500
        elif k == "duration_s":
            ok = _num(v) and 1 <= v <= 1_000_000
        elif k == "pace_s_per_km":
            ok = _num(v) and 60 <= v <= 3600
        elif k == "climb_m":
            ok = _num(v) and 0 <= v <= 10000
        elif k == "trail_runs":
            ok = _int_in(v, 1, 999)
        elif k == "trail_board":
            ok = True
        elif k == "elev_profile":
            ok = ints(v, TRAIL_PROFILE_MAX, -2000, 9000)
        elif k == "ghost_gap":
            ok = ints(v, TRAIL_PROFILE_MAX, -3600, 3600)
        elif k == "turn_idx":
            ok = _int_in(v, 0, TRAIL_PROFILE_MAX - 1)
        elif k == "trail_shape":
            ok = _in(v, TRAIL_SHAPES)
        elif k == "elev_src":
            ok = _in(v, ELEV_SRCS)
        elif k == "trail_name":
            ok = trail_name_ok(v)
        elif k == "hr_series":
            ok = ints(v, TRAIL_PROFILE_MAX, 30, 250)
        elif k == "hr_zones":
            ok = ints(v, TRAIL_PROFILE_MAX, 1, 5)
        else:
            ok = False
        if not ok:
            return False
    if _int_in(facts.get("trail_runs"), 1, 999) and facts["trail_runs"] < len(board):
        return False
    if "turn_idx" in facts and (not isinstance(facts.get("elev_profile"), list) or facts["turn_idx"] >= len(facts["elev_profile"])):
        return False
    return True


def _heart_ok(facts: dict) -> bool:
    """A heart card needs the hill to lay the heart over: a profile, and one bpm and one zone per profile point."""
    prof, hr, z = facts.get("elev_profile"), facts.get("hr_series"), facts.get("hr_zones")
    if not (isinstance(prof, list) and isinstance(hr, list) and isinstance(z, list) and len(prof) == len(hr) == len(z)):
        return False
    best = 0
    for _, zone in sorted(zip(hr, z)):   # a zone is a function of bpm: a higher bpm never sits in a lower zone
        if zone < best:
            return False
        best = zone
    return True


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
