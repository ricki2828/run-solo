"""Check-ins: one-tap life answers that move the coach's next session. Pure logic, no I/O.

The runner answers with buttons only (fixed enums, no free text). The answers live in `checkin_answers` for 14 days and
nothing here is ever handed to the writer or any model: every line that uses an answer comes from checkin_copy.py
templates (eng-review A2). The next session is one resolver, `resolve`, so the evening rules, the morning card and
`GET /v1/me/next-session` always agree. It is a pure function of the app's planned session plus the answers, so a move is
never stored: delete the answer (Undo, or the 14-day purge) and the session is back where the plan put it.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from statistics import median
from typing import Any, Mapping, Sequence

from .timeutil import parse_iso, to_local

RETENTION_DAYS = 14

READY = ("fresh", "normal", "flat", "sore", "not_tomorrow")
TODAY = ("going", "later", "skip")
WHY = ("busy", "tired", "sore", "travelling", "ill")
POSTRUN = ("sleep", "stress", "heat", "none")
SHAPE = ("3", "4", "5", "away")
VALUES: dict[str, tuple[str, ...]] = {"ready": READY, "today": TODAY, "why": WHY, "postrun": POSTRUN, "shape": SHAPE}

# The coach goes lighter for this many days after a skip. Ill pauses longer (eng-review C8: rest, do not push on).
LIGHTER_DAYS = 3
ILL_DAYS = 7
POSTRUN_LIGHTER_DAYS = 2
MAX_MOVES = 6

# Slots (C2): when each is planned, how long it stays worth sending, and how long a tap on it still counts.
SLOTS = ("ready", "today", "postrun", "shape")
SEND_WINDOW_MIN = {"ready": 75, "today": 90, "postrun": 120, "shape": 120}   # after its due time; a later send is dropped
TAP_DAYS_AFTER = {"ready": 0, "today": 0, "postrun": 1, "shape": 2}          # local days after its date a tap still counts
TODAY_LEAD_MIN = 15       # the morning card goes this long before the usual start
TODAY_MIN_LEAD_MIN = 5    # ... and never closer to the start than this (after quiet hours it would arrive too late)
READY_START_MIN = 20 * 60  # the evening-before question, planned in the same window as the evening suggestion
READY_END_MIN = 21 * 60
SHAPE_START_MIN = 19 * 60 + 5   # Sunday, just after the recap
SHAPE_END_MIN = 20 * 60
POSTRUN_DELAY_MIN = 20

# callback code -> (kind, value). value "" clears that kind. Codes are the whole of a check-in button's callback data:
# `ci1:<card id>:<code>`, 4 + 32 + 1 + <= 8 bytes, far under Telegram's 64 (eng-review C6). The code names the stage, so
# a stale tap can never be read as another button: "w.sore" is only valid while the runner has said skip.
CODES: dict[str, tuple[str, str]] = {
    "r.fresh": ("ready", "fresh"), "r.normal": ("ready", "normal"), "r.flat": ("ready", "flat"),
    "r.sore": ("ready", "sore"), "r.not": ("ready", "not_tomorrow"), "r.chg": ("ready", ""),
    "t.go": ("today", "going"), "t.later": ("today", "later"), "t.skip": ("today", "skip"),
    "w.busy": ("why", "busy"), "w.tired": ("why", "tired"), "w.sore": ("why", "sore"),
    "w.trav": ("why", "travelling"), "w.ill": ("why", "ill"), "u.undo": ("undo", ""),
    "p.sleep": ("postrun", "sleep"), "p.stress": ("postrun", "stress"), "p.heat": ("postrun", "heat"),
    "p.none": ("postrun", "none"),
    "s.3": ("shape", "3"), "s.4": ("shape", "4"), "s.5": ("shape", "5"), "s.away": ("shape", "away"), "s.chg": ("shape", ""),
}
CODE_OF = {(k, v): c for c, (k, v) in CODES.items()}
SLOT_OF_KIND = {"ready": "ready", "today": "today", "why": "today", "undo": "today", "postrun": "postrun", "shape": "shape"}


@dataclass(frozen=True)
class Planned:
    """The app's next planned session, as the newest run row holds it."""
    type: str                  # easy | long | quality
    day: date                  # the planned local date
    week: int | None = None
    weeks: int | None = None
    minutes: int | None = None
    distance_m: int | None = None
    session_name: str | None = None    # the session's display name, when the app's plan_next carried one
    session_id: str | None = None      # the app's template id for it (a hint)


@dataclass(frozen=True)
class Resolved:
    type: str                  # easy | long | quality ("easy" when made easy)
    day: date
    moved: bool
    original_day: date
    easier: bool
    planned: Planned


