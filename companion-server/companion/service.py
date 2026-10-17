"""Core behaviour: enrolment, run ingest, cards, memory, outbox, inbound commands."""
from __future__ import annotations

import contextlib
import dataclasses
import math

import hashlib
import hmac
import json
import logging
import re
import secrets
import sqlite3
import string
import unicodedata
from datetime import date, datetime, timedelta
from typing import Annotated, Any

import httpx
from pydantic_core import PydanticCustomError
from pydantic import BaseModel, ConfigDict, Field, StrictInt, ValidationError, field_validator, model_validator

from . import db
from .channels import ChannelError, Inbound, OutCard, TelegramChannel, WhatsAppChannel, feel_template_eligible
from .checkin_service import CheckinMixin
from .measure import MeasureMixin
from . import measure as cv_measure
from .config import Settings
from .deeplink import run_link, web_twin, week_link
from .media import GHOST_CLIP_S, Media, MediaError, from_settings
from . import feedback as cv_feedback
from . import ops_send
from . import notes as cv_notes
from . import quest as cv_quest
from . import trail as cv_trail
from .convo import engine as cv_engine
from .convo import recap as cv_recap
from . import default_week as cv_default_week
from .checkins import planned_from_run as ci_planned_from_run
from .convo import suggest as cv_suggest
from .convo import touches as cv_touches
from .convo.questions import REASK_DAYS, known_without_asking, next_weekly_question
from .convo.weather import NoWeather, OpenMeteo, cell
from .facts import APP_TYPES, GOAL_PURPOSE, FactsResult, build_facts, next_line, known_session, infer_coach_type, tomorrow_is_usual_day, valid_answer, NIGGLE_TTL_DAYS
from .rails import SLOW_DOWN, SLOW_DOWN_DAY, RateLimiter, add_alert, tag
from .timeutil import (in_quiet, iso, now_utc, parse_iso, quiet_end_utc, resolve_cap_week, to_local, UTC,
                       valid_zone, week_key)
from .writer import Writer, Written, digest_lines

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
# The route outline is only needed to draw the card or video minutes after the run: it is dropped 30 days after the
# run it came from. Splits and reps stay with the run.
RETENTION_ROUTE_DAYS = 30
AREA_USABLE_DAYS = 7  # a forecast is never asked for a place older than this

NOT_OPEN = "Run Supreme's companion isn't open yet. We'll let you know when it is."
# Open enrolment is capped (Settings.max_users). The refusal names exactly what is kept (docs/privacy, 2b).
TEST_FULL = ("The Run Supreme coach test is full right now, so I can't connect you. The app works without me. "
             "I haven't kept your chat or your name: the only record is a tally of how many people asked today.")
RATE_PAUSED = "I've paused this chat for now because of how many messages came in. Your runs still sync as normal."
NOTE_ACTION = "note:add"
NOTE_STOP_WORDS = frozenset({"STOP", "STOP ALL", "UNSUBSCRIBE"})
NOTE_CANCEL_WORDS = frozenset({"CANCEL", "END", "QUIT"})
NOTE_BARE_WORDS = NOTE_STOP_WORDS | NOTE_CANCEL_WORDS | {"DELETE"}
NOTE_DELETE_FIRST = "Not saved as a note. Send DELETE again to erase everything."
NOTE_CANCELLED = "Note cancelled."
UNKNOWN = ("I only send run recaps. To connect, open Run Supreme, go to Settings > Companion and tap "
           "Turn on. Send STOP to pause or DELETE to erase everything.")
NOTE_PROMPT = "Go on, type your note. Up to 500 characters. I'll keep it with this run."
NOTE_SAVED = "Noted. I'll keep it in mind."
NOTE_TOO_LONG = "That's over 500 characters. Trim it and send it again."
NOTE_EXPIRED = "That note window closed after 10 minutes. Tap Add a note on the run card to start again."
NOTE_PAUSED = "You're paused. Send RESUME first, then tap Add a note again."
# Tell Ricki: the reply is always one of these fixed lines, whatever was typed. No model writes it.
FEEDBACK_PROMPT = "Go on, tell Ricki. Type it in one message, up to 1000 characters. Only Ricki reads it, no AI does."
FEEDBACK_SAVED = "Got it. Ricki will read this."
FEEDBACK_TOO_LONG = "That's over 1000 characters. Trim it and send it again."
FEEDBACK_EXPIRED = "That window closed after 30 minutes. Tap Tell Ricki or send /feedback to start again."
FEEDBACK_PAUSED = "You're paused. Send RESUME first, then tap Tell Ricki again."
FEEDBACK_NO_CONSENT = ("I can't take feedback yet. Open Run Supreme, go to Settings > Companion and accept the latest "
                       "privacy terms, then try again.")
FEEDBACK_CANCELLED = "Cancelled."
FEEDBACK_DELETE_FIRST = "Not sent as feedback. Send DELETE again to erase everything."
CODE_MSG = ("Your code is {code}. Type it into Run Supreme to finish connecting. Only ever enter it in the app, "
            "and never share it. If you didn't start this, ignore this message.")
WELCOME = ("You're connected. After each run you get a short card, at most one question a day, and a recap on Sunday. "
           "This is running guidance, not medical advice. Send /feedback to tell Ricki what's working or not (he reads it, "
           "no AI does). Send STOP to pause or DELETE to erase everything we hold about you.")


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

# The route shape the app sends (see docs/privacy 2b): at most 120 points, whole numbers on a 0..255 grid in a unit
# box. No latitude, longitude, scale or north: the phone normalises it before it leaves.
ROUTE_GRID = 255
MAX_ROUTE_POINTS = 120
MAX_SPLITS = 100
MAX_REPS = 60
GridInt = Annotated[int, Field(strict=True, ge=0, le=ROUTE_GRID)]  # a float, even 12.0, is refused

VERDICT_WIRE = ("faster", "holding", "slower", "noRealChange", "baselineSet", "noVerdict", "indoorRun")


class SplitIn(BaseModel):
    """One piece of the run: `km` long (1.0 except the last), at `pace_s` s/km, mostly in HR zone `zone` (none without HR)."""
    model_config = ConfigDict(extra="forbid")
    km: float = Field(gt=0, le=1.0)
    pace_s: float = Field(ge=60, le=3600)
    zone: int | None = Field(default=None, ge=1, le=5)


class RepIn(BaseModel):
    """One rep of a structured run: how long it took and the HR zone it mostly ran in."""
    model_config = ConfigDict(extra="forbid")
    time_s: float = Field(gt=0, le=3600)
    zone: int | None = Field(default=None, ge=1, le=5)


class PlanNextIn(BaseModel):
    """The next session in the runner's 4-week block, as the app plans it. Numbers only when the plan holds them."""
    model_config = ConfigDict(extra="forbid")
    type: str = Field(pattern=r"^(easy|long|quality)$")
    day: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")  # the planned local date
    week: int = Field(ge=1, le=52)
    minutes: int | None = Field(default=None, ge=1, le=600)
    distance_m: int | None = Field(default=None, ge=500, le=100000)
    # Optional: which session it is. session_name is shown; session_ref is the app's opaque plan id (dedupe only, never
    # shown). A bad value drops that one field, never the plan.
    session_name: str | None = Field(default=None, min_length=1, max_length=40)
    session_id: str | None = Field(default=None, pattern=r"^[a-z0-9_]{1,40}$")   # a hint from the app's template id
    session_ref: str | None = Field(default=None, pattern=r"^[a-z0-9_]{1,16}$")
    # Optional: the work pace the app targets for it, True Pace in s/km (a runner's own paces, so 2:00 to 20:00 per km),
    # and which method it came from. A bad or inconsistent value drops the pace, never the plan. Older apps send none.
    target_pace_lo_s: float | None = Field(default=None, ge=120, le=1200)
    target_pace_hi_s: float | None = Field(default=None, ge=120, le=1200)
    target_pace_method: str | None = Field(default=None, pattern=r"^(vdot|moved)$")

    @field_validator("target_pace_lo_s", "target_pace_hi_s", "target_pace_method", mode="wrap")
    @classmethod
    def _optional_pace(cls, v, handler):
        try:
            out = handler(v)
        except ValidationError:
            return None
        if isinstance(out, float) and not math.isfinite(out):
            return None
        return out

    @model_validator(mode="after")
    def _pace_is_a_range(self):
        lo, hi = self.target_pace_lo_s, self.target_pace_hi_s
        if lo is None or hi is None or lo > hi or self.target_pace_method is None:   # half a range, backwards, or no method: no pace
            self.target_pace_lo_s = self.target_pace_hi_s = self.target_pace_method = None
        return self

    @field_validator("session_name", "session_id", "session_ref", mode="wrap")
    @classmethod
    def _optional_session_ident(cls, v, handler):
        try:
            out = handler(v)
        except ValidationError:
            return None
        if isinstance(out, str):
            out = out.strip()
            if not out or any(unicodedata.category(ch)[0] == "C" for ch in out):
                return None   # control or format characters: not a name
        return out

    @field_validator("session_name", mode="after")
    @classmethod
    def _built_in_only(cls, v):
        """Only the app's own built-in session names, exactly (facts.known_session): nothing a runner typed, nothing that
        merely looks like a name (a homoglyph, a link, a handle). Anything else drops the name."""
        k = known_session(v) if v else None
        return v if v is None or (k and k[1] != GOAL_PURPOSE) else None   # a planned session is never a goal run

    @model_validator(mode="after")
    def _id_needs_a_name(self):
        if self.session_name is None:
            self.session_id = None   # the id is only a hint about a name we accepted
        return self

    @field_validator("minutes", "distance_m", mode="before")
    @classmethod
    def _whole(cls, v):
        """Like the top-level metres: a finite decimal is rounded, not refused."""
        return round(v) if isinstance(v, float) and math.isfinite(v) else v

    @field_validator("day")
    @classmethod
    def _real_date(cls, v: str) -> str:
        date.fromisoformat(v)  # ValueError -> 422 for 2026-13-45
        return v


