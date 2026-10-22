"""Coach chat (C1): free text from a gated runner -> a Sonnet agent loop with read tools -> checked reply.

Flow (eng-review section 2):
  handle_inbound (sync, no model call)
    gate: COMPANION_COACH_CHAT, allowlist, consent >= coach_consent_required, not paused, not ops-paused   (B1)
    red-flag check, hard tier -> fixed safety template, health flag, deduped alert, no model             (B6)
    else one transaction: inbound_seen + coach_jobs (UNIQUE msg_mac) + the runner's words                 (B3)
  one worker thread (persisted jobs survive a restart)                                                    (B2)
    claim: per runner, messages within coach_merge_s answered as one turn; gate re-checked; daily caps;
           first spend reservation in the claim transaction                                              (B9)
    agent: <= coach_max_tool_turns tool turns, 30 s per model call, 60 s per job, max_tokens 2000 (thinking included);
         typing heartbeat for the whole job; a validator miss gets ONE repair turn (the reason goes back to the model)
    hard tier again on the merged turn, then the safety classifier (screen.py): a hit, or a soft regex
           hit with a classifier error, gets the safety template and no main model call
    chat validator -> repair turn -> template fallback on a second failure (counted, alert above 20% in 24 h)   (B7)
    reply stored on the job before the send (HTML, up to 3 chip buttons that come back as the runner's next
    turn); a failed send retries the send only                                                          (B3)
"""
from __future__ import annotations

import contextlib
import json
import logging
import threading
import time
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta
from typing import Any

import httpx

from .. import db
from ..channels import ChannelError, chip_data, utf16_len
from ..notes import clean as clean_text
from ..rails import add_alert, tag
from ..timeutil import iso, now_utc, parse_iso
from . import budget, prompt as coach_prompt, redflag, screen, validator
from .briefing import Briefings
from .ext import ToolContext
from .tools import ReadTools

log = logging.getLogger("companion")

COACH_PAUSED = "You're paused, so the coach chat is off too. Send RESUME to turn it back on."
FALLBACK_TEXT = "That one got away from me. Ask it again, or tap one of these."
FALLBACK_CHIPS = ("How was my last run?", "What's next in my plan?")
FALLBACK = validator.with_chips(FALLBACK_TEXT, FALLBACK_CHIPS)
DAILY_CAP = "That's all the chat I've got in me today. Ask me again tomorrow; your run cards still come as normal."
BUDGET = "The coach chat is resting for now. Your run cards still come as normal."
MAX_CHAT_CHARS = 2000
MAX_SEND_ATTEMPTS = 5
STALE_GRACE_S = 30
MAX_BATCH_CHARS = 4000   # a merged turn is cut to its latest 4000 characters
SEND_BACKOFF_S = 30
MAX_TOOL_CALLS_PER_TURN = 8
TG_LIMIT = 4096
TYPING_EVERY_S = 4.0   # Telegram's typing indicator lasts about 5 s
REPAIR_HINTS = {
    "empty": "it was empty",
    "too_long": f"it was too long (keep it well under {validator.MAX_REPLY_CHARS} characters)",
    "link": "it had a link that no tool returned (leave links out unless a tool result has them)",
    "phone_like": "it had a phone number that no tool returned",
    "spelled_measure": "it gave a measurement in words (use a figure from a tool, or leave the figure out)",
    "foreign_unit": "it used a unit the runner's data does not use (stick to km, minutes and m:ss pace)",
    "ungrounded": "the figure {detail} is not in any tool result or in what the runner said (call calc_pace for pace, time "
                  "or distance sums, or say it without that figure)",
}
FALLBACK_ALERT_SHARE = 0.2
SCREEN_ALERT_SHARE = 0.05
SCREEN_ALERT_MIN_JOBS = 10
FALLBACK_ALERT_MIN_JOBS = 5
CAP_OUTCOMES = ("daily_cap", "daily_usd", "month_cap")


class _NotCoach(Exception):
    """Raised inside the accept transaction to roll it back: this message takes the ordinary path."""


def split_text(text: str, limit: int = TG_LIMIT) -> list[str]:
    """Telegram's 4096 limit (UTF-16 units), cut at a line break or a space where possible (W8)."""
    parts: list[str] = []
    rest = text
    while rest:
        if utf16_len(rest) <= limit:
            parts.append(rest)
            break
        lo, hi = 1, len(rest)
        while lo < hi:   # the longest prefix that fits
            mid = (lo + hi + 1) // 2
            if utf16_len(rest[:mid]) <= limit:
                lo = mid
            else:
                hi = mid - 1
        cut = lo
        for sep in ("\n", " "):
            i = rest.rfind(sep, 0, lo)
            if i > lo // 2:
                cut = i
                break
        parts.append(rest[:cut].rstrip())
        rest = rest[cut:].lstrip()
    return [p for p in parts if p]


def alternate(history: list[dict]) -> list[dict]:
    """Earlier turns as strict user/assistant alternation starting with the runner: consecutive messages from one side are
    joined (merged turns, a reply that failed to send), and a leading coach message is dropped."""
    out: list[dict] = []
    for m in history:
        if out and out[-1]["role"] == m["role"]:
            out[-1] = {"role": m["role"], "content": out[-1]["content"] + "\n" + m["content"]}
        else:
            out.append(dict(m))
    while out and out[0]["role"] != "user":
        out.pop(0)
    return out


@dataclass
class Claimed:
    job_id: int
    user_id: str
    batch: list[int]
    ledger_id: int
    chars: int
    history: list[dict] = field(default_factory=list)
    message: str = ""
    soft_kind: str | None = None     # a soft regex hit on the merged turn: a classifier error means the safety reply
    zone_id: str = "UTC"


