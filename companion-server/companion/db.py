"""SQLite access. One short-lived connection per operation (WAL, secure_delete)."""
from __future__ import annotations

import os
import sqlite3
import threading
from datetime import timezone
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
  hr_optin INTEGER NOT NULL DEFAULT 0,       -- the app's "Heart rate on cards" switch; a trail block's hr series is kept only while 1
  place_optin INTEGER NOT NULL DEFAULT 0,    -- the app's place opt-in (share place names); a trail name is kept only while 1
  route_optin INTEGER NOT NULL DEFAULT 1,    -- the app's "Show route shape on cards" switch (default on); a shape is stored only while 1
  checkin_consent INTEGER,                   -- the companion consent version the app says the runner agreed to; NULL = never said (no check-ins)
  tester_no INTEGER,                         -- T1, T2 ...: the number the operator CLI and the logs use instead of a name; never reused
  ops_paused INTEGER NOT NULL DEFAULT 0,     -- paused by the operator or the rate limiter; only `ops resume` clears it (the runner's own RESUME does not)
  ops_paused_reason TEXT,                    -- 'ops' | 'rate'
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
  plan_next_session_id TEXT, plan_next_session_ref TEXT, plan_next_session_name TEXT,  -- which session it is, when the app says so (ref: opaque, never shown)
  plan_next_pace_lo REAL, plan_next_pace_hi REAL, plan_next_pace_method TEXT,  -- the work pace the app targets for it (True Pace s/km), when it says so
  feel TEXT,
  goal_reached INTEGER, session_name TEXT, work_pace_s_per_km REAL, reps_done INTEGER, rep_spread_s REAL, recovery_pace_s_per_km REAL,  -- an interval session, from the app's verdict numbers
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
CREATE TABLE IF NOT EXISTS ops_sends (   -- the audit of `ops send`: which fixed template went to which tester, never the text
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  template TEXT NOT NULL, text_hash TEXT NOT NULL, ts TEXT NOT NULL, result TEXT NOT NULL, card_id TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ops_sent_once ON ops_sends (user_id, template) WHERE result='sent';   -- a skipped row may be retried
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
  trail_json TEXT,   -- the trail board, elevation profile (metres relative to the start) and ghost gap: whole numbers, no coordinates
  PRIMARY KEY (user_id, run_id),
  FOREIGN KEY (user_id, run_id) REFERENCES runs (user_id, run_id) ON DELETE CASCADE
);
-- Telegram's file_id of an animation already sent for a run (the ghost race clip), so a repeat send is one id and not another
-- render and upload. Only an opaque id the runner's own chat already holds. It lives and dies with its run (cascade) and the user.
CREATE TABLE IF NOT EXISTS media_file_ids (
  user_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  file_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, run_id, kind),
  FOREIGN KEY (user_id, run_id) REFERENCES runs (user_id, run_id) ON DELETE CASCADE
);
-- "Add a note" was tapped: the next free-text message is that run's note, until expires_at. One row per user.
CREATE TABLE IF NOT EXISTS note_mode (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
-- "Tell Ricki" was tapped (or /feedback sent): the next free-text message is feedback, until expires_at. One row per user.
CREATE TABLE IF NOT EXISTS feedback_mode (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL
);
-- Tell Ricki (companion.feedback): what a runner typed to the operator. Kept 30 days, then purged; exported to the runner
-- under `feedback`; excluded from the nightly backup (backup.PRIVATE_TABLES). Never read by the writer or any model prompt.
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts TEXT NOT NULL,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS feedback_age ON feedback (ts);
CREATE INDEX IF NOT EXISTS feedback_user ON feedback (user_id, ts);
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
-- Quests (the app computes them; this is what it last said, to issue the month's card and add one line). Whole numbers only.
-- trail_name is a place: kept only while place_optin = 1, cleared when it turns off. Rows go 90 days after the quest ends.
CREATE TABLE IF NOT EXISTS quests (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  quest_id TEXT NOT NULL,
  month TEXT NOT NULL,              -- 'YYYY-MM' the offer belongs to (the runner's local month of the run that carried it)
  kind TEXT NOT NULL, target INTEGER NOT NULL, baseline INTEGER, unit TEXT NOT NULL,
  trail_name TEXT,
  state TEXT NOT NULL,              -- offered | accepted | skipped | done | expired
  value INTEGER, ends_on TEXT,
  pos INTEGER NOT NULL DEFAULT 0,   -- order of the offers (0 is the default one)
  card_id TEXT,                     -- the offer card currently showing this quest
  accepted_at TEXT,
  done_run_id TEXT,                 -- the run that finished it: its post-run card carries the done line
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, quest_id)
);
CREATE INDEX IF NOT EXISTS quests_month ON quests (user_id, month);
CREATE INDEX IF NOT EXISTS quests_card ON quests (card_id);
-- Inbound rate-limit slow-downs (one row each, kept 2 days): three inside 24 hours pause the runner.
CREATE TABLE IF NOT EXISTS inbound_strikes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ts TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS inbound_strikes_user ON inbound_strikes (user_id, ts);
-- One row per writing-service call. user_id says whose card it paid for (per-runner cost). It has no foreign key:
-- deleting a runner sets it to NULL (see hard_delete_user) so the month's spend, which the cap counts, cannot be reset by
-- deleting; what remains is a cost, a time and a model name with nothing to link it to anyone.
CREATE TABLE IF NOT EXISTS llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL, model TEXT, provider TEXT, cost_usd REAL NOT NULL DEFAULT 0, outcome TEXT NOT NULL,
  user_id TEXT
);
-- Phase A measurement. inbound_events: one row per thing a consented runner did in the chat or Mini App: a kind and a time,
-- never content (tap | note | feedback | command | text | miniapp_open). Kept 120 days, deleted with the runner, left out of the
-- nightly backup (backup.PRIVATE_TABLES). survey_answers: the day-after-recap "did last week get you right" (kind trust) and the one
-- "how would you feel if the coach went away" question (kind ellis) as fixed options, kept until the test ends.
CREATE TABLE IF NOT EXISTS inbound_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, ts TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS inbound_events_user ON inbound_events (user_id, ts);
CREATE INDEX IF NOT EXISTS inbound_events_age ON inbound_events (ts);
CREATE TABLE IF NOT EXISTS survey_answers (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL, ref TEXT NOT NULL, value TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, kind, ref)
);
-- Tables below hold no user data (no user_id column).
-- Opt-out counts by ISO week (Monday UTC): a runner who sends DELETE (chat, app or web) is erased, so the scorecard would
-- lose them. A week and a number only, never an id. stop_counts counts STOP messages that paused a runner.
CREATE TABLE IF NOT EXISTS deleted_tombstones (week TEXT PRIMARY KEY, n INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS stop_counts (week TEXT PRIMARY KEY, n INTEGER NOT NULL);
-- Messages for Ricki (spend at 50/80/100% of the cap, a runner paused for flooding). T-numbers only, never a name or chat.
-- The host cron (deploy/flush-alerts.sh) sends the unsent ones through notify: the service sandbox cannot reach it.
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE, ts TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, sent_at TEXT
);
-- "The test is full" refusals: a count per day, nothing about who asked.
CREATE TABLE IF NOT EXISTS enrol_refused (day TEXT PRIMARY KEY, n INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

# Tables allowed to carry no user_id. The deletion test fails on any other new table without one.
NO_USER_TABLES = frozenset({"alerts", "enrol_refused", "settings", "sqlite_sequence", "deleted_tombstones", "stop_counts"})
# Tables with a user_id that a delete clears (sets NULL) instead of removing the rows, so shared totals stay true.
ANONYMISE_ON_DELETE = frozenset({"llm_calls"})


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
        if "place_optin" not in cols:  # databases created before the place switch (default off)
            try:
                c.execute("ALTER TABLE users ADD COLUMN place_optin INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        if "hr_optin" not in cols:  # databases created before the heart-rate switch (default off)
            try:
                c.execute("ALTER TABLE users ADD COLUMN hr_optin INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        if "checkin_consent" not in cols:  # databases created before check-in consent gating
            try:
                c.execute("ALTER TABLE users ADD COLUMN checkin_consent INTEGER")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        for col, typ in (("tester_no", "INTEGER"), ("ops_paused", "INTEGER NOT NULL DEFAULT 0"), ("ops_paused_reason", "TEXT")):
            if col not in cols:  # databases created before the tester rails
                try:
                    c.execute(f"ALTER TABLE users ADD COLUMN {col} {typ}")
                except sqlite3.OperationalError as e:
                    if "duplicate column" not in str(e):
                        raise
        if "user_id" not in [r["name"] for r in c.execute("PRAGMA table_info(llm_calls)")]:  # per-runner cost
            try:
                c.execute("ALTER TABLE llm_calls ADD COLUMN user_id TEXT")
            except sqlite3.OperationalError as e:
                if "duplicate column" not in str(e):
                    raise
        c.execute("CREATE INDEX IF NOT EXISTS llm_calls_user ON llm_calls (user_id, ts)")
        c.commit()
        number_testers(c)
        run_cols = {r["name"] for r in c.execute("PRAGMA table_info(runs)")}
        for col, typ in (("app_type", "TEXT"), ("real_upload", "INTEGER"),
                         ("plan_week", "INTEGER"), ("plan_weeks", "INTEGER"), ("plan_next_type", "TEXT"),
                         ("plan_next_day", "TEXT"), ("plan_next_week", "INTEGER"), ("plan_next_min", "INTEGER"),
                         ("plan_next_m", "INTEGER"), ("plan_next_session_id", "TEXT"), ("plan_next_session_ref", "TEXT"), ("plan_next_session_name", "TEXT"),
                         ("plan_next_pace_lo", "REAL"), ("plan_next_pace_hi", "REAL"), ("plan_next_pace_method", "TEXT"),
                         ("session_name", "TEXT"), ("work_pace_s_per_km", "REAL"), ("reps_done", "INTEGER"),
                         ("rep_spread_s", "REAL"), ("recovery_pace_s_per_km", "REAL"), ("goal_reached", "INTEGER")):
            if col not in run_cols:  # databases created before these columns
                try:
                    c.execute(f"ALTER TABLE runs ADD COLUMN {col} {typ}")
                except sqlite3.OperationalError as e:
                    if "duplicate column" not in str(e):
                        raise
        if "trail_json" not in [r["name"] for r in c.execute("PRAGMA table_info(run_shape)")]:
            try:
                c.execute("ALTER TABLE run_shape ADD COLUMN trail_json TEXT")
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


def next_tester_no(c: sqlite3.Connection) -> int:
    """The next T-number. A counter in `settings`, never the max of the users, so a deleted runner's number is not reused."""
    r = c.execute("SELECT value FROM settings WHERE key='tester_seq'").fetchone()
    n = int(r[0]) + 1 if r else 1
    c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('tester_seq', ?)", (str(n),))
    return n


def number_testers(c: sqlite3.Connection) -> None:
    """Give runners that predate the numbers one, oldest first (a fresh database has none to give)."""
    todo = [r[0] for r in c.execute("SELECT id FROM users WHERE tester_no IS NULL ORDER BY created_at, rowid")]
    if not todo:
        return
    c.execute("BEGIN IMMEDIATE")
    for uid in todo:
        c.execute("UPDATE users SET tester_no=? WHERE id=? AND tester_no IS NULL", (next_tester_no(c), uid))
    c.commit()


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


def bump_week(c: sqlite3.Connection, table: str, now) -> None:
    """Add one to this ISO week's count (week = Monday UTC, as the scorecard counts). `table` is one of ours, never input."""
    y, w, _ = now.astimezone(timezone.utc).isocalendar()
    c.execute(f"INSERT INTO {table} (week, n) VALUES (?,1) ON CONFLICT(week) DO UPDATE SET n = n + 1", (f"{y}-W{w:02d}",))


def hard_delete_user(path: str, user_id: str, tombstone_at=None) -> None:
    """Delete every row keyed by the user in one transaction, then scrub and truncate the WAL. `tombstone_at` (a time)
    adds one to that week's deleted count, in the same transaction: pass it when the runner asked for the deletion."""
    with tx(path) as c:
        if tombstone_at is not None:
            bump_week(c, "deleted_tombstones", tombstone_at)
        for t in user_tables(c):
            if t in ANONYMISE_ON_DELETE:
                c.execute(f"UPDATE {t} SET user_id = NULL WHERE user_id = ?", (user_id,))
            else:
                c.execute(f"DELETE FROM {t} WHERE user_id = ?", (user_id,))
        c.execute("DELETE FROM users WHERE id = ?", (user_id,))
    checkpoint_truncate(path)
