"""Core behaviour: enrolment, run ingest, cards, memory, outbox, inbound commands."""
from __future__ import annotations

import math

import hashlib
import hmac
import json
import logging
import re
import secrets
import string
from datetime import datetime, timedelta
from typing import Any

import httpx
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import db
from .channels import ChannelError, Inbound, OutCard, TelegramChannel, WhatsAppChannel, feel_template_eligible
from .config import Settings
from .deeplink import run_link, web_twin, week_link
from .media import Media, MediaError, from_settings
from . import notes as cv_notes
from .convo import engine as cv_engine
from .convo import recap as cv_recap
from .convo import suggest as cv_suggest
from .convo import touches as cv_touches
from .convo.questions import REASK_DAYS, known_without_asking, next_weekly_question
from .convo.weather import NoWeather, OpenMeteo, cell
from .facts import APP_TYPES, FactsResult, build_facts, infer_coach_type, tomorrow_is_usual_day, valid_answer, NIGGLE_TTL_DAYS
from .timeutil import (in_quiet, iso, now_utc, parse_iso, quiet_end_utc, resolve_cap_week, to_local, UTC,
                       valid_zone, week_key)
from .writer import Writer, digest_lines

log = logging.getLogger("companion")

ENROL_TTL_MIN = 15
MAX_CODE_ATTEMPTS = 5
MAX_ATTEMPTS = 4
RUNS_PER_DAY = 30
QUESTION_DELAY_MIN = 30
QUESTION_HEADS = ("Quick question", "Help me out", "For your plan", "Tell me this")
START_RE = re.compile(r"^\s*/?start\s+([A-Za-z0-9_-]{8,64})\s*$", re.I)
RETENTION_INACTIVE_DAYS = 183
RETENTION_LOG_DAYS = 30
# The stored weather area goes 30 days after the run it came from (its own age, so indoor runs cannot keep a stale
# cell alive). Lookups ignore an area older than AREA_USABLE_DAYS.
RETENTION_AREA_DAYS = 30
AREA_USABLE_DAYS = 7  # a forecast is never asked for a place older than this

NOT_OPEN = "Run Supreme's companion isn't open yet. We'll let you know when it is."
NOTE_ACTION = "note:add"
UNKNOWN = ("I only send run recaps. To connect, open Run Supreme, go to Settings > Companion and tap "
           "Turn on. Send STOP to pause or DELETE to erase everything.")
NOTE_PROMPT = "Go on, type your note. Up to 500 characters. I'll keep it with this run."
NOTE_SAVED = "Noted. I'll keep it in mind."
NOTE_TOO_LONG = "That's over 500 characters. Trim it and send it again."
NOTE_EXPIRED = "That note window closed after 10 minutes. Tap Add a note on the run card to start again."
NOTE_PAUSED = "You're paused. Send RESUME first, then tap Add a note again."
CODE_MSG = ("Your code is {code}. Type it into Run Supreme to finish connecting. Only ever enter it in the app, "
            "and never share it. If you didn't start this, ignore this message.")
WELCOME = ("You're connected. Your run recaps will land here. Send STOP to pause them or DELETE to "
           "erase everything we hold about you.")


# Dart VerdictHeadline.name -> the words the facts engine may say. noVerdict says nothing.
# Users with a coach replay in progress or paused. The replay owns their outbox, planning and retention until it is
# 'done': the live worker on the real clock would otherwise send virtual-past items at once.
REPLAY_RUN_STALE = timedelta(minutes=15)   # a running replay whose heartbeat is older than this has lost its process
REPLAY_STOPPED_MAX = timedelta(hours=48)   # a stopped replay holds the user for at most this long
REPLAY_ALIVE = timedelta(minutes=5)        # a heartbeat newer than this is a live process: not "overdue", it is working
# Outbox rows the live worker still sends for a held user: a real run's card and question (the run is not one the
# replay is walking through). Everything else for that user belongs to the replay.
LIVE_ROW = ("(outbox.kind IN ('run_card','question') AND outbox.ref NOT IN "
            "(SELECT run_id FROM replay_runs r WHERE r.user_id = outbox.user_id))")


def replay_hold(now: datetime) -> str:
    """SQL subquery: users a coach replay currently owns, on the real clock `now`. Bounded, so a replay whose process
    died (or that was stopped and forgotten) releases the user by itself instead of muting them for good."""
    return ("(SELECT user_id FROM replay_state WHERE "
            f"(status IN ('running','stopping') AND heartbeat_at > '{iso(now - REPLAY_RUN_STALE)}') OR "
            f"(status = 'stopped' AND updated_at > '{iso(now - REPLAY_STOPPED_MAX)}'))")

VERDICT_WIRE = ("faster", "holding", "slower", "noRealChange", "baselineSet", "noVerdict", "indoorRun")


class RunIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    run_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_.:-]+$")
    type: str = Field(pattern=r"^[a-z_]{1,24}$")
    start_utc: datetime
    utc_offset_min: int = Field(ge=-840, le=840)
    zone_id: str = Field(max_length=64)
    duration_s: int = Field(ge=1, le=86400)
    distance_m: int = Field(ge=0, le=300000)
    pace_s_per_km: float | None = Field(default=None, gt=0, lt=3600)
    true_pace_s_per_km: float | None = Field(default=None, gt=0, lt=3600)
    verdict: str | None = None  # VerdictHeadline.name from the app; unknown values become None
    scores_delta: dict[str, float] = Field(default_factory=dict, max_length=8)
    zone_min: dict[str, float] = Field(default_factory=dict, max_length=8)
    climb_m: int | None = Field(default=None, ge=0, le=10000)
    locality: str | None = Field(default=None, max_length=60)  # suburb only, never a street
    route_id: str | None = Field(default=None, max_length=64)
    load_state: str | None = Field(default=None, pattern=r"^(low|steady|high|very_high)$")
    pb: str | None = Field(default=None, pattern=r"^(5k|10k|half|longest|fastest_km)$")
    plan_kind: str | None = Field(default=None, pattern=r"^[a-z_]{1,24}$")
    plan_target_m: int | None = Field(default=None, ge=0, le=300000)
    plan_weeks_to_race: int | None = Field(default=None, ge=0, le=104)
    feel: str | None = Field(default=None, pattern=r"^(easy|right|hard)$")
    area_lat: float | None = Field(default=None, ge=-90, le=90)  # approximate area for weather; the phone rounds to 0.1 degree and the server rounds again
    area_lon: float | None = Field(default=None, ge=-180, le=180)

    @field_validator("distance_m", "climb_m", mode="before")
    @classmethod
    def _whole_metres(cls, v):
        """The app sends metres with one decimal (r1); store whole metres. Only finite numbers; strings, NaN and inf still fail."""
        if isinstance(v, float) and math.isfinite(v):
            return round(v)
        return v

    @field_validator("verdict", mode="before")
    @classmethod
    def _verdict(cls, v):
        """Enum on the wire (never free text). An unrecognised value is dropped, not a 422 for the whole run."""
        return v if isinstance(v, str) and v in VERDICT_WIRE else None

    @field_validator("zone_id")
    @classmethod
    def _zone(cls, v: str) -> str:
        if not valid_zone(v):
            raise ValueError("unknown zone")
        return v

    @field_validator("start_utc")
    @classmethod
    def _aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("start_utc needs a timezone")
        return v.astimezone(UTC)


# Export coverage (/v1/me). Every table with a user_id column must be in one of these two maps; a test walks
# the live schema, so a new user table cannot be added without deciding whether the runner sees it.
EXPORTED_TABLES = {
    "users": "profile", "runs": "runs_received", "memory": "memory", "cards": "messages_sent_30d",
    "outcomes": "suggestion_outcomes", "convo_cards": "messages_sent_30d", "convo_log": "conversation_log",
    "convo_area": "areas", "run_notes": "run_notes",
}
NOT_EXPORTED_TABLES = {  # operational plumbing: no run, location or message content of its own
    "devices": "hashed device tokens", "enrolments": "short-lived sign-up nonces", "outbox": "send queue, ids only",
    "quota": "weekly cap counters", "msglog": "send counts, no content", "inbound_seen": "hashed message ids",
    "replay_state": "coach replay progress", "replay_runs": "run ids the replay inserted",
    "replay_items": "replay send times and card ids",
    "note_mode": "10-minute 'Add a note' waiting state: a run id and an expiry, no text",
}


class RateLimited(Exception):
    pass


class NotFound(Exception):
    pass


def _opaque_user_id() -> str:
    return "u_" + "".join(secrets.choice(string.ascii_lowercase) for _ in range(12))