@dataclass
class Answers:
    """The 14-day answers, by kind then local date."""
    by: dict[str, dict[date, str]] = field(default_factory=lambda: {k: {} for k in VALUES})
    stamped: dict[tuple[str, date], datetime] = field(default_factory=dict)

    def get(self, kind: str, d: date) -> str | None:
        return self.by[kind].get(d)

    def with_(self, kind: str, d: date, value: str) -> "Answers":
        out = Answers({k: dict(v) for k, v in self.by.items()}, dict(self.stamped))
        out.by[kind][d] = value
        return out

    @classmethod
    def from_rows(cls, rows: Sequence[Mapping[str, Any]]) -> "Answers":
        a = cls()
        for r in rows:
            if r["kind"] in a.by and r["value"] in VALUES[r["kind"]]:
                try:
                    d = date.fromisoformat(r["local_date"])
                except ValueError:
                    continue
                a.by[r["kind"]][d] = r["value"]
                if r.get("created_at"):
                    a.stamped[(r["kind"], d)] = parse_iso(r["created_at"])
        return a


def planned_from_run(run: Mapping[str, Any] | None) -> Planned | None:
    """The plan snapshot on the newest run row (companion.service stores plan_next_*), or None."""
    if not run or run.get("plan_next_type") not in ("easy", "long", "quality") or not run.get("plan_next_day"):
        return None
    try:
        day = date.fromisoformat(run["plan_next_day"])
    except ValueError:
        return None
    return Planned(run["plan_next_type"], day, run.get("plan_next_week"), run.get("plan_weeks"),
                   run.get("plan_next_min"), run.get("plan_next_m"),
                   run.get("plan_next_session_name"), run.get("plan_next_session_id"))


def usual_weekdays(usual: str | None) -> frozenset[int] | None:
    """memory `usual_days` -> the weekdays the runner runs on (Mon=0), or None for any day."""
    return {"weekdays": frozenset(range(5)), "weekends": frozenset({5, 6})}.get(usual or "")


def _next_usual(earliest: date, usual: frozenset[int] | None) -> date:
    d = earliest
    for _ in range(8):
        if usual is None or d.weekday() in usual:
            return d
        d += timedelta(days=1)
    return earliest


def lighter_days(why: str | None) -> int:
    return ILL_DAYS if why == "ill" else LIGHTER_DAYS


def _move_from(d: date, a: Answers, usual: frozenset[int] | None) -> date | None:
    """Where a session planned for `d` goes when the answers say it is not happening that day, or None to stay."""
    if a.get("today", d) == "skip":
        return _next_usual(d + timedelta(days=lighter_days(a.get("why", d)) + 1), usual)
    ready = a.get("ready", d)
    if ready == "not_tomorrow":
        return _next_usual(d + timedelta(days=1), usual)
    if ready == "sore":
        return _next_usual(d + timedelta(days=LIGHTER_DAYS + 1), usual)
    return None


def resolve(planned: Planned | None, a: Answers, today: date, usual: frozenset[int] | None = None) -> Resolved | None:
    """The coach's next session. A skipped day (and a "not tomorrow" or "sore" the evening before) moves the session to
    the next usual day after the lighter window; "flat" keeps the day but makes it easy; "away" moves it past that week.
    None when nothing is planned or the date has passed."""
    if planned is None:
        return None
    d, moved = planned.day, False
    for _ in range(MAX_MOVES):
        nd = _move_from(d, a, usual)
        if nd is None or nd == d:
            break
        d, moved = nd, True
    for monday, v in sorted(a.by["shape"].items()):
        if v == "away" and monday <= d <= monday + timedelta(days=6):
            d, moved = _next_usual(monday + timedelta(days=7), usual), True
    if d < today:
        return None
    easier = planned.type != "easy" and (a.get("ready", d) == "flat" or lighter_covers(a, d))
    return Resolved("easy" if easier else planned.type, d, moved, planned.day, easier, planned)


def lighter_windows(a: Answers) -> list[tuple[date, date, str]]:
    """(first day, last day, source) of every window in which the coach keeps things light: a skip (3 days, 7 for ill)
    from the day skipped, a sore evening-before answer from the session day, a sleepless or stressed post-run answer
    from the run day. Derived on read, never stored, so the purge removes it with the answers."""
    out: list[tuple[date, date, str]] = []
    for d, v in a.by["today"].items():
        if v == "skip":
            why = a.get("why", d)
            out.append((d, d + timedelta(days=lighter_days(why)), "ill" if why == "ill" else "skip"))
    for d, v in a.by["ready"].items():
        if v == "sore":
            out.append((d, d + timedelta(days=LIGHTER_DAYS), "sore"))
    for d, v in a.by["postrun"].items():
        if v in ("sleep", "stress"):
            out.append((d, d + timedelta(days=POSTRUN_LIGHTER_DAYS), "postrun"))
    return out


