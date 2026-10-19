"""Coach chat (C1): free text from a gated runner -> a Sonnet agent loop with read tools -> checked reply.

Flow (eng-review section 2):
  handle_inbound (sync, no model call)
    gate: COMPANION_COACH_CHAT, allowlist, consent >= coach_consent_required, not paused, not ops-paused   (B1)
    red-flag check -> fixed safety template, health flag, deduped alert, no model                        (B6)
    else one transaction: inbound_seen + coach_jobs (UNIQUE msg_mac) + the runner's words                 (B3)
  one worker thread (persisted jobs survive a restart)                                                    (B2)
    claim: per runner, messages within coach_merge_s answered as one turn; gate re-checked; daily caps;
           first spend reservation in the claim transaction                                              (B9)
    agent: <= coach_max_tool_turns tool turns, 30 s per model call, 60 s per job, max_tokens 600
    chat validator -> template fallback on failure (counted, alert above 20% in 24 h)                     (B7)
    reply stored on the job before the send; a failed send retries the send only                         (B3)
"""
from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

import httpx

from .. import db
from ..channels import ChannelError, utf16_len
from ..notes import clean as clean_text
from ..rails import add_alert, tag
from ..timeutil import iso, now_utc, parse_iso
from . import budget, prompt as coach_prompt, redflag, validator
from .tools import ReadTools

log = logging.getLogger("companion")

COACH_PAUSED = "You're paused, so the coach chat is off too. Send RESUME to turn it back on."
FALLBACK = "Sorry, I couldn't put a proper answer together just now. Give me another go in a bit."
DAILY_CAP = "That's all the chat I've got in me today. Ask me again tomorrow; your run cards still come as normal."
BUDGET = "The coach chat is resting for now. Your run cards still come as normal."
MAX_CHAT_CHARS = 2000
MAX_SEND_ATTEMPTS = 5
SEND_BACKOFF_S = 30
MAX_TOOL_CALLS_PER_TURN = 8
TG_LIMIT = 4096
TYPING_EVERY_S = 4.0
FALLBACK_ALERT_SHARE = 0.2
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