class Service:
    def __init__(self, settings: Settings, http: httpx.Client):
        self.s, self.http = settings, http
        self.writer = Writer(settings, http)
        self.channels: dict[str, Any] = {}
        if settings.telegram_enabled:
            self.channels["telegram"] = TelegramChannel(settings, http)
        if settings.wa_ready:
            self.channels["whatsapp"] = WhatsAppChannel(settings, http)
        self.weather = OpenMeteo(http) if settings.weather_enabled else NoWeather()
        self.media = from_settings(settings.render_socket)  # a socket client only; nothing connects unless media_enabled is on
        db.init(settings.db_path)

    # ---------------------------------------------------------------- tokens / enrolment (B1)
    def token_hash(self, token: str) -> str:
        return hmac.new(self.s.pepper, token.encode(), hashlib.sha256).hexdigest()

    def authenticate(self, token: str) -> str | None:
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT user_id FROM devices WHERE token_hash = ?", (self.token_hash(token),)).fetchone()
        return r["user_id"] if r else None

    def _mac(self, value: str) -> str:
        return hmac.new(self.s.pepper, value.encode(), hashlib.sha256).hexdigest()

    def enrol_start(self, now: datetime | None = None) -> dict:
        """The nonce travels through chat; the poll secret never does. Only the app holds both."""
        now = now or now_utc()
        nonce = secrets.token_urlsafe(18)
        poll_secret = secrets.token_urlsafe(24)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO enrolments (nonce, created_at, expires_at, poll_hash) VALUES (?,?,?,?)",
                      (nonce, iso(now), iso(now + timedelta(minutes=ENROL_TTL_MIN)), self._mac(poll_secret)))
        links: dict[str, str] = {}
        if self.s.telegram_bot and "telegram" in self.channels:
            links["telegram"] = f"https://t.me/{self.s.telegram_bot}?start={nonce}"
        if self.s.wa_number and "whatsapp" in self.channels:
            links["whatsapp"] = f"https://wa.me/{self.s.wa_number}?text=START%20{nonce}"
        return {"nonce": nonce, "poll_secret": poll_secret, "expires_in": ENROL_TTL_MIN * 60, "links": links}

    def _enrolment(self, c, nonce: str, poll_secret: str):
        e = c.execute("SELECT * FROM enrolments WHERE nonce = ?", (nonce,)).fetchone()
        if not e or not hmac.compare_digest(e["poll_hash"].encode(), self._mac(poll_secret).encode()):
            return None
        return e

    def enrol_status(self, nonce: str, poll_secret: str, now: datetime | None = None) -> dict:
        """Read-only. Never returns a token: the token only comes from enrol_confirm."""
        now = now or now_utc()
        with db.ro(self.s.db_path) as c:
            e = self._enrolment(c, nonce, poll_secret)
        if e is None:
            return {"state": "unknown"}
        if e["state"] in ("pending", "awaiting_code") and parse_iso(e["expires_at"]) <= now:
            return {"state": "expired"}
        return {"state": e["state"]}

    def enrol_confirm(self, nonce: str, poll_secret: str, code: str, now: datetime | None = None) -> tuple[str, str | None, str | None]:
        """-> (result, token, chat_name). result: ok | wrong | locked | gone. The old token is revoked only here."""
        now = now or now_utc()
        result, token, chat_name = "gone", None, None
        with db.tx(self.s.db_path) as c:
            e = self._enrolment(c, nonce, poll_secret)
            if e is None or e["state"] != "awaiting_code" or parse_iso(e["expires_at"]) <= now:
                return "gone", None, None
            if not hmac.compare_digest((e["code"] or "").encode(), code.encode()):
                attempts = e["attempts"] + 1
                if attempts >= MAX_CODE_ATTEMPTS:
                    c.execute("UPDATE enrolments SET state='expired', code=NULL, attempts=? WHERE nonce=?", (attempts, nonce))
                    result = "locked"
                else:
                    c.execute("UPDATE enrolments SET attempts=? WHERE nonce=?", (attempts, nonce))
                    result = "wrong"
            else:
                uid = e["user_id"]
                token = secrets.token_urlsafe(32)  # 256 bits; only the keyed hash is stored, and it is never re-readable
                c.execute("DELETE FROM devices WHERE user_id=?", (uid,))  # re-enrol rotates, but only now
                c.execute("INSERT INTO devices (token_hash, user_id, created_at) VALUES (?,?,?)",
                          (self.token_hash(token), uid, iso(now)))
                # A fresh enrolment starts with weather off on the phone, so the server must match: forget the
                # switch and any stored area (reinstall, new phone, 401 wipe of the same chat).
                c.execute("UPDATE users SET weather_optin=0 WHERE id=?", (uid,))
                c.execute("DELETE FROM convo_area WHERE user_id=?", (uid,))
                c.execute("UPDATE users SET paused=0, consent_version=?, consent_at=?, consent_msg_id=?, chat_name=? WHERE id=?",
                          (self.s.consent_version, iso(now), e["consent_msg_id"], e["chat_name"], uid))
                chat_name = e["chat_name"]
                c.execute("UPDATE enrolments SET state='claimed', code=NULL WHERE nonce=?", (nonce,))
                result = "ok"
        if result == "ok":
            log.info("enrolled user=%s", uid)
            with db.ro(self.s.db_path) as c:
                u = c.execute("SELECT channel, chat_ref FROM users WHERE id=?", (uid,)).fetchone()
            ch = self.channels.get(u["channel"]) if u else None
            if ch:
                self._reply(ch, u["chat_ref"], WELCOME)
        return result, token, chat_name

    def _bind(self, inb: Inbound, nonce: str, now: datetime) -> str:
        """The user's own message proves the chat. It starts a code check; it issues nothing."""
        ident = f"{inb.channel}:{inb.ref}"
        with db.tx(self.s.db_path) as c:
            e = c.execute("SELECT * FROM enrolments WHERE nonce = ?", (nonce,)).fetchone()
            if not e or e["state"] != "pending" or parse_iso(e["expires_at"]) <= now:
                return "That link has expired. Open Run Supreme and start again."
            if not (self.s.open_enrolment or ident in self.s.allowed_ids):
                c.execute("UPDATE enrolments SET state='denied' WHERE nonce=?", (nonce,))
                return NOT_OPEN
            u = c.execute("SELECT id FROM users WHERE channel=? AND chat_ref=?", (inb.channel, inb.ref)).fetchone()
            if u:
                uid = u["id"]  # existing user: nothing changes until the code is confirmed
            else:
                uid = _opaque_user_id()
                c.execute("INSERT INTO users (id, channel, chat_ref, created_at, last_inbound_at) VALUES (?,?,?,?,?)",
                          (uid, inb.channel, inb.ref, iso(now), iso(now)))
            code = f"{secrets.randbelow(10**6):06d}"
            c.execute("UPDATE enrolments SET state='awaiting_code', user_id=?, code=?, attempts=0, consent_msg_id=?, "
                      "chat_name=? WHERE nonce=?", (uid, code, self._mac(inb.msg_id), inb.name or None, nonce))
            c.execute("UPDATE inbound_seen SET user_id=? WHERE msg_id=?", (uid, self._mac(inb.msg_id)))
        return CODE_MSG.format(code=code)

    # ---------------------------------------------------------------- inbound (webhooks)
    def _seen(self, inb: Inbound, now: datetime) -> bool:
        """True if this message id was already handled."""
        with db.tx(self.s.db_path) as c:
            cur = c.execute("INSERT OR IGNORE INTO inbound_seen (msg_id, user_id, ts) VALUES (?,NULL,?)",
                            (self._mac(inb.msg_id), iso(now)))
            return cur.rowcount == 0

    def _user_by_ref(self, channel: str, ref: str) -> dict | None:
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT * FROM users WHERE channel=? AND chat_ref=?", (channel, ref)).fetchone()
        return dict(r) if r else None

    def handle_inbound(self, inb: Inbound, now: datetime | None = None) -> None:
        now = now or now_utc()
        if self._seen(inb, now):
            return
        ch = self.channels.get(inb.channel)
        if ch is None:
            return
        user = self._user_by_ref(inb.channel, inb.ref)
        if user:
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE users SET last_inbound_at=? WHERE id=?", (iso(now), user["id"]))
                c.execute("UPDATE inbound_seen SET user_id=? WHERE msg_id=?", (user["id"], self._mac(inb.msg_id)))
        if inb.card_id is not None:
            self._handle_button(ch, inb, user, now)
            return
        text = inb.text.strip()
        word = text.lstrip("/").upper()
        m = START_RE.match(text)
        reply: str
        if m:
            reply = self._bind(inb, m.group(1), now)
        elif word in ("STOP", "STOP ALL", "UNSUBSCRIBE", "CANCEL", "END", "QUIT"):
            if user:
                with db.tx(self.s.db_path) as c:
                    c.execute("UPDATE users SET paused=1 WHERE id=?", (user["id"],))
            reply = ("Paused. No more messages from me. Send RESUME to turn them back on, or DELETE to erase your data."
                     if user else "Nothing to pause here.")
        elif word == "RESUME":
            if user:
                with db.tx(self.s.db_path) as c:
                    c.execute("UPDATE users SET paused=0 WHERE id=?", (user["id"],))
                    c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
            reply = "Back on. Your next run recap will land here." if user else UNKNOWN
        elif word == "DELETE":
            if user:
                db.hard_delete_user(self.s.db_path, user["id"])
                log.info("deleted user=%s via keyword", user["id"])
                reply = "Done. Everything we held about you is deleted. Meta may keep delivery records for up to 30 days."
            else:
                reply = "We hold nothing for this chat."
        else:
            # Free text is only ever a note, after "Add a note". Everything else gets the fixed canned reply, and no
            # free text ever reaches a model.
            reply = self._note_reply(user, inb.text, now) or UNKNOWN
        self._reply(ch, inb.ref, reply)

    def _note_reply(self, user: dict | None, raw: str, now: datetime) -> str | None:
        """The reply when this free text is (or was meant to be) a note; None when the user is not in note mode."""
        if not user:
            return None
        with db.ro(self.s.db_path) as c:
            mode = c.execute("SELECT run_id, expires_at FROM note_mode WHERE user_id=?", (user["id"],)).fetchone()
        if mode is None:
            return None
        if parse_iso(mode["expires_at"]) <= now:
            with db.tx(self.s.db_path) as c:
                c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
            return NOTE_EXPIRED
        if user["paused"]:
            return NOTE_PAUSED  # nothing is stored for a paused chat
        text = cv_notes.clean(raw)
        if not text:
            return None
        if len(text) > cv_notes.NOTE_MAX_CHARS:
            return NOTE_TOO_LONG  # still in note mode: the runner can send a shorter one
        with db.tx(self.s.db_path) as c:
            c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
            if not c.execute("SELECT 1 FROM runs WHERE user_id=? AND run_id=?", (user["id"], mode["run_id"])).fetchone():
                return NOTE_EXPIRED
            c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?) "
                      "ON CONFLICT(user_id, run_id) DO UPDATE SET note=excluded.note, created_at=excluded.created_at",
                      (user["id"], mode["run_id"], text, iso(now)))
        return NOTE_SAVED

    def _reply(self, ch: Any, ref: str, text: str) -> None:
        try:
            ch.send_text(ref, text)
        except ChannelError as e:
            log.warning("reply failed: %s", e)

    def _handle_button(self, ch: Any, inb: Inbound, user: dict | None, now: datetime) -> None:
        with db.ro(self.s.db_path) as c:
            card = c.execute("SELECT * FROM cards WHERE card_id=?", (inb.card_id,)).fetchone()
        # The opaque card id must belong to the sender; otherwise behave as if it does not exist.
        if not card or not user or card["user_id"] != user["id"]:
            ch.ack_callback(inb, "That button has expired.", clear=False)
            return
        buttons = json.loads(card["buttons_json"])
        if inb.button_idx is None or not 0 <= inb.button_idx < len(buttons):
            ch.ack_callback(inb, "That button has expired.", clear=False)
            return
        real_now = now  # note mode runs on the real clock, even for a replayed card
        now = self._tap_time(card["card_id"], now)
        action = buttons[inb.button_idx]["action"]
        kind, _, rest = action.partition(":")
        msg = "Thanks."
        keep: list[tuple[str, int]] = []
        note_tapped = False
        after: str | None = None  # a chat message to send once the transaction is closed
        with db.tx(self.s.db_path) as c:
            if kind == "feel" and card["run_id"] and rest in ("easy", "right", "hard"):
                c.execute("UPDATE runs SET feel=? WHERE user_id=? AND run_id=?", (rest, user["id"], card["run_id"]))
                # the feel row goes after a tap; "Add a note" stays so a note can still follow
                keep = [(b["label"], i) for i, b in enumerate(buttons) if b["action"] == NOTE_ACTION]
            elif kind == "note":
                # The card must be a run card whose run still exists. A tap on another run's card moves note mode to
                # that card: the note goes where the runner last pointed.
                if card["kind"] != "run" or not card["run_id"] or not c.execute(
                        "SELECT 1 FROM runs WHERE user_id=? AND run_id=?", (user["id"], card["run_id"])).fetchone():
                    msg = "That button has expired."
                elif user["paused"]:
                    msg, after = "You're paused.", NOTE_PAUSED
                else:
                    c.execute("INSERT INTO note_mode (user_id, run_id, card_id, expires_at) VALUES (?,?,?,?) "
                              "ON CONFLICT(user_id) DO UPDATE SET run_id=excluded.run_id, card_id=excluded.card_id, "
                              "expires_at=excluded.expires_at",
                              (user["id"], card["run_id"], card["card_id"],
                               iso(real_now + timedelta(minutes=cv_notes.NOTE_MODE_MIN))))
                    msg, note_tapped = "Type your note.", True
            elif kind == "ans":
                key, _, val = rest.partition(":")
                if valid_answer(key, val):
                    self._memory_set(c, user["id"], key, val, now)
            elif kind == "sugg":
                outcome, _, skind = rest.partition(":")
                if outcome in ("yes", "skip"):
                    c.execute("INSERT OR REPLACE INTO outcomes (user_id, card_id, kind, outcome, ts) VALUES (?,?,?,?,?)",
                              (user["id"], card["card_id"], skind or "unknown", outcome, iso(now)))
                    if outcome == "skip":  # "not this week": spend the rest of this week's cap
                        wk = self._cap_week(c, user["id"], now)
                        for n in (1, 2):
                            c.execute("INSERT OR IGNORE INTO quota (user_id, key, created_at) VALUES (?,?,?)",
                                      (user["id"], f"sugg:{wk}:{n}", iso(now)))
                        msg = "Okay, nothing more this week."
            c.execute("UPDATE cards SET answered_at=COALESCE(answered_at, ?) WHERE card_id=?", (iso(now), card["card_id"]))
        if note_tapped:
            ch.ack_callback(inb, msg, clear=False)  # the card keeps its buttons
            self._reply(ch, inb.ref, NOTE_PROMPT)
        elif kind == "note":
            ch.ack_callback(inb, msg, clear=False)
            if after:
                self._reply(ch, inb.ref, after)
        elif keep:
            ch.ack_callback(inb, msg, keep=keep)
        else:
            ch.ack_callback(inb, msg)

    def _tap_time(self, card_id: str, now: datetime) -> datetime:
        """When a tap happened on the card's own clock. A replayed card lives at a virtual time in the past, so its
        answers (memory, caps, outcomes) are stamped with that virtual time, not the real date. Every other card: the
        real time."""
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT virtual_at, real_at FROM replay_items WHERE card_id=? ORDER BY id DESC LIMIT 1",
                          (card_id,)).fetchone()
        if not r:
            return now
        return parse_iso(r["virtual_at"])  # exactly: anything later would be invisible to the very next virtual item

    # ---------------------------------------------------------------- memory
    @staticmethod
    def _memory_set(c, uid: str, key: str, value: str, now: datetime) -> None:
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?) "
                  "ON CONFLICT(user_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                  (uid, key, value, iso(now)))

    @staticmethod
    def _memory_get(c, uid: str, now: datetime) -> dict[str, str]:
        out = {}
        for r in c.execute("SELECT key, value, updated_at FROM memory WHERE user_id=? AND updated_at<=?",
                           (uid, iso(now))):
            if r["key"] == "niggle_area" and parse_iso(r["updated_at"]) < now - timedelta(days=NIGGLE_TTL_DAYS):
                continue  # health-adjacent: expires after 8 weeks
            out[r["key"]] = r["value"]
        return out

    def get_me(self, uid: str, now: datetime | None = None) -> dict:
        now = now or now_utc()
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            if not u:
                raise NotFound()
            runs = [dict(r) for r in c.execute(
                "SELECT run_id, type, app_type, start_utc, zone_id, duration_s, distance_m, pace_s_per_km, true_pace_s_per_km, "
                "verdict, locality, feel, received_at FROM runs WHERE user_id=? ORDER BY start_utc DESC", (uid,))]
            cutoff = iso(now - timedelta(days=RETENTION_LOG_DAYS))
            msgs = [dict(r) for r in c.execute(
                "SELECT k.kind, k.headline, k.body, k.sent_at, cc.situation, cc.touch_kind FROM cards k "
                "LEFT JOIN convo_cards cc ON cc.card_id = k.card_id WHERE k.user_id=? AND k.sent_at >= ? "
                "ORDER BY k.sent_at DESC", (uid, cutoff))]
            areas = [dict(r) for r in c.execute("SELECT run_id, lat, lon FROM convo_area WHERE user_id=? ORDER BY rowid", (uid,))]
            convo = [dict(r) for r in c.execute("SELECT kind, key, ts FROM convo_log WHERE user_id=? ORDER BY id", (uid,))]
            memory = self._memory_get(c, uid, now)
            optin = bool(u["weather_optin"])
            outcomes = [dict(r) for r in c.execute("SELECT kind, outcome, ts FROM outcomes WHERE user_id=?", (uid,))]
            run_notes = [dict(r) for r in c.execute(
                "SELECT run_id, note, created_at FROM run_notes WHERE user_id=? ORDER BY created_at", (uid,))]
        ref = u["chat_ref"]
        return {
            "profile": {
                "channel": u["channel"], "chat_name": u["chat_name"], "chat_ref_hint": "…" + ref[-3:], "created_at": u["created_at"],
                "consent_version": u["consent_version"], "consent_at": u["consent_at"], "paused": bool(u["paused"]),
                "zone_id": u["zone_id"], "tz_set_at": u["tz_set_at"], "weather_in_suggestions": optin, "quiet_start_min": u["quiet_start"], "quiet_end_min": u["quiet_end"],
            },
            "runs_received": runs, "run_notes": run_notes, "memory": memory, "suggestion_outcomes": outcomes,
            "messages_sent_30d": msgs, "areas": areas, "conversation_log": convo,
            "goes_to": ["OpenRouter and the model provider (facts and enumerated memory only, no phone number or chat id)",
                        "Telegram" if u["channel"] == "telegram" else "Meta (WhatsApp Cloud API, keeps messages up to 30 days)",
                        *(["Open-Meteo (a location rounded to about 11 km and a timezone, no identifier)"]
                          if self.s.weather_enabled else [])],
        }

    def delete_me(self, uid: str) -> None:
        db.hard_delete_user(self.s.db_path, uid)
        log.info("deleted user=%s via api", uid)

    def set_settings(self, uid: str, quiet_start: int | None, quiet_end: int | None, zone_id: str | None,
                     weather: bool | None = None) -> None:
        with db.tx(self.s.db_path) as c:
            if weather is not None:  # the app's "Weather in suggestions" switch; off forgets every stored area
                c.execute("UPDATE users SET weather_optin=? WHERE id=?", (int(weather), uid))
                if not weather:
                    c.execute("DELETE FROM convo_area WHERE user_id=?", (uid,))
            if quiet_start is not None and quiet_end is not None:
                c.execute("UPDATE users SET quiet_start=?, quiet_end=? WHERE id=?", (quiet_start, quiet_end, uid))
            if zone_id and valid_zone(zone_id):
                c.execute("UPDATE users SET zone_id=? WHERE id=?", (zone_id, uid))

    def set_timezone(self, uid: str, zone_id: str, now: datetime | None = None) -> dict:
        """Move the user to `zone_id` (already validated). Scheduling reads users.zone_id; weekly caps stay pinned
        to the week they started in (resolve_cap_week), so travelling does not hand out a second weekly allowance."""
        now = now or now_utc()
        if not valid_zone(zone_id):
            raise ValueError("unknown time zone")
        offset = int(to_local(now, zone_id).utcoffset().total_seconds() // 60)
        with db.tx(self.s.db_path) as c:
            if not c.execute("UPDATE users SET zone_id=?, utc_offset_min=?, tz_set_at=? WHERE id=?",
                             (zone_id, offset, iso(now), uid)).rowcount:
                raise NotFound()
        return {"status": "ok", "zone_id": zone_id, "utc_offset_min": offset}

    # ---------------------------------------------------------------- runs (B6)
    def _coach_type(self, c, uid: str, run: RunIn) -> tuple[str, str | None]:
        """(coach type, the app's own type when it differed). See facts.infer_coach_type."""
        hist = self._history(c, uid, iso(run.start_utc), limit=80)
        coach = infer_coach_type(run.type, distance_m=run.distance_m, duration_s=run.duration_s,
                                 zone_min=run.zone_min, pb=run.pb, history=hist)
        return coach, (run.type if run.type in APP_TYPES else None)

    def ingest_run(self, uid: str, run: RunIn, now: datetime | None = None) -> dict:
        now = now or now_utc()
        if run.start_utc > now + timedelta(minutes=10):
            raise ValueError("start_utc in the future")
        end = run.start_utc + timedelta(seconds=run.duration_s)
        stale = (now - end) > timedelta(hours=self.s.stale_card_hours)
        with db.tx(self.s.db_path) as c:
            coach_type, app_type = self._coach_type(c, uid, run)
            if c.execute("SELECT 1 FROM runs WHERE user_id=? AND run_id=?", (uid, run.run_id)).fetchone():
                if c.execute("UPDATE replay_runs SET inserted=0 WHERE user_id=? AND run_id=? AND inserted=1",
                             (uid, run.run_id)).rowcount:
                    # The coach replay inserted this run from an export file; the app's own upload is the same run.
                    # Update it in place (a feel tapped during the replay is kept) and send no second card.
                    c.execute(
                        "UPDATE runs SET start_utc=?, end_utc=?, utc_offset_min=?, zone_id=?, type=?, app_type=?, duration_s=?, "
                        "distance_m=?, pace_s_per_km=?, true_pace_s_per_km=?, verdict=?, scores_delta=?, zone_min=?, "
                        "climb_m=?, locality=?, route_id=?, load_state=?, pb=?, plan_kind=?, plan_target_m=?, "
                        "plan_weeks_to_race=?, feel=COALESCE(feel, ?) WHERE user_id=? AND run_id=?",
                        (iso(run.start_utc), iso(end), run.utc_offset_min, run.zone_id, coach_type, app_type,
                         run.duration_s, run.distance_m, run.pace_s_per_km, run.true_pace_s_per_km, run.verdict,
                         json.dumps(run.scores_delta), json.dumps(run.zone_min), run.climb_m, run.locality,
                         run.route_id, run.load_state, run.pb, run.plan_kind, run.plan_target_m,
                         run.plan_weeks_to_race, run.feel, uid, run.run_id))
                    return {"status": "updated"}
                return {"status": "duplicate"}
            n = c.execute("SELECT COUNT(*) FROM runs WHERE user_id=? AND received_at >= ?",
                          (uid, iso(now - timedelta(days=1)))).fetchone()[0]
            if n >= RUNS_PER_DAY:
                raise RateLimited()
            c.execute(
                "INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, app_type, "
                "duration_s, distance_m, pace_s_per_km, true_pace_s_per_km, verdict, scores_delta, zone_min, climb_m, "
                "locality, route_id, load_state, pb, plan_kind, plan_target_m, plan_weeks_to_race, feel, received_at, "
                "stale) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (uid, run.run_id, iso(run.start_utc), iso(end), run.utc_offset_min, run.zone_id, coach_type, app_type,
                 run.duration_s, run.distance_m, run.pace_s_per_km, run.true_pace_s_per_km, run.verdict,
                 json.dumps(run.scores_delta), json.dumps(run.zone_min), run.climb_m, run.locality, run.route_id,
                 run.load_state, run.pb, run.plan_kind, run.plan_target_m, run.plan_weeks_to_race, run.feel,
                 iso(now), int(stale)))
            if self.s.weather_enabled and run.area_lat is not None and run.area_lon is not None \
                    and c.execute("SELECT weather_optin FROM users WHERE id=?", (uid,)).fetchone()["weather_optin"]:
                self._keep_latest_area(c, uid, run.run_id, run.start_utc, cell(run.area_lat, run.area_lon))
            urow = c.execute("SELECT last_run_utc, tz_set_at FROM users WHERE id=?", (uid,)).fetchone()
            last = urow["last_run_utc"]
            # the newest run decides the zone, unless the app PUT a zone after that run started (an offline queue
            # delivering an old run must not undo a PUT)
            if not last or iso(run.start_utc) >= last:
                held = bool(urow["tz_set_at"] and iso(run.start_utc) <= urow["tz_set_at"])
                # last_run_utc always advances (evening and recap targeting read it); only the zone is held back
                c.execute("UPDATE users SET last_run_utc=? WHERE id=?", (iso(run.start_utc), uid))
                if not held:
                    c.execute("UPDATE users SET zone_id=?, utc_offset_min=? WHERE id=?",
                              (run.zone_id, run.utc_offset_min, uid))
            if not stale:
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (uid, "run_card", iso(now), f"card:{uid}:{run.run_id}", run.run_id))
        return {"status": "stored" if stale else "accepted"}

    @staticmethod
    def _keep_latest_area(c, uid: str, run_id: str, start: datetime, at: tuple[float, float]) -> None:
        """One area per user: the one from their newest run. An older run arriving late (offline queue) is dropped."""
        held = c.execute("SELECT r.start_utc FROM convo_area a JOIN runs r ON r.user_id=a.user_id AND r.run_id=a.run_id "
                         "WHERE a.user_id=? ORDER BY r.start_utc DESC LIMIT 1", (uid,)).fetchone()
        if held and held["start_utc"] > iso(start):
            return
        c.execute("DELETE FROM convo_area WHERE user_id=?", (uid,))
        c.execute("INSERT INTO convo_area (user_id, run_id, lat, lon) VALUES (?,?,?,?)", (uid, run_id, at[0], at[1]))

    def set_feel(self, uid: str, run_id: str, feel: str) -> None:
        with db.tx(self.s.db_path) as c:
            cur = c.execute("UPDATE runs SET feel=? WHERE user_id=? AND run_id=?", (feel, uid, run_id))
            if cur.rowcount == 0:
                raise NotFound()

    # ---------------------------------------------------------------- weekly caps (C4/C5)
    def _cap_week(self, c, uid: str, now: datetime) -> str:
        u = c.execute("SELECT zone_id, cap_zone, cap_week FROM users WHERE id=?", (uid,)).fetchone()
        z, w = resolve_cap_week(u["cap_zone"], u["cap_week"], u["zone_id"], now)
        if (z, w) != (u["cap_zone"], u["cap_week"]):
            c.execute("UPDATE users SET cap_zone=?, cap_week=? WHERE id=?", (z, w, uid))
        return w

    @staticmethod
    def _claim(c, uid: str, key: str, now: datetime) -> bool:
        return c.execute("INSERT OR IGNORE INTO quota (user_id, key, created_at) VALUES (?,?,?)",
                         (uid, key, iso(now))).rowcount == 1

    def _claim_suggestion(self, c, uid: str, now: datetime) -> bool:
        wk = self._cap_week(c, uid, now)
        return any(self._claim(c, uid, f"sugg:{wk}:{n}", now) for n in (1, 2))

    # ---------------------------------------------------------------- cards
    def _kill_switch(self) -> bool:
        if self.s.sends_paused:
            return True
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT value FROM settings WHERE key='sends_paused'").fetchone()
        return bool(r and r["value"] == "1")

    def _quiet(self, user: dict) -> tuple[int, int]:
        qs = user["quiet_start"] if user["quiet_start"] is not None else self.s.default_quiet[0]
        qe = user["quiet_end"] if user["quiet_end"] is not None else self.s.default_quiet[1]
        return qs, qe

    def _history(self, c, uid: str, before: str | None, limit: int = 60) -> list[dict]:
        q = "SELECT * FROM runs WHERE user_id=?" + (" AND start_utc < ?" if before else "") + \
            " ORDER BY start_utc DESC LIMIT ?"
        args: tuple = (uid, before, limit) if before else (uid, limit)
        return [dict(r) for r in c.execute(q, args)]

    @staticmethod
    def _feel_counts(c, uid: str, now: datetime) -> dict[str, int]:
        out = {}
        for r in c.execute("SELECT feel, COUNT(*) n FROM runs WHERE user_id=? AND feel IS NOT NULL AND start_utc >= ? "
                           "AND start_utc <= ? GROUP BY feel", (uid, iso(now - timedelta(days=28)), iso(now))):
            out[r["feel"]] = r["n"]
        return out

    @staticmethod
    def _buttons(run_feel: str | None, suggestion_kind: str | None, question: dict | None,
                 note: bool = False) -> list[dict]:
        b: list[dict] = []
        if run_feel is None:
            b += [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
        if suggestion_kind:
            b += [{"label": "Sounds good", "action": f"sugg:yes:{suggestion_kind}", "row": 1},
                  {"label": "Not this week", "action": f"sugg:skip:{suggestion_kind}", "row": 1}]
        if question:
            for i, (v, l) in enumerate(question["options"]):
                b.append({"label": l, "action": f"ans:{question['key']}:{v}", "row": 2 + i // 3})
        if note:  # its own row under the feel row, so the feel row stays at three
            b.append({"label": "Add a note", "action": NOTE_ACTION, "row": 1})
        return b

    @staticmethod
    def _soften(c, uid: str, now: datetime) -> bool:
        """A recent note carries a niggle/sore/injury/tired/sick word. Reads the note text here and returns only a
        boolean: the text itself goes nowhere."""
        rows = [(r["note"], parse_iso(r["created_at"])) for r in c.execute(
            "SELECT note, created_at FROM run_notes WHERE user_id=? AND created_at>=? AND created_at<=?",
            (uid, iso(now - timedelta(days=cv_notes.SOFTEN_DAYS)), iso(now)))]
        return cv_notes.soften(rows, now)

    # ---------------------------------------------------------------- conversation layer (convo/)
    def _full_history(self, c, uid: str, before: str | None, now: datetime | None = None) -> list[dict]:
        """Every run, newest first. `now` caps it at that moment: a replay's clock is in the past, and a run uploaded
        for real since must not leak into a card dated before it. Live, nothing starts after now."""
        if before is None and now is not None:
            before = iso(now + timedelta(seconds=1))
        return self._history(c, uid, before, limit=2000)

    @staticmethod
    def _usage(c, uid: str, now: datetime) -> cv_touches.Usage:
        u = cv_touches.Usage()
        # Everything is read as of `now`: on a replay's clock, rows dated later (a real card sent meanwhile) must not
        # count toward touch spacing, no-repeat or the feel references.
        upto = iso(now)
        for r in c.execute("SELECT key, MAX(ts) ts FROM convo_log WHERE user_id=? AND kind='variant' AND ts>=? "
                           "AND ts<=? GROUP BY key", (uid, iso(now - timedelta(days=45)), upto)):
            u.variants[r["key"]] = parse_iso(r["ts"])
        last_touch = None
        for r in c.execute("SELECT key, ts FROM convo_log WHERE user_id=? AND kind='touch' AND ts<=? ORDER BY ts, id",
                           (uid, upto)):
            kind, _, key = r["key"].partition("|")
            u.touches.append((parse_iso(r["ts"]), kind, key))
            last_touch = r["ts"]
        u.cards_since_touch = c.execute("SELECT COUNT(*) FROM convo_log WHERE user_id=? AND kind='card' AND ts>? "
                                        "AND ts<=?", (uid, last_touch or "", upto)).fetchone()[0] if last_touch else 99
        u.feel_refs = {r["key"] for r in c.execute(
            "SELECT key FROM convo_log WHERE user_id=? AND kind='feel_ref' AND ts<=?", (uid, upto))}
        return u

    @staticmethod
    def _area(c, uid: str, run_id: str | None = None, now: datetime | None = None) -> tuple[float | None, float | None]:
        """The stored area, only while the runner is opted in. Without a run id: the latest, and only if it came from
        a run in the last AREA_USABLE_DAYS."""
        base = ("SELECT a.lat, a.lon FROM convo_area a JOIN users u ON u.id=a.user_id "
                "JOIN runs r ON r.user_id=a.user_id AND r.run_id=a.run_id WHERE a.user_id=? AND u.weather_optin=1")
        if run_id:
            r = c.execute(base + " AND a.run_id=?", (uid, run_id)).fetchone()
        else:
            cut = iso((now or now_utc()) - timedelta(days=AREA_USABLE_DAYS))
            r = c.execute(base + " AND r.start_utc >= ? ORDER BY r.start_utc DESC LIMIT 1", (uid, cut)).fetchone()
        return (r["lat"], r["lon"]) if r else (None, None)

    @staticmethod
    def _card_situation(c, uid: str, run_id: str | None) -> str | None:
        if not run_id:
            return None
        r = c.execute("SELECT cc.situation s FROM cards k JOIN convo_cards cc ON cc.card_id=k.card_id "
                      "WHERE k.user_id=? AND k.run_id=? AND k.kind='run'", (uid, run_id)).fetchone()
        return r["s"] if r else None

    @staticmethod
    def _convo_write(c, uid: str, now: datetime, card_id: str, situation: str, media: cv_engine.MediaPlan,
                     allowed: str, variants: list[str], touch: cv_touches.Touch | None) -> None:
        c.execute("INSERT INTO convo_cards (card_id, user_id, situation, media_json, allowed, touch_kind) VALUES (?,?,?,?,?,?)",
                  (card_id, uid, situation, media.to_json(), allowed, touch.kind if touch else None))
        rows = [("variant", v) for v in variants] + [("card", card_id)]
        if touch:
            rows.append(("touch", f"{touch.kind}|{touch.key}"))
        for kind, key in rows:
            c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)", (uid, kind, key, iso(now)))

    def _build_run_card(self, uid: str, run_id: str, now: datetime) -> str | None:
        """Returns card_id, or None when the engine decides to say nothing. Idempotent per (user, run)."""
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='run'", (uid, run_id)).fetchone()
            if ex:
                return ex["card_id"]
            run_r = c.execute("SELECT * FROM runs WHERE user_id=? AND run_id=?", (uid, run_id)).fetchone()
            if not run_r:
                return None
            run = dict(run_r)
            hist = self._history(c, uid, run["start_utc"])
            mem = self._memory_get(c, uid, now)
            last = c.execute("SELECT MAX(sent_at) m FROM cards WHERE user_id=?", (uid,)).fetchone()["m"]
            feels = self._feel_counts(c, uid, now)
        age_h = (now - parse_iso(last)).total_seconds() / 3600 if last else None
        res = build_facts(run, hist, mem, last_card_age_h=age_h)
        if res.say_nothing:
            return None
        with db.ro(self.s.db_path) as c:
            full = self._full_history(c, uid, run["start_utc"])
            usage = self._usage(c, uid, now)
            sunrises = c.execute("SELECT COUNT(*) FROM convo_log WHERE user_id=? AND kind='sunrise' AND key<>?",
                                 (uid, run_id)).fetchone()[0]
        with db.ro(self.s.db_path) as c:
            lat, lon = self._area(c, uid, run_id)
            prev_sit = self._card_situation(c, uid, full[0]["run_id"] if full else None)
            soft = self._soften(c, uid, now)
        rw = self.weather.at_run(lat, lon, run["zone_id"], parse_iso(run["start_utc"]), now)
        v = cv_engine.enrich_run(run, full, mem, now, usage, rw, sunrise_count=sunrises, prev_situation=prev_sit,
                                 soften=soft)
        # A run card carries the feel row only. A post-run suggestion is deferred to the evening-before slot
        # (under its own weekly cap and spacing), never piggybacked as buttons or text on the run card.
        suggestion, sline = None, None
        with db.tx(self.s.db_path) as c:
            if rw and cv_touches.is_sunrise_start(to_local(parse_iso(run["start_utc"]), run["zone_id"]), rw.sunrise_local):
                c.execute("INSERT INTO convo_log (user_id, kind, key, ts) SELECT ?,?,?,? WHERE NOT EXISTS "
                          "(SELECT 1 FROM convo_log WHERE user_id=? AND kind='sunrise' AND key=?)",
                          (uid, "sunrise", run_id, iso(now), uid, run_id))
        res = FactsResult(res.facts, None, res.tone, False, res.reason)
        w = self.writer.write(res, digest_lines(mem, feels), voice=v.rendered, style=v.style,
                              suggestion_line=sline.body if sline else None)
        body = w.body
        if v.touch_line:
            body += f"\n\n{v.touch_line}"
        buttons = self._buttons(run["feel"], None, None, note=True)
        card_id = secrets.token_hex(16)
        allowed = " ".join([f.text for f in res.facts] + [v.allowed, suggestion.text if suggestion else "",
                                                          sline.allowed if sline else ""])
        used = v.used_variants if w.source == "template" else [x for x in v.used_variants if x.startswith("touch_")]
        if sline and w.source == "template":
            used = used + [sline.variant_id]
        quiet_card = (v.media.reason in ("pb", "big_session", "long_run") or v.situation == "back_after_break"
                      or (v.touch is not None and v.touch.kind == "comeback"))
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, run_id, "run", w.headline, body, json.dumps(buttons), w.source, iso(now)))
            self._convo_write(c, uid, now, card_id, v.situation, v.media, allowed, used, v.touch)
            if not quiet_card and self._question_for(c, uid, full, mem, now) is not None:
                # the weekly question goes as its own short message about 30 minutes later, never on a big moment
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (uid, "question", iso(now + timedelta(minutes=QUESTION_DELAY_MIN)), f"q:{uid}:{run_id}", run_id))
        return card_id

    def _question_for(self, c, uid: str, hist: list[dict], mem: dict, now: datetime) -> dict | None:
        """The next question worth asking: not known, not answered, not asked in the last 28 days."""
        weeks = cv_suggest.plan_weeks(hist, now)
        skip = set(known_without_asking(hist, weeks, mem))
        skip |= {r["key"] for r in c.execute("SELECT key FROM convo_log WHERE user_id=? AND kind='asked' AND ts>?",
                                             (uid, iso(now - timedelta(days=REASK_DAYS))))}
        return next_weekly_question(mem, now, skip)

    def _build_question_card(self, uid: str, parent_run_id: str, now: datetime) -> str | None:
        ref = f"question:{parent_run_id}"
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='question'", (uid, ref)).fetchone()
            if ex:
                return ex["card_id"]
            hist = self._full_history(c, uid, None, now)
            mem = self._memory_get(c, uid, now)
        with db.tx(self.s.db_path) as c:
            q = self._question_for(c, uid, hist, mem, now)
            wk = self._cap_week(c, uid, now)
            if q is None or not self._claim(c, uid, f"question:{wk}", now):
                return None  # one a week
            head = QUESTION_HEADS[sum(map(ord, q["key"])) % len(QUESTION_HEADS)]
            card_id = secrets.token_hex(16)
            buttons = self._buttons("set", None, q)
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, ref, "question", head, q["text"], json.dumps(buttons), "template", iso(now)))
            media = cv_engine.MediaPlan("none", False, "question")
            self._convo_write(c, uid, now, card_id, "question", media, "", [], None)
            c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)", (uid, "asked", q["key"], iso(now)))
        return card_id

    def _build_evening_card(self, uid: str, local_date: str, now: datetime) -> str | None:
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='evening'",
                           (uid, f"evening:{local_date}")).fetchone()
            if ex:
                return ex["card_id"]
            hist = self._full_history(c, uid, None, now)
            mem = self._memory_get(c, uid, now)
            feels = self._feel_counts(c, uid, now)
            usage = self._usage(c, uid, now)
            zone_id = c.execute("SELECT zone_id FROM users WHERE id=?", (uid,)).fetchone()["zone_id"]
            soft = self._soften(c, uid, now)
        fc = None
        if hist:
            tomorrow = to_local(now, zone_id).date() + timedelta(days=1)
            with db.ro(self.s.db_path) as c:
                lat, lon = self._area(c, uid, None, now)
                last_sit = self._card_situation(c, uid, hist[0]["run_id"])
            fc = self.weather.tomorrow(lat, lon, hist[0]["zone_id"] or zone_id, tomorrow)
        else:
            last_sit = None
        ev = cv_suggest.evening(hist, now, fc, usage.variants, seed=local_date, zone_id=zone_id, last_situation=last_sit,
                                soften=soft)
        if not ev:
            return None
        with db.tx(self.s.db_path) as c:
            if not self._claim_suggestion(c, uid, now):
                return None
        w = self.writer.write(FactsResult((), ev.suggestion, "steady", False, "ok"), digest_lines(mem, feels),
                              voice=ev.rendered, style=ev.style)
        buttons = self._buttons("set", ev.suggestion.kind, None)
        card_id = secrets.token_hex(16)
        media = cv_engine.MediaPlan("suggestion", False, ev.suggestion.reason)
        used = [ev.rendered.variant_id] if w.source == "template" else []
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, f"evening:{local_date}", "evening", w.headline, w.body, json.dumps(buttons),
                       w.source, iso(now)))
            self._convo_write(c, uid, now, card_id, ev.rendered.situation, media, ev.rendered.allowed, used, None)
            if ev.suggestion.reason == "feel":  # the next post-run card must not repeat it
                c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)",
                          (uid, "feel_ref", hist[0]["run_id"], iso(now)))
        return card_id

    def _build_recap_card(self, uid: str, week_ref: str, now: datetime) -> str | None:
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='recap'",
                           (uid, f"recap:{week_ref}")).fetchone()
            if ex:
                return ex["card_id"]
            runs = self._full_history(c, uid, None, now)
            usage = self._usage(c, uid, now)
            zone_id = c.execute("SELECT zone_id FROM users WHERE id=?", (uid,)).fetchone()["zone_id"]
            empty_before = c.execute("SELECT COUNT(*) FROM convo_log WHERE user_id=? AND kind='recap_empty' AND ts>?",
                                     (uid, iso(now - timedelta(days=9)))).fetchone()[0]
        rc = cv_recap.build(runs, now, zone_id, usage.variants, seed=week_ref)
        if rc is None or (rc.empty and empty_before):  # one gentle nudge after a missed week, never two in a row
            return None
        body = rc.rendered.body
        with db.ro(self.s.db_path) as c:  # the newest note from this week, quoted back as written (never to a model)
            for rid in rc.week_run_ids:
                n = c.execute("SELECT note FROM run_notes WHERE user_id=? AND run_id=?", (uid, rid)).fetchone()
                if n:
                    body += f"\n\n{cv_notes.quote(n['note'])}"
                    break
        card_id = secrets.token_hex(16)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, f"recap:{week_ref}", "recap", rc.rendered.headline, body, "[]",
                       "template", iso(now)))
            self._convo_write(c, uid, now, card_id, rc.rendered.situation, rc.media, rc.rendered.allowed,
                              [rc.rendered.variant_id], None)
            if rc.empty:
                c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)",
                          (uid, "recap_empty", week_ref, iso(now)))
        return card_id

    def _send_card(self, user: dict, card_id: str, now: datetime) -> bool:
        """True when the card went out. False when it was deliberately not sent (WhatsApp, outside the 24 h window,
        on a card the fixed Easy/Right/Hard template cannot honestly carry)."""
        ch = self.channels.get(user["channel"])
        if ch is None:
            raise ChannelError("channel not configured")
        with db.ro(self.s.db_path) as c:
            card = dict(c.execute("SELECT * FROM cards WHERE card_id=?", (card_id,)).fetchone())
        if card["sent_at"]:
            return True
        buttons = json.loads(card["buttons_json"])
        telegram = user["channel"] == "telegram"
        links = self._links(card) if telegram else ()
        in_window = bool(user["last_inbound_at"] and parse_iso(user["last_inbound_at"]) > now - timedelta(hours=24))
        if user["channel"] == "whatsapp" and not in_window and not feel_template_eligible(
                OutCard(card_id, card["headline"], card["body"], buttons)):
            log.info("whatsapp card not sent outside the window: no template fits it")
            return False
        media = self._render_media(user, card, now) if telegram and self.s.media_enabled else None
        followups: list[str] = []
        if media is not None:
            out = OutCard(card_id, card["headline"], card["body"], buttons, media, links)
            try:
                ch.send_card(user["chat_ref"], out)
                followups = ch.followups(out)  # the media is delivered: from here only text may be retried
            except ChannelError as e:
                if not e.permanent:
                    raise
                log.warning("media refused, sending text: %s", e)
                media = None
        if media is None:
            ch.send_card(user["chat_ref"], OutCard(card_id, card["headline"], card["body"], buttons, None, links),
                         in_window=in_window)
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE cards SET sent_at=? WHERE card_id=?", (iso(now), card_id))
            c.execute("INSERT INTO msglog (user_id, ts, direction, kind) VALUES (?,?,?,?)",
                      (user["id"], iso(now), "out", card["kind"]))
            for mode in followups:  # its own outbox item each: a failure retries the text, never the upload
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (user["id"], "followup", iso(now), f"fu:{card_id}:{mode}", f"{card_id}:{mode}"))
        return True

    def _send_followup(self, user: dict, ref: str, now: datetime) -> bool:
        """False when dropped: unknown card or mode, or older than stale_card_hours since the media went out (a
        follow-up held back by the kill switch or quiet hours must not arrive long after its card)."""
        card_id, _, mode = ref.partition(":")
        ch = self.channels.get(user["channel"])
        if ch is None or mode not in ("caption", "question"):
            return False
        with db.ro(self.s.db_path) as c:
            row = c.execute("SELECT * FROM cards WHERE card_id=? AND user_id=?", (card_id, user["id"])).fetchone()
        if row is None:
            return False
        card = dict(row)
        if not card["sent_at"] or parse_iso(card["sent_at"]) < now - timedelta(hours=self.s.stale_card_hours):
            log.info("follow-up dropped: stale")
            return False
        ch.send_followup(user["chat_ref"], OutCard(card_id, card["headline"], card["body"],
                                                   json.loads(card["buttons_json"]), None, self._links(card)), mode)
        return True

    def _links(self, card: dict) -> tuple[tuple[str, str], ...]:
        """Deep-link buttons for a card: the run itself, or the recap's week. Empty without a configured https base."""
        ref = card.get("run_id") or ""
        if card["kind"] == "run":
            uri = run_link(ref)
        elif card["kind"] == "recap" and ref.startswith("recap:"):
            uri = week_link(ref[len("recap:"):])
        else:
            return ()
        url = web_twin(self.s.deeplink_base, uri)
        return (("Open in app", url),) if url else ()

    def _render_media(self, user: dict, card: dict, now: datetime) -> Media | None:
        """The card's planned photo or video, or None (no media planned, or any render failure: the text goes out)."""
        with db.ro(self.s.db_path) as c:
            cc = c.execute("SELECT media_json FROM convo_cards WHERE card_id=?", (card["card_id"],)).fetchone()
            if not cc:
                return None
            plan = json.loads(cc["media_json"])
            if plan.get("card") in (None, "none"):
                return None
            if card["kind"] == "recap":
                runs = [dict(r) for r in c.execute("SELECT * FROM runs WHERE user_id=? AND start_utc>=? AND start_utc<=?",
                                                    (user["id"], iso(now - timedelta(days=21)), iso(now)))]
            else:
                runs = [dict(r) for r in c.execute("SELECT * FROM runs WHERE user_id=? AND run_id=?",
                                                    (user["id"], card.get("run_id")))]
        try:
            return self.media.render(plan, card, runs)
        except MediaError as e:
            log.warning("render failed, sending text: %s", e)
        except Exception as e:  # renderer missing or crashed: the text card is still the product
            log.warning("render crashed, sending text: %s", type(e).__name__)
        return None

    # ---------------------------------------------------------------- outbox worker (C5)
    def _process(self, item: dict, now: datetime) -> tuple[str, datetime | None]:
        """-> (state, retry_at). state: done | skipped | defer."""
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT * FROM users WHERE id=?", (item["user_id"],)).fetchone()
        if not r:
            return "skipped", None
        user = dict(r)
        if user["paused"]:
            return "skipped", None
        if self._kill_switch():
            return "defer", now + timedelta(minutes=15)
        qs, qe = self._quiet(user)
        if in_quiet(now, user["zone_id"], qs, qe):
            return "defer", quiet_end_utc(now, user["zone_id"], qe)
        if item["kind"] == "followup":
            return ("done" if self._send_followup(user, item["ref"], now) else "skipped"), None
        if item["kind"] == "run_card":
            card_id = self._build_run_card(user["id"], item["ref"], now)
        elif item["kind"] == "evening":
            if user["channel"] != "telegram":  # WhatsApp would bill an unprompted suggestion as marketing
                return "skipped", None
            card_id = self._build_evening_card(user["id"], item["ref"], now)
        elif item["kind"] == "question":
            card_id = self._build_question_card(user["id"], item["ref"], now)
        elif item["kind"] == "recap":
            if user["channel"] != "telegram":  # Telegram first; WhatsApp would bill it as marketing
                return "skipped", None
            card_id = self._build_recap_card(user["id"], item["ref"], now)
        else:
            return "skipped", None
        if card_id is None:
            return "skipped", None
        return ("done" if self._send_card(user, card_id, now) else "skipped"), None

    def run_outbox(self, now: datetime | None = None, limit: int = 20, only_user: str | None = None) -> int:
        """`only_user` is the coach replay driving one user on its own clock; the live worker (no `only_user`) skips
        every user a replay still holds, except for a real run's own card and question (LIVE_ROW), which go out at
        once, unprefixed. The replay never touches those."""
        now = now or now_utc()
        who, args = ((f" AND user_id = ? AND NOT {LIVE_ROW}", (only_user,)) if only_user
                     else (f" AND (user_id NOT IN {replay_hold(now)} OR {LIVE_ROW})", ()))
        with db.tx(self.s.db_path) as c:
            rows = [dict(r) for r in c.execute(
                "SELECT * FROM outbox WHERE state IN ('pending','sending') AND due_at <= ?" + who +
                " ORDER BY due_at LIMIT ?", (iso(now), *args, limit))]
            for r in rows:  # 5 minute lease: a crash mid-send makes the row claimable again
                c.execute("UPDATE outbox SET state='sending', attempts=attempts+1, due_at=? WHERE id=?",
                          (iso(now + timedelta(minutes=5)), r["id"]))
        for r in rows:
            attempts = r["attempts"] + 1
            try:
                state, retry = self._process(r, now)
                err = None
            except ChannelError as e:
                state, retry, err = "retry", None, str(e)[:120]
            except Exception as e:  # never let one item stall the loop
                log.error("outbox item failed: %s", type(e).__name__)
                state, retry, err = "retry", None, type(e).__name__
            with db.tx(self.s.db_path) as c:
                if state in ("done", "skipped"):
                    c.execute("UPDATE outbox SET state=?, last_error=NULL WHERE id=?", (state, r["id"]))
                elif state == "defer":
                    c.execute("UPDATE outbox SET state='pending', attempts=attempts-1, due_at=? WHERE id=?",
                              (iso(retry), r["id"]))
                elif attempts >= MAX_ATTEMPTS:
                    c.execute("UPDATE outbox SET state='failed', last_error=? WHERE id=?", (err, r["id"]))
                else:
                    c.execute("UPDATE outbox SET state='pending', due_at=?, last_error=? WHERE id=?",
                              (iso(now + timedelta(minutes=2 ** attempts)), err, r["id"]))
        return len(rows)

    def mark_replay_aware(self) -> None:  # also refreshed every tick (tick_replay_flag)
        """The live worker records that it leaves a replayed user alone. `companion.cli replay` refuses to start
        until this exists, so a service still running older code (which would send the replay's virtual-past
        items at once) cannot be left running beside it."""
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('replay_aware_at', ?)", (iso(now_utc()),))

    def tick_replay_flag(self, now: datetime) -> None:
        """Refresh `replay_aware_at` (the gate `cli replay` checks) and release replays whose hold has lapsed."""
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('replay_aware_at', ?)", (iso(now),))
            lapsed = [r["user_id"] for r in c.execute(
                f"SELECT user_id FROM replay_state WHERE status <> 'done' AND user_id NOT IN {replay_hold(now)}")]
            for uid in lapsed:  # same release as a finished replay: nothing old goes out in a flood
                c.execute("UPDATE outbox SET state='skipped' WHERE user_id=? AND state IN ('pending','sending') AND due_at < ?",
                          (uid, iso(now - timedelta(hours=self.s.stale_card_hours))))
                c.execute("UPDATE replay_state SET status='done', updated_at=? WHERE user_id=?", (iso(now), uid))
                log.warning("replay auto-released user=%s", uid)

    def overdue_count(self, now: datetime | None = None) -> int:
        """Outbox rows overdue by an hour. A replay with a live heartbeat is working through its own backlog and is
        not counted; a stalled or stopped one is, so the health watch alerts."""
        now = now or now_utc()
        alive = ("(SELECT user_id FROM replay_state WHERE status IN ('running','stopping') "
                 f"AND heartbeat_at > '{iso(now - REPLAY_ALIVE)}')")
        with db.ro(self.s.db_path) as c:
            return c.execute("SELECT COUNT(*) FROM outbox WHERE state IN ('pending','sending') AND due_at < ? "
                             f"AND user_id NOT IN {alive}", (iso(now - timedelta(hours=1)),)).fetchone()[0]

    def replay_held(self, now: datetime | None = None) -> int:
        now = now or now_utc()
        with db.ro(self.s.db_path) as c:
            return c.execute(f"SELECT COUNT(*) FROM {replay_hold(now)}").fetchone()[0]

    # ---------------------------------------------------------------- planning + retention
    def plan_evening(self, now: datetime | None = None, only_user: str | None = None) -> int:
        """Queue the evening-before suggestion (Telegram only) in the user's 20:00-21:00 local window."""
        now = now or now_utc()
        n = 0
        who, args = ((" AND id = ?", (only_user,)) if only_user else (f" AND id NOT IN {replay_hold(now)}", ()))
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND last_run_utc >= ?" + who,
                (iso(now - timedelta(days=14)), *args))]
            for u in users:
                loc = to_local(now, u["zone_id"])
                if not (cv_suggest.EVENING_START_MIN <= loc.hour * 60 + loc.minute < cv_suggest.EVENING_END_MIN):
                    continue
                if loc.weekday() == cv_recap.RECAP_WEEKDAY:
                    continue  # Sunday evening belongs to the weekly recap
                qs, qe = self._quiet(u)
                if in_quiet(now, u["zone_id"], qs, qe):
                    continue
                mem = self._memory_get(c, u["id"], now)
                if not tomorrow_is_usual_day(mem.get("usual_days"), (loc + timedelta(days=1)).weekday()):
                    continue
                recent = c.execute("SELECT 1 FROM cards WHERE user_id=? AND kind='evening' AND created_at>?",
                                   (u["id"], iso(now - timedelta(hours=cv_suggest.EVENING_MIN_GAP_H)))).fetchone()
                if recent:
                    continue  # no suggestion two evenings running
                d = loc.date().isoformat()
                n += c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                               (u["id"], "evening", iso(now), f"evening:{u['id']}:{d}", d)).rowcount
        return n

    def plan_recap(self, now: datetime | None = None, only_user: str | None = None) -> int:
        """Queue the weekly recap for Sunday 19:00-20:00 local, once per local week."""
        now = now or now_utc()
        n = 0
        who, args = ((" AND id = ?", (only_user,)) if only_user else (f" AND id NOT IN {replay_hold(now)}", ()))
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND last_run_utc >= ?" + who,
                (iso(now - timedelta(days=cv_recap.QUIET_AFTER_DAYS)), *args))]
            for u in users:
                loc = to_local(now, u["zone_id"])
                if loc.weekday() != cv_recap.RECAP_WEEKDAY:
                    continue
                if not (cv_recap.RECAP_START_MIN <= loc.hour * 60 + loc.minute < cv_recap.RECAP_END_MIN):
                    continue
                qs, qe = self._quiet(u)
                if in_quiet(now, u["zone_id"], qs, qe):
                    continue
                wk = week_key(now, u["zone_id"])
                n += c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                               (u["id"], "recap", iso(now), f"recap:{u['id']}:{wk}", wk)).rowcount
        return n

    def purge(self, now: datetime | None = None) -> None:
        now = now or now_utc()
        log_cut = iso(now - timedelta(days=RETENTION_LOG_DAYS))
        with db.tx(self.s.db_path) as c:
            c.execute("DELETE FROM enrolments WHERE expires_at < ?", (iso(now - timedelta(days=1)),))
            c.execute("DELETE FROM users WHERE created_at < ? AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.user_id = users.id)",
                      (iso(now - timedelta(hours=1)),))  # started enrolling, never confirmed
            # A replay holds its user: its rows carry virtual (past) dates and are still being used.
            held = f" AND user_id NOT IN {replay_hold(now)}"
            c.execute("DELETE FROM msglog WHERE ts < ?" + held, (log_cut,))
            c.execute("DELETE FROM inbound_seen WHERE ts < ?", (log_cut,))
            c.execute("DELETE FROM cards WHERE created_at < ?" + held, (log_cut,))
            c.execute("DELETE FROM outbox WHERE state IN ('done','skipped','failed') AND due_at < ?" + held, (log_cut,))
            c.execute("DELETE FROM convo_log WHERE ts < ?" + held, (iso(now - timedelta(days=400)),))
            c.execute("DELETE FROM note_mode WHERE expires_at < ?", (iso(now - timedelta(hours=1)),))
            c.execute("DELETE FROM run_notes WHERE NOT EXISTS (SELECT 1 FROM runs r WHERE r.user_id=run_notes.user_id "
                      "AND r.run_id=run_notes.run_id)")  # belt and braces: a note never outlives its run
            c.execute("DELETE FROM quota WHERE created_at < ?" + held, (iso(now - timedelta(days=60)),))
            c.execute("DELETE FROM replay_items WHERE real_at < ?" + held, (log_cut,))
            c.execute("DELETE FROM replay_runs WHERE user_id IN (SELECT user_id FROM replay_state WHERE status = 'done' "
                      "AND updated_at < ?)", (log_cut,))
            c.execute("DELETE FROM replay_state WHERE status = 'done' AND updated_at < ?", (log_cut,))
            c.execute("DELETE FROM llm_calls WHERE ts < ?", (iso(now - timedelta(days=400)),))
            # the area's own age: 30 days after the run it came from (or its run is gone), or the switch is off
            c.execute("DELETE FROM convo_area WHERE NOT EXISTS (SELECT 1 FROM runs r WHERE r.user_id=convo_area.user_id "
                      "AND r.run_id=convo_area.run_id AND r.start_utc >= ?)" + held, (iso(now - timedelta(days=RETENTION_AREA_DAYS)),))
            c.execute("DELETE FROM convo_area WHERE user_id IN (SELECT id FROM users WHERE weather_optin=0)" + held)
            c.execute("DELETE FROM memory WHERE key='niggle_area' AND updated_at < ?" + held,
                      (iso(now - timedelta(days=NIGGLE_TTL_DAYS)),))
            idle = [r["id"] for r in c.execute(
                f"SELECT id FROM users WHERE COALESCE(last_run_utc, created_at) < ? AND id NOT IN {replay_hold(now)}",
                (iso(now - timedelta(days=RETENTION_INACTIVE_DAYS)),))]
        for uid in idle:  # six months without a run: hard delete
            db.hard_delete_user(self.s.db_path, uid)
            log.info("retention-deleted user=%s", uid)

    def tick(self, now: datetime | None = None) -> None:
        now = now or now_utc()
        self.tick_replay_flag(now)
        self.plan_evening(now)
        self.plan_recap(now)
        self.run_outbox(now)
        with db.tx(self.s.db_path) as c:
            r = c.execute("SELECT value FROM settings WHERE key='last_purge'").fetchone()
            due = not r or parse_iso(r["value"]) < now - timedelta(hours=1)
            if due:
                c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('last_purge', ?)", (iso(now),))
        if due:
            self.purge(now)