def lighter_until(a: Answers, today: date) -> date | None:
    """The last day the coach keeps things light, or None when no window reaches today or later."""
    live = [e for _s, e, _k in lighter_windows(a) if e >= today]
    return max(live) if live else None


def lighter_covers(a: Answers, day: date) -> bool:
    """Is `day` inside a lighter window? Soften outranks the plan, so a session on such a day is made easy wherever it
    is shown (the morning card, the next-session view, the week card), whatever plan the newest run brought."""
    return any(s <= day <= e for s, e, _k in lighter_windows(a))


def ill_covers(a: Answers, day: date) -> bool:
    return any(s <= day <= e for s, e, k in lighter_windows(a) if k == "ill")


def away_covers(a: Answers, day: date) -> bool:
    return any(v == "away" and m <= day <= m + timedelta(days=6) for m, v in a.by["shape"].items())


def _signature(slot: str, planned: Planned | None, a: Answers, today: date, usual: frozenset[int] | None):
    """What the coach would do next under these answers. The post-run question has no session to move, so for it the
    lighter window is the outcome; for the others the next session is, and without a plan there is none to change."""
    r = resolve(planned, a, today, usual)
    session = (r.day, r.type) if r else None
    return (session, lighter_until(a, today)) if slot == "postrun" else session


def worth_asking(slot: str, planned: Planned | None, a: Answers, for_date: date, today: date,
                 usual: frozenset[int] | None = None) -> bool:
    """C1: ask only when the answers lead to at least two different next suggestions. The resolver is run once per
    possible answer; if they all give the same next session and the same lighter window, the question changes nothing
    and is not asked."""
    kind = {"ready": "ready", "today": "today", "postrun": "postrun", "shape": "shape"}[slot]
    outcomes = {_signature(slot, planned, a.with_(kind, for_date, v), today, usual) for v in VALUES[kind]}
    return len(outcomes) >= 2


# ---------------------------------------------------------------- when things happen
def at_local(d: date, minute: int, zone_id: str | None) -> datetime:
    """The UTC instant of local wall time `minute` (after midnight) on `d`. Built from wall time, so DST is safe."""
    from .timeutil import zone, UTC
    return datetime(d.year, d.month, d.day, minute // 60, minute % 60, tzinfo=zone(zone_id)).astimezone(UTC)


def usual_start_min(history: Sequence[Mapping[str, Any]], weekday: int, zone_id: str, now: datetime) -> int | None:
    """The runner's usual start, in minutes after local midnight, rounded to 5. The median start of the runs on this
    weekday in the last 8 weeks when there are two or more; else the median of the last 8 runs; else None."""
    def minute(h: Mapping[str, Any]) -> tuple[int, int]:
        loc = to_local(parse_iso(h["start_utc"]), h.get("zone_id") or zone_id)
        return loc.weekday(), loc.hour * 60 + loc.minute

    recent = [minute(h) for h in history if (now - parse_iso(h["start_utc"])).days <= 56]
    same = [m for wd, m in recent if wd == weekday]
    pool = same if len(same) >= 2 else [minute(h)[1] for h in history[:8]]
    if not pool:
        return None
    # a circular median: starts either side of midnight (23:50 and 00:10) must not average to midday
    ref = pool[0]
    off = [((m - ref + 720) % 1440) - 720 for m in pool]
    return int(round(((median(off) + ref) % 1440) / 5.0) * 5) % 1440


def send_deadline(slot: str, due: datetime, latest: datetime | None = None) -> datetime:
    """When a slot stops being worth sending. `latest` caps it: the morning card never goes out after start - 5 min."""
    d = due + timedelta(minutes=SEND_WINDOW_MIN[slot])
    return min(d, latest) if latest else d


def tap_open(slot: str, for_date: date, local_today: date) -> bool:
    return local_today <= for_date + timedelta(days=TAP_DAYS_AFTER[slot])


# ---------------------------------------------------------------- when the post-run question is worth asking
def run_is_ambiguous(run: Mapping[str, Any]) -> bool:
    """An easy run that came out slower with a lot of time in the harder zones: the numbers alone cannot say why.
    Only then does the coach ask. Zones come from the run row (zone_min), as in convo.touches.hard_share."""
    from .convo.touches import _zone_minutes
    if run.get("type") != "easy" or run.get("verdict") != "slower":
        return False
    z = _zone_minutes(run)
    total = sum(z.values())
    return bool(total) and (z.get(3, 0) + z.get(4, 0) + z.get(5, 0)) / total >= 0.25
