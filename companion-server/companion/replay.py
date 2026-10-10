"""Coach replay: walk a runner's real history on a virtual clock and send what the live coach would have sent.

    python -m companion.cli replay <facts_dir> --every 300 [--dry-run] [--from YYYY-MM-DD]
    python -m companion.cli replay-stop | replay-abort

`facts_dir` holds one JSON per run, exactly the body the app POSTs to /v1/runs (see
packages/run_engine/tool/companion_facts.dart). Everything else is the production Service driven with a virtual `now`:
quiet hours, the two-a-week suggestion cap, no repeats, B4 and the evening / Sunday-recap schedule all read that clock.

Items are generated LAZILY, one at a time, just before they are sent, so a button tap that the live webhook records
between two items changes the next one. State lives in the database (`replay_state`), so a stop or a crash resumes
where it was, and while it runs the live worker leaves this user alone (service.REPLAY_HOLD).
"""
from __future__ import annotations

import json
import logging
import sqlite3
import tempfile
import time
from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Callable

import httpx

from . import db
from .channels import OutCard
from .config import Settings
from .convo import recap as cv_recap
from .convo import suggest as cv_suggest
from .service import RunIn, Service
from .timeutil import UTC, iso, now_utc, parse_iso, to_local, zone

log = logging.getLogger("companion.replay")

UPLOAD_DELAY_S = 60        # the app posts a run about a minute after it finishes
HEARTBEAT_FRESH_S = 45     # a 'running' row with a newer heartbeat than this means another process is driving
TICK_MINUTES = (cv_recap.RECAP_START_MIN, cv_suggest.EVENING_START_MIN)  # local planning moments, as the live tick sees them
MAX_RETRIES_PER_ITEM = 5


class ReplayError(Exception):
    pass


# ---------------------------------------------------------------------------------------- facts

def load_facts(facts_dir: str | Path) -> list[RunIn]:
    """Every `*.json` in the folder as the run the app would have uploaded, oldest first. Validated by the
    server's own RunIn model, so a file the live endpoint would refuse is refused here too."""
    d = Path(facts_dir)
    if not d.is_dir():
        raise ReplayError(f"not a folder: {d}")
    runs: dict[str, RunIn] = {}
    for f in sorted(d.glob("*.json")):
        try:
            r = RunIn.model_validate(json.loads(f.read_text()))
        except (ValueError, OSError) as e:
            raise ReplayError(f"{f.name}: {str(e)[:200]}") from None
        if r.run_id in runs:
            raise ReplayError(f"{f.name}: run id {r.run_id} appears twice")
        runs[r.run_id] = r
    if not runs:
        raise ReplayError(f"no *.json run files in {d}")
    return sorted(runs.values(), key=lambda r: (r.start_utc, r.run_id))


def upload_time(r: RunIn) -> datetime:
    return r.start_utc + timedelta(seconds=r.duration_s + UPLOAD_DELAY_S)


# ---------------------------------------------------------------------------------------- channels

class Recorder:
    """Dry-run stand-in for Telegram: remembers what would have been sent."""
    name = "telegram"

    def __init__(self) -> None:
        self.sent: list[dict] = []

    def send_card(self, ref: str, card: OutCard, **_: Any) -> str:
        self.sent.append({"text": f"{card.headline}\n{card.body}", "buttons": [b["label"] for b in card.buttons]})
        return str(len(self.sent))

    def send_text(self, ref: str, text: str) -> str:
        self.sent.append({"text": text, "buttons": []})
        return str(len(self.sent))

    @staticmethod
    def followups(card: OutCard) -> list[str]:
        return []

    def send_followup(self, ref: str, card: OutCard, mode: str) -> str:
        return self.send_text(ref, f"{card.headline}\n{card.body}")