CUSTOM_SESSION_RE = re.compile(r"^custom:[0-9a-f]{16}$")


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
    plan_kind: str | None = Field(default=None, pattern=r"^(easy|long|quality)$")
    plan_target_m: int | None = Field(default=None, ge=0, le=300000)
    plan_weeks_to_race: int | None = Field(default=None, ge=0, le=104)
    plan_week: int | None = Field(default=None, ge=1, le=52)   # this run's week of the app's plan
    plan_weeks: int | None = Field(default=None, ge=1, le=52)  # how many weeks the plan has
    plan_next: PlanNextIn | None = None
    feel: str | None = Field(default=None, pattern=r"^(easy|right|hard)$")
    # An interval session, from the numbers the app's verdict shows. All optional: an older app sends none.
    session_name: str | None = Field(default=None, max_length=40)
    work_pace_s_per_km: float | None = Field(default=None, gt=0, lt=3600)  # mean pace over the work reps
    reps_done: int | None = Field(default=None, ge=1, le=200)
    rep_spread_s: float | None = Field(default=None, ge=0, lt=3600)  # slowest minus fastest clean rep, s/km
    recovery_pace_s_per_km: float | None = Field(default=None, gt=0, lt=3600)
    goal_reached: bool | None = None  # a goal run ("10K goal" in session_name): whether the goal was reached
    consent_version: StrictInt | None = Field(default=None, ge=0, le=1000)  # the consent version the runner agreed to; an older app sends none
    area_lat: float | None = Field(default=None, ge=-90, le=90)  # approximate area for weather; the phone rounds to 0.1 degree and the server rounds again
    area_lon: float | None = Field(default=None, ge=-180, le=180)
    route: list[tuple[GridInt, GridInt]] | None = Field(default=None, min_length=2, max_length=MAX_ROUTE_POINTS)
    splits: list[SplitIn] | None = Field(default=None, min_length=1, max_length=MAX_SPLITS)
    reps: list[RepIn] | None = Field(default=None, min_length=1, max_length=MAX_REPS)
    trail: cv_trail.TrailIn | None = None  # the run's trail board, profile and ghost gap; a bad block drops the trail, never the run
    quest: cv_quest.QuestIn | None = None  # the app's quest offers, active quest and a finished one; a bad block drops the quest, never the run

    @field_validator("quest", mode="wrap")
    @classmethod
    def _quest_is_optional_extra(cls, v, handler):
        try:
            return handler(v)
        except ValidationError:
            return None

    @field_validator("trail", mode="wrap")
    @classmethod
    def _trail_is_optional_extra(cls, v, handler):
        try:
            return handler(v)
        except ValidationError:
            return None

    @model_validator(mode="after")
    def _shape(self):
        """Only the canonical shape is accepted: it touches x=0 and y=0 and its longer side is the full grid, which is
        exactly what the phone's normaliser produces. A shape that is not (a translated or unscaled path) is refused,
        so nothing but a unit-box outline can be stored."""
        if self.route is not None:
            xs, ys = [p[0] for p in self.route], [p[1] for p in self.route]
            if min(xs) != 0 or min(ys) != 0 or max(max(xs), max(ys)) != ROUTE_GRID:
                raise ValueError("route is not a normalised shape")
        if self.splits is not None and sum(x.km for x in self.splits) > self.distance_m / 1000 + 0.5:
            raise ValueError("splits are longer than the run")
        return self

    @field_validator("session_name", "work_pace_s_per_km", "reps_done", "rep_spread_s", "recovery_pace_s_per_km",
                     mode="wrap")
    @classmethod
    def _session_field_is_optional_extra(cls, v, handler):
        """A bad session value drops that one field (stored as none), never the run: it only adds colour to a card."""
        try:
            out = handler(v)
        except ValidationError:
            return None
        if isinstance(out, str):
            # Only a built-in session name or the app's unreadable code for a custom one is kept: no typed text is
            # ever stored. Anything else (including control or format characters) drops the field.
            out = out.strip()
            return out if known_session(out) or CUSTOM_SESSION_RE.match(out) else None
        return out

    @field_validator("plan_kind", "plan_target_m", "plan_week", "plan_weeks", "plan_next", mode="wrap")
    @classmethod
    def _plan_field_is_optional_extra(cls, v, handler):
        """A bad plan value drops that one field (stored as none), never the run: the plan only adds colour to a card."""
        try:
            return handler(v)
        except ValidationError as e:
            if any(err["type"] == "extra_forbidden" for err in e.errors()):
                # an unknown key (inside plan_next) stays a loud 422: the tripwire for a client that over-sends
                raise PydanticCustomError("extra_forbidden", "Extra inputs are not permitted") from None
            return None

    @model_validator(mode="after")
    def _plan_consistent(self):
        if self.plan_week is not None and self.plan_weeks is not None and self.plan_week > self.plan_weeks:
            self.plan_week = self.plan_weeks = None
        if self.plan_next is not None and self.plan_weeks is not None and self.plan_next.week > self.plan_weeks:
            self.plan_next = None
        return self

    @field_validator("distance_m", "climb_m", "plan_target_m", mode="before")
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
    "convo_area": "areas", "run_notes": "run_notes", "run_shape": "run_shapes", "checkin_answers": "checkins",
    "feedback": "feedback", "quests": "quests", "inbound_events": "activity", "survey_answers": "survey_answers",
    "ops_sends": "ops_messages",
}
NOT_EXPORTED_TABLES = {  # operational plumbing: no run, location or message content of its own
    "devices": "hashed device tokens", "enrolments": "short-lived sign-up nonces", "outbox": "send queue, ids only",
    "quota": "weekly cap counters", "msglog": "send counts, no content", "inbound_seen": "hashed message ids",
    "replay_state": "coach replay progress", "replay_runs": "run ids the replay inserted",
    "replay_items": "replay send times and card ids", "replay_rows": "which rows the replay wrote",
    "note_mode": "10-minute 'Add a note' waiting state: a run id and an expiry, no text",
    "feedback_mode": "30-minute 'Tell Ricki' waiting state: an expiry, no text",
    "checkin_slots": "which check-in messages were sent (ids and dates, no answer)",
    "question_cap": "one row per local day a question was sent (the daily cap)",
    "media_file_ids": "Telegram file ids of clips already sent to the runner (opaque, no content)",
    "inbound_strikes": "times the chat was told to slow down (2 days), used to pause a flood",
    "llm_calls": "the cost of each writing-service call, so the monthly cap can be counted per runner; no content",
}


class RateLimited(Exception):
    pass


class NotFound(Exception):
    pass


def _opaque_user_id() -> str:
    return "u_" + "".join(secrets.choice(string.ascii_lowercase) for _ in range(12))


