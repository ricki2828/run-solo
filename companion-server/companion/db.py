"""SQLite access. One short-lived connection per operation (WAL, secure_delete)."""
from __future__ import annotations

import os
import sqlite3
import threading
from contextlib import contextmanager
from typing import Iterator

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  channel TEXT NOT NULL CHECK (channel IN ('telegram','whatsapp')),
  chat_ref TEXT NOT NULL,
  chat_name TEXT,
  created_at TEXT NOT NULL,
  consent_version TEXT, consent_at TEXT, consent_msg_id TEXT,
  zone_id TEXT NOT NULL DEFAULT 'UTC',
  tz_set_at TEXT,  -- when the app last PUT a zone; a run that started before it cannot move the zone
  utc_offset_min INTEGER NOT NULL DEFAULT 0,
  quiet_start INTEGER, quiet_end INTEGER,
  paused INTEGER NOT NULL DEFAULT 0,
  last_run_utc TEXT, last_inbound_at TEXT,
  cap_zone TEXT, cap_week TEXT,
  weather_optin INTEGER NOT NULL DEFAULT 0,  -- the app's "Weather in suggestions" switch; area is stored only while 1
  route_optin INTEGER NOT NULL DEFAULT 1,    -- the app's "Show route shape on cards" switch (default on); a shape is stored only while 1
  UNIQUE (channel, chat_ref)
);
CREATE TABLE IF NOT EXISTS devices (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS enrolments (
  nonce TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  poll_hash TEXT NOT NULL,
  code TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  consent_msg_id TEXT,
  chat_name TEXT
);
CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  start_utc TEXT NOT NULL, end_utc TEXT NOT NULL,
  utc_offset_min INTEGER NOT NULL, zone_id TEXT NOT NULL,
  type TEXT NOT NULL,  -- the coach's type (easy | long | tempo | interval | race), inferred from the app's
  app_type TEXT,       -- the app's own type (intervals | cooper | laps | free | trail); NULL when it sent a coach type
  duration_s INTEGER NOT NULL, distance_m INTEGER NOT NULL,
  pace_s_per_km REAL, true_pace_s_per_km REAL,
  verdict TEXT, scores_delta TEXT, zone_min TEXT,
  climb_m INTEGER, locality TEXT, route_id TEXT,
  load_state TEXT, pb TEXT,
  plan_kind TEXT, plan_target_m INTEGER, plan_weeks_to_race INTEGER,
  plan_week INTEGER, plan_weeks INTEGER,  -- the app's 4-week block: this run's week, of how many
  plan_next_type TEXT, plan_next_day TEXT, plan_next_week INTEGER, plan_next_min INTEGER, plan_next_m INTEGER,  -- the next planned session
  feel TEXT,
  session_name TEXT, work_pace_s_per_km REAL, reps_done INTEGER, rep_spread_s REAL, recovery_pace_s_per_km REAL,  -- an interval session, from the app's verdict numbers
  received_at TEXT NOT NULL,
  stale INTEGER NOT NULL DEFAULT 0,
  real_upload INTEGER,  -- 1 the app uploaded it; 0 a coach replay created it from an export; NULL rows from before this column
  UNIQUE (user_id, run_id)
);
CREATE INDEX IF NOT EXISTS runs_user_start ON runs (user_id, start_utc);
CREATE TABLE IF NOT EXISTS memory (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key TEXT NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, key)
);
CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT, kind TEXT NOT NULL,
  headline TEXT NOT NULL, body TEXT NOT NULL,
  buttons_json TEXT NOT NULL,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL, sent_at TEXT, answered_at TEXT,
  quote_run_id TEXT  -- a recap that quotes this run's note: the quote is looked up at send time, never stored in body
);
CREATE UNIQUE INDEX IF NOT EXISTS cards_once ON cards (user_id, run_id, kind) WHERE run_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  due_at TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  dedupe_key TEXT NOT NULL UNIQUE,
  ref TEXT,
  last_error TEXT
);
CREATE INDEX IF NOT EXISTS outbox_due ON outbox (state, due_at);
CREATE TABLE IF NOT EXISTS quota (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, key)
);
CREATE TABLE IF NOT EXISTS outcomes (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  card_id TEXT NOT NULL, kind TEXT NOT NULL, outcome TEXT NOT NULL, ts TEXT NOT NULL,
  PRIMARY KEY (user_id, card_id)
);
CREATE TABLE IF NOT EXISTS msglog (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts TEXT NOT NULL, direction TEXT NOT NULL, kind TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS inbound_seen (
  msg_id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  ts TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS convo_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,  -- variant | touch | card | sunrise | recap_empty
  key TEXT NOT NULL, ts TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS convo_log_user ON convo_log (user_id, kind, ts);
CREATE TABLE IF NOT EXISTS convo_cards (
  card_id TEXT PRIMARY KEY REFERENCES cards(card_id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  situation TEXT NOT NULL, media_json TEXT NOT NULL,
  allowed TEXT NOT NULL,       -- the number sources behind this card's text (eng-review B4 audit)
  touch_kind TEXT
);
-- A note the runner typed for one run ("Add a note"). Kept apart from `runs` so no SELECT * over runs can carry it into
-- a prompt or a render. Read only by the deterministic recap quote and keyword softening; never sent to a model.
-- It lives and dies with its run (cascade), and with the user (hard delete).
CREATE TABLE IF NOT EXISTS run_notes (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  note TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, run_id),
  FOREIGN KEY (user_id, run_id) REFERENCES runs (user_id, run_id) ON DELETE CASCADE
);
-- The simplified route shape, per-km splits and rep times the app sends for the cards and videos. Kept apart from `runs`
-- so no SELECT * over runs can carry it into a prompt; read only by the media renderer and the /v1/me export. The route
-- is a shape only: integers 0..255 in a unit box, no latitude, longitude, scale or north. It lives and dies with its
-- run (cascade), and with the user (hard delete). Switching "Show route shape" off clears route_json at once.
CREATE TABLE IF NOT EXISTS run_shape (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  route_json TEXT, splits_json TEXT, reps_json TEXT,
  PRIMARY KEY (user_id, run_id),
  FOREIGN KEY (user_id, run_id) REFERENCES runs (user_id, run_id) ON DELETE CASCADE
);
-- "Add a note" was tapped: the next free-text message is that run's note, until expires_at. One row per user.
CREATE TABLE IF NOT EXISTS note_mode (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS convo_area (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL,  -- rounded to 0.1 degree (about 11 km); only the latest row per user, only while opted in
  PRIMARY KEY (user_id, run_id)
);
-- Coach replay (companion.replay): a virtual-clock walk through the runner's real history.
-- While a row is not 'done' the live worker leaves that user's outbox, plans and purges alone.
CREATE TABLE IF NOT EXISTS replay_state (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('running','stopping','stopped','done')),
  driver TEXT,                 -- token of the process that owns the row; a newer one taking over stops the older
  facts_dir TEXT NOT NULL, every_s INTEGER NOT NULL,
  vnow TEXT NOT NULL,          -- the virtual clock
  last_tick TEXT,              -- last planning tick that ran
  items INTEGER NOT NULL DEFAULT 0,
  heartbeat_at TEXT, started_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS replay_runs (  -- runs the replay has reached. inserted=1: it created the row, so the app's
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,  -- own later upload updates it in place (then 2); 0 = a run that was already there
  run_id TEXT NOT NULL,
  inserted INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, run_id)
);
CREATE TABLE IF NOT EXISTS replay_rows (  -- rows the replay driver created (tbl + rowid), tagged as they are written
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tbl TEXT NOT NULL, rid TEXT NOT NULL,  -- the row's identity (see IDENT), not its rowid: rowids get reused
  PRIMARY KEY (user_id, tbl, rid)
);
CREATE TABLE IF NOT EXISTS replay_items (  -- every message the replay sent: virtual time, real time, card
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  card_id TEXT, kind TEXT NOT NULL,
  virtual_at TEXT NOT NULL, real_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS replay_items_card ON replay_items (card_id);
-- Check-ins (companion.checkins): the runner's one-tap life answers. Kept 14 days, then purged; shown in the export under
-- `checkins`; excluded from the nightly backup (backup.PRIVATE_TABLES). Never read by the writer or any model prompt.
-- kind: ready | today | why | postrun | shape. local_date: the session day (ready, today, why), the run's local day
-- (postrun) or the Monday of the week it is about (shape). value: a fixed enum (see checkins.py), never free text.
CREATE TABLE IF NOT EXISTS checkin_answers (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, local_date TEXT NOT NULL, value TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, kind, local_date)
);
CREATE INDEX IF NOT EXISTS checkin_answers_age ON checkin_answers (user_id, created_at);
-- One row per coach-initiated check-in message (C2): claimed BEFORE the send, message_id stored after, so a retry or a
-- restart can never post it twice (at-most-once). Holds ids and dates only, no answer.
CREATE TABLE IF NOT EXISTS checkin_slots (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slot TEXT NOT NULL, local_date TEXT NOT NULL,
  card_id TEXT, message_id TEXT, is_photo INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'claimed',  -- claimed | sent | consumed
  claimed_at TEXT NOT NULL, sent_at TEXT,
  PRIMARY KEY (user_id, slot, local_date)
);
CREATE INDEX IF NOT EXISTS checkin_slots_card ON checkin_slots (card_id);
-- The question cap (C1): at most one unprompted question with a keyboard per runner local day. The unique key IS the
-- cap: a send claims its row first, and only the claimer sends.
CREATE TABLE IF NOT EXISTS question_cap (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  local_date TEXT NOT NULL, slot TEXT NOT NULL, claimed_at TEXT NOT NULL,
  PRIMARY KEY (user_id, local_date)
);
-- Tables below hold no user data (no user_id column).
CREATE TABLE IF NOT EXISTS llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL, model TEXT, provider TEXT, cost_usd REAL NOT NULL DEFAULT 0, outcome TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

# Tables allowed to carry no user_id. The deletion test fails on any other new table without one.
NO_USER_TABLES = frozenset({"llm_calls", "settings", "sqlite_sequence"})


def connect(path: str) -> sqlite3.Connection:
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, mode=0o700, exist_ok=True)
    fresh = not os.path.exists(path)
    c = sqlite3.connect(path, timeout=15)
    if fresh:
        os.chmod(path, 0o600)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA secure_delete=ON")
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("PRAGMA busy_timeout=15000")
    return c


def init(path: str) -> None:
    c = connect(path)
    try:
        c.executescript(SCHEMA)
        cols = [r["name"] for r in c.execute("PRAGMA table_info(users)")]
        if "tz_set_at" not in cols:  # databases created before this column
            try:
                c.execute("ALTER TABLE users ADD COLUMN tz_set_at TEXT")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        if "weather_optin" not in cols:  # databases created before the weather switch
            try:
                c.execute("ALTER TABLE users ADD COLUMN weather_optin INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        if "route_optin" not in cols:  # databases created before the route-shape switch (default on, like the app)
            try:
                c.execute("ALTER TABLE users ADD COLUMN route_optin INTEGER NOT NULL DEFAULT 1")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        run_cols = {r["name"] for r in c.execute("PRAGMA table_info(runs)")}
        for col, typ in (("app_type", "TEXT"), ("real_upload", "INTEGER"),
                         ("plan_week", "INTEGER"), ("plan_weeks", "INTEGER"), ("plan_next_type", "TEXT"),
                         ("plan_next_day", "TEXT"), ("plan_next_week", "INTEGER"), ("plan_next_min", "INTEGER"),
                         ("plan_next_m", "INTEGER"),
                         ("session_name", "TEXT"), ("work_pace_s_per_km", "REAL"), ("reps_done", "INTEGER"),
                         ("rep_spread_s", "REAL"), ("recovery_pace_s_per_km", "REAL")):
            if col not in run_cols:  # databases created before these columns
                try:
                    c.execute(f"ALTER TABLE runs ADD COLUMN {col} {typ}")
                except sqlite3.OperationalError as e:
                    if "duplicate column" not in str(e):
                        raise
        if "quote_run_id" not in [r["name"] for r in c.execute("PRAGMA table_info(cards)")]:
            try:
                c.execute("ALTER TABLE cards ADD COLUMN quote_run_id TEXT")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        c.commit()
    finally:
        c.close()


_origin = threading.local()
# Tables whose new rows are tagged (in replay_rows) when written under origin("replay"): the coach replay's own
# writes, and the taps on a replayed card. Every table here is a rowid table with a user_id column.
TAGGED = ("cards", "outbox", "convo_log", "quota", "outcomes", "msglog", "memory",
          "checkin_answers", "checkin_slots", "question_cap")
# A tagged row is named by a stable identity: SQLite reuses the rowid of a deleted row in tables without
# AUTOINCREMENT, and a live row must never inherit a replay tag that way. (Those with AUTOINCREMENT never reuse.)
IDENT = {"cards": "card_id", "quota": "key", "memory": "key", "outcomes": "card_id",
         "outbox": "CAST(id AS TEXT)", "convo_log": "CAST(id AS TEXT)", "msglog": "CAST(id AS TEXT)",
         "checkin_answers": "kind || '|' || local_date", "checkin_slots": "slot || '|' || local_date",
         "question_cap": "local_date"}


@contextmanager
def origin(tag: str | None = "replay") -> Iterator[None]:
    """Transactions opened on this thread inside the block tag the rows they create as the replay's. The write lock a
    `tx` holds makes that exact: no other writer can add a row in between, so nothing the live worker writes is tagged."""
    prev = getattr(_origin, "tag", None)
    _origin.tag = tag
    try:
        yield
    finally:
        _origin.tag = prev


def origin_active() -> bool:
    return getattr(_origin, "tag", None) == "replay"


def tag_row(c: sqlite3.Connection, uid: str, tbl: str, where: str, args: tuple) -> None:
    """Tag an existing row the replay changed in place (an upsert), e.g. a memory answer."""
    if origin_active():
        c.execute(f"INSERT OR IGNORE INTO replay_rows (user_id, tbl, rid) SELECT user_id, ?, {IDENT[tbl]} FROM {tbl} "
                  f"WHERE user_id=? AND {where}", (tbl, uid, *args))


def untag(c: sqlite3.Connection, uid: str, tbl: str, ident: str) -> None:
    """A write outside the replay made this row live (e.g. a memory answer overwritten from a live card)."""
    if not origin_active():
        c.execute("DELETE FROM replay_rows WHERE user_id=? AND tbl=? AND rid=?", (uid, tbl, ident))


@contextmanager
def tx(path: str) -> Iterator[sqlite3.Connection]:
    c = connect(path)
    try:
        c.execute("BEGIN IMMEDIATE")
        before = {t: c.execute(f"SELECT COALESCE(MAX(rowid), 0) FROM {t}").fetchone()[0] for t in TAGGED} \
            if origin_active() else None
        yield c
        if before is not None:
            for t, last in before.items():
                c.execute(f"INSERT OR IGNORE INTO replay_rows (user_id, tbl, rid) SELECT user_id, ?, {IDENT[t]} FROM {t} "
                          "WHERE rowid > ?", (t, last))
        c.commit()
    except BaseException:
        c.rollback()
        raise
    finally:
        c.close()


@contextmanager
def ro(path: str) -> Iterator[sqlite3.Connection]:
    c = connect(path)
    try:
        yield c
    finally:
        c.close()


def user_tables(c: sqlite3.Connection) -> list[str]:
    """Every table with a user_id column, found from the live schema (so new tables are covered)."""
    out = []
    for (name,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"):
        cols = [r["name"] for r in c.execute(f"PRAGMA table_info({name})")]
        if "user_id" in cols:
            out.append(name)
    return out


def checkpoint_truncate(path: str, tries: int = 5, wait_s: float = 0.2) -> bool:
    """Fold the WAL into the main file and truncate it, so deleted pages are not left in it. SQLite reports `busy` in
    the first column of the result when a reader stopped it, so retry a few times and say so when it never cleared."""
    import logging
    import time
    for i in range(tries):
        c = connect(path)
        try:
            c.execute("PRAGMA busy_timeout=0")
            busy = c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]
        finally:
            c.close()
        if not busy:
            return True
        if i + 1 < tries:
            time.sleep(wait_s)
    logging.getLogger("companion").warning("wal checkpoint stayed busy; deleted pages remain in the WAL until the next one")
    return False


def hard_delete_user(path: str, user_id: str) -> None:
    """Delete every row keyed by the user in one transaction, then scrub and truncate the WAL."""
    with tx(path) as c:
        for t in user_tables(c):
            c.execute(f"DELETE FROM {t} WHERE user_id = ?", (user_id,))
        c.execute("DELETE FROM users WHERE id = ?", (user_id,))
    checkpoint_truncate(path)
