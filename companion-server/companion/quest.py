"""Quests: the block the app sends with a run, the server's copy of it, and the words the coach uses.

The app owns quests (it holds the history, the trail grouping and True Pace) and works out every number. The server only keeps
what the app last said, so it can issue the month's card in Telegram, add one line when a quest is done, and nudge once. It never
computes progress and never guesses a quest. Every number is a whole number; there are no coordinates, run ids or dates other
than the end date. `trail_name` is a place, so it is kept only while the runner's place opt-in is on.
"""
from __future__ import annotations

import calendar
import re
from datetime import date, datetime, timedelta
from typing import Any, Mapping

from render.protocol import normalize_trail_name, trail_name_ok
from pydantic import BaseModel, ConfigDict, Field, StrictInt, ValidationError, field_validator, model_validator

from .timeutil import iso, zone

# kind -> the one unit it counts in
KIND_UNIT = {"trail_visits": "runs", "trail_best": "s", "climb_best": "s", "climb_month": "m", "distance_month": "km"}
ID_PATTERN = r"^q_[a-z0-9_-]{1,48}$"
MAX_OFFERS = 3
WINDOW_DAYS = 30
NUDGE_DAYS_LEFT = 7        # the one nudge goes when this many days or fewer are left ...
NUDGE_SHORT_SHARE = 0.25   # ... and the runner is at least a quarter short (or one run short)
RETENTION_DAYS = 90        # a quest row goes this long after its end (or after its offer month, if never taken)
BIG = 1_000_000


def _name_is_a_label(v):
    """A name that is digits only, has an @ or looks like a link is dropped (the copy says "your trail"); the quest stays."""
    if v is None:
        return None
    v = normalize_trail_name(v)
    return v if isinstance(v, str) and trail_name_ok(v) else None


class _Quest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=ID_PATTERN)
    kind: str
    target: StrictInt = Field(ge=1, le=BIG)
    trail_name: str | None = Field(default=None, max_length=30)

    @field_validator("kind")
    @classmethod
    def _known_kind(cls, v):
        if v not in KIND_UNIT:
            raise ValueError("unknown kind")
        return v

    @field_validator("trail_name", mode="wrap")
    @classmethod
    def _name(cls, v, handler):
        try:
            return _name_is_a_label(handler(v))
        except ValidationError:
            return None


class OfferIn(_Quest):
    baseline: StrictInt | None = Field(default=None, ge=0, le=BIG)
    unit: str

    @model_validator(mode="after")
    def _unit_fits_kind(self):
        if KIND_UNIT[self.kind] != self.unit:
            raise ValueError("unit does not fit the kind")
        return self


class ActiveIn(_Quest):
    value: StrictInt = Field(ge=0, le=BIG)
    ends_on: str

    @field_validator("ends_on")
    @classmethod
    def _real_date(cls, v: str) -> str:
        return date.fromisoformat(v).isoformat()


class ClosedIn(BaseModel):
    """The app closed a quest the server may still be showing: it finished, the runner dropped it, or its 30 days ran out."""
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=ID_PATTERN)
    result: str

    @field_validator("result")
    @classmethod
    def _known_result(cls, v):
        if v not in ("done", "dropped", "expired"):
            raise ValueError("unknown result")
        return v


class QuestIn(BaseModel):
    """The optional `quest` block of POST /v1/runs. A bad block drops the quest, never the run."""
    model_config = ConfigDict(extra="forbid")
    offers: list[OfferIn] = Field(default_factory=list, max_length=MAX_OFFERS)
    active: ActiveIn | None = None
    done_now: str | None = Field(default=None, pattern=ID_PATTERN)
    closed: ClosedIn | None = None
    month_skipped: str | None = Field(default=None, pattern=r"^\d{4}-(0[1-9]|1[0-2])$")   # "YYYY-MM": the runner said "Not this month"

    @model_validator(mode="after")
    def _something_to_say(self):
        if len({o.id for o in self.offers}) != len(self.offers):
            raise ValueError("offer ids must differ")
        if not (self.offers or self.active or self.done_now or self.closed or self.month_skipped):
            raise ValueError("empty quest block")
        return self