class ReplayChannel:
    """Wraps the real channel. Puts one small context line on top of every message ("Replay · Tue 6 Oct, 07:13"),
    and records each send with its virtual and real time so a later tap can be dated on the card's own clock."""

    def __init__(self, inner: Any, replayer: "Replayer"):
        self.inner, self.r = inner, replayer
        self.name = inner.name

    def __getattr__(self, item: str) -> Any:  # ack_callback, parse ... stay the inner channel's
        return getattr(self.inner, item)

    def _tag(self, kind: str, card_id: str | None) -> str:
        self.r.note_send(kind, card_id)
        return self.r.label()

    def send_card(self, ref: str, card: OutCard, **kw: Any) -> str:
        line = self._tag(self.r.card_kind(card.card_id), card.card_id)
        return self.inner.send_card(ref, replace(card, headline=f"{line}\n{card.headline}"), **kw)

    def send_text(self, ref: str, text: str) -> str:
        return self.inner.send_text(ref, f"{self._tag('text', None)}\n{text}")

    def send_followup(self, ref: str, card: OutCard, mode: str) -> str:
        self._tag("followup", card.card_id)  # media is off, so the service never asks for one; kept honest anyway
        return self.inner.send_followup(ref, card, mode)


# ---------------------------------------------------------------------------------------- replay

@dataclass
class Item:
    n: int
    card_id: str | None
    kind: str
    virtual_at: datetime
    local: str
    text: str
    buttons: list[str]


