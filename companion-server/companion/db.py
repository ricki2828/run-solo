"""SQLite access. One short-lived connection per operation (WAL, secure_delete)."""
from __future__ import annotations

import os
import sqlite3
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
  feel TEXT,
  received_at TEXT NOT NULL,
  stale INTEGER NOT NULL DEFAULT 0,
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
  created_at TEXT NOT NULL, sent_at TEXT, answered_at TEXT
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
CREATE TABLE IF NOT EXISTS convo_area (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL,  -- rounded to 0.1 degree (about 11 km), only when weather is on
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
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,  -- own later upload updates it in place (then 0)
  run_id TEXT NOT NULL,
  inserted INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, run_id)
);
CREATE TABLE IF NOT EXISTS replay_items (  -- every message the replay sent: virtual time, real time, card
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  card_id TEXT, kind TEXT NOT NULL,
  virtual_at TEXT NOT NULL, real_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS replay_items_card ON replay_items (card_id);
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
        if "app_type" not in [r["name"] for r in c.execute("PRAGMA table_info(runs)")]:
            try:
                c.execute("ALTER TABLE runs ADD COLUMN app_type TEXT")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        c.commit()
    finally:
        c.close()


@contextmanager
def tx(path: str) -> Iterator[sqlite3.Connection]:
    c = connect(path)
    try:
        c.execute("BEGIN IMMEDIATE")
        yield c
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


def hard_delete_user(path: str, user_id: str) -> None:
    """Delete every row keyed by the user in one transaction, then scrub and truncate the WAL."""
    with tx(path) as c:
        for t in user_tables(c):
            c.execute(f"DELETE FROM {t} WHERE user_id = ?", (user_id,))
        c.execute("DELETE FROM users WHERE id = ?", (user_id,))
    c = connect(path)
    try:
        c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        c.close()
