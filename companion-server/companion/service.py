"""Core behaviour: enrolment, run ingest, cards, memory, outbox, inbound commands."""
from __future__ import annotations

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
from .channels import ChannelError, Inbound, OutCard, TelegramChannel, WhatsAppChannel
from .config import Settings
from .facts import (FactsResult, build_facts, next_question, suggest_evening, tomorrow_is_usual_day,
                    valid_answer, NIGGLE_TTL_DAYS)
from .timeutil import (in_quiet, iso, now_utc, parse_iso, quiet_end_utc, resolve_cap_week, to_local, UTC,
                       valid_zone)
from .writer import Writer, digest_lines

log = logging.getLogger("companion")

ENROL_TTL_MIN = 15
MAX_CODE_ATTEMPTS = 5
MAX_ATTEMPTS = 4
RUNS_PER_DAY = 30
START_RE = re.compile(r"^\s*/?start\s+([A-Za-z0-9_-]{8,64})\s*$", re.I)
RETENTION_INACTIVE_DAYS = 183
RETENTION_LOG_DAYS = 30

NOT_OPEN = "Run Supreme's companion isn't open yet. We'll let you know when it is."
UNKNOWN = ("I only send run recaps. To connect, open Run Supreme, go to Settings > Companion and tap "
           "Turn on. Send STOP to pause or DELETE to erase everything.")
CODE_MSG = ("Your code is {code}. Type it into Run Supreme to finish connecting. Only ever enter it in the app, "
            "and never share it. If you didn't start this, ignore this message.")
WELCOME = ("You're connected. Your run recaps will land here. Send STOP to pause them or DELETE to "
           "erase everything we hold about you.")