class Replayer:
    def __init__(self, svc: Service, uid: str, runs: list[RunIn], every_s: int, *, facts_dir: str = "",
                 from_dt: datetime | None = None, real_now: Callable[[], datetime] = now_utc,
                 sleep: Callable[[float], None] = time.sleep, on_item: Callable[[Item], None] | None = None,
                 out: Callable[[str], None] = print, channel: Any = None):
        if every_s < 0:
            raise ReplayError("--every must be 0 or more seconds")
        self.svc, self.uid, self.runs, self.every_s = svc, uid, runs, every_s
        self.facts_dir, self.from_dt, self.real_now, self.sleep, self.on_item, self.out = (
            facts_dir, from_dt, real_now, sleep, on_item, out)
        self.s = svc.s
        self.vnow: datetime = datetime(1970, 1, 1, tzinfo=UTC)
        self.items: list[Item] = []
        self._sig_stop = False
        self._retries: dict[int, int] = {}
        inner = channel if channel is not None else svc.channels.get("telegram")
        while isinstance(inner, ReplayChannel):  # a second replayer on the same service must not stack prefixes
            inner = inner.inner
        if inner is None:
            raise ReplayError("telegram is not configured")
        svc.channels["telegram"] = ReplayChannel(inner, self)
        self._pending_note: tuple[str, str | None] | None = None

    # -- bookkeeping the channel wrapper calls
    def label(self) -> str:
        loc = to_local(self.vnow, self._zone())
        return f"Replay · {loc:%a} {loc.day} {loc:%b}, {loc:%H:%M}"

    def card_kind(self, card_id: str) -> str:
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT kind FROM cards WHERE card_id=?", (card_id,)).fetchone()
        return r["kind"] if r else "card"

    def note_send(self, kind: str, card_id: str | None) -> None:
        self._pending_note = (kind, card_id)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO replay_items (user_id, card_id, kind, virtual_at, real_at) VALUES (?,?,?,?,?)",
                      (self.uid, card_id, kind, iso(self.vnow), iso(self.real_now())))

    def _zone(self) -> str:
        with db.ro(self.s.db_path) as c:
            return c.execute("SELECT zone_id FROM users WHERE id=?", (self.uid,)).fetchone()["zone_id"]

    # -- state
    def _state(self) -> sqlite3.Row | None:
        with db.ro(self.s.db_path) as c:
            return c.execute("SELECT * FROM replay_state WHERE user_id=?", (self.uid,)).fetchone()

    def _save(self, **cols: Any) -> None:
        cols["updated_at"] = iso(self.real_now())
        sets = ", ".join(f"{k}=?" for k in cols)
        with db.tx(self.s.db_path) as c:
            c.execute(f"UPDATE replay_state SET {sets} WHERE user_id=?", (*cols.values(), self.uid))

    def _beat(self) -> None:
        self._save(heartbeat_at=iso(self.real_now()), vnow=iso(self.vnow))

    def request_stop(self) -> None:
        """Signal-safe: finish the current item, then stop."""
        self._sig_stop = True

    def _stopping(self) -> bool:
        if self._sig_stop:
            return True
        st = self._state()
        return bool(st and st["status"] == "stopping")

    # -- start / resume
    def prepare(self) -> bool:
        """Create or resume the state row. True when it resumed."""
        st = self._state()
        now = self.real_now()
        if st is not None:
            if st["status"] == "done":
                raise ReplayError("this replay is complete (replay-abort and a new run are not needed: nothing is left)")
            fresh = st["heartbeat_at"] and parse_iso(st["heartbeat_at"]) > now - timedelta(seconds=HEARTBEAT_FRESH_S)
            if st["status"] in ("running", "stopping") and fresh:
                raise ReplayError("a replay is already running; use replay-stop first")
            if st["facts_dir"] != self.facts_dir:
                raise ReplayError(f"a replay of {st['facts_dir']} is in progress; resume that folder or replay-abort")
            self.vnow = parse_iso(st["vnow"])
            self._save(status="running", every_s=self.every_s, heartbeat_at=iso(now))
            return True
        first = upload_time(self.runs[0])
        self.vnow = self.from_dt or (first - timedelta(minutes=1))
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO replay_state (user_id, status, facts_dir, every_s, vnow, last_tick, items, heartbeat_at, "
                      "started_at, updated_at) VALUES (?,?,?,?,?,?,0,?,?,?)",
                      (self.uid, "running", self.facts_dir, self.every_s, iso(self.vnow), iso(self.vnow), iso(now),
                       iso(now), iso(now)))
        # History before --from is context only: stored like an offline-queued old run, no card.
        for r in self.runs:
            if self.from_dt and upload_time(r) < self.from_dt:
                self._ingest(r, silent=True)
        return False

    def _ingest(self, r: RunIn, *, silent: bool = False) -> None:
        with db.ro(self.s.db_path) as c:
            exists = c.execute("SELECT 1 FROM runs WHERE user_id=? AND run_id=?", (self.uid, r.run_id)).fetchone()
        due = upload_time(r)
        if exists:  # uploaded for real already: replay its card at its own moment instead of today's
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE outbox SET due_at=? WHERE user_id=? AND dedupe_key=? AND state='pending'",
                          (iso(max(due, self.vnow)), self.uid, f"card:{self.uid}:{r.run_id}"))
                c.execute("INSERT OR IGNORE INTO replay_runs (user_id, run_id, inserted) VALUES (?,?,0)",
                          (self.uid, r.run_id))
            return
        stale_now = r.start_utc + timedelta(seconds=r.duration_s) + timedelta(hours=self.s.stale_card_hours + 1)
        at = stale_now if silent else max(due, self.vnow)
        self.svc.ingest_run(self.uid, r, at)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT OR IGNORE INTO replay_runs (user_id, run_id) VALUES (?,?)", (self.uid, r.run_id))

    # -- the clock
    def _ingested(self) -> set[str]:
        """Runs the replay has reached (inserted by it, or already there from a real upload)."""
        with db.ro(self.s.db_path) as c:
            return {x["run_id"] for x in c.execute("SELECT run_id FROM replay_runs WHERE user_id=?", (self.uid,))}

    def _next_tick(self) -> datetime:
        st = self._state()
        after = parse_iso(st["last_tick"]) if st and st["last_tick"] else self.vnow
        z = zone(self._zone())
        day = to_local(after, z.key).date()
        for add in range(0, 4):
            d = day + timedelta(days=add)
            for m in sorted(TICK_MINUTES):
                cand = datetime(d.year, d.month, d.day, m // 60, m % 60, tzinfo=z).astimezone(UTC)
                if cand > after:
                    return cand
        return after + timedelta(days=1)

    def _next_event(self) -> datetime | None:
        cands: list[datetime] = []
        have = self._ingested()
        nxt = next((r for r in self.runs if r.run_id not in have), None)
        if nxt is not None:
            cands.append(upload_time(nxt))
        with db.ro(self.s.db_path) as c:
            o = c.execute("SELECT MIN(due_at) d FROM outbox WHERE user_id=? AND state IN ('pending','sending')",
                          (self.uid,)).fetchone()["d"]
        if o:
            cands.append(parse_iso(o))
        cands.append(self._next_tick())
        t = max(min(cands), self.vnow)
        return t if t <= self.real_now() else None

    def _held(self) -> bool:
        with db.ro(self.s.db_path) as c:
            paused = c.execute("SELECT paused FROM users WHERE id=?", (self.uid,)).fetchone()["paused"]
        return bool(paused) or self.svc._kill_switch()

    def _recover_failed(self) -> bool:
        with db.tx(self.s.db_path) as c:
            rows = [r["id"] for r in c.execute("SELECT id FROM outbox WHERE user_id=? AND state='failed'", (self.uid,))]
            for i in rows:
                self._retries[i] = self._retries.get(i, 0) + 1
                if self._retries[i] > MAX_RETRIES_PER_ITEM:
                    c.execute("UPDATE outbox SET state='skipped' WHERE id=?", (i,))
                    log.error("replay gave up on outbox item %s after %d tries", i, MAX_RETRIES_PER_ITEM)
                else:
                    c.execute("UPDATE outbox SET state='pending', attempts=0, due_at=? WHERE id=?", (iso(self.vnow), i))
        return bool(rows)

    # -- one item
    def _pace(self) -> None:
        for _ in range(self.every_s):
            if self._stopping():
                return
            self.sleep(1)
            self._beat()

    def run(self, max_items: int | None = None) -> str:
        """Drive the clock until the history is spent, a stop is requested or `max_items` were sent.
        Returns 'done', 'stopped' or 'limit'."""
        self.prepare()
        sent_here = 0
        while True:
            self._beat()
            if self._stopping():
                self._save(status="stopped")
                return "stopped"
            if max_items is not None and sent_here >= max_items:
                self._save(status="stopped")
                return "limit"
            if self._held():
                self.sleep(5)
                continue
            if self._recover_failed():
                self.sleep(30)
            t = self._next_event()
            if t is None:
                self._finish()
                return "done"
            self.vnow = t
            for r in self.runs:  # arrivals due at this moment
                if upload_time(r) <= self.vnow and r.run_id not in self._ingested():
                    self._ingest(r)
            tick = self._next_tick()
            if tick <= self.vnow:
                self.svc.plan_evening(tick, only_user=self.uid)
                self.svc.plan_recap(tick, only_user=self.uid)
                self._save(last_tick=iso(tick))
            self._pending_note = None
            self.svc.run_outbox(self.vnow, limit=1, only_user=self.uid)
            self._save(vnow=iso(self.vnow))
            if self._pending_note is None:
                continue  # nothing went out (deferred, skipped or silent): the clock just moves on
            sent_here += 1
            item = self._record_item()
            if self.on_item:
                self.on_item(item)
            self._pace()

    def _record_item(self) -> Item:
        kind, card_id = self._pending_note or ("card", None)
        text, buttons = "", []
        if card_id:
            with db.ro(self.s.db_path) as c:
                r = c.execute("SELECT headline, body, buttons_json FROM cards WHERE card_id=?", (card_id,)).fetchone()
            if r:
                text, buttons = f"{r['headline']}\n{r['body']}", [b["label"] for b in json.loads(r["buttons_json"])]
        with db.tx(self.s.db_path) as c:
            n = c.execute("SELECT items FROM replay_state WHERE user_id=?", (self.uid,)).fetchone()["items"] + 1
            c.execute("UPDATE replay_state SET items=? WHERE user_id=?", (n, self.uid))
        item = Item(n, card_id, kind, self.vnow, self.label().removeprefix("Replay · "), text, buttons)
        self.items.append(item)
        self.out(f"#{n:03d} {item.local}  {kind}")
        return item

    def _finish(self) -> None:
        cut = iso(self.real_now() - timedelta(hours=self.s.stale_card_hours))
        with db.tx(self.s.db_path) as c:  # leftovers the live worker must not send in a flood on release
            c.execute("UPDATE outbox SET state='skipped' WHERE user_id=? AND state IN ('pending','sending') AND due_at < ?",
                      (self.uid, cut))
        self._save(status="done", vnow=iso(self.vnow))


# ---------------------------------------------------------------------------------------- entry points

def find_user(settings: Settings) -> str:
    """The single enrolled, allowlisted Telegram user. The replay is Ricki's own history; anything else is an error."""
    with db.ro(settings.db_path) as c:
        rows = [dict(r) for r in c.execute("SELECT id, chat_ref FROM users WHERE channel='telegram' AND consent_at IS NOT NULL "
                                           "AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = users.id)")]
    mine = [r for r in rows if f"telegram:{r['chat_ref']}" in settings.allowed_ids]
    if len(mine) != 1:
        raise ReplayError(f"expected exactly one enrolled allowlisted Telegram user, found {len(mine)}")
    return mine[0]["id"]


def replay_settings(s: Settings) -> Settings:
    return replace(s, media_enabled=False)  # text cards with buttons only


def from_datetime(text: str | None, zone_id: str) -> datetime | None:
    if not text:
        return None
    try:
        d = date.fromisoformat(text)
    except ValueError:
        raise ReplayError("--from needs YYYY-MM-DD") from None
    return datetime(d.year, d.month, d.day, tzinfo=zone(zone_id)).astimezone(UTC)


def dry_run(settings: Settings, facts_dir: str, every_s: int, from_text: str | None, full: bool = False,
            out: Callable[[str], None] = print) -> int:
    """The whole schedule on a scratch copy of the database, nothing sent. Taps are not simulated, so the real run
    diverges from this wherever a button press would have changed what comes next."""
    runs = load_facts(facts_dir)
    uid = find_user(settings)
    with tempfile.TemporaryDirectory(prefix="replay-dry-") as td:
        path = str(Path(td) / "dry.db")
        src = db.connect(settings.db_path)
        dst = sqlite3.connect(path)
        try:
            src.backup(dst)
        finally:
            src.close()
            dst.close()
        Path(path).chmod(0o600)
        s2 = replace(replay_settings(settings), db_path=path, openrouter_key=None, weather_enabled=False,
                     sends_paused=False)
        svc = Service(s2, httpx.Client(timeout=5))
        with db.tx(path) as c:  # carry on from wherever a real replay got to, but as a fresh, idle process
            c.execute("UPDATE replay_state SET status='stopped', heartbeat_at=NULL WHERE user_id=?", (uid,))
            c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('sends_paused', '0')")
        rec = Recorder()
        r = Replayer(svc, uid, runs, 0, facts_dir=facts_dir, from_dt=from_datetime(from_text, runs[0].zone_id),
                     channel=rec, out=lambda _l: None)
        r.run()
        out(f"Dry run: {len(r.items)} messages, one every {every_s} s of wall time = "
            f"{len(r.items) * every_s / 3600:.1f} h. No taps simulated; the phrasing here is the template one (no model call).")
        for it in r.items:
            first, *_ = it.text.splitlines() or [""]
            out(f"#{it.n:03d} +{it.n * every_s // 60:>5d}m  {it.local:<18} {it.kind:<9} {first}"
                + (f"  [{' | '.join(it.buttons)}]" if it.buttons else ""))
            if full:
                out("      " + it.text.replace("\n", "\n      "))
    return 0