class Service(CheckinMixin, MeasureMixin):
    def __init__(self, settings: Settings, http: httpx.Client):
        self.s, self.http = settings, http
        self.writer = Writer(settings, http)
        self.channels: dict[str, Any] = {}
        self.limiter = RateLimiter(settings.rate_per_min, settings.rate_per_day)
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
                c.execute("UPDATE users SET paused=0, checkin_consent=NULL, consent_version=?, consent_at=?, consent_msg_id=?, chat_name=? WHERE id=?",
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
                if ident not in self.s.allowed_ids and self._places_taken(c, now) >= self.s.max_users:
                    # The test is full. Nothing about this chat is written: the enrolment row (a random nonce) is marked
                    # denied, and today's refusal tally goes up by one.
                    c.execute("UPDATE enrolments SET state='denied' WHERE nonce=?", (nonce,))
                    c.execute("INSERT INTO enrol_refused (day, n) VALUES (?, 1) ON CONFLICT(day) DO UPDATE SET n = n + 1",
                              (now.strftime("%Y-%m-%d"),))
                    log.info("enrolment refused: test full")
                    return TEST_FULL
                uid = _opaque_user_id()
                c.execute("INSERT INTO users (id, channel, chat_ref, created_at, last_inbound_at, tester_no) VALUES (?,?,?,?,?,?)",
                          (uid, inb.channel, inb.ref, iso(now), iso(now), db.next_tester_no(c)))
            code = f"{secrets.randbelow(10**6):06d}"
            c.execute("UPDATE enrolments SET state='awaiting_code', user_id=?, code=?, attempts=0, consent_msg_id=?, "
                      "chat_name=? WHERE nonce=?", (uid, code, self._mac(inb.msg_id), inb.name or None, nonce))
            c.execute("UPDATE inbound_seen SET user_id=? WHERE msg_id=?", (uid, self._mac(inb.msg_id)))
        return CODE_MSG.format(code=code)

    def _places_taken(self, c, now: datetime) -> int:
        """Runners holding one of the open places: not on the allowlist, and either connected or started within the last hour
        (an unfinished connection is deleted after an hour, and until then it must not hold a place)."""
        rows = c.execute("SELECT channel, chat_ref FROM users WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = users.id) "
                         "OR created_at >= ?", (iso(now - timedelta(hours=1)),)).fetchall()
        return sum(1 for r in rows if f"{r['channel']}:{r['chat_ref']}" not in self.s.allowed_ids)

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
        ch = self.channels.get(inb.channel)
        if ch is None:
            return
        bare_delete = inb.card_id is None and inb.text.strip().lstrip("/").upper() == "DELETE"
        if not bare_delete:   # erasure by chat DELETE always works, flooding or paused: it never meets the limiter
            if self._redelivered(inb):
                return   # a webhook retry of a message we already handled does not count against the limit
            verdict = self.limiter.check(f"{inb.channel}:{inb.ref}", now)   # before anything is stored for this message
        else:
            verdict = "ok"
        if verdict != "ok":
            self._rate_limited(ch, inb, verdict, now)
            return
        if self._seen(inb, now):
            return
        user = self._user_by_ref(inb.channel, inb.ref)
        if user and user["ops_paused"] and not bare_delete:
            return   # an operator-paused runner gets nothing back; DELETE still works (erasure is not ours to refuse)
        if user:
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE users SET last_inbound_at=? WHERE id=?", (iso(now), user["id"]))
                c.execute("UPDATE inbound_seen SET user_id=? WHERE msg_id=?", (user["id"], self._mac(inb.msg_id)))
        if inb.card_id is not None:
            self._log_event(user, "tap", now)
            self._handle_button(ch, inb, user, now)
            return
        text = inb.text.strip()
        event = "command"   # what this message was, for the scorecard: a kind and a time, never the words
        word = text.lstrip("/").upper()
        m = START_RE.match(text)
        reply: str
        noted: list[str] = []   # the run a note was just saved for
        note_open = bool(user) and word in NOTE_BARE_WORDS and self._note_mode_open(user["id"], now)
        fb_open = bool(user) and word in NOTE_BARE_WORDS and not note_open and self._feedback_mode_open(user["id"], now)
        if note_open or fb_open:
            # Right after "type your note" (or "tell Ricki") a bare keyword is far more likely an answer than a command:
            # DELETE must not erase the account on one word, and CANCEL/END/QUIT just leave the mode. STOP still pauses
            # (opt-out always works) and closes it.
            with db.tx(self.s.db_path) as c:
                c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
                c.execute("DELETE FROM feedback_mode WHERE user_id=?", (user["id"],))
            if word == "DELETE":
                self._reply(ch, inb.ref, NOTE_DELETE_FIRST if note_open else FEEDBACK_DELETE_FIRST)
                return
            if word in NOTE_CANCEL_WORDS:
                self._reply(ch, inb.ref, NOTE_CANCELLED if note_open else FEEDBACK_CANCELLED)
                return
        if m:
            reply = self._bind(inb, m.group(1), now)
        elif word in ("STOP", "STOP ALL", "UNSUBSCRIBE", "CANCEL", "END", "QUIT"):
            if user:
                with db.tx(self.s.db_path) as c:
                    c.execute("UPDATE users SET paused=1 WHERE id=?", (user["id"],))
                    if not user["paused"]:
                        db.bump_week(c, "stop_counts", now)   # a week and a number, no id
            reply = ("Paused. No more messages from me. Send RESUME to turn them back on, or DELETE to erase your data."
                     if user else "Nothing to pause here.")
        elif word == "RESUME":
            if user:
                with db.tx(self.s.db_path) as c:
                    c.execute("UPDATE users SET paused=0 WHERE id=?", (user["id"],))
                    c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
                    c.execute("DELETE FROM feedback_mode WHERE user_id=?", (user["id"],))
            reply = "Back on. Your next run recap will land here." if user else UNKNOWN
        elif word == "DELETE":
            if user:
                db.hard_delete_user(self.s.db_path, user["id"], tombstone_at=now)
                event = None   # the runner and their events are gone
                log.info("deleted user=%s via keyword", user["id"])
                reply = "Done. Everything we held about you is deleted. Meta may keep delivery records for up to 30 days."
            else:
                reply = "We hold nothing for this chat."
        elif word == cv_feedback.FEEDBACK_WORD:
            reply = self._feedback_open(user, now) if user else UNKNOWN
        else:
            # Free text is only ever a note (after "Add a note") or feedback (after "Tell Ricki"). Everything else gets
            # the fixed canned reply, and no free text ever reaches a model.
            reply = self._feedback_reply(user, inb.text, now) or self._note_reply(user, inb.text, now, noted) or UNKNOWN
            event = {FEEDBACK_SAVED: "feedback", NOTE_SAVED: "note"}.get(reply, "text")
        if event:
            self._log_event(user, event, now)
        self._reply(ch, inb.ref, reply)
        if noted:   # a note just saved: the run card it belongs to may update, once
            self._late_edit(ch, user, noted[0], now)

    def _redelivered(self, inb: Inbound) -> bool:
        with db.ro(self.s.db_path) as c:
            return c.execute("SELECT 1 FROM inbound_seen WHERE msg_id=?", (self._mac(inb.msg_id),)).fetchone() is not None

    def _rate_limited(self, ch: Any, inb: Inbound, verdict: str, now: datetime) -> None:
        """Over the per-chat limit: one polite note per ten minutes, then silence. A known runner's slow-downs are counted,
        and `rate_strikes_to_pause` of them in 24 hours pause that runner and raise an alert. A stranger's chat is never
        stored: the limiter is in memory."""
        if verdict == "silent":
            return
        user = self._user_by_ref(inb.channel, inb.ref)
        text = SLOW_DOWN_DAY if verdict == "notice-day" else SLOW_DOWN
        if user and user["ops_paused"]:
            return
        if user:
            with db.tx(self.s.db_path) as c:
                c.execute("INSERT INTO inbound_strikes (user_id, ts) VALUES (?,?)", (user["id"], iso(now)))
                n = c.execute("SELECT COUNT(*) FROM inbound_strikes WHERE user_id=? AND ts > ?",
                              (user["id"], iso(now - timedelta(hours=24)))).fetchone()[0]
                if n >= self.s.rate_strikes_to_pause:
                    c.execute("UPDATE users SET ops_paused=1, ops_paused_reason='rate' WHERE id=?", (user["id"],))
                    t = tag(user["tester_no"])
                    add_alert(c, f"rate-pause:{t}:{iso(now)}", f"Run Supreme coach: {t} paused for flooding",
                              f"{t} hit the inbound limit {n} times in 24 hours and was paused automatically. "
                              f"To let them back in: companion.cli ops resume {t}", now)
                    log.warning("rate-paused tester=%s", t)
                    text = RATE_PAUSED
        self._reply(ch, inb.ref, text)

    def _note_mode_open(self, uid: str, now: datetime) -> bool:
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT expires_at FROM note_mode WHERE user_id=?", (uid,)).fetchone()
        return r is not None and parse_iso(r["expires_at"]) > now

    def _feedback_mode_open(self, uid: str, now: datetime) -> bool:
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT expires_at FROM feedback_mode WHERE user_id=?", (uid,)).fetchone()
        return r is not None and parse_iso(r["expires_at"]) > now

    def _fb_start(self, c, user: dict, now: datetime) -> str | None:
        """Open feedback mode inside the caller's transaction. None when it opened, else the refusal to send. Consent is
        read here, in the same transaction, so a withdrawal cannot slip in between. Only one of note/feedback mode is
        ever open: the last tap wins."""
        if user["paused"]:
            return FEEDBACK_PAUSED
        if not self._ci_consented(c, user["id"]):
            return FEEDBACK_NO_CONSENT
        c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
        c.execute("INSERT INTO feedback_mode (user_id, expires_at) VALUES (?,?) "
                  "ON CONFLICT(user_id) DO UPDATE SET expires_at=excluded.expires_at",
                  (user["id"], iso(now + timedelta(minutes=cv_feedback.FEEDBACK_MODE_MIN))))
        return None

    def _feedback_open(self, user: dict, now: datetime) -> str:
        """/feedback typed in the chat."""
        with db.tx(self.s.db_path) as c:
            return self._fb_start(c, user, now) or FEEDBACK_PROMPT

    def _feedback_reply(self, user: dict | None, raw: str, now: datetime) -> str | None:
        """The reply when this free text is (or was meant to be) feedback; None when the user is not in feedback mode.
        The text goes into the feedback table and nowhere else: no model, no log line, no card."""
        if not user:
            return None
        with db.ro(self.s.db_path) as c:
            mode = c.execute("SELECT expires_at FROM feedback_mode WHERE user_id=?", (user["id"],)).fetchone()
        if mode is None:
            return None
        if parse_iso(mode["expires_at"]) <= now:
            with db.tx(self.s.db_path) as c:
                c.execute("DELETE FROM feedback_mode WHERE user_id=?", (user["id"],))
            return FEEDBACK_EXPIRED
        if user["paused"]:
            return FEEDBACK_PAUSED  # nothing is stored for a paused chat
        text = cv_feedback.clean(raw)
        if not text:
            return None
        if len(text) > cv_feedback.FEEDBACK_MAX_CHARS:
            return FEEDBACK_TOO_LONG  # still in feedback mode: the runner can send a shorter one
        with db.tx(self.s.db_path) as c:
            # re-read under the write lock; one message ends the mode whatever happens next
            mode = c.execute("SELECT expires_at FROM feedback_mode WHERE user_id=?", (user["id"],)).fetchone()
            c.execute("DELETE FROM feedback_mode WHERE user_id=?", (user["id"],))
            if mode is None or parse_iso(mode["expires_at"]) <= now:
                return FEEDBACK_EXPIRED
            if not self._ci_consented(c, user["id"]):
                return FEEDBACK_NO_CONSENT
            c.execute("INSERT INTO feedback (user_id, ts, text) VALUES (?,?,?)", (user["id"], iso(now), text))
        return FEEDBACK_SAVED

    def _note_reply(self, user: dict | None, raw: str, now: datetime, saved: list[str] | None = None) -> str | None:
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
            # re-read under the write lock: a tap on another card since the read above decides where the note goes
            mode = c.execute("SELECT run_id, expires_at FROM note_mode WHERE user_id=?", (user["id"],)).fetchone()
            c.execute("DELETE FROM note_mode WHERE user_id=?", (user["id"],))
            if mode is None or parse_iso(mode["expires_at"]) <= now or not c.execute(
                    "SELECT 1 FROM runs WHERE user_id=? AND run_id=?", (user["id"], mode["run_id"])).fetchone():
                return NOTE_EXPIRED
            c.execute("INSERT INTO run_notes (user_id, run_id, note, created_at) VALUES (?,?,?,?) "
                      "ON CONFLICT(user_id, run_id) DO UPDATE SET note=excluded.note, created_at=excluded.created_at",
                      (user["id"], mode["run_id"], text, iso(now)))
        if saved is not None:
            saved.append(mode["run_id"])
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
        if inb.code is not None:   # a check-in button: edits its own message in place (checkin_service)
            self._ci_tap(ch, inb, user, dict(card), now)
            return
        buttons = json.loads(card["buttons_json"])
        if inb.button_idx is None or not 0 <= inb.button_idx < len(buttons):
            ch.ack_callback(inb, "That button has expired.", clear=False)
            return
        real_now = now  # note mode runs on the real clock, even for a replayed card
        now, replay_card = self._tap_time(card["card_id"], now)
        action = buttons[inb.button_idx]["action"]
        kind, _, rest = action.partition(":")
        if kind == "q":   # the month's quest offer: edits its own message in place
            self._quest_tap(ch, inb, user, dict(card), rest, real_now)
            return
        msg = "Thanks."
        keep: list[tuple[str, int]] = []
        note_tapped = False
        fb_prompt: str | None = None   # "Tell Ricki" tapped: the chat message that follows (the prompt or a refusal)
        after: str | None = None  # a chat message to send once the transaction is closed
        with (db.origin() if replay_card else contextlib.nullcontext()), db.tx(self.s.db_path) as c:  # a replayed card's answers are the replay's rows
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
                    c.execute("DELETE FROM feedback_mode WHERE user_id=?", (user["id"],))
                    c.execute("INSERT INTO note_mode (user_id, run_id, expires_at) VALUES (?,?,?) "
                              "ON CONFLICT(user_id) DO UPDATE SET run_id=excluded.run_id, expires_at=excluded.expires_at",
                              (user["id"], card["run_id"],
                               iso(real_now + timedelta(minutes=cv_notes.NOTE_MODE_MIN))))
                    msg, note_tapped = "Type your note.", True
            elif kind == "fb" and rest == "tell":
                refusal = self._fb_start(c, user, real_now)   # feedback runs on the real clock, even for a replayed card
                msg, fb_prompt = ("Type your feedback.", FEEDBACK_PROMPT) if refusal is None else ("Not now.", refusal)
            elif kind in ("trust", "ellis"):
                if replay_card or not self._survey_answer(c, user, dict(card), kind, rest, now):
                    msg = "That button has expired."
                else:
                    msg = cv_measure.TRUST_THANKS if kind == "trust" else "Thanks."
                    if kind == "trust" and rest == "not" and not replay_card and card["run_id"]:
                        self._trust_not_followup(c, user, card["run_id"], now)
                    # nothing more to show under either survey card
                    keep = [(b["label"], i) for i, b in enumerate(buttons) if b["action"] == cv_feedback.FEEDBACK_ACTION]
            elif kind == cv_measure.WHY_OFF_ACTION:
                if replay_card or not self._why_off_answer(c, user, dict(card), rest, now):
                    msg = "That button has expired."
                elif rest == "other":
                    refusal = self._fb_start(c, user, real_now)
                    msg, fb_prompt = (cv_measure.WHY_OFF_THANKS, cv_measure.WHY_OFF_OTHER) if refusal is None else ("Not now.", refusal)
                else:
                    msg = cv_measure.WHY_OFF_THANKS
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
        elif fb_prompt:
            ch.ack_callback(inb, msg, clear=False)  # the card keeps its buttons
            self._reply(ch, inb.ref, fb_prompt)
        elif kind == "note":
            ch.ack_callback(inb, msg, clear=False)
            if after:
                self._reply(ch, inb.ref, after)
        elif keep:
            ch.ack_callback(inb, msg, keep=keep)
        else:
            ch.ack_callback(inb, msg)
        if kind == "feel" and not replay_card and card["run_id"] and rest in ("easy", "right", "hard"):
            self._late_edit(ch, user, card["run_id"], real_now)

    def _tap_time(self, card_id: str, now: datetime) -> tuple[datetime, bool]:
        """(when a tap happened on the card's own clock, whether the card is a replayed one). A replayed card lives at
        a virtual time in the past, so its answers (memory, caps, outcomes) are stamped with that virtual time, not
        the real date, and tagged as the replay's. Every other card: the real time."""
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT virtual_at, real_at FROM replay_items WHERE card_id=? ORDER BY id DESC LIMIT 1",
                          (card_id,)).fetchone()
        if not r:
            return now, False
        return parse_iso(r["virtual_at"]), True  # exactly: anything later would be invisible to the very next virtual item

    # ---------------------------------------------------------------- memory
    @staticmethod
    def _memory_set(c, uid: str, key: str, value: str, now: datetime) -> None:
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?) "
                  "ON CONFLICT(user_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                  (uid, key, value, iso(now)))
        # An upsert of an existing key is a change, not a new row: a replay answer is tagged, and a live answer to the
        # same key takes the row over, so it is no longer the replay's to delete.
        db.tag_row(c, uid, "memory", "key=?", (key,))
        db.untag(c, uid, "memory", key)

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
                "verdict, locality, plan_kind, plan_target_m, plan_week, plan_weeks, plan_next_type, plan_next_day, plan_next_week, "
                "plan_next_min, plan_next_m, plan_next_session_id, plan_next_session_ref, plan_next_session_name, plan_next_pace_lo, plan_next_pace_hi, plan_next_pace_method, feel, session_name, work_pace_s_per_km, reps_done, "
                "rep_spread_s, recovery_pace_s_per_km, goal_reached, received_at FROM runs WHERE user_id=? ORDER BY start_utc DESC", (uid,))]
            cutoff = iso(now - timedelta(days=RETENTION_LOG_DAYS))
            msgs = [dict(r) for r in c.execute(
                "SELECT k.kind, k.headline, k.body, k.sent_at, cc.situation, cc.touch_kind, cc.media_json FROM cards k "
                "LEFT JOIN convo_cards cc ON cc.card_id = k.card_id WHERE k.user_id=? AND "
                "(k.sent_at >= ? OR (k.sent_at IS NULL AND k.created_at >= ?)) "   # built but not sent yet is held too
                "ORDER BY COALESCE(k.sent_at, k.created_at) DESC", (uid, cutoff, cutoff))]
            for m in msgs:  # the facts a picture was drawn from, stored when the card was decided (see media_json)
                m["picture_facts"] = self._picture_facts(m.pop("media_json", None))
            areas = [dict(r) for r in c.execute("SELECT run_id, lat, lon FROM convo_area WHERE user_id=? ORDER BY rowid", (uid,))]
            convo = [dict(r) for r in c.execute("SELECT kind, key, ts FROM convo_log WHERE user_id=? ORDER BY id", (uid,))]
            memory = self._memory_get(c, uid, now)
            checkins = self._ci_export(c, uid, now)
            quests = cv_quest.export_rows(c, uid)
            ops_msgs = [{"template": r["template"], "date": r["ts"][:10]} for r in c.execute(
                "SELECT template, ts FROM ops_sends WHERE user_id=? AND result='sent' ORDER BY id", (uid,))]   # which fixed message, never its words
            optin = bool(u["weather_optin"])
            outcomes = [dict(r) for r in c.execute("SELECT kind, outcome, ts FROM outcomes WHERE user_id=?", (uid,))]
            run_notes = [dict(r) for r in c.execute(
                "SELECT run_id, note, created_at FROM run_notes WHERE user_id=? ORDER BY created_at", (uid,))]
            feedback = [dict(r) for r in c.execute("SELECT ts, text FROM feedback WHERE user_id=? ORDER BY id", (uid,))]
            activity = [dict(r) for r in c.execute("SELECT kind, ts FROM inbound_events WHERE user_id=? ORDER BY id", (uid,))]
            survey = [dict(r) for r in c.execute("SELECT kind, ref, value, created_at FROM survey_answers WHERE user_id=? ORDER BY created_at", (uid,))]
            shapes = [{"run_id": r["run_id"], "route": json.loads(r["route_json"]) if r["route_json"] else None,
                       "splits": json.loads(r["splits_json"]) if r["splits_json"] else None,
                       "reps": json.loads(r["reps_json"]) if r["reps_json"] else None,
                       "trail": json.loads(r["trail_json"]) if r["trail_json"] else None}
                      for r in c.execute("SELECT run_id, route_json, splits_json, reps_json, trail_json FROM run_shape WHERE user_id=? "
                                         "ORDER BY rowid", (uid,))]
        ref = u["chat_ref"]
        return {
            "profile": {
                "channel": u["channel"], "chat_name": u["chat_name"], "chat_ref_hint": "…" + ref[-3:], "created_at": u["created_at"],
                "consent_version": u["consent_version"], "consent_at": u["consent_at"], "checkin_consent": u["checkin_consent"], "paused": bool(u["paused"]),
                "zone_id": u["zone_id"], "tz_set_at": u["tz_set_at"], "weather_in_suggestions": optin, "route_shape_on_cards": bool(u["route_optin"]), "place_names_on_cards": bool(u["place_optin"]), "heart_rate_on_cards": bool(u["hr_optin"]), "quiet_start_min": u["quiet_start"], "quiet_end_min": u["quiet_end"],
            },
            "runs_received": runs, "run_shapes": shapes, "run_notes": run_notes, "feedback": feedback, "activity": activity, "survey_answers": survey, "memory": memory, "suggestion_outcomes": outcomes,
            "messages_sent_30d": msgs, "areas": areas, "conversation_log": convo, "checkins": checkins, "quests": quests, "ops_messages": ops_msgs,
            "goes_to": ["OpenRouter and the model provider (facts and enumerated memory only, no phone number or chat id)",
                        "Telegram" if u["channel"] == "telegram" else "Meta (WhatsApp Cloud API, keeps messages up to 30 days)",
                        *(["Open-Meteo (a location rounded to about 11 km and a timezone, no identifier)"]
                          if self.s.weather_enabled else [])],
        }

    @staticmethod
    def _picture_facts(media_json: str | None) -> dict | None:
        try:
            plan = json.loads(media_json) if media_json else {}
        except ValueError:
            return None
        out = {k: plan[k] for k in ("facts", "touch_facts") if isinstance(plan, dict) and plan.get(k)}
        return out or None

    def delete_me(self, uid: str) -> None:
        db.hard_delete_user(self.s.db_path, uid, tombstone_at=now_utc())
        log.info("deleted user=%s via api", uid)

    def set_settings(self, uid: str, quiet_start: int | None, quiet_end: int | None, zone_id: str | None,
                     weather: bool | None = None, route_shape: bool | None = None,
                     place_names: bool | None = None, heart_rate: bool | None = None) -> None:
        wipe_wal = False
        with db.tx(self.s.db_path) as c:
            if route_shape is not None:  # "Show route shape on cards"; off forgets every stored shape, now
                c.execute("UPDATE users SET route_optin=? WHERE id=?", (int(route_shape), uid))
                if not route_shape:
                    c.execute("UPDATE run_shape SET route_json=NULL WHERE user_id=?", (uid,))
                    c.execute("DELETE FROM run_shape WHERE user_id=? AND splits_json IS NULL AND reps_json IS NULL "
                              "AND trail_json IS NULL", (uid,))
                    wipe_wal = True
            if place_names is not None:  # the place opt-in; off forgets every stored trail name, now
                c.execute("UPDATE users SET place_optin=? WHERE id=?", (int(place_names), uid))
                if not place_names:
                    for r in c.execute("SELECT run_id, trail_json FROM run_shape WHERE user_id=? AND trail_json LIKE '%\"name\"%'",
                                       (uid,)).fetchall():
                        t = json.loads(r["trail_json"])
                        t.pop("name", None)
                        c.execute("UPDATE run_shape SET trail_json=? WHERE user_id=? AND run_id=?",
                                  (json.dumps(t, separators=(",", ":")), uid, r["run_id"]))
                    c.execute("UPDATE quests SET trail_name=NULL WHERE user_id=?", (uid,))
                    wipe_wal = True
            if heart_rate is not None:  # "Heart rate on cards"; off forgets every stored heart-rate series, now
                c.execute("UPDATE users SET hr_optin=? WHERE id=?", (int(heart_rate), uid))
                if not heart_rate:
                    for r in c.execute("SELECT run_id, trail_json FROM run_shape WHERE user_id=? AND trail_json LIKE '%\"hr\"%'",
                                       (uid,)).fetchall():
                        t = json.loads(r["trail_json"])
                        t.pop("hr", None)
                        t.pop("hr_z", None)
                        c.execute("UPDATE run_shape SET trail_json=? WHERE user_id=? AND run_id=?",
                                  (json.dumps(t, separators=(",", ":")), uid, r["run_id"]))
                    wipe_wal = True
            if weather is not None:  # the app's "Weather in suggestions" switch; off forgets every stored area
                c.execute("UPDATE users SET weather_optin=? WHERE id=?", (int(weather), uid))
                if not weather:
                    c.execute("DELETE FROM convo_area WHERE user_id=?", (uid,))
            if quiet_start is not None and quiet_end is not None:
                c.execute("UPDATE users SET quiet_start=?, quiet_end=? WHERE id=?", (quiet_start, quiet_end, uid))
            if zone_id and valid_zone(zone_id):
                c.execute("UPDATE users SET zone_id=? WHERE id=?", (zone_id, uid))
        if wipe_wal:  # old page images of the deleted outlines must not wait in the WAL
            db.checkpoint_truncate(self.s.db_path)

    def set_checkin_consent(self, uid: str, version: int, c=None, source: str = "app") -> None:
        """Record the consent version the app says the runner agreed to (latest report wins, so a downgrade counts).
        `source` is only for the log line: "app" (PUT or run upload) or "cli" (operator seeding)."""
        def go(c):
            if not c.execute("UPDATE users SET checkin_consent=? WHERE id=?", (version, uid)).rowcount:
                raise NotFound()
            log.info("consent version=%s set user=%s via %s", version, uid, source)
        if c is not None:
            return go(c)   # inside the caller's transaction: it calls _ci_unpin_weeks after the commit
        with db.tx(self.s.db_path) as c:
            go(c)
        if version < self.s.checkin_consent_required:
            self._ci_unpin_weeks(uid)

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
                                 zone_min=run.zone_min, pb=run.pb, history=hist,
                                 reps_done=run.reps_done, work_pace=run.work_pace_s_per_km)
        app = run.type if run.type in APP_TYPES else None
        if app == "intervals" and not run.reps_done and not run.work_pace_s_per_km:
            app = "free"  # same rule as infer_coach_type: stopped before any work rep
        return coach, app

    def ingest_run(self, uid: str, run: RunIn, now: datetime | None = None, *, replay: bool = False) -> dict:
        out = self._ingest_run(uid, run, now, replay=replay)
        if run.consent_version is not None and run.consent_version < self.s.checkin_consent_required:
            self._ci_unpin_weeks(uid)
        return out

    def _ingest_run(self, uid: str, run: RunIn, now: datetime | None = None, *, replay: bool = False) -> dict:
        now = now or now_utc()
        if run.start_utc > now + timedelta(minutes=10):
            raise ValueError("start_utc in the future")
        end = run.start_utc + timedelta(seconds=run.duration_s)
        stale = (now - end) > timedelta(hours=self.s.stale_card_hours)
        nx = run.plan_next
        plan_cols = (run.plan_week, run.plan_weeks, nx.type if nx else None, nx.day if nx else None,
                     nx.week if nx else None, nx.minutes if nx else None, nx.distance_m if nx else None)
        session_cols = (run.session_name, run.work_pace_s_per_km, run.reps_done, run.rep_spread_s,
                        run.recovery_pace_s_per_km, None if run.goal_reached is None else int(run.goal_reached))
        with db.tx(self.s.db_path) as c:
            if run.consent_version is not None:
                self.set_checkin_consent(uid, run.consent_version, c)
            coach_type, app_type = self._coach_type(c, uid, run)
            have = c.execute("SELECT real_upload FROM runs WHERE user_id=? AND run_id=?", (uid, run.run_id)).fetchone()
            if have:
                tag = c.execute("SELECT inserted FROM replay_runs WHERE user_id=? AND run_id=?", (uid, run.run_id)).fetchone()
                replay_made = have["real_upload"] == 0 or (have["real_upload"] is None and bool(tag) and tag["inserted"] == 1)
                if replay_made and not replay:
                    # The coach replay inserted this run from an export file; the app's own upload is the same run.
                    # Update it in place (a feel tapped during the replay is kept), send no second card, and mark it
                    # real ON THE RUN (real_upload, and the real arrival time) so no replay reset or tag loss can make
                    # it look replay-made again.
                    c.execute("UPDATE replay_runs SET inserted=2 WHERE user_id=? AND run_id=?", (uid, run.run_id))
                    c.execute(
                        "UPDATE runs SET real_upload=1, received_at=?, "
                        "start_utc=?, end_utc=?, utc_offset_min=?, zone_id=?, type=?, app_type=?, duration_s=?, "
                        "distance_m=?, pace_s_per_km=?, true_pace_s_per_km=?, verdict=?, scores_delta=?, zone_min=?, "
                        "climb_m=?, locality=?, route_id=?, load_state=?, pb=?, plan_kind=?, plan_target_m=?, "
                        "plan_weeks_to_race=?, plan_week=?, plan_weeks=?, plan_next_type=?, plan_next_day=?, plan_next_week=?, "
                        "plan_next_min=?, plan_next_m=?, feel=COALESCE(feel, ?), session_name=?, work_pace_s_per_km=?, reps_done=?, "
                        "rep_spread_s=?, recovery_pace_s_per_km=?, goal_reached=? WHERE user_id=? AND run_id=?",
                        (iso(now), iso(run.start_utc), iso(end), run.utc_offset_min, run.zone_id, coach_type, app_type,
                         run.duration_s, run.distance_m, run.pace_s_per_km, run.true_pace_s_per_km, run.verdict,
                         json.dumps(run.scores_delta), json.dumps(run.zone_min), run.climb_m, run.locality,
                         run.route_id, run.load_state, run.pb, run.plan_kind, run.plan_target_m,
                         run.plan_weeks_to_race, *plan_cols, run.feel, *session_cols, uid, run.run_id))
                    self._keep_plan_session(c, uid, run)
                    self._keep_shape(c, uid, run)
                    self._keep_quest(c, uid, run, now, stale)
                    return {"status": "updated"}
                return {"status": "duplicate"}
            n = c.execute("SELECT COUNT(*) FROM runs WHERE user_id=? AND received_at >= ?",
                          (uid, iso(now - timedelta(days=1)))).fetchone()[0]
            if n >= RUNS_PER_DAY:
                raise RateLimited()
            c.execute(
                "INSERT INTO runs (user_id, run_id, start_utc, end_utc, utc_offset_min, zone_id, type, app_type, "
                "duration_s, distance_m, pace_s_per_km, true_pace_s_per_km, verdict, scores_delta, zone_min, climb_m, "
                "locality, route_id, load_state, pb, plan_kind, plan_target_m, plan_weeks_to_race, plan_week, plan_weeks, plan_next_type, plan_next_day, "
                "plan_next_week, plan_next_min, plan_next_m, feel, session_name, work_pace_s_per_km, reps_done, rep_spread_s, "
                "recovery_pace_s_per_km, goal_reached, received_at, "
                "stale, real_upload) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (uid, run.run_id, iso(run.start_utc), iso(end), run.utc_offset_min, run.zone_id, coach_type, app_type,
                 run.duration_s, run.distance_m, run.pace_s_per_km, run.true_pace_s_per_km, run.verdict,
                 json.dumps(run.scores_delta), json.dumps(run.zone_min), run.climb_m, run.locality, run.route_id,
                 run.load_state, run.pb, run.plan_kind, run.plan_target_m, run.plan_weeks_to_race, *plan_cols, run.feel, *session_cols,
                 iso(now), int(stale), 0 if replay else 1))
            self._keep_plan_session(c, uid, run)
            self._keep_shape(c, uid, run)
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
            self._keep_quest(c, uid, run, now, stale)   # after the zone update: the offer card's evening is the runner's own
            if not stale:
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (uid, "run_card", iso(now), f"card:{uid}:{run.run_id}", run.run_id))
        return {"status": "stored" if stale else "accepted"}

    @staticmethod
    def _keep_plan_session(c, uid: str, run: RunIn) -> None:
        """Which session the plan's next one is (its display name and the app's opaque ref), when the app sent them."""
        nx = run.plan_next
        c.execute("UPDATE runs SET plan_next_session_ref=?, plan_next_session_name=? WHERE user_id=? AND run_id=?",
                  (nx.session_ref if nx else None, nx.session_name if nx else None, uid, run.run_id))
        c.execute("UPDATE runs SET plan_next_session_id=? WHERE user_id=? AND run_id=?",
                  (nx.session_id if nx else None, uid, run.run_id))
        c.execute("UPDATE runs SET plan_next_pace_lo=?, plan_next_pace_hi=?, plan_next_pace_method=? "
                  "WHERE user_id=? AND run_id=?",
                  (nx.target_pace_lo_s if nx else None, nx.target_pace_hi_s if nx else None,
                   nx.target_pace_method if nx else None, uid, run.run_id))

    @staticmethod
    def _keep_shape(c, uid: str, run: RunIn) -> None:
        """Store the run's route shape, splits and reps (already validated and capped by RunIn). The route is kept only
        while the runner's "Show route shape on cards" switch is on; splits and reps ride with the companion itself."""
        route = run.route if c.execute("SELECT route_optin FROM users WHERE id=?", (uid,)).fetchone()["route_optin"] else None
        splits = [x.model_dump(exclude_none=True) for x in run.splits] if run.splits else None
        reps = [x.model_dump(exclude_none=True) for x in run.reps] if run.reps else None
        place_ok = c.execute("SELECT place_optin FROM users WHERE id=?", (uid,)).fetchone()["place_optin"]
        hr_ok = c.execute("SELECT hr_optin FROM users WHERE id=?", (uid,)).fetchone()["hr_optin"]
        trail = cv_trail.dump(run.trail, keep_name=bool(place_ok), keep_hr=bool(hr_ok))   # the elevation profile stays whatever the route switch says: own chat only
        if route is None and splits is None and reps is None and trail is None:
            return
        dump = lambda v: None if v is None else json.dumps(v, separators=(",", ":"))  # noqa: E731
        c.execute("INSERT OR REPLACE INTO run_shape (user_id, run_id, route_json, splits_json, reps_json, trail_json) "
                  "VALUES (?,?,?,?,?,?)",
                  (uid, run.run_id, dump([list(p) for p in route]) if route else None, dump(splits), dump(reps), trail))

    def _keep_quest(self, c, uid: str, run: RunIn, now: datetime, stale: bool) -> None:
        """Keep the run's quest block (already validated) and, once a month, queue the Telegram offer card for the runner's
        next evening window. The offer waits for a run that carries offers; the server never invents one."""
        if run.quest is None:
            return
        u = c.execute("SELECT channel, zone_id, place_optin FROM users WHERE id=?", (uid,)).fetchone()
        month = to_local(run.start_utc, run.zone_id).strftime("%Y-%m")
        today = cv_quest.local_today(u["zone_id"], now)
        # an upload older than one already stored (an offline queue) describes the past: its active quest must not undo today's
        older = stale or c.execute("SELECT 1 FROM runs WHERE user_id=? AND run_id<>? AND start_utc>?",
                                   (uid, run.run_id, iso(run.start_utc))).fetchone() is not None
        offers_left = cv_quest.store(c, uid, run.quest, month, run.run_id, today, now, bool(u["place_optin"]), older)
        omonth = cv_quest.id_month(run.quest.offers[0].id, month) if run.quest.offers else month   # the offer's month, from its id
        if (not offers_left or older or u["channel"] != "telegram"
                or c.execute("SELECT 1 FROM cards WHERE user_id=? AND run_id=? AND kind='quest'", (uid, f"quest:{omonth}")).fetchone()):
            return
        due = cv_quest.next_evening(now, u["zone_id"], cv_suggest.EVENING_START_MIN, cv_suggest.EVENING_END_MIN)
        c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                  (uid, "quest_offer", iso(due), f"quest:{uid}:{today.isoformat()}", omonth))

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
            tr = c.execute("SELECT trail_json FROM run_shape WHERE user_id=? AND run_id=?", (uid, run_id)).fetchone()
            trail = cv_trail.load(tr["trail_json"]) if tr else None
            hist = self._history(c, uid, run["start_utc"])
            mem = self._memory_get(c, uid, now)
            last = c.execute("SELECT MAX(sent_at) m FROM cards WHERE user_id=? AND sent_at<=?",
                             (uid, iso(now))).fetchone()["m"]  # as of now: a card sent later (real, during a replay) is not "the last"
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
        tkind = cv_trail.card_kind(trail) if self.s.trail_cards else None
        if tkind:   # a trail best or board is the run's picture; it replaces the generic PB or run card, and has no video
            v = dataclasses.replace(v, media=cv_engine.MediaPlan(tkind, False, "trail_pb" if tkind == "trail_record" else "trail_board",
                                                                 v.media.touch_card, None, v.media.touch_facts))
        # A run card carries the feel row only. A post-run suggestion is deferred to the evening-before slot
        # (under its own weekly cap and spacing), never piggybacked as buttons or text on the run card.
        suggestion, sline = None, None
        with db.tx(self.s.db_path) as c:
            if rw and cv_touches.is_sunrise_start(to_local(parse_iso(run["start_utc"]), run["zone_id"]), rw.sunrise_local):
                c.execute("INSERT INTO convo_log (user_id, kind, key, ts) SELECT ?,?,?,? WHERE NOT EXISTS "
                          "(SELECT 1 FROM convo_log WHERE user_id=? AND kind='sunrise' AND key=?)",
                          (uid, "sunrise", run_id, iso(now), uid, run_id))
        res = FactsResult(res.facts, None, res.tone, False, res.reason, res.session)
        w = self.writer.write(res, digest_lines(mem, feels), voice=v.rendered, style=v.style,
                              suggestion_line=sline.body if sline else None, user_id=uid)
        body = w.body
        nline = next_line(self._with_default_plan(uid, run, now), full, soften=soft)   # fixed text: what next and when, never the model's
        body += f"\n{nline}"
        if v.touch_line:
            body += f"\n\n{v.touch_line}"
        with db.ro(self.s.db_path) as c:
            done = cv_quest.done_for_run(c, uid, run_id)
        if done:   # the run that finished a quest: one fixed line on its card, no message of its own
            body += f"\n\n{cv_quest.done_line(done)}"
        buttons = self._buttons(run["feel"], None, None, note=True)
        card_id = secrets.token_hex(16)
        allowed = " ".join([f.text for f in res.facts] + [nline, v.allowed, suggestion.text if suggestion else "",
                                                          sline.allowed if sline else ""])
        used = v.used_variants if w.source == "template" else [x for x in v.used_variants if x.startswith("touch_")]
        if sline and w.source == "template":
            used = used + [sline.variant_id]
        quiet_card = (v.media.reason in ("pb", "trail_pb", "big_session", "long_run") or v.situation == "back_after_break"
                      or (v.touch is not None and v.touch.kind == "comeback"))
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at, "
                      "next_line) VALUES (?,?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, run_id, "run", w.headline, body, json.dumps(buttons), w.source, iso(now), nline))
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
            if q is None or self._ci_cap_taken(c, uid, now) or not self._claim(c, uid, f"question:{wk}", now):
                return None  # one a week, and never on a day that already had a question (C1)
            self._ci_claim_question(c, uid, "question", now)
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

    QUEST_BUTTONS = [{"label": "Take it", "action": "q:take", "row": 0}, {"label": "Another", "action": "q:next", "row": 0},
                     {"label": "Not this month", "action": "q:skip", "row": 0}]

    def _build_quest_card(self, uid: str, month: str, now: datetime) -> str | None:
        """The month's quest offer, once, from the offers the app last sent. Counts inside the weekly suggestion cap and
        takes the day's one question. None (nothing sent) when the month is already decided or a quest is running; a later
        run that carries offers queues it again until one goes."""
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='quest'", (uid, f"quest:{month}")).fetchone()
        if ex:
            return ex["card_id"]
        with db.tx(self.s.db_path) as c:
            zone_id = c.execute("SELECT zone_id FROM users WHERE id=?", (uid,)).fetchone()["zone_id"]
            today = cv_quest.local_today(zone_id, now)
            offers = cv_quest.suggestable(c, uid, cv_quest.offered_rows(c, uid, month))
            if not offers or cv_quest.month_is_decided(c, uid, month) or cv_quest.active_row(c, uid, today):
                return None
            if self._ci_cap_taken(c, uid, now, today.isoformat()) or not self._claim_suggestion(c, uid, now):
                return None
            self._ci_claim_question(c, uid, "quest", now, today.isoformat())
            head, body = cv_quest.offer_text(month, offers[0])
            card_id = secrets.token_hex(16)
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, f"quest:{month}", "quest", head, body, json.dumps(self.QUEST_BUTTONS), "template", iso(now)))
            c.execute("UPDATE quests SET card_id=? WHERE user_id=? AND quest_id=?", (card_id, uid, offers[0]["quest_id"]))
            self._convo_write(c, uid, now, card_id, "quest", cv_engine.MediaPlan("none", False, "quest"), "", [], None)
        return card_id

    def _quest_tap(self, ch: Any, inb: Inbound, user: dict, card: dict, choice: str, now: datetime) -> None:
        """Take it / Another / Not this month on the offer card. The row showing on the card (quests.card_id) is the one the
        tap means; a card that has moved on, or a month that is already decided, answers "moved on" and loses its buttons."""
        uid = user["id"]
        ts = iso(now)
        edit: tuple[str, list[dict]] | None = None   # (text, buttons) the message becomes
        toast = "That one has moved on."
        with db.tx(self.s.db_path) as c:
            today = cv_quest.local_today(user["zone_id"], now)
            row = c.execute("SELECT * FROM quests WHERE user_id=? AND card_id=? AND state='offered'", (uid, card["card_id"])).fetchone()
            if row is not None and choice in ("take", "next", "skip"):
                row = dict(row)
                month = row["month"]
                everything = [r for r in cv_quest.offered_rows(c, uid, month)
                              if r in cv_quest.suggestable(c, uid, [r]) or r["quest_id"] == row["quest_id"]]
                if choice == "next":
                    nxt = everything[(next(i for i, r in enumerate(everything) if r["quest_id"] == row["quest_id"]) + 1) % len(everything)]
                    if nxt["quest_id"] == row["quest_id"]:
                        toast = "That's the only one this month."
                    else:
                        c.execute("UPDATE quests SET card_id=NULL WHERE user_id=? AND quest_id=?", (uid, row["quest_id"]))
                        c.execute("UPDATE quests SET card_id=? WHERE user_id=? AND quest_id=?", (card["card_id"], uid, nxt["quest_id"]))
                        head, body = cv_quest.offer_text(month, nxt)
                        c.execute("UPDATE cards SET headline=?, body=? WHERE card_id=?", (head, body, card["card_id"]))
                        edit, toast = (f"{head}\n{body}", self.QUEST_BUTTONS), "Here's another."
                else:
                    c.execute("UPDATE quests SET state='skipped', card_id=NULL, updated_at=? WHERE user_id=? AND month=? AND state='offered'",
                              (ts, uid, month))
                    if choice == "take" and cv_quest.active_row(c, uid, today) is None:
                        c.execute("UPDATE quests SET state='accepted', accepted_at=?, ends_on=?, updated_at=? WHERE user_id=? AND quest_id=?",
                                  (ts, (today + timedelta(days=cv_quest.WINDOW_DAYS)).isoformat(), ts, uid, row["quest_id"]))
                        text, toast = cv_quest.taken_text(row), "Quest taken."
                    elif choice == "take":
                        text, toast = "You already have a quest running.", "You already have one running."
                    else:
                        text, toast = "Okay. No quest this month.", "Okay."
                    c.execute("UPDATE cards SET body=?, buttons_json='[]', answered_at=COALESCE(answered_at, ?) WHERE card_id=?",
                              (text, ts, card["card_id"]))
                    edit = (f"{card['headline']}\n{text}", [])
        ch.ack_callback(inb, toast, clear=edit is None and toast != "That's the only one this month.")
        if edit is not None and inb.callback_message_id:
            try:
                ch.edit_card_text(inb.ref, inb.callback_message_id, card["card_id"], edit[0], edit[1])
            except ChannelError as e:
                log.warning("quest card edit failed: %s", "429" if e.rate_limited else "error")

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
            tomorrow_d = to_local(now, zone_id).date() + timedelta(days=1)
            lighter = self._ci_lighter(c, uid, now, tomorrow_d)
            hold = self._ci_evening_held(c, uid, tomorrow_d, now)
        if hold:   # ill or away: no suggestion at all; or a readiness question is due in this window and wins the day's cap
            return None
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
                                soften=soft or lighter)
        if not ev:
            return None
        with db.tx(self.s.db_path) as c:
            # a suggestion has a keyboard, so it is the day's one question (C1): it yields to a check-in already sent
            if self._ci_cap_taken(c, uid, now, local_date) or not self._claim_suggestion(c, uid, now):
                return None
            self._ci_claim_question(c, uid, "evening", now, local_date)
        if lighter:   # the softening came from a check-in answer: templated only, the writer never sees it (A2)
            w = Written(ev.rendered.headline, ev.rendered.body, "template")
        else:
            w = self.writer.write(FactsResult((), ev.suggestion, "steady", False, "ok"), digest_lines(mem, feels),
                                  voice=ev.rendered, style=ev.style, user_id=uid)
        buttons = self._buttons("set", ev.suggestion.kind, None)
        card_id = secrets.token_hex(16)
        media = cv_engine.MediaPlan("suggestion", False, ev.suggestion.reason, facts=ev.card_facts)
        used = [ev.rendered.variant_id] if w.source == "template" else []
        with db.tx(self.s.db_path) as c:
            nudge = None if lighter else cv_quest.nudge_for(c, uid, tomorrow_d - timedelta(days=1), now)   # never in a care window
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, f"evening:{local_date}", "evening", w.headline,
                       f"{w.body}\n\n{nudge}" if nudge else w.body, json.dumps(buttons), w.source, iso(now)))
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
        with db.ro(self.s.db_path) as c:  # the newest run this week with a note: it is quoted at send time, not stored
            quote_rid = next((rid for rid in rc.week_run_ids if c.execute(
                "SELECT 1 FROM run_notes WHERE user_id=? AND run_id=?", (uid, rid)).fetchone()), None)
        card_id = secrets.token_hex(16)
        with db.tx(self.s.db_path) as c:
            buttons = [{"label": "Tell Ricki", "action": cv_feedback.FEEDBACK_ACTION, "row": 0}]
            body = rc.rendered.body
            allowed = rc.rendered.allowed
            shape = None if rc.empty else self._recap_shape_line(c, uid, zone_id, now)
            if shape:   # said again only when it changed: the same line every Sunday is noise
                last = c.execute("SELECT key FROM convo_log WHERE user_id=? AND kind='recap_shape' ORDER BY id DESC LIMIT 1", (uid,)).fetchone()
                if last is None or last["key"] != shape:
                    body, allowed = f"{body}\n\n{shape}", f"{allowed} {shape}"   # its numbers come from the default week
                    c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)", (uid, "recap_shape", shape, iso(now)))
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at, "
                      "quote_run_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, f"recap:{week_ref}", "recap", rc.rendered.headline, body,
                       json.dumps(buttons), "template", iso(now), quote_rid))
            self._convo_write(c, uid, now, card_id, rc.rendered.situation, rc.media, allowed,
                              [rc.rendered.variant_id], None)
            if rc.empty:
                c.execute("INSERT INTO convo_log (user_id, kind, key, ts) VALUES (?,?,?,?)",
                          (uid, "recap_empty", week_ref, iso(now)))
        return card_id

    def _with_default_plan(self, uid: str, run: dict, now: datetime) -> dict:
        """The run row with the coach's default week in its plan_next_* fields when the app sent no plan, resolved with the
        runner's check-in answers: the card's Next line then reads the same session as the evening card, the morning card
        and Home. A real plan on the run is left alone."""
        if ci_planned_from_run(run) is not None and run["plan_next_day"] >= to_local(now, run.get("zone_id") or "UTC").date().isoformat():
            return run
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            if u is None or not self._ci_consented(c, uid):
                return run
            _ans, planned, _usual, _today, res = self._ci_state(c, dict(u), now)
        if res is None or planned is None or not planned.derived:
            return run
        same = not res.easier   # a session made easy is not the named one: no name, no pace
        return dict(run, plan_next_type=res.type, plan_next_day=res.day.isoformat(),
                    plan_next_m=planned.distance_m if same else None,
                    plan_next_session_name=planned.session_name if same else None,
                    plan_next_pace_lo=planned.pace_lo_s if same else None, plan_next_pace_hi=planned.pace_hi_s if same else None)

    def _recap_shape_line(self, c, uid: str, zone_id: str, now: datetime) -> str | None:
        """One line on what next week looks like, from the default coach week. Not when the runner has a 4-week plan on
        their newest run: the plan owns the shape then."""
        user = {"id": uid, "zone_id": zone_id}
        _a, planned, *_ = self._ci_state(c, user, now)
        if planned is not None and not planned.derived:   # a live plan (a stale one has fallen back to the default week)
            return None
        today = to_local(now, zone_id).date()
        monday = today + timedelta(days=7 - today.weekday())
        hist = [dict(r) for r in c.execute("SELECT * FROM runs WHERE user_id=? ORDER BY start_utc DESC LIMIT 80", (uid,))]
        memory = {r["key"]: r["value"] for r in c.execute("SELECT key, value FROM memory WHERE user_id=?", (uid,))}
        week = cv_default_week.build_week(hist, memory=memory, zone_id=user["zone_id"], today=monday, now=now)
        return cv_default_week.shape_line(week, monday)

    def _build_monthly_card(self, uid: str, month_ref: str, now: datetime) -> str | None:
        """The month poster for 'YYYY-MM' (the month just ended). Nothing is stored for the picture: it is rebuilt from the
        run rows when it is sent, like the weekly recap. Once per user per month, however often it is planned."""
        ref = f"monthly:{month_ref}"
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='monthly'", (uid, ref)).fetchone()
            if ex:
                return ex["card_id"]
            runs = self._full_history(c, uid, None, now)
            usage = self._usage(c, uid, now)
            zone_id = c.execute("SELECT zone_id FROM users WHERE id=?", (uid,)).fetchone()["zone_id"]
        mr = cv_recap.build_monthly(runs, month_ref, zone_id, usage.variants, now, month_ref)
        if mr is None:
            return None
        card_id = secrets.token_hex(16)
        with db.tx(self.s.db_path) as c:
            if not self._claim(c, uid, f"monthly:{month_ref}", now):
                return None
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, ref, "monthly", mr.rendered.headline, mr.rendered.body, "[]", "template", iso(now)))
            self._convo_write(c, uid, now, card_id, mr.rendered.situation, mr.media, mr.rendered.allowed,
                              [mr.rendered.variant_id], None)
        return card_id

    def _send_card(self, user: dict, card_id: str, now: datetime) -> bool:
        """True when the card went out. False when it was deliberately not sent (WhatsApp, outside the 24 h window,
        on a card the fixed Easy/Right/Hard template cannot honestly carry)."""
        ch = self.channels.get(user["channel"])
        if ch is None:
            raise ChannelError("channel not configured")
        with db.ro(self.s.db_path) as c:
            card = self._ci_line(c, self._quoted(c, dict(c.execute("SELECT * FROM cards WHERE card_id=?", (card_id,)).fetchone())), now)
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
        mid: str | None = None
        carries_text = False   # the delivered message holds the card's whole text and its buttons
        if media is not None:
            out = OutCard(card_id, card["headline"], card["body"], buttons, media, links,
                          short_caption=card["kind"] == "run",
                          neutral_caption=self._spoiler_caption(user["id"], card) if media.spoiler else "")
            try:
                mid = self._deliver(ch, user, card, out)
                followups = ch.followups(out)  # the media is delivered: from here only text may be retried
                carries_text = not media.spoiler and not {"caption", "coach_line"} & set(followups)
                if media.sent.get("file_id"):
                    with db.tx(self.s.db_path) as c:   # the clip's Telegram id; a run that was deleted meanwhile just fails the FK
                        try:
                            c.execute("INSERT OR REPLACE INTO media_file_ids (user_id, run_id, kind, file_id, created_at) VALUES (?,?,?,?,?)",
                                      (user["id"], card.get("run_id"), "ghostclip", media.sent["file_id"], iso(now)))
                        except sqlite3.IntegrityError:
                            pass
            except ChannelError as e:
                if not e.permanent:
                    raise
                log.warning("media refused, sending text: %s", e)
                media = None
        if media is None:
            mid = self._deliver(ch, user, card, OutCard(card_id, card["headline"], card["body"], buttons, None, links),
                                in_window=in_window)
            carries_text = True
        if telegram and carries_text and mid and card["kind"] == "run":
            self._remember_card_message(user["id"], card_id, str(mid), media is not None and bool(media.has_content))
        if telegram and self.s.media_enabled:
            plan = self._plan(card_id)
            if plan.get("touch_card") and plan.get("touch_facts"):
                followups.append("touch_card")   # its own outbox item: a failed render never blocks or repeats the card
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE cards SET sent_at=? WHERE card_id=?", (iso(now), card_id))
            c.execute("INSERT INTO msglog (user_id, ts, direction, kind) VALUES (?,?,?,?)",
                      (user["id"], iso(now), "out", card["kind"]))
            for mode in followups:  # its own outbox item each: a failure retries the text, never the upload
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (user["id"], "followup", iso(now), f"fu:{card_id}:{mode}", f"{card_id}:{mode}"))
        if card["kind"] == "run":
            self._ci_week_enqueue(user, now)   # the pinned week card follows each run
        return True

    def _remember_card_message(self, uid: str, card_id: str, mid: str, is_photo: bool) -> None:
        """Keep which Telegram message carries a run card, so a late note or feel can edit it in place. A card that
        became the morning message reports that message's own kind (photo or text)."""
        with db.tx(self.s.db_path) as c:
            slot = c.execute("SELECT is_photo FROM checkin_slots WHERE user_id=? AND slot='today' AND state='consumed' "
                             "AND message_id=?", (uid, mid)).fetchone()
            photo = int(is_photo)   # 1: a picture whose caption is the short one (caption_text)
            if slot is not None:     # the morning edit puts the whole text in the caption: 2
                photo = 2 if slot["is_photo"] else 0
            c.execute("UPDATE cards SET tg_message_id=?, tg_is_photo=? WHERE card_id=?", (mid, photo, card_id))

    LATE_NOTE_MIN = 15   # a note or feel landing this soon after the card went out may update that card, once

    def _late_edit(self, ch: Any, user: dict | None, run_id: str | None, now: datetime) -> None:
        """A note or feel tap landed after the run card went out. Re-run its fixed Next line with that answer (a flagged
        note or a hard feel eases the next session) and, when the line changes or the note carries a flag, edit the card
        in place with one "Noted: ..." line. Telegram only, within LATE_NOTE_MIN minutes, at most one edit per card,
        never a new message. The note's own words stay off the card: only a plain label for what it mentions."""
        if not user or not run_id or user["paused"] or user["channel"] != "telegram" or not hasattr(ch, "edit_card_body"):
            return
        try:
            with db.ro(self.s.db_path) as c:
                row = c.execute("SELECT * FROM cards WHERE user_id=? AND run_id=? AND kind='run'", (user["id"], run_id)).fetchone()
                if row is None or not (row["sent_at"] and row["tg_message_id"] and row["next_line"]) or row["note_edit_at"]:
                    return
                age = now - parse_iso(row["sent_at"])
                if not timedelta(0) <= age <= timedelta(minutes=self.LATE_NOTE_MIN):
                    return
                run_r = c.execute("SELECT * FROM runs WHERE user_id=? AND run_id=?", (user["id"], run_id)).fetchone()
                if run_r is None:
                    return
                run = dict(run_r)
                note = c.execute("SELECT note FROM run_notes WHERE user_id=? AND run_id=?", (user["id"], run_id)).fetchone()
                label = cv_notes.flag_label(note["note"]) if note else None
                full = self._full_history(c, user["id"], run["start_utc"])
                soft = self._soften(c, user["id"], now)
            nline = next_line(self._with_default_plan(user["id"], run, now), full, soften=soft)
            old = row["next_line"]
            if nline == old and not label:
                return
            what = label or ("that it felt hard" if run["feel"] == "hard" else None)
            if what is None or old not in row["body"]:
                return
            ack = f"Noted: {what}. {nline}" if nline != old else f"Noted: {what}. {old}"
            with db.tx(self.s.db_path) as c:   # the claim: whoever sets it owns the one edit
                if c.execute("UPDATE cards SET note_edit_at=? WHERE card_id=? AND note_edit_at IS NULL",
                             (iso(now), row["card_id"])).rowcount != 1:
                    return
            card = dict(row, body=row["body"].replace(old, ack, 1))
            with db.ro(self.s.db_path) as c:
                card = self._ci_line(c, self._quoted(c, card), now)
            # The keyboard as it is on screen, by the stored indices (the callback data): a feel tap left "Add a note" alone
            buttons = json.loads(row["buttons_json"])
            felt = run["feel"] is not None and any(b["action"].startswith("feel:") for b in buttons)
            if felt:
                buttons = [b if b["action"] == NOTE_ACTION else dict(b, hidden=True) for b in buttons]
            out = OutCard(row["card_id"], card["headline"], card["body"], buttons, None, () if felt else self._links(card),
                          short_caption=row["tg_is_photo"] == 1)
            try:
                ch.edit_card_body(user["chat_ref"], row["tg_message_id"], out, bool(row["tg_is_photo"]))
            except ChannelError as e:
                with db.tx(self.s.db_path) as c:   # nothing changed on screen: let a later answer try once more
                    c.execute("UPDATE cards SET note_edit_at=NULL WHERE card_id=?", (row["card_id"],))
                log.warning("late note edit failed: %s", "429" if e.rate_limited else "error")
        except Exception:   # cosmetic: the answer is already saved, the card just stays as it was
            log.exception("late note edit skipped")

    @staticmethod
    def _quoted(c, card: dict) -> dict:
        """A recap that quotes a note gets the quote added now, from the note as it is now: a replaced or deleted note
        is never quoted, and the quote is not kept in the card."""
        rid = card.get("quote_run_id")
        if rid:
            n = c.execute("SELECT note FROM run_notes WHERE user_id=? AND run_id=?", (card["user_id"], rid)).fetchone()
            if n:
                card = {**card, "body": f"{card['body']}\n\n{cv_notes.quote(n['note'])}"}
        return card

    def _spoiler_caption(self, uid: str, card: dict) -> str:
        """The caption of a spoilered trail photo: which run it was and nothing about how it went."""
        with db.ro(self.s.db_path) as c:
            tr = c.execute("SELECT trail_json FROM run_shape WHERE user_id=? AND run_id=?", (uid, card.get("run_id"))).fetchone()
        trail = cv_trail.load(tr["trail_json"]) if tr else None
        if not trail:
            return "Trail run done. Tap to see how it went."
        place = f" on {trail['name']}" if trail.get("name") else ""
        return f"Trail run {trail['n']}{place}. Tap to see how it went."

    def _ops_mark(self, item: dict, result: str) -> None:
        if item["kind"] == "ops":
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE ops_sends SET result=? WHERE card_id=?", (result, item["ref"]))

    def _send_ops(self, user: dict, card_id: str, now: datetime) -> bool:
        """An approved ops template, queued by `ops send`. Checked again here: consent v2, still approved, one a week."""
        if ops_send.test_over(self.s, now):
            self._ops_mark({"kind": "ops", "ref": card_id}, "skipped: test ended")
            return False
        with db.ro(self.s.db_path) as c:
            row = c.execute("SELECT o.template, o.text_hash FROM ops_sends o WHERE o.card_id=? AND o.user_id=?",
                            (card_id, user["id"])).fetchone()
            card = c.execute("SELECT body FROM cards WHERE card_id=?", (card_id,)).fetchone()
        if row is None:
            return False
        if card is None or ops_send.text_hash(card["body"]) != row["text_hash"]:
            self._ops_mark({"kind": "ops", "ref": card_id}, "skipped: text changed")
            return False
        if user["checkin_consent"] is None or user["checkin_consent"] < self.s.checkin_consent_required:
            self._ops_mark({"kind": "ops", "ref": card_id}, "skipped: no consent")
            return False
        if (row["template"], row["text_hash"]) not in ops_send.approved_hashes():
            self._ops_mark({"kind": "ops", "ref": card_id}, "skipped: approval withdrawn")
            return False
        with db.ro(self.s.db_path) as c:   # the weekly cap: one ops message that actually went out in the last 7 days
            capped = c.execute("SELECT 1 FROM ops_sends WHERE user_id=? AND result='sent' AND card_id<>? AND ts>?",
                               (user["id"], card_id, iso(now - timedelta(days=7)))).fetchone()
        if capped:
            self._ops_mark({"kind": "ops", "ref": card_id}, "skipped: weekly cap")
            return False
        sent = self._send_card(user, card_id, now)
        self._ops_mark({"kind": "ops", "ref": card_id}, "sent" if sent else "skipped")
        return sent

    def _send_followup(self, user: dict, ref: str, now: datetime) -> bool:
        """False when dropped: unknown card or mode, or older than stale_card_hours since the media went out (a
        follow-up held back by the kill switch or quiet hours must not arrive long after its card)."""
        card_id, _, mode = ref.partition(":")
        ch = self.channels.get(user["channel"])
        if ch is None or mode not in ("caption", "question", "touch_card", "coach_line"):
            return False
        with db.ro(self.s.db_path) as c:
            row = c.execute("SELECT * FROM cards WHERE card_id=? AND user_id=?", (card_id, user["id"])).fetchone()
        if row is None:
            return False
        with db.ro(self.s.db_path) as c:
            card = self._ci_line(c, self._quoted(c, dict(row)), now)
        if not card["sent_at"] or parse_iso(card["sent_at"]) < now - timedelta(hours=self.s.stale_card_hours):
            log.info("follow-up dropped: stale")
            return False
        if mode == "touch_card":
            # The milestone or countdown picture. The touch line already rode the card's text, so any failure to draw it
            # (no worker, refused upload) just means the text stands alone: skipped, not retried into a loop.
            try:
                media = self.media.render_touch(self._plan(card_id))
            except Exception as e:
                log.warning("touch card render failed, text stands: %s", type(e).__name__)
                return False
            if media is None:
                return False
            try:
                ch.send_followup(user["chat_ref"], OutCard(card_id, "", "", [], media, ()), mode)
            except ChannelError as e:
                if not e.permanent:
                    raise
                log.warning("touch card refused, text stands: %s", e)
                return False
            return True
        ch.send_followup(user["chat_ref"], OutCard(card_id, card["headline"], card["body"],
                                                   json.loads(card["buttons_json"]), None, self._links(card)), mode)
        return True

    def _plan(self, card_id: str) -> dict:
        """The stored media plan of a card ({} when there is none or it cannot be read)."""
        with db.ro(self.s.db_path) as c:
            cc = c.execute("SELECT media_json FROM convo_cards WHERE card_id=?", (card_id,)).fetchone()
        try:
            plan = json.loads(cc["media_json"]) if cc else {}
        except ValueError:
            return {}
        return plan if isinstance(plan, dict) else {}

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
        out = (("Open in app", url),) if url else ()
        if self.s.miniapp_enabled:  # a web_app button: opens the read-only Mini App inside Telegram
            out += (("Open the week", self.s.miniapp_url),)
        return out

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
            elif card["kind"] == "monthly":
                ref = str(card.get("run_id") or "")
                try:
                    y, m = int(ref[len("monthly:"):][:4]), int(ref[len("monthly:"):][5:7])
                    lo, hi = datetime(y, m, 1, tzinfo=UTC) - timedelta(days=2), datetime(y + m // 12, m % 12 + 1, 1, tzinfo=UTC) + timedelta(days=2)
                except ValueError:
                    return None
                runs = [dict(r) for r in c.execute("SELECT * FROM runs WHERE user_id=? AND start_utc>=? AND start_utc<=?",
                                                    (user["id"], iso(lo), iso(hi)))]
            else:
                runs = [dict(r) for r in c.execute("SELECT * FROM runs WHERE user_id=? AND run_id=?",
                                                    (user["id"], card.get("run_id")))]
                for r in runs:  # the shape rides beside the row, for the renderer only (never into a prompt)
                    sh = c.execute("SELECT route_json, splits_json, reps_json, trail_json FROM run_shape WHERE user_id=? AND run_id=?",
                                   (user["id"], r["run_id"])).fetchone()
                    if sh:
                        r["_shape"] = {"route": json.loads(sh["route_json"]) if sh["route_json"] else None,
                                       "splits": json.loads(sh["splits_json"]) if sh["splits_json"] else None,
                                       "reps": json.loads(sh["reps_json"]) if sh["reps_json"] else None,
                                       "trail": cv_trail.load(sh["trail_json"])}
        try:
            if plan.get("card") == "trail_record" and self.s.trail_clip and any((r.get("_shape") or {}).get("trail") for r in runs):
                # a clip already sent for this run is one id, not another render and upload (an outbox retry). Only while the trail
                # block it was made from is still stored (it ages out at 30 days, and so does the id). The still rides beside it, so
                # a refused id falls back to a photo and not to text.
                with db.ro(self.s.db_path) as c:
                    hit = c.execute("SELECT file_id FROM media_file_ids WHERE user_id=? AND run_id=? AND kind='ghostclip'",
                                    (user["id"], card.get("run_id"))).fetchone()
                if hit:
                    still = None
                    try:
                        still = self.media.render(plan, {"run_id": card.get("run_id"), "headline": card["headline"]}, runs, clip=False)
                    except Exception as e:   # the id alone is still worth trying
                        log.warning("ghost clip cached still skipped: %s", type(e).__name__)
                    return dataclasses.replace(Media(), photo=still.photo if still else None, animation=True,
                                               animation_file_id=hit["file_id"], duration_s=GHOST_CLIP_S, spoiler=self.s.trail_spoiler)
            # the renderer gets the two fields it uses, never the whole card (whose body may quote a note)
            media = self.media.render(plan, {"run_id": card.get("run_id"), "headline": card["headline"]}, runs, clip=self.s.trail_clip)
            if media is not None and self.s.trail_spoiler and (
                    plan.get("card") in cv_trail.TRAIL_KINDS
                    or (card["kind"] == "run" and runs and runs[0].get("app_type") == "trail")):
                media = dataclasses.replace(media, spoiler=True)   # the verdict is a tap to reveal: trail cards, and any trail-type run's picture
            return media
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
        if user["paused"] or user["ops_paused"]:
            self._ops_mark(item, "skipped: paused or stopped")
            return "skipped", None
        if self._kill_switch():
            return "defer", now + timedelta(minutes=15)
        if item["kind"] == "ci_edit":   # the answer to a tap the runner just made: not held back by quiet hours
            return self._ci_process_edit(user, item["ref"], now)
        if item["kind"] == "ci_week":   # a silent edit of the pinned week card, also not held back by quiet hours
            return self._ci_week_sync(user, item["ref"], now)
        qs, qe = self._quiet(user)
        if in_quiet(now, user["zone_id"], qs, qe):
            until = quiet_end_utc(now, user["zone_id"], qe)
            if item["kind"] == "ci" and until >= self._ci_deadline(item["ref"]):
                return "skipped", None   # a check-in is dropped, never sent late (C2)
            return "defer", until
        if item["kind"] == "ci":
            return self._ci_process(user, item["ref"], now)
        if item["kind"] == "ops":
            return ("done" if self._send_ops(user, item["ref"], now) else "skipped"), None
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
        elif item["kind"] == "quest_offer":
            if user["channel"] != "telegram":
                return "skipped", None
            card_id = self._build_quest_card(user["id"], item["ref"], now)
        elif item["kind"] == "recap":
            if user["channel"] != "telegram":  # Telegram first; WhatsApp would bill it as marketing
                return "skipped", None
            card_id = self._build_recap_card(user["id"], item["ref"], now)
        elif item["kind"] == "trust":
            if user["channel"] != "telegram":
                return "skipped", None
            card_id = self._build_trust_card(user["id"], item["ref"], now)
        elif item["kind"] == "trust_why":
            if user["channel"] != "telegram":
                return "skipped", None
            card_id = self._build_trust_why_card(user["id"], item["ref"], now)
        elif item["kind"] == "ellis":
            if user["channel"] != "telegram":
                return "skipped", None
            card_id = self._build_ellis_card(user["id"], now)
        elif item["kind"] == "monthly":
            if user["channel"] != "telegram":  # same as the recap: WhatsApp would bill an unprompted poster as marketing
                return "skipped", None
            card_id = self._build_monthly_card(user["id"], item["ref"], now)
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
            wait = 0.0
            try:
                state, retry = self._process(r, now)
                err = None
            except ChannelError as e:
                state, retry, err = "retry", None, str(e)[:120]
                wait = e.retry_after or 0.0   # Telegram 429: never earlier than it asked
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
                              (iso(now + max(timedelta(minutes=2 ** attempts), timedelta(seconds=wait))), err, r["id"]))
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
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND ops_paused=0 AND last_run_utc >= ?" + who,
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
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND ops_paused=0 AND last_run_utc >= ?" + who,
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

    def plan_monthly(self, now: datetime | None = None, only_user: str | None = None) -> int:
        """Queue the month poster on the 1st, 09:00-12:00 local, for the month that just ended. Once per user per month
        (the dedupe key, the existing card and the build's own quota claim all say so), only when that month had runs,
        never inside quiet hours and never within MONTHLY_MIN_GAP_H of another card: the poster waits for a later tick
        in its window rather than land on top of one."""
        now = now or now_utc()
        n = 0
        who, args = ((" AND id = ?", (only_user,)) if only_user else (f" AND id NOT IN {replay_hold(now)}", ()))
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND ops_paused=0 AND last_run_utc >= ?" + who,
                (iso(now - timedelta(days=62)), *args))]
            for u in users:
                loc = to_local(now, u["zone_id"])
                if loc.day != cv_recap.MONTHLY_DAY:
                    continue
                if not (cv_recap.MONTHLY_START_MIN <= loc.hour * 60 + loc.minute < cv_recap.MONTHLY_END_MIN):
                    continue
                qs, qe = self._quiet(u)
                if in_quiet(now, u["zone_id"], qs, qe):
                    continue
                ref = cv_recap.previous_month(now, u["zone_id"])
                if c.execute("SELECT 1 FROM cards WHERE user_id=? AND run_id=? AND kind='monthly'",
                             (u["id"], f"monthly:{ref}")).fetchone():
                    continue  # already built (and sent or about to be)
                if c.execute("SELECT 1 FROM cards WHERE user_id=? AND sent_at>?",
                             (u["id"], iso(now - timedelta(hours=cv_recap.MONTHLY_MIN_GAP_H)))).fetchone():
                    continue
                rows = [dict(r) for r in c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? AND start_utc>=? "
                                                   "AND start_utc<=?", (u["id"], iso(now - timedelta(days=64)), iso(now)))]
                if not cv_recap.month_runs(rows, u["zone_id"], ref):
                    continue  # nothing to show for the month
                n += c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                               (u["id"], "monthly", iso(now), f"monthly:{u['id']}:{ref}", ref)).rowcount
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
            cv_quest.purge(c, now, held)
            if ops_send.test_over(self.s, now):   # the tester programme's audit goes when the test ends
                c.execute("DELETE FROM ops_sends")
                cv_measure.purge_surveys(c, now, self.s.test_end_date)
            c.execute("DELETE FROM replay_items WHERE real_at < ?" + held, (log_cut,))
            c.execute("DELETE FROM replay_runs WHERE user_id IN (SELECT user_id FROM replay_state WHERE status = 'done' "
                      "AND updated_at < ?)", (log_cut,))
            c.execute("DELETE FROM replay_rows WHERE user_id IN (SELECT user_id FROM replay_state WHERE status = 'done' "
                      "AND updated_at < ?)", (log_cut,))
            for tbl, ident in db.IDENT.items():  # a tag for a row that is gone must not outlive it (a new row could reuse the name)
                c.execute("DELETE FROM replay_rows WHERE tbl=? AND NOT EXISTS (SELECT 1 FROM " + tbl + " t WHERE "
                          "t.user_id = replay_rows.user_id AND " + ident + " = replay_rows.rid)", (tbl,))
            c.execute("DELETE FROM replay_state WHERE status = 'done' AND updated_at < ?", (log_cut,))
            c.execute("DELETE FROM llm_calls WHERE ts < ?", (iso(now - timedelta(days=400)),))
            c.execute("DELETE FROM inbound_strikes WHERE ts < ?", (iso(now - timedelta(days=2)),))
            c.execute("DELETE FROM inbound_events WHERE ts < ?" + held, (iso(now - timedelta(days=cv_measure.EVENT_RETENTION_DAYS)),))
            # Only sent alerts age out, and after 62 days (two months), so a month's cap keys outlive the month: no re-fire on
            # the 31st, and an unsent backlog (cron not running) is never silently dropped.
            c.execute("DELETE FROM alerts WHERE sent_at IS NOT NULL AND ts < ?", (iso(now - timedelta(days=62)),))
            c.execute("DELETE FROM enrol_refused WHERE day < ?", ((now - timedelta(days=90)).strftime("%Y-%m-%d"),))
            # the area's own age: 30 days after the run it came from (or its run is gone), or the switch is off
            c.execute("DELETE FROM convo_area WHERE NOT EXISTS (SELECT 1 FROM runs r WHERE r.user_id=convo_area.user_id "
                      "AND r.run_id=convo_area.run_id AND r.start_utc >= ?)" + held, (iso(now - timedelta(days=RETENTION_AREA_DAYS)),))
            c.execute("DELETE FROM convo_area WHERE user_id IN (SELECT id FROM users WHERE weather_optin=0)" + held)
            c.execute("UPDATE run_shape SET route_json=NULL WHERE route_json IS NOT NULL AND EXISTS (SELECT 1 FROM runs r "
                      "WHERE r.user_id=run_shape.user_id AND r.run_id=run_shape.run_id AND r.start_utc < ?)" + held,
                      (iso(now - timedelta(days=RETENTION_ROUTE_DAYS)),))
            c.execute("UPDATE run_shape SET trail_json=NULL WHERE trail_json IS NOT NULL AND EXISTS (SELECT 1 FROM runs r "
                      "WHERE r.user_id=run_shape.user_id AND r.run_id=run_shape.run_id AND r.start_utc < ?)" + held,
                      (iso(now - timedelta(days=RETENTION_ROUTE_DAYS)),))   # the trail block ages like the route outline
            c.execute("DELETE FROM media_file_ids WHERE EXISTS (SELECT 1 FROM runs r WHERE r.user_id=media_file_ids.user_id "
                      "AND r.run_id=media_file_ids.run_id AND r.start_utc < ?)" + held,
                      (iso(now - timedelta(days=RETENTION_ROUTE_DAYS)),))   # the clip's Telegram id goes with the trail block it came from
            c.execute("DELETE FROM run_shape WHERE route_json IS NULL AND splits_json IS NULL AND reps_json IS NULL "
                      "AND trail_json IS NULL")
            c.execute("DELETE FROM run_shape WHERE NOT EXISTS (SELECT 1 FROM runs r WHERE r.user_id=run_shape.user_id "
                      "AND r.run_id=run_shape.run_id)")  # belt and braces: a shape never outlives its run
            c.execute("DELETE FROM memory WHERE key='niggle_area' AND updated_at < ?" + held,
                      (iso(now - timedelta(days=NIGGLE_TTL_DAYS)),))
            gone = self.purge_checkins(c, now, held)
            gone += c.execute("DELETE FROM feedback WHERE ts < ?" + held,
                              (iso(now - timedelta(days=cv_feedback.FEEDBACK_RETENTION_DAYS)),)).rowcount
            c.execute("DELETE FROM feedback_mode WHERE expires_at < ?", (iso(now - timedelta(hours=1)),))
            idle = [r["id"] for r in c.execute(
                f"SELECT id FROM users WHERE COALESCE(last_run_utc, created_at) < ? AND id NOT IN {replay_hold(now)}",
                (iso(now - timedelta(days=RETENTION_INACTIVE_DAYS)),))]
        if gone:   # old page images of purged answers and feedback must not wait in the WAL (P1)
            db.checkpoint_truncate(self.s.db_path)
        for uid in idle:  # six months without a run: hard delete
            db.hard_delete_user(self.s.db_path, uid)
            log.info("retention-deleted user=%s", uid)

    def tick(self, now: datetime | None = None) -> None:
        now = now or now_utc()
        self.tick_replay_flag(now)
        self.plan_checkins(now)   # before the evening suggestion: a question that is due in the same window goes first
        self.plan_evening(now)
        self.plan_recap(now)
        self.plan_trust(now)
        self.plan_ellis(now)
        self.plan_monthly(now)
        self.run_outbox(now)
        with db.tx(self.s.db_path) as c:
            r = c.execute("SELECT value FROM settings WHERE key='last_purge'").fetchone()
            due = not r or parse_iso(r["value"]) < now - timedelta(hours=1)
            if due:
                c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('last_purge', ?)", (iso(now),))
        if due:
            self.purge(now)