# Dart VerdictHeadline.name -> the words the facts engine may say. noVerdict says nothing.
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
            reply = "Back on. Your next run recap will land here." if user else UNKNOWN
        elif word == "DELETE":
            if user:
                db.hard_delete_user(self.s.db_path, user["id"])
                log.info("deleted user=%s via keyword", user["id"])
                reply = "Done. Everything we held about you is deleted. Meta may keep delivery records for up to 30 days."
            else:
                reply = "We hold nothing for this chat."
        else:
            reply = UNKNOWN  # fixed canned reply; unrecognised free text never reaches a model
        self._reply(ch, inb.ref, reply)

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
        action = buttons[inb.button_idx]["action"]
        kind, _, rest = action.partition(":")
        msg = "Thanks."
        with db.tx(self.s.db_path) as c:
            if kind == "feel" and card["run_id"] and rest in ("easy", "right", "hard"):
                c.execute("UPDATE runs SET feel=? WHERE user_id=? AND run_id=?", (rest, user["id"], card["run_id"]))
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
        ch.ack_callback(inb, msg)

    # ---------------------------------------------------------------- memory
    @staticmethod
    def _memory_set(c, uid: str, key: str, value: str, now: datetime) -> None:
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?) "
                  "ON CONFLICT(user_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                  (uid, key, value, iso(now)))

    @staticmethod
    def _memory_get(c, uid: str, now: datetime) -> dict[str, str]:
        out = {}
        for r in c.execute("SELECT key, value, updated_at FROM memory WHERE user_id=?", (uid,)):
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
                "SELECT run_id, type, start_utc, zone_id, duration_s, distance_m, pace_s_per_km, true_pace_s_per_km, "
                "verdict, locality, feel, received_at FROM runs WHERE user_id=? ORDER BY start_utc DESC", (uid,))]
            cutoff = iso(now - timedelta(days=RETENTION_LOG_DAYS))
            msgs = [dict(r) for r in c.execute(
                "SELECT kind, headline, body, sent_at FROM cards WHERE user_id=? AND sent_at >= ? ORDER BY sent_at DESC",
                (uid, cutoff))]
            memory = self._memory_get(c, uid, now)
            outcomes = [dict(r) for r in c.execute("SELECT kind, outcome, ts FROM outcomes WHERE user_id=?", (uid,))]
        ref = u["chat_ref"]
        return {
            "profile": {
                "channel": u["channel"], "chat_name": u["chat_name"], "chat_ref_hint": "…" + ref[-3:], "created_at": u["created_at"],
                "consent_version": u["consent_version"], "consent_at": u["consent_at"], "paused": bool(u["paused"]),
                "zone_id": u["zone_id"], "quiet_start_min": u["quiet_start"], "quiet_end_min": u["quiet_end"],
            },
            "runs_received": runs, "memory": memory, "suggestion_outcomes": outcomes,
            "messages_sent_30d": msgs,
            "goes_to": ["OpenRouter and the model provider (facts and enumerated memory only, no phone number or chat id)",
                        "Telegram" if u["channel"] == "telegram" else "Meta (WhatsApp Cloud API, keeps messages up to 30 days)"],
        }

    def delete_me(self, uid: str) -> None:
        db.hard_delete_user(self.s.db_path, uid)
        log.info("deleted user=%s via api", uid)

    def set_settings(self, uid: str, quiet_start: int | None, quiet_end: int | None, zone_id: str | None) -> None:
        with db.tx(self.s.db_path) as c:
            if quiet_start is not None and quiet_end is not None:
                c.execute("UPDATE users SET quiet_start=?, quiet_end=? WHERE id=?", (quiet_start, quiet_end, uid))
            if zone_id and valid_zone(zone_id):
                c.execute("UPDATE users SET zone_id=? WHERE id=?", (zone_id, uid))

    # ---------------------------------------------------------------- runs (B6)
    def ingest_run(self, uid: str, run: RunIn, now: datetime | None = None) -> dict:
        now = now or now_utc()
        if run.start_utc > now + timedelta(minutes=10):
            raise ValueError("start_utc in the future")
        end = run.start_utc + timedelta(seconds=run.duration_s)
        stale = (now - end) > timedelta(hours=self.s.stale_card_hours)
        with db.tx(self.s.db_path) as c:
            if c.execute("SELECT 1 FROM runs WHERE user_id=? AND run_id=?", (uid, run.run_id)).fetchone():
                return {"status": "duplicate"}
            n = c.execute("SELECT COUNT(*) FROM runs WHERE user_id=? AND received_at >= ?",
                          (uid, iso(now - timedelta(days=1)))).fetchone()[0]
            if n >= RUNS_PER_DAY:
                raise RateLimited()
            c.execute(
                "INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, duration_s, "
                "distance_m, pace_s_per_km, true_pace_s_per_km, verdict, scores_delta, zone_min, climb_m, locality, "
                "route_id, load_state, pb, plan_kind, plan_target_m, plan_weeks_to_race, feel, received_at, stale) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (uid, run.run_id, iso(run.start_utc), iso(end), run.utc_offset_min, run.zone_id, run.type,
                 run.duration_s, run.distance_m, run.pace_s_per_km, run.true_pace_s_per_km, run.verdict,
                 json.dumps(run.scores_delta), json.dumps(run.zone_min), run.climb_m, run.locality, run.route_id,
                 run.load_state, run.pb, run.plan_kind, run.plan_target_m, run.plan_weeks_to_race, run.feel,
                 iso(now), int(stale)))
            last = c.execute("SELECT last_run_utc FROM users WHERE id=?", (uid,)).fetchone()["last_run_utc"]
            if not last or iso(run.start_utc) >= last:  # newest run decides the user's current zone
                c.execute("UPDATE users SET zone_id=?, utc_offset_min=?, last_run_utc=? WHERE id=?",
                          (run.zone_id, run.utc_offset_min, iso(run.start_utc), uid))
            if not stale:
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (uid, "run_card", iso(now), f"card:{uid}:{run.run_id}", run.run_id))
        return {"status": "stored" if stale else "accepted"}

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
                           "GROUP BY feel", (uid, iso(now - timedelta(days=28)))):
            out[r["feel"]] = r["n"]
        return out

    @staticmethod
    def _buttons(run_feel: str | None, suggestion_kind: str | None, question: dict | None) -> list[dict]:
        b: list[dict] = []
        if run_feel is None:
            b += [{"label": l, "action": f"feel:{v}", "row": 0} for v, l in (("easy", "Easy"), ("right", "Right"), ("hard", "Hard"))]
        if suggestion_kind:
            b += [{"label": "Sounds good", "action": f"sugg:yes:{suggestion_kind}", "row": 1},
                  {"label": "Not this week", "action": f"sugg:skip:{suggestion_kind}", "row": 1}]
        if question:
            for i, (v, l) in enumerate(question["options"]):
                b.append({"label": l, "action": f"ans:{question['key']}:{v}", "row": 2 + i // 3})
        return b

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
        with db.tx(self.s.db_path) as c:
            suggestion, question = res.suggestion, None
            if suggestion and not self._claim_suggestion(c, uid, now):
                suggestion = None
            if not suggestion:
                q = next_question(mem, now)
                wk = self._cap_week(c, uid, now)
                if q and self._claim(c, uid, f"question:{wk}", now):
                    question = q
        res = FactsResult(res.facts, suggestion, res.tone, False, res.reason)
        w = self.writer.write(res, digest_lines(mem, feels))
        body = w.body + (f"\n\n{question['text']}" if question else "")
        buttons = self._buttons(run["feel"], suggestion.kind if suggestion else None, question)
        card_id = secrets.token_hex(16)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, run_id, "run", w.headline, body, json.dumps(buttons), w.source, iso(now)))
        return card_id

    def _build_evening_card(self, uid: str, local_date: str, now: datetime) -> str | None:
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='evening'",
                           (uid, f"evening:{local_date}")).fetchone()
            if ex:
                return ex["card_id"]
            hist = self._history(c, uid, None)
            mem = self._memory_get(c, uid, now)
            feels = self._feel_counts(c, uid, now)
        sug = suggest_evening(hist, now)
        if not sug:
            return None
        with db.tx(self.s.db_path) as c:
            if not self._claim_suggestion(c, uid, now):
                return None
        w = self.writer.write(FactsResult((), sug, "steady", False, "ok"), digest_lines(mem, feels))
        buttons = self._buttons("set", sug.kind, None)
        card_id = secrets.token_hex(16)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, f"evening:{local_date}", "evening", w.headline, w.body, json.dumps(buttons),
                       w.source, iso(now)))
        return card_id

    def _send_card(self, user: dict, card_id: str, now: datetime) -> None:
        ch = self.channels.get(user["channel"])
        if ch is None:
            raise ChannelError("channel not configured")
        with db.ro(self.s.db_path) as c:
            card = dict(c.execute("SELECT * FROM cards WHERE card_id=?", (card_id,)).fetchone())
        if card["sent_at"]:
            return
        out = OutCard(card_id, card["headline"], card["body"], json.loads(card["buttons_json"]))
        in_window = bool(user["last_inbound_at"] and parse_iso(user["last_inbound_at"]) > now - timedelta(hours=24))
        ch.send_card(user["chat_ref"], out, in_window=in_window)
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE cards SET sent_at=? WHERE card_id=?", (iso(now), card_id))
            c.execute("INSERT INTO msglog (user_id, ts, direction, kind) VALUES (?,?,?,?)",
                      (user["id"], iso(now), "out", card["kind"]))

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
        if item["kind"] == "run_card":
            card_id = self._build_run_card(user["id"], item["ref"], now)
        elif item["kind"] == "evening":
            if user["channel"] != "telegram":  # WhatsApp would bill an unprompted suggestion as marketing
                return "skipped", None
            card_id = self._build_evening_card(user["id"], item["ref"], now)
        else:
            return "skipped", None
        if card_id is None:
            return "skipped", None
        self._send_card(user, card_id, now)
        return "done", None

    def run_outbox(self, now: datetime | None = None, limit: int = 20) -> int:
        now = now or now_utc()
        with db.tx(self.s.db_path) as c:
            rows = [dict(r) for r in c.execute(
                "SELECT * FROM outbox WHERE state IN ('pending','sending') AND due_at <= ? ORDER BY due_at LIMIT ?",
                (iso(now), limit))]
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

    def overdue_count(self, now: datetime | None = None) -> int:
        now = now or now_utc()
        with db.ro(self.s.db_path) as c:
            return c.execute("SELECT COUNT(*) FROM outbox WHERE state IN ('pending','sending') AND due_at < ?",
                             (iso(now - timedelta(hours=1)),)).fetchone()[0]

    # ---------------------------------------------------------------- planning + retention
    def plan_evening(self, now: datetime | None = None) -> int:
        """Queue the evening-before suggestion (Telegram only) in the user's 18:00-19:30 local window."""
        now = now or now_utc()
        n = 0
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND last_run_utc >= ?",
                (iso(now - timedelta(days=14)),))]
            for u in users:
                loc = to_local(now, u["zone_id"])
                if not (18 * 60 <= loc.hour * 60 + loc.minute < 19 * 60 + 30):
                    continue
                qs, qe = self._quiet(u)
                if in_quiet(now, u["zone_id"], qs, qe):
                    continue
                mem = self._memory_get(c, u["id"], now)
                if not tomorrow_is_usual_day(mem.get("usual_days"), (loc + timedelta(days=1)).weekday()):
                    continue
                d = loc.date().isoformat()
                n += c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                               (u["id"], "evening", iso(now), f"evening:{u['id']}:{d}", d)).rowcount
        return n

    def purge(self, now: datetime | None = None) -> None:
        now = now or now_utc()
        log_cut = iso(now - timedelta(days=RETENTION_LOG_DAYS))
        with db.tx(self.s.db_path) as c:
            c.execute("DELETE FROM enrolments WHERE expires_at < ?", (iso(now - timedelta(days=1)),))
            c.execute("DELETE FROM users WHERE created_at < ? AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.user_id = users.id)",
                      (iso(now - timedelta(hours=1)),))  # started enrolling, never confirmed
            c.execute("DELETE FROM msglog WHERE ts < ?", (log_cut,))
            c.execute("DELETE FROM inbound_seen WHERE ts < ?", (log_cut,))
            c.execute("DELETE FROM cards WHERE created_at < ?", (log_cut,))
            c.execute("DELETE FROM outbox WHERE state IN ('done','skipped','failed') AND due_at < ?", (log_cut,))
            c.execute("DELETE FROM quota WHERE created_at < ?", (iso(now - timedelta(days=60)),))
            c.execute("DELETE FROM llm_calls WHERE ts < ?", (iso(now - timedelta(days=400)),))
            c.execute("DELETE FROM memory WHERE key='niggle_area' AND updated_at < ?",
                      (iso(now - timedelta(days=NIGGLE_TTL_DAYS)),))
            idle = [r["id"] for r in c.execute(
                "SELECT id FROM users WHERE COALESCE(last_run_utc, created_at) < ?",
                (iso(now - timedelta(days=RETENTION_INACTIVE_DAYS)),))]
        for uid in idle:  # six months without a run: hard delete
            db.hard_delete_user(self.s.db_path, uid)
            log.info("retention-deleted user=%s", uid)

    def tick(self, now: datetime | None = None) -> None:
        now = now or now_utc()
        self.plan_evening(now)
        self.run_outbox(now)
        with db.tx(self.s.db_path) as c:
            r = c.execute("SELECT value FROM settings WHERE key='last_purge'").fetchone()
            due = not r or parse_iso(r["value"]) < now - timedelta(hours=1)
            if due:
                c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('last_purge', ?)", (iso(now),))
        if due:
            self.purge(now)