@dataclass
class AgentResult:
    reply: str | None          # the checked reply (HTML subset, no chips block), None when the template goes out
    chips: list[str]
    outcome: str
    sources: list[str]
    calls: int = 0
    cost_usd: float = 0.0


class _Heartbeat:
    """Sends 'typing...' now and every TYPING_EVERY_S until the job ends."""

    def __init__(self, ch: Any, ref: str):
        self.ch, self.ref = ch, ref
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="coach-typing", daemon=True)

    def _loop(self) -> None:
        while True:
            with contextlib.suppress(Exception):   # cosmetic, never takes the job down
                self.ch.send_typing(self.ref)
            if self._stop.wait(TYPING_EVERY_S):
                return

    def __enter__(self) -> "_Heartbeat":
        self._thread.start()
        return self

    def __exit__(self, *exc: Any) -> None:
        self._stop.set()
        self._thread.join(2.0)


class CoachChat:
    def __init__(self, svc: Any):
        self.svc, self.s = svc, svc.s
        self.prompt: coach_prompt.CoachPrompt | None = None
        self.wake = threading.Event()
        self._last_typing: dict[str, float] = {}
        self._placeholders: dict[int, str] = {}   # job id -> message id of its "on it" line, until the answer replaces it
        self.briefing = Briefings(self)   # C2b: the spoken session briefing; shares the gate, the worker and the ledger
        if self.s.coach_chat:
            try:
                self.prompt = coach_prompt.load(self.s.coach_dir)
                log.info("coach chat on: prompt_hash=%s model=%s", self.prompt.prompt_hash, self.s.coach_model)
            except Exception as e:   # fail closed: no partial prompt ever reaches a model
                log.error("coach chat off: the skill did not compile (%s)", type(e).__name__)

    @property
    def enabled(self) -> bool:
        return bool(self.s.coach_chat and self.prompt is not None and self.s.coach_allowlist)

    # ------------------------------------------------------------------------------------------ gate (B1)
    def allowlisted(self, u: Any, a: frozenset[str] | None = None) -> bool:
        a = self.s.coach_allowlist if a is None else a
        return (u["id"] in a or (bool(u["tester_no"]) and f"T{u['tester_no']}" in a)
                or f"{u['channel']}:{u['chat_ref']}" in a)

    def gate(self, c, uid: str) -> str | None:
        """None when this runner's free text may go to the model, else why not. Read fresh from the database (never a
        cached user dict), so a withdrawal or a pause between enqueue and claim is seen."""
        if not self.enabled:
            return "off"
        u = c.execute("SELECT id, tester_no, channel, chat_ref, checkin_consent, paused, ops_paused FROM users WHERE id=?",
                      (uid,)).fetchone()
        if not u:
            return "gone"
        if not self.allowlisted(u):
            return "allowlist"
        if u["checkin_consent"] is None or u["checkin_consent"] < self.s.coach_consent_required:
            return "consent"
        if u["ops_paused"]:
            return "ops_paused"
        if u["paused"]:
            return "paused"
        return None

    def gate_for(self, uid: str) -> str | None:
        with db.ro(self.s.db_path) as c:
            return self.gate(c, uid)

    # ------------------------------------------------------------------------------------------ inbound
    def accept(self, ch: Any, inb: Any, user: dict, now: datetime) -> bool:
        """Take this free-text message for the coach. False (nothing written) when the gate says no: the caller then
        handles it exactly as before. True when it was taken, or was a redelivery of one already taken."""
        text = clean_text(inb.text)[:MAX_CHAT_CHARS]
        if not text:
            return False
        kind = redflag.detect(text)   # before any cap, budget or model (B6)
        mac = self.svc._mac(inb.msg_id)
        uid = user["id"]
        safety_job = None
        try:
            with db.tx(self.s.db_path) as c:
                if self.gate(c, uid) is not None:
                    raise _NotCoach()
                if c.execute("INSERT OR IGNORE INTO inbound_seen (msg_id, user_id, ts) VALUES (?,?,?)",
                             (mac, uid, iso(now))).rowcount == 0:
                    return True   # a redelivery: already queued (or answered) once
                c.execute("UPDATE users SET last_inbound_at=? WHERE id=?", (iso(now), uid))
                if kind:
                    reply = redflag.template(kind, user.get("zone_id"))
                    cur = c.execute("INSERT INTO coach_jobs (user_id, msg_mac, kind, state, reply, reply_source, outcome, "
                                    "created_at, replied_at) VALUES (?,?,?,?,?,?,?,?,?)",
                                    (uid, mac, "safety", "replied", reply, "safety", kind, iso(now), iso(now)))
                    safety_job = cur.lastrowid
                    self._flag(c, user, kind, now)
                    self._message(c, uid, safety_job, "runner", text, now)
                    self._message(c, uid, safety_job, "coach", reply, now)
                else:
                    cur = c.execute("INSERT INTO coach_jobs (user_id, msg_mac, kind, state, created_at) VALUES (?,?,?,?,?)",
                                    (uid, mac, "chat", "pending", iso(now)))
                    self._message(c, uid, cur.lastrowid, "runner", text, now)
        except _NotCoach:
            return False
        self.svc._log_event(user, "text", now)
        if safety_job is not None:
            log.warning("coach red flag kind=%s tester=%s job=%s", kind, tag(user.get("tester_no")), safety_job)
            self.send_job(safety_job)
        else:
            self._typing(ch, inb.ref, force=True)
            self.wake.set()
        return True

    def chip_tap(self, ch: Any, inb: Any, now: datetime) -> None:
        """A coach quick-reply button: its label is the runner's next message, taken exactly like typed text (gate, red-flag
        rail, caps), so a button can never reach the coach by another road. Command words are not looked at: a chip
        called "Delete" is only ever words to the coach."""
        user = self.svc._user_by_ref(inb.channel, inb.ref)
        taken = bool(user) and self.accept(ch, replace(inb, text=inb.chip or "", chip=None), user, now)
        ack = getattr(ch, "ack_chip", None)
        if ack:
            ack(inb, (inb.chip or "") if taken else
                (COACH_PAUSED if user and self.gate_for(user["id"]) == "paused" else "The coach chat isn't on right now."))

    def rail(self, user: dict, text: str, now: datetime, where: str = "note") -> str | None:
        """The red-flag check for text that does not go to the coach: a typed run note, Tell Ricki feedback, or free text
        from a paused coach runner (review of #341, P2-5). Applies to runners past the gate or only paused. -> the safety
        reply (the flag and the alert are written), or None. Hard tier only: these paths have no classifier (the webhook
        never calls a model), and soft words in notes ("legs were dead") must not page the operator."""
        kind = redflag.detect(text)
        if not kind or self.gate_for(user["id"]) not in (None, "paused"):
            return None
        with db.tx(self.s.db_path) as c:
            self._flag(c, user, kind, now)
        log.warning("coach red flag in %s kind=%s tester=%s", where, kind, tag(user.get("tester_no")))
        return redflag.template(kind, user.get("zone_id"))

    def _flag(self, c, user: dict, kind: str, now: datetime) -> None:
        """Set the flag in code and queue one alert per runner, kind and UTC day (W7). No message text in the alert."""
        c.execute("INSERT INTO health_flags (user_id, kind, state, source, set_at) VALUES (?,?,?,?,?) "
                  "ON CONFLICT(user_id, kind) DO UPDATE SET state='active', source=excluded.source, set_at=excluded.set_at, "
                  "cleared_at=NULL, cleared_by=NULL", (user["id"], kind, "active", "rail", iso(now)))
        t = tag(user.get("tester_no"))
        what = "a physical red flag (chest pain, fainting, breathing, heat)" if kind == redflag.URGENT else "distress or self-harm words"
        add_alert(c, f"coach-flag:{t}:{kind}:{now.strftime('%Y-%m-%d')}", f"Run Supreme coach: {t} {kind} red flag",
                  f"{t} sent a message with {what}. They got the fixed safety reply; no model call. "
                  f"Check in with them. Clear the flag: companion.cli ops clear-flag {t} {kind}", now)

    @staticmethod
    def _message(c, uid: str, job_id: int | None, role: str, text: str, now: datetime) -> None:
        if role == "coach":   # chips and the operator footer are buttons and a readout, not words the coach said
            text = validator.strip_footer(validator.split_chips(text)[0])
        c.execute("INSERT INTO coach_messages (user_id, job_id, role, text, ts) VALUES (?,?,?,?,?)",
                  (uid, job_id, role, text, iso(now)))

    def withdraw(self, c, uid: str) -> None:
        """Consent dropped below the coach version (W6): the chat history goes and nothing queued is answered."""
        c.execute("DELETE FROM coach_messages WHERE user_id=?", (uid,))
        c.execute("DELETE FROM coach_briefings WHERE user_id=?", (uid,))   # C2b: the briefing came from check-in data too
        c.execute("UPDATE coach_jobs SET reply=NULL WHERE user_id=?", (uid,))
        c.execute("UPDATE coach_jobs SET state='cancelled', outcome='withdrawn' "
                  "WHERE user_id=? AND state IN ('pending','running','merged','replied','sending')", (uid,))   # briefing jobs too

    # ------------------------------------------------------------------------------------------ Telegram out
    def _typing(self, ch: Any, ref: str, force: bool = False) -> None:
        last = self._last_typing.get(ref, 0.0)
        if not force and time.monotonic() - last < TYPING_EVERY_S:
            return
        self._last_typing[ref] = time.monotonic()
        fn = getattr(ch, "send_typing", None)
        if fn:
            try:
                fn(ref)
            except ChannelError:
                pass   # cosmetic

    def _heartbeat(self, uid: str):
        """'typing...' for the whole job (a beat now, then every 4 s), so the chat never goes quiet while the model works."""
        out = self._ref_for(uid)
        if out is None or not getattr(out[0], "send_typing", None):
            return contextlib.nullcontext()
        return _Heartbeat(out[0], out[1])

    def _send_placeholder(self, job: "Claimed", ch: Any, ref: str, text: str) -> None:
        """A one-line 'on it' message for a slow job; send_job edits it into the answer. Once per job."""
        if job.job_id in self._placeholders:
            return
        try:
            self._placeholders[job.job_id] = ch.send_text(ref, text)
        except ChannelError:
            pass   # cosmetic

    @staticmethod
    def _chip_rows(job_id: int, chips: list[str]) -> list[list[tuple[str, str]]]:
        """One row when the labels are short enough to sit side by side, else one button per row."""
        btns = [(c, chip_data(job_id, c)) for c in chips]
        return [btns] if sum(len(c) for c in chips) <= 36 else [[b] for b in btns]

    def send_job(self, job_id: int) -> bool:
        """Send a stored reply as plain text, split at 4096. The send is claimed first (replied -> sending, one winner),
        so the webhook and the worker can never both send it (review of #341, P2-1). A failure goes back to 'replied' for
        the worker to retry, the send only. After the send the reply is cleared from the job (it lives in coach_messages)."""
        with db.tx(self.s.db_path) as c:
            if c.execute("UPDATE coach_jobs SET state='sending', sending_at=? WHERE id=? AND state='replied' AND reply IS NOT NULL",
                         (iso(now_utc()), job_id)).rowcount != 1:
                return False
            j = c.execute("SELECT * FROM coach_jobs WHERE id=?", (job_id,)).fetchone()
            u = c.execute("SELECT channel, chat_ref, tester_no FROM users WHERE id=?", (j["user_id"],)).fetchone()
        ch = self.svc.channels.get(u["channel"]) if u else None
        if ch is None:
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE coach_jobs SET state='failed', outcome=COALESCE(outcome,'')||':no_channel' WHERE id=?", (job_id,))
            return False
        body, chips = validator.split_chips(j["reply"])
        rich = bool(getattr(ch, "supports_html", False)) and j["kind"] != "safety" and j["reply_source"] in ("llm", "template")
        parts = split_text(body)
        done = j["parts_sent"]
        placeholder = self._placeholders.get(job_id)
        try:
            for i in range(done, len(parts)):
                text = validator.render_html(parts[i]) if rich else (
                    validator.plain(parts[i]) if j["reply_source"] == "llm" else parts[i])
                kw: dict[str, Any] = {}
                if rich:
                    kw["html"] = True
                    if chips and i == len(parts) - 1:
                        kw["buttons"] = self._chip_rows(job_id, chips)
                if i == 0 and placeholder:   # the answer replaces the "on it" line
                    try:
                        ch.edit_text(u["chat_ref"], placeholder, text, **kw)
                        placeholder, done = None, 1
                        self._placeholders.pop(job_id, None)
                        continue
                    except (ChannelError, AttributeError):
                        placeholder = None
                ch.send_text(u["chat_ref"], text, **kw)
                done = i + 1
        except ChannelError as e:
            failed = j["send_attempts"] + 1 >= MAX_SEND_ATTEMPTS
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE coach_jobs SET parts_sent=?, send_attempts=send_attempts+1, state=? WHERE id=? AND state='sending'",
                          (done, "failed" if failed else "replied", job_id))
                if failed and j["kind"] == "safety":   # a safety reply that never arrived: a person has to follow up
                    t = tag(u["tester_no"])
                    add_alert(c, f"coach-safety-send:{job_id}", f"Run Supreme coach: safety reply to {t} NOT delivered",
                              f"The fixed safety reply to {t} failed {MAX_SEND_ATTEMPTS} times (Telegram). Contact them directly.",
                              now_utc())
            log.warning("coach send failed job=%s: %s", job_id, type(e).__name__)
            return False
        self._placeholders.pop(job_id, None)
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE coach_jobs SET state='sent', sent_at=?, parts_sent=?, reply=NULL WHERE id=? AND state='sending'",
                      (iso(now_utc()), done, job_id))
        return True

    # ------------------------------------------------------------------------------------------ worker
    def run_forever(self, stop: threading.Event) -> None:
        self.recover(now_utc())
        while not stop.is_set():
            try:
                busy = self.step(now_utc())
            except Exception as e:   # keep the worker alive; the job stays in the table
                log.error("coach step failed: %s", type(e).__name__)
                busy = False
            if not busy:
                self.wake.wait(1.0)
                self.wake.clear()

    def drain(self, now: datetime, limit: int = 20) -> int:
        """Run steps until there is nothing to do (tests and the CLI)."""
        n = 0
        while n < limit and self.step(now):
            n += 1
        return n

    def recover(self, now: datetime, stale_only: bool = False) -> int:
        """A job left 'running' (a restart, or a crash in the worker) gets one more try, then the template (B3). With
        stale_only, only jobs claimed longer ago than the job deadline + 30 s (the worker calls this every step, review of
        #341 P2-2). A send left 'sending' goes back to 'replied'. Stale reservations go. -> jobs touched."""
        cut = iso(now - timedelta(seconds=self.s.coach_job_deadline_s + STALE_GRACE_S)) if stale_only else iso(now + timedelta(days=1))
        n = 0
        with db.tx(self.s.db_path) as c:
            budget.release_stale(c, now)
            n += c.execute("UPDATE coach_jobs SET state='replied' WHERE state='sending' AND COALESCE(sending_at, '') < ?", (cut,)).rowcount
            for j in c.execute("SELECT id, user_id, attempts FROM coach_jobs WHERE state='running' AND kind<>'briefing' AND COALESCE(claimed_at, '') < ?",
                               (cut,)).fetchall():
                n += 1
                if j["attempts"] >= 2:
                    c.execute("UPDATE coach_jobs SET state='replied', reply=?, reply_source='template', outcome='recovered', "
                              "replied_at=? WHERE id=?", (FALLBACK, iso(now), j["id"]))
                    self._message(c, j["user_id"], j["id"], "coach", FALLBACK, now)
                else:
                    c.execute("UPDATE coach_jobs SET state='pending', claimed_at=NULL WHERE id=?", (j["id"],))
                    c.execute("UPDATE coach_jobs SET state='pending', merged_into=NULL WHERE merged_into=? AND state='merged'",
                              (j["id"],))
        if not stale_only:
            n += self.briefing.recover(now + timedelta(days=1))
        return n

    def step(self, now: datetime) -> bool:
        """One unit of work. True when something was done (send, claim, cancel or a stuck job recovered)."""
        if self.recover(now, stale_only=True):
            return True
        with db.ro(self.s.db_path) as c:
            unsent = c.execute("SELECT id, send_attempts, replied_at FROM coach_jobs WHERE state='replied' AND send_attempts < ? "
                               "ORDER BY id LIMIT 20", (MAX_SEND_ATTEMPTS,)).fetchall()
        for j in unsent:   # a failed send waits 30 s more for each failure so far
            if parse_iso(j["replied_at"]) + timedelta(seconds=SEND_BACKOFF_S * j["send_attempts"]) <= now:
                if self.send_job(j["id"]):
                    return True
                break
        return self._claim_and_run(now) or self.briefing.step(now)

    def _claim_and_run(self, now: datetime) -> bool:
        claimed = self._claim(now)
        if claimed is None:
            return False
        if claimed is True:
            return True
        try:
            with self._heartbeat(claimed.user_id):
                self._run(claimed, now)
        except Exception as e:   # never leave a claimed job hanging: the runner gets the template (review of #341, P2-2)
            log.error("coach run failed job=%s: %s", claimed.job_id, type(e).__name__)
            with db.tx(self.s.db_path) as c:
                if c.execute("SELECT 1 FROM coach_jobs WHERE id=? AND state='running'", (claimed.job_id,)).fetchone():
                    self._reply_now(c, claimed.user_id, claimed.job_id, FALLBACK, f"error:{type(e).__name__}", now)
            if claimed.ledger_id is not None:
                with contextlib.suppress(Exception):
                    self._settle(claimed.ledger_id, now, None, "error", None)
            self.send_job(claimed.job_id)
        return True

    def _claim(self, now: datetime) -> Claimed | bool | None:
        merge_cut = iso(now - timedelta(seconds=self.s.coach_merge_s))
        with db.tx(self.s.db_path) as c:
            budget.release_stale(c, now)
            row = c.execute("SELECT user_id, MIN(id) AS first, MAX(created_at) AS newest FROM coach_jobs "
                            "WHERE state='pending' AND kind='chat' GROUP BY user_id HAVING newest <= ? ORDER BY first LIMIT 1",
                            (merge_cut,)).fetchone()
            if not row:
                return None
            uid = row["user_id"]
            batch = [r["id"] for r in c.execute("SELECT id FROM coach_jobs WHERE user_id=? AND state='pending' AND kind='chat' "
                                                "ORDER BY id", (uid,))]
            primary = batch[-1]
            marks = ",".join("?" * len(batch))
            why = self.gate(c, uid)
            if why is not None:   # consent withdrawn, paused or flag off since it was queued: no model, no reply
                c.execute(f"UPDATE coach_jobs SET state='cancelled', outcome=? WHERE id IN ({marks})", (why, *batch))
                log.info("coach jobs cancelled user=%s reason=%s", uid, why)
                return True
            c.execute(f"UPDATE coach_jobs SET state='merged', merged_into=? WHERE id IN ({marks}) AND id<>?",
                      (primary, *batch, primary))
            c.execute("UPDATE coach_jobs SET state='running', claimed_at=?, attempts=attempts+1, prompt_hash=? WHERE id=?",
                      (iso(now), self.prompt.prompt_hash if self.prompt else None, primary))
            u = dict(c.execute("SELECT id, tester_no, zone_id FROM users WHERE id=?", (uid,)).fetchone())
            texts = [r["text"] for r in c.execute(
                f"SELECT text FROM coach_messages WHERE user_id=? AND role='runner' AND job_id IN ({marks}) ORDER BY id",
                (uid, *batch))]
            # Earlier turns, without the red-flag turns: those were answered by the fixed template and are not coaching
            # context the model should build on (review of #341, P3).
            history = alternate([{"role": "user" if r["role"] == "runner" else "assistant", "content": r["text"]}
                                 for r in reversed(c.execute(
                                     "SELECT m.role, m.text FROM coach_messages m LEFT JOIN coach_jobs j ON j.id = m.job_id "
                                     f"WHERE m.user_id=? AND (m.job_id IS NULL OR m.job_id NOT IN ({marks})) "
                                     "AND COALESCE(j.kind, 'chat') <> 'safety' AND COALESCE(j.reply_source, '') <> 'safety' "
                                     "ORDER BY m.id DESC LIMIT ?", (uid, *batch, self.s.coach_history)).fetchall())])
            message = "\n".join(texts)
            if message and history and history[-1]["role"] == "user":   # earlier words that never got an answer lead in
                message = history.pop()["content"] + "\n" + message
            message = message[-MAX_BATCH_CHARS:]
            if not message:
                self._reply_now(c, uid, primary, FALLBACK, "no_text", now)
                return True
            # The rail again, on the merged turn: "I want to" + "die" or "chest" + "pain on the hill" sent as two messages
            # each pass alone (review of #341, P1-2). Before the caps, like the inbound rail.
            level, kind = redflag.tier(message)
            if level == redflag.HARD:
                self._safety_now(c, u, primary, kind, kind, now, "merged turn")
                return True
            soft_kind = kind if level == redflag.SOFT else None
            over = None
            chars = len(self.prompt.text if self.prompt else "") + sum(len(h["content"]) for h in history) + len(message)
            if budget.daily_msgs(c, uid, now, u["zone_id"]) > self.s.coach_daily_msgs:
                over = (DAILY_CAP, "daily_cap")
            else:
                ledger_id, why = budget.reserve(c, self.s, uid, primary, budget.estimate(self.s, chars, first=True), now,
                                                self.prompt.prompt_hash if self.prompt else None, u["zone_id"])
                if ledger_id is None:
                    over = (BUDGET if why == "month_cap" else DAILY_CAP, why)
            if over:
                if soft_kind:   # no classifier over the caps: an ambiguous red flag fails towards the safety reply
                    self._safety_now(c, u, primary, soft_kind, f"soft:{soft_kind}:{over[1]}", now, "soft hit over cap")
                else:
                    self._reply_now(c, uid, primary, over[0], over[1], now)
                return True
        return Claimed(primary, uid, batch, ledger_id, chars, history, message, soft_kind, u["zone_id"] or "UTC")

    def _safety_now(self, c, u: dict, job_id: int, kind: str, outcome: str, now: datetime, where: str) -> None:
        """The fixed safety reply on this job (no model), the flag and the deduped alert, in the caller's transaction."""
        reply = redflag.template(kind, u["zone_id"])
        c.execute("UPDATE coach_jobs SET kind='safety', state='replied', reply=?, reply_source='safety', outcome=?, "
                  "replied_at=? WHERE id=?", (reply, outcome, iso(now), job_id))
        self._message(c, u["id"], job_id, "coach", reply, now)
        self._flag(c, u, kind, now)
        log.warning("coach red flag (%s) kind=%s tester=%s job=%s", where, kind, tag(u["tester_no"]), job_id)

    def _reply_now(self, c, uid: str, job_id: int, text: str, outcome: str, now: datetime) -> None:
        c.execute("UPDATE coach_jobs SET state='replied', reply=?, reply_source='template', outcome=?, replied_at=? WHERE id=?",
                  (text, outcome, iso(now), job_id))
        self._message(c, uid, job_id, "coach", text, now)

    def _screen(self, job: Claimed, now: datetime) -> tuple[str, str | None]:
        """The classifier on the merged turn. -> ("hit", kind) | ("clear", None or "injury") | ("error", why)."""
        if not self.s.openrouter_key:
            return "error", "no_key"
        with db.tx(self.s.db_path) as c:
            ledger_id, why = budget.reserve(c, self.s, job.user_id, job.job_id, budget.screen_estimate(self.s, len(job.message)),
                                            now, None, job.zone_id, purpose="screen")
        if ledger_id is None:
            return "error", why
        body = screen.request_body(self.s.coach_screen_model, job.message, self.s.coach_screen_max_tokens)
        data, why = screen.call(self.svc.http, self.s.openrouter_url, self.s.openrouter_key, body, self.s.coach_screen_timeout_s)
        if data is None:
            self._settle(ledger_id, now, None, why, None)
            return "error", why
        provider = data.get("provider") if isinstance(data.get("provider"), str) else None
        self._settle(ledger_id, now, provider, "ok", budget.usage_fields(data.get("usage"), self.s))
        verdict = screen.parse(data)
        if verdict is None:
            return "error", "bad_output"
        if verdict[screen.SELF_HARM]:
            return "hit", redflag.WELLBEING
        if verdict[screen.URGENT_MEDICAL]:
            return "hit", redflag.URGENT
        if verdict[screen.INJURY]:
            log.info("coach screen job=%s injury=true (the coach model handles injury triage)", job.job_id)
            return "clear", "injury"   # stored on the job (coach_jobs.screen = "clear:injury"): the briefing reads it for 7 days
        return "clear", None

    def _screen_alert(self, c, now: datetime) -> None:
        r = c.execute("SELECT COUNT(*) AS n, SUM(screen LIKE 'error:%') AS e FROM coach_jobs WHERE screen IS NOT NULL "
                      "AND claimed_at >= ?", (iso(now - timedelta(hours=24)),)).fetchone()
        n, e = r["n"] or 0, r["e"] or 0
        if n >= SCREEN_ALERT_MIN_JOBS and e / n > SCREEN_ALERT_SHARE:
            add_alert(c, f"coach-screen-errors:{now.strftime('%Y-%m-%d')}", "Run Supreme coach: safety classifier failing",
                      f"{e} of {n} safety classifier calls in the last 24 hours failed (timeout or error). Turns with an "
                      "ambiguous red flag got the safety reply; the rest went to the main model on its own safety rules.", now)

    def _run(self, job: Claimed, now: datetime) -> None:
        result, detail = self._screen(job, now)
        screen_note = {"hit": f"hit:{detail}", "clear": f"clear:{detail}" if detail else "clear"}.get(result, f"error:{detail}")
        kind = detail if result == "hit" else (job.soft_kind if result == "error" else None)
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE coach_jobs SET screen=? WHERE id=?", (screen_note, job.job_id))
            self._screen_alert(c, now)
            if kind:
                u = c.execute("SELECT id, tester_no, zone_id FROM users WHERE id=?", (job.user_id,)).fetchone()
                j = c.execute("SELECT state FROM coach_jobs WHERE id=?", (job.job_id,)).fetchone()
                if u and j and j["state"] == "running":
                    why = f"screen:{kind}" if result == "hit" else f"soft:{kind}:screen_{detail}"
                    self._safety_now(c, dict(u), job.job_id, kind, why, now,
                                     "classifier" if result == "hit" else "soft hit, classifier failed")
        if kind:
            self._settle(job.ledger_id, now, None, "safety", None)   # the main call never happens
            self.send_job(job.job_id)
            return
        if result == "error":
            log.warning("coach screen failed job=%s why=%s: no regex hit, going on to the main model", job.job_id, detail)
        t0 = time.monotonic()
        res = self._agent(job, now)
        outcome, source = res.outcome, "llm"
        if res.reply is not None:
            body = res.reply
            if self._show_cost(job.user_id):
                body += f"\n\n<i>· {res.cost_usd * 100:.1f}¢ · {res.calls} call{'s' if res.calls != 1 else ''} · {time.monotonic() - t0:.0f} s</i>"
            reply = validator.with_chips(body, res.chips)
        else:
            reply, source = FALLBACK, "template"
        with db.tx(self.s.db_path) as c:
            # B8: a DELETE or a withdrawal while the model was thinking wins; nothing is written back for a runner who is gone
            j = c.execute("SELECT state FROM coach_jobs WHERE id=?", (job.job_id,)).fetchone()
            if not j or j["state"] != "running" or not c.execute("SELECT 1 FROM users WHERE id=?", (job.user_id,)).fetchone():
                log.info("coach job=%s dropped: runner deleted or job cancelled", job.job_id)
                return
            c.execute("UPDATE coach_jobs SET state='replied', reply=?, reply_source=?, outcome=?, replied_at=? WHERE id=?",
                      (reply, source, outcome, iso(now), job.job_id))
            self._message(c, job.user_id, job.job_id, "coach", reply, now)
            self._fallback_alert(c, now)
        log.info("coach job=%s source=%s outcome=%s", job.job_id, source, outcome)
        self.send_job(job.job_id)

    def _fallback_alert(self, c, now: datetime) -> None:
        since = iso(now - timedelta(hours=24))
        caps = ",".join("?" * len(CAP_OUTCOMES))
        r = c.execute(f"SELECT COUNT(*) AS n, SUM(reply_source='template') AS t FROM coach_jobs WHERE kind='chat' "
                      f"AND replied_at>=? AND reply_source IN ('llm','template') AND COALESCE(outcome,'') NOT IN ({caps})",
                      (since, *CAP_OUTCOMES)).fetchone()
        n, t = r["n"] or 0, r["t"] or 0
        if n >= FALLBACK_ALERT_MIN_JOBS and t / n > FALLBACK_ALERT_SHARE:
            add_alert(c, f"coach-fallback:{now.strftime('%Y-%m-%d')}", "Run Supreme coach: chat fallback rate high",
                      f"{t} of {n} coach chat replies in the last 24 hours fell back to the template "
                      "(model error, timeout or the validator). See coach_jobs.outcome.", now)

    # ------------------------------------------------------------------------------------------ agent loop
    def _ref_for(self, uid: str) -> tuple[Any, str] | None:
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT channel, chat_ref FROM users WHERE id=?", (uid,)).fetchone()
        if not u or u["channel"] not in self.svc.channels:
            return None
        return self.svc.channels[u["channel"]], u["chat_ref"]

    def request_body(self, messages: list[dict], final: bool) -> dict:
        assert self.prompt is not None
        body: dict[str, Any] = {
            "model": self.s.coach_model,
            "messages": messages,
            "tools": [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                        "parameters": t["input_schema"]}} for t in self.prompt.tools],
            "tool_choice": "none" if final else "auto",
            # Zero data retention, no training, and no silent hop to another provider (W4). No `order`: the ZDR endpoints
            # for Sonnet 5.5 are Google and Bedrock, not Anthropic first-party.
            "provider": {"zdr": True, "data_collection": "deny", "allow_fallbacks": False, "require_parameters": True},
            "max_tokens": self.s.coach_max_tokens,
            # Sonnet 5.5 refuses "thinking off" (HTTP 400 "Reasoning is mandatory", 20-Oct). Low effort keeps it short;
            # it still counts against max_tokens, hence the 2000 default. `exclude`: the thinking text is not sent back.
            "reasoning": {"effort": "low", "exclude": True},
            # No temperature: Sonnet 5.5 endpoints do not list it, and with require_parameters OpenRouter then has no
            # endpoint at all (HTTP 404, the first live message on 20-Oct).
            "usage": {"include": True},
        }
        return body

    def system_message(self) -> dict:
        assert self.prompt is not None
        # The static skill prefix carries cache_control so repeat turns read it from the provider's cache (W5).
        return {"role": "system", "content": [{"type": "text", "text": self.prompt.text, "cache_control": {"type": "ephemeral"}}]}

    def _show_cost(self, uid: str) -> bool:
        if not self.s.coach_show_cost:
            return False
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT id, tester_no, channel, chat_ref FROM users WHERE id=?", (uid,)).fetchone()
        return bool(u) and self.allowlisted(u, self.s.coach_show_cost)

    @staticmethod
    def host_note(reason: str) -> str:
        code, _, detail = reason.partition(":")
        hint = REPAIR_HINTS.get(code, "it did not pass the server's checks").format(detail=detail)
        return f"<host_note>Your reply was not sent: {hint}. Write the reply again.</host_note>"

    def _agent(self, job: Claimed, now: datetime) -> "AgentResult":
        """The model loop: tool turns, then a checked reply. A reply the validator refuses goes back to the model once with
        the reason (repair turn); a second miss is the template."""
        sources = [job.message] + [h["content"] for h in job.history]
        res = AgentResult(None, [], "ok", sources)
        if not self.s.openrouter_key or self.prompt is None:
            self._settle(job.ledger_id, now, None, "no_key", None)
            res.outcome = "no_key"
            return res
        out = self._ref_for(job.user_id)
        ch, ref = out if out else (None, "")
        tools = ReadTools(self.svc, self.prompt.tools, job.user_id, now)
        registry = self.prompt.registry
        ctx = ToolContext(self.svc, job.user_id, now, job.job_id,
                          placeholder=(lambda text: self._send_placeholder(job, ch, ref, text)) if ch is not None else (lambda text: None))
        history = [dict(h) for h in job.history]
        if history:   # second cache breakpoint: the earlier conversation is read from cache on the next turn
            last = history[-1]
            history[-1] = {"role": last["role"], "content": [{"type": "text", "text": last["content"],
                                                               "cache_control": {"type": "ephemeral"}}]}
        turn_text = job.message
        extra = registry.context(ctx)
        if extra:
            sources.append(extra)
            turn_text = extra + "\n\n" + turn_text
        messages: list[dict] = [self.system_message(), *history, {"role": "user", "content": turn_text}]
        base = len(messages)
        deadline = time.monotonic() + self.s.coach_job_deadline_s
        ledger_id: int | None = job.ledger_id
        tool_turn, repairs = 0, 0
        for _ in range(self.s.coach_max_tool_turns + 1 + self.s.coach_repair_turns):
            final = tool_turn >= self.s.coach_max_tool_turns
            if ledger_id is None:
                with db.tx(self.s.db_path) as c:
                    chars = job.chars + sum(len(json.dumps(m)) for m in messages[base:])
                    zone = (c.execute("SELECT zone_id FROM users WHERE id=?", (job.user_id,)).fetchone() or {"zone_id": "UTC"})["zone_id"]
                    ledger_id, why = budget.reserve(c, self.s, job.user_id, job.job_id, budget.estimate(self.s, chars),
                                                    now, self.prompt.prompt_hash, zone)
                if ledger_id is None:
                    res.outcome = why
                    return res
            remaining = deadline - time.monotonic()
            if remaining < 1.0:
                self._settle(ledger_id, now, None, "deadline", None)
                res.outcome = "deadline"
                return res
            data, why = self._post(self.request_body(messages, final), min(self.s.coach_turn_timeout_s, remaining))
            if data is None:
                self._settle(ledger_id, now, None, why, None)
                res.outcome = why
                return res
            provider = data.get("provider") if isinstance(data.get("provider"), str) else None
            fields = budget.usage_fields(data.get("usage"), self.s)
            self._settle(ledger_id, now, provider, "ok", fields)
            ledger_id = None
            res.calls += 1
            res.cost_usd += fields["cost_usd"] or 0.0
            log.info("coach call job=%s turn=%d provider=%s prompt_tokens=%s cached_tokens=%s cache_write=%s cost=%.5f",
                     job.job_id, res.calls - 1, provider, fields["prompt_tokens"], fields["cached_tokens"],
                     fields["cache_write_tokens"], fields["cost_usd"])
            try:
                msg = data["choices"][0]["message"]
                if not isinstance(msg, dict):
                    raise TypeError("message")
            except (KeyError, IndexError, TypeError):
                res.outcome = "bad_response"
                return res
            calls = msg.get("tool_calls") or []
            if not isinstance(calls, list):
                calls = []
            if calls and not final:
                tool_turn += 1
                calls = [x if isinstance(x, dict) else {} for x in calls]   # odd shapes from the provider never raise
                messages.append({"role": "assistant", "content": msg.get("content") or None, "tool_calls": calls})
                for k, call in enumerate(calls):
                    call_id = str(call.get("id") or f"call_{k}")
                    if k >= MAX_TOOL_CALLS_PER_TURN:
                        messages.append({"role": "tool", "tool_call_id": call_id,
                                         "content": json.dumps({"ok": False, "error": "too many tool calls in one turn"})})
                        continue
                    fn = call.get("function") if isinstance(call.get("function"), dict) else {}
                    name = str(fn.get("name", ""))
                    result = registry.call(name, fn.get("arguments"), ctx) if registry.has(name) else tools.call(name, fn.get("arguments"))
                    enc = tools.encode(result)
                    sources.append(enc)
                    messages.append({"role": "tool", "tool_call_id": call_id, "content": enc})
                continue
            content = msg.get("content")
            if isinstance(content, list):
                content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
            if not isinstance(content, str) or not content.strip():
                res.outcome = "tool_loop" if final else "empty"
                return res
            body, chips = validator.split_chips(validator.tidy(content))
            bad = validator.check(body, sources)
            if bad is None:
                res.reply, res.outcome = body, "repaired" if repairs else "ok"
                res.chips = [c for c in chips if validator.check(c, sources) is None]
                return res
            res.outcome = f"rejected:{bad.split(':')[0]}"
            if repairs >= self.s.coach_repair_turns:
                return res
            repairs += 1   # the refused reply and the reason go back; the reason is never added to `sources`
            messages += [{"role": "assistant", "content": content}, {"role": "user", "content": self.host_note(bad)}]
        res.outcome = "tool_loop"
        return res

    def _settle(self, ledger_id: int | None, now: datetime, provider: str | None, outcome: str, fields: dict | None) -> None:
        if ledger_id is None:
            return
        with db.tx(self.s.db_path) as c:
            budget.settle(c, self.s, ledger_id, now, provider=provider, outcome=outcome, fields=fields)

    def _post(self, body: dict, timeout: float) -> tuple[dict | None, str]:
        """One call; one retry on 429/5xx while time remains. Never retried on a timeout (the job deadline wins)."""
        last = "error"
        start = time.monotonic()
        for _attempt in (0, 1):
            left = timeout - (time.monotonic() - start)
            if left < 1.0:
                break
            try:
                r = self.svc.http.post(f"{self.s.openrouter_url}/chat/completions",
                                       headers={"Authorization": f"Bearer {self.s.openrouter_key}", "X-Title": "Run Supreme coach"},
                                       json=body, timeout=left)
            except httpx.TimeoutException:
                return None, "timeout"
            except httpx.HTTPError:
                last = "transport"
                continue
            if r.status_code == 429 or r.status_code >= 500:
                last = f"http_{r.status_code}"
                continue
            if r.status_code != 200:
                log.warning("coach openrouter http_%s: %s", r.status_code, error_reason(r))
                return None, f"http_{r.status_code}"
            try:
                data = r.json()
            except ValueError:
                return None, "bad_json"
            return (data, "") if isinstance(data, dict) else (None, "bad_json")
        return None, last


def error_reason(r: httpx.Response) -> str:
    """OpenRouter's error message for a refused call, cut to 300 chars, for the log. The 400 and 404 on the first live
    messages (20-Oct) were undiagnosable from the status alone. It names a parameter or schema problem; never the
    request body, the key or the runner's text."""
    try:
        err = r.json().get("error") or {}
        meta = err.get("metadata") or {}
        why = f"{err.get('message', '')} | provider={meta.get('provider_name', '')} | raw={meta.get('raw', '')}"
    except (ValueError, AttributeError):
        why = "(no JSON body)"
    return " ".join(str(why).split())[:300]


def active_flags(c, uid: str) -> list[str]:
    return [r["kind"] for r in c.execute("SELECT kind FROM health_flags WHERE user_id=? AND state='active'", (uid,))]


def clear_flag(c, uid: str, kind: str, by: str, now: datetime) -> bool:
    return c.execute("UPDATE health_flags SET state='cleared', cleared_at=?, cleared_by=? WHERE user_id=? AND kind=? "
                     "AND state='active'", (iso(now), by, uid, kind)).rowcount == 1