# ---------------------------------------------------------------- words
def clock(s: int) -> str:
    h, rest = divmod(int(s), 3600)
    m, sec = divmod(rest, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def _place(name: str | None) -> str:
    return name or "your trail"


def month_name(month: str) -> str:
    return calendar.month_name[int(month[5:7])]


def what(q: Mapping[str, Any]) -> str:
    """The quest as one plain sentence, no full stop."""
    kind, t, name = q["kind"], q["target"], q.get("trail_name")
    if kind == "trail_visits":
        return f"Run {_place(name)} {t} times in {WINDOW_DAYS} days"
    if kind == "trail_best":
        return f"Beat {clock(t)} on {_place(name)}. Your best so far, heat taken out"
    if kind == "climb_best":
        return f"Beat {clock(t)} up the climb on {_place(name)}. Your best so far"
    if kind == "climb_month":
        return f"Climb {t:,} m in {WINDOW_DAYS} days"
    return f"Run {t:,} km in {WINDOW_DAYS} days"


def offer_text(month: str, q: Mapping[str, Any]) -> tuple[str, str]:
    """(headline, body) of the month's offer card. `baseline` is the runner's own best, when the app sent it."""
    body = what(q) + "."
    b = q.get("baseline")
    if b is not None:
        if q["kind"] == "trail_visits":
            body += f" Your busiest {WINDOW_DAYS} days on it was {b}."
        elif q["kind"] in ("climb_month", "distance_month"):
            body += f" Your biggest {WINDOW_DAYS} days was {b:,} {q['unit']}."
    return f"{month_name(month)}'s quest", body


def taken_text(q: Mapping[str, Any]) -> str:
    return f"Quest taken. {what(q)}. {WINDOW_DAYS} days from today."


def done_line(q: Mapping[str, Any]) -> str:
    """The line added to the post-run card of the run that finished the quest."""
    kind, t, name = q["kind"], q["target"], q.get("trail_name")
    if kind == "trail_visits":
        return f"Quest done: {t} runs of {_place(name)}."
    if kind == "trail_best":
        return f"Quest done: you beat {clock(t)} on {_place(name)}."
    if kind == "climb_best":
        return f"Quest done: you beat {clock(t)} up the climb on {_place(name)}."
    if kind == "climb_month":
        return f"Quest done: {t:,} m climbed in {WINDOW_DAYS} days."
    return f"Quest done: {t:,} km in {WINDOW_DAYS} days."


def nudge_line(q: Mapping[str, Any]) -> str | None:
    """The one 7-days-left line, or None when the runner is not behind enough to need it."""
    kind, t, v, name = q["kind"], q["target"], q.get("value") or 0, q.get("trail_name")
    left = t - v
    if kind in ("trail_best", "climb_best"):   # a best is done or not: there is no share short
        where = "the climb on " + _place(name) if kind == "climb_best" else _place(name)
        return f"One good run on {where} could still beat {clock(t)}."
    if left < 1 or (kind != "trail_visits" and left / t < NUDGE_SHORT_SHARE):
        return None
    if kind == "trail_visits":
        return (f"One more run of {_place(name)} makes it {t}." if left == 1
                else f"{left} more runs of {_place(name)} make it {t}.")
    unit = "m" if kind == "climb_month" else "km"
    return f"{left:,} {unit} more makes it {t:,}."


# ---------------------------------------------------------------- state (callers hold the transaction)
def local_today(zone_id: str | None, now: datetime) -> date:
    return now.astimezone(zone(zone_id)).date()


def next_evening(now: datetime, zone_id: str | None, start_min: int, end_min: int) -> datetime:
    """The next time the evening window is open: now when it is open, else its start today or tomorrow."""
    z = zone(zone_id)
    loc = now.astimezone(z)
    m = loc.hour * 60 + loc.minute
    if start_min <= m < end_min:
        return now
    day = loc.date() + timedelta(days=0 if m < start_min else 1)
    return datetime(day.year, day.month, day.day, start_min // 60, start_min % 60, tzinfo=z).astimezone(now.tzinfo)


def active_row(c, uid: str, today: date) -> dict | None:
    r = c.execute("SELECT * FROM quests WHERE user_id=? AND state='accepted' AND (ends_on IS NULL OR ends_on >= ?) "
                  "ORDER BY accepted_at DESC LIMIT 1", (uid, today.isoformat())).fetchone()
    return dict(r) if r else None


def offered_rows(c, uid: str, month: str) -> list[dict]:
    return [dict(r) for r in c.execute("SELECT * FROM quests WHERE user_id=? AND month=? AND state='offered' ORDER BY pos, rowid",
                                       (uid, month))]


TRAIL_KINDS = frozenset({"trail_visits", "trail_best"})


def suggestable(c, uid: str, rows: list[dict]) -> list[dict]:
    """The offers worth putting on a card. Trail quests only when the runner's newest run was a trail run (or the app did not say what it was): a runner who
    is travelling or has gone back to the road is not offered a trail they are not on."""
    if not any(r["kind"] in TRAIL_KINDS for r in rows):
        return rows
    last = c.execute("SELECT app_type FROM runs WHERE user_id=? ORDER BY start_utc DESC LIMIT 1", (uid,)).fetchone()
    if last is None or last["app_type"] in (None, "trail"):   # no run, or the app did not say: do not guess
        return rows
    return [r for r in rows if r["kind"] not in TRAIL_KINDS]


def month_is_decided(c, uid: str, month: str) -> bool:
    """A quest was taken, skipped, finished or lapsed this month: nothing more is offered until next month."""
    return c.execute("SELECT 1 FROM quests WHERE user_id=? AND month=? AND state<>'offered'", (uid, month)).fetchone() is not None


def id_month(quest_id: str, fallback: str) -> str:
    """The month an offer belongs to is in its id (q_2026-11_...), not the month of the run that carried it."""
    m = re.match(r"^q_(\d{4}-(?:0[1-9]|1[0-2]))_", quest_id)
    return m.group(1) if m else fallback


def store(c, uid: str, q: QuestIn, month: str, run_id: str, today: date, now: datetime, keep_name: bool,
          older: bool = False) -> bool:
    """Keep what the run's quest block says. -> True when the month still has offers to issue.

    The app is the source of truth for progress and for what is active: an `active` it sends displaces a quest the runner
    accepted in Telegram under another id (the device that holds the history wins). `older` is a stale or out-of-order upload:
    its `active` and offers describe the past, so they are ignored; what it closed still counts."""
    ts = iso(now)
    name = (lambda n: n) if keep_name else (lambda n: None)
    c.execute("UPDATE quests SET state='expired', card_id=NULL, updated_at=? WHERE user_id=? AND state='accepted' AND ends_on < ?",
              (ts, uid, today.isoformat()))
    if q.month_skipped and not older:   # that month only: any offer still waiting goes, and so does its queued card
        c.execute("UPDATE quests SET state='skipped', card_id=NULL, updated_at=? WHERE user_id=? AND month=? AND state='offered'",
                  (ts, uid, q.month_skipped))
        c.execute("DELETE FROM outbox WHERE user_id=? AND kind='quest_offer' AND ref=? AND state='pending'", (uid, q.month_skipped))
    if q.closed:
        end = {"done": "done", "dropped": "skipped", "expired": "expired"}[q.closed.result]
        c.execute("UPDATE quests SET state=?, card_id=NULL, updated_at=? WHERE user_id=? AND quest_id=? AND state IN ('offered','accepted')",
                  (end, ts, uid, q.closed.id))
    if q.active and not older:
        a = q.active
        c.execute("UPDATE quests SET state='skipped', card_id=NULL, updated_at=? WHERE user_id=? AND state='accepted' AND quest_id<>?",
                  (ts, uid, a.id))
        have = c.execute("SELECT month, state FROM quests WHERE user_id=? AND quest_id=?", (uid, a.id)).fetchone()
        decided_month = None   # a quest already done, lapsed or skipped is not reopened by the app's word
        if have is None:
            c.execute("INSERT INTO quests (user_id, quest_id, month, kind, target, unit, trail_name, state, value, ends_on, "
                      "accepted_at, pos, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                      (uid, a.id, id_month(a.id, month), a.kind, a.target, KIND_UNIT[a.kind], name(a.trail_name), "accepted", a.value, a.ends_on,
                       ts, 0, ts, ts))
            decided_month = id_month(a.id, month)
        elif have["state"] in ("offered", "accepted"):
            c.execute("UPDATE quests SET state='accepted', value=?, ends_on=?, trail_name=COALESCE(?, trail_name), "
                      "accepted_at=COALESCE(accepted_at, ?), card_id=NULL, updated_at=? WHERE user_id=? AND quest_id=?",
                      (a.value, a.ends_on, name(a.trail_name), ts, ts, uid, a.id))
            decided_month = have["month"]
        if decided_month:   # one quest a month: the rest of that month's offers are off the table
            c.execute("UPDATE quests SET state='skipped', card_id=NULL, updated_at=? WHERE user_id=? AND month=? AND state='offered'",
                      (ts, uid, decided_month))
    if q.done_now:
        c.execute("UPDATE quests SET state='done', done_run_id=?, value=target, card_id=NULL, updated_at=? "
                  "WHERE user_id=? AND quest_id=? AND state IN ('offered','accepted')", (run_id, ts, uid, q.done_now))
    omonth = id_month(q.offers[0].id, month) if q.offers else month
    if q.offers and not older and q.month_skipped != omonth and not month_is_decided(c, uid, omonth):
        c.execute("DELETE FROM quests WHERE user_id=? AND month=? AND state='offered'", (uid, omonth))
        for pos, o in enumerate(q.offers):
            c.execute("INSERT OR IGNORE INTO quests (user_id, quest_id, month, kind, target, baseline, unit, trail_name, state, "
                      "pos, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                      (uid, o.id, omonth, o.kind, o.target, o.baseline, o.unit, name(o.trail_name), "offered", pos, ts, ts))
    return bool(offered_rows(c, uid, omonth))


def done_for_run(c, uid: str, run_id: str) -> dict | None:
    r = c.execute("SELECT * FROM quests WHERE user_id=? AND state='done' AND done_run_id=?", (uid, run_id)).fetchone()
    return dict(r) if r else None


def nudge_for(c, uid: str, today: date, now: datetime) -> str | None:
    """The one line for the evening suggestion, claimed once per quest (a quota row), or None."""
    r = active_row(c, uid, today)
    if not r or not r["ends_on"]:
        return None
    if not 1 <= (date.fromisoformat(r["ends_on"]) - today).days <= NUDGE_DAYS_LEFT:
        return None
    line = nudge_line(r)
    if line is None:
        return None
    if c.execute("INSERT OR IGNORE INTO quota (user_id, key, created_at) VALUES (?,?,?)",
                 (uid, f"qnudge:{r['quest_id']}", iso(now))).rowcount != 1:
        return None
    return line


def purge(c, now: datetime, held: str) -> None:
    cut = now - timedelta(days=RETENTION_DAYS)
    c.execute("DELETE FROM quests WHERE ends_on IS NOT NULL AND ends_on < ?" + held, (cut.date().isoformat(),))
    c.execute("DELETE FROM quests WHERE ends_on IS NULL AND month < ?" + held, (cut.strftime("%Y-%m"),))


def export_rows(c, uid: str) -> list[dict]:
    return [dict(r) for r in c.execute(
        "SELECT quest_id, month, kind, target, baseline, unit, trail_name, state, value, ends_on, accepted_at, created_at "
        "FROM quests WHERE user_id=? ORDER BY created_at, rowid", (uid,))]


def view_for_app(c, uid: str, today: date) -> dict | None:
    """What next-session says: the quest the runner has accepted, so the app can adopt one taken in Telegram."""
    r = active_row(c, uid, today)
    return {"id": r["quest_id"], "state": "accepted", "accepted_at": r["accepted_at"]} if r else None