class CoachChat:
    def __init__(self, svc: Any):
        self.svc, self.s = svc, svc.s
        self.prompt: coach_prompt.CoachPrompt | None = None
        self.wake = threading.Event()
        self._last_typing: dict[str, float] = {}
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
    def allowlisted(self, u: Any) -> bool:
        a = self.s.coach_allowlist
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

    def note_flag(self, user: dict, note_text: str, now: datetime) -> str | None:
        """A typed run note from a gated runner goes through the same red-flag check. -> the safety reply, or None."""
        kind = redflag.detect(note_text)
        if not kind or self.gate_for(user["id"]) is not None:
            return None
        with db.tx(self.s.db_path) as c:
            self._flag(c, user, kind, now)
        log.warning("coach red flag in a note kind=%s tester=%s", kind, tag(user.get("tester_no")))
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
        c.execute("INSERT INTO coach_messages (user_id, job_id, role, text, ts) VALUES (?,?,?,?,?)",
                  (uid, job_id, role, text, iso(now)))

    def withdraw(self, c, uid: str) -> None:
        """Consent dropped below the coach version (W6): the chat history goes and nothing queued is answered."""
        c.execute("DELETE FROM coach_messages WHERE user_id=?", (uid,))
        c.execute("UPDATE coach_jobs SET state='cancelled', outcome='withdrawn', reply=NULL "
                  "WHERE user_id=? AND state IN ('pending','running','merged')", (uid,))

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

    def send_job(self, job_id: int) -> bool:
        """Send a stored reply as plain text, split at 4096. A failure is retried later by the worker, the send only."""
        with db.ro(self.s.db_path) as c:
            j = c.execute("SELECT * FROM coach_jobs WHERE id=?", (job_id,)).fetchone()
            u = c.execute("SELECT channel, chat_ref FROM users WHERE id=?", (j["user_id"],)).fetchone() if j else None
        if not j or not u or j["state"] != "replied" or not j["reply"]:
            return False
        ch = self.svc.channels.get(u["channel"])
        if ch is None:
            return False
        parts = split_text(j["reply"])
        done = j["parts_sent"]
        try:
            for i in range(done, len(parts)):
                ch.send_text(u["chat_ref"], parts[i])
                done = i + 1
        except ChannelError as e:
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE coach_jobs SET parts_sent=?, send_attempts=send_attempts+1, "
                          "state=CASE WHEN send_attempts+1 >= ? THEN 'failed' ELSE state END WHERE id=? AND state='replied'",
                          (done, MAX_SEND_ATTEMPTS, job_id))
            log.warning("coach send failed job=%s: %s", job_id, type(e).__name__)
            return False
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE coach_jobs SET state='sent', sent_at=?, parts_sent=? WHERE id=? AND state='replied'",
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

    def recover(self, now: datetime) -> None:
        """After a restart: a job left 'running' gets one more try, then the template (B3). Stale reservations go."""
        with db.tx(self.s.db_path) as c:
            budget.release_stale(c, now)
            for j in c.execute("SELECT id, user_id, attempts FROM coach_jobs WHERE state='running'").fetchall():
                if j["attempts"] >= 2:
                    c.execute("UPDATE coach_jobs SET state='replied', reply=?, reply_source='template', outcome='recovered', "
                              "replied_at=? WHERE id=?", (FALLBACK, iso(now), j["id"]))
                    self._message(c, j["user_id"], j["id"], "coach", FALLBACK, now)
                else:
                    c.execute("UPDATE coach_jobs SET state='pending', claimed_at=NULL WHERE id=?", (j["id"],))
                    c.execute("UPDATE coach_jobs SET state='pending', merged_into=NULL WHERE merged_into=? AND state='merged'",
                              (j["id"],))

    def step(self, now: datetime) -> bool:
        """One unit of work. True when something was done (send, claim or cancel)."""
        with db.ro(self.s.db_path) as c:
            unsent = c.execute("SELECT id, send_attempts, replied_at FROM coach_jobs WHERE state='replied' AND send_attempts < ? "
                               "ORDER BY id LIMIT 20", (MAX_SEND_ATTEMPTS,)).fetchall()
        for j in unsent:   # a failed send waits 30 s more for each failure so far
            if parse_iso(j["replied_at"]) + timedelta(seconds=SEND_BACKOFF_S * j["send_attempts"]) <= now:
                if self.send_job(j["id"]):
                    return True
                break
        return self._claim_and_run(now)

    def _claim_and_run(self, now: datetime) -> bool:
        claimed = self._claim(now)
        if claimed is None:
            return False
        if claimed is True:
            return True
        self._run(claimed, now)
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
            if budget.daily_msgs(c, uid, now) > self.s.coach_daily_msgs:
                self._reply_now(c, uid, primary, DAILY_CAP, "daily_cap", now)
                return True
            texts = [r["text"] for r in c.execute(
                f"SELECT text FROM coach_messages WHERE user_id=? AND role='runner' AND job_id IN ({marks}) ORDER BY id",
                (uid, *batch))]
            history = alternate([{"role": "user" if r["role"] == "runner" else "assistant", "content": r["text"]}
                                 for r in reversed(c.execute(
                                     f"SELECT role, text FROM coach_messages WHERE user_id=? AND (job_id IS NULL OR job_id NOT IN ({marks})) "
                                     "ORDER BY id DESC LIMIT ?", (uid, *batch, self.s.coach_history)).fetchall())])
            message = "\n".join(texts)
            if message and history and history[-1]["role"] == "user":   # earlier words that never got an answer lead in
                message = history.pop()["content"] + "\n" + message
            if not message:
                self._reply_now(c, uid, primary, FALLBACK, "no_text", now)
                return True
            chars = len(self.prompt.text if self.prompt else "") + sum(len(h["content"]) for h in history) + len(message)
            ledger_id, why = budget.reserve(c, self.s, uid, primary, budget.estimate(self.s, chars), now,
                                            self.prompt.prompt_hash if self.prompt else None)
            if ledger_id is None:
                self._reply_now(c, uid, primary, BUDGET if why == "month_cap" else DAILY_CAP, why, now)
                return True
        return Claimed(primary, uid, batch, ledger_id, chars, history, message)

    def _reply_now(self, c, uid: str, job_id: int, text: str, outcome: str, now: datetime) -> None:
        c.execute("UPDATE coach_jobs SET state='replied', reply=?, reply_source='template', outcome=?, replied_at=? WHERE id=?",
                  (text, outcome, iso(now), job_id))
        self._message(c, uid, job_id, "coach", text, now)

    def _run(self, job: Claimed, now: datetime) -> None:
        reply, outcome, sources = self._agent(job, now)
        source = "llm"
        if reply is not None:
            reply = validator.tidy(reply)
            bad = validator.check(reply, sources)
            if bad:
                outcome, reply = f"rejected:{bad.split(':')[0]}", None
        if reply is None:
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
            "temperature": 0.5,
            "usage": {"include": True},
        }
        return body

    def system_message(self) -> dict:
        assert self.prompt is not None
        # The static skill prefix carries cache_control so repeat turns read it from the provider's cache (W5).
        return {"role": "system", "content": [{"type": "text", "text": self.prompt.text, "cache_control": {"type": "ephemeral"}}]}

    def _agent(self, job: Claimed, now: datetime) -> tuple[str | None, str, list[str]]:
        """-> (reply text or None, outcome, the texts whose numbers the reply may use)."""
        sources = [job.message] + [h["content"] for h in job.history]
        if not self.s.openrouter_key or self.prompt is None:
            self._settle(job.ledger_id, now, None, "no_key", None)
            return None, "no_key", sources
        out = self._ref_for(job.user_id)
        ch, ref = out if out else (None, "")
        tools = ReadTools(self.svc, self.prompt.tools, job.user_id, now)
        messages: list[dict] = [self.system_message(), *job.history, {"role": "user", "content": job.message}]
        deadline = time.monotonic() + self.s.coach_job_deadline_s
        ledger_id: int | None = job.ledger_id
        for turn in range(self.s.coach_max_tool_turns + 1):
            final = turn == self.s.coach_max_tool_turns
            if ledger_id is None:
                with db.tx(self.s.db_path) as c:
                    chars = job.chars + sum(len(json.dumps(m)) for m in messages[2 + len(job.history):])
                    ledger_id, why = budget.reserve(c, self.s, job.user_id, job.job_id, budget.estimate(self.s, chars),
                                                    now, self.prompt.prompt_hash)
                if ledger_id is None:
                    return None, why, sources
            remaining = deadline - time.monotonic()
            if remaining < 1.0:
                self._settle(ledger_id, now, None, "deadline", None)
                return None, "deadline", sources
            if ch is not None:
                self._typing(ch, ref)
            data, why = self._post(self.request_body(messages, final), min(self.s.coach_turn_timeout_s, remaining))
            if data is None:
                self._settle(ledger_id, now, None, why, None)
                return None, why, sources
            provider = data.get("provider") if isinstance(data.get("provider"), str) else None
            fields = budget.usage_fields(data.get("usage"), self.s)
            self._settle(ledger_id, now, provider, "ok", fields)
            ledger_id = None
            log.info("coach call job=%s turn=%d provider=%s prompt_tokens=%s cached_tokens=%s cache_write=%s cost=%.5f",
                     job.job_id, turn, provider, fields["prompt_tokens"], fields["cached_tokens"],
                     fields["cache_write_tokens"], fields["cost_usd"])
            try:
                msg = data["choices"][0]["message"]
                if not isinstance(msg, dict):
                    raise TypeError("message")
            except (KeyError, IndexError, TypeError):
                return None, "bad_response", sources
            calls = msg.get("tool_calls") or []
            if calls and not final:
                messages.append({"role": "assistant", "content": msg.get("content") or None, "tool_calls": calls})
                for call in calls[:MAX_TOOL_CALLS_PER_TURN]:
                    fn = (call.get("function") or {}) if isinstance(call, dict) else {}
                    res = tools.call(str(fn.get("name", "")), fn.get("arguments"))
                    enc = tools.encode(res)
                    sources.append(enc)
                    messages.append({"role": "tool", "tool_call_id": str(call.get("id", "")), "content": enc})
                for call in calls[MAX_TOOL_CALLS_PER_TURN:]:
                    messages.append({"role": "tool", "tool_call_id": str(call.get("id", "")),
                                     "content": json.dumps({"ok": False, "error": "too many tool calls in one turn"})})
                continue
            content = msg.get("content")
            if isinstance(content, list):
                content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
            if not isinstance(content, str) or not content.strip():
                return None, "tool_loop" if final else "empty", sources
            return content, "ok", sources
        return None, "tool_loop", sources

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
                return None, f"http_{r.status_code}"
            try:
                data = r.json()
            except ValueError:
                return None, "bad_json"
            return (data, "") if isinstance(data, dict) else (None, "bad_json")
        return None, last


def active_flags(c, uid: str) -> list[str]:
    return [r["kind"] for r in c.execute("SELECT kind FROM health_flags WHERE user_id=? AND state='active'", (uid,))]


def clear_flag(c, uid: str, kind: str, by: str, now: datetime) -> bool:
    return c.execute("UPDATE health_flags SET state='cleared', cleared_at=?, cleared_by=? WHERE user_id=? AND kind=? "
                     "AND state='active'", (iso(now), by, uid, kind)).rowcount == 1


