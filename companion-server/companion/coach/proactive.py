"""The proactive coach (coach PR5): the coach starts the conversation, at most once a day per runner, only when it has a
reason. Five triggers, tried in this order:

  niggle   48 h after an amber or green triage ("how's the knee?"), within the next 48 h
  run      a run the app uploaded (real_upload, 1 km or more, not a race) that finished 10 min to 12 h ago: a short debrief with
           one observation and one line about the next session. A run in quiet hours waits for the next allowed tick, and is
           skipped once it is more than 12 h old
  race     a race the runner finished 2 to 36 h ago (a debrief opener)
  heat     the evening before a quality session whose hour is over the heat line (a heads-up)
  day      the runner's local morning (from 06:30, or the first minute after quiet hours, until noon): what today is in the plan
           or the coach week, and how the week is tracking. Skipped on a rest day that follows a run (the run debrief covers it).
           With no plan at all, a short "how is the week looking?", and only if they have not written to the coach for 3 days

It is not a second scheduler and not a second pipeline. A proactive message is a normal coach job (kind 'proactive' in
coach_jobs): the same model loop (`CoachChat._agent`: tools, validator, repair turn, ledger, caps), the same outbox (`send_job`,
chips, retry), the same gate (`CoachChat.gate`: flag, allowlist, consent, pause), the same quiet hours and kill switch as the
check-ins. What is new is only the decision "is there a reason, and is it allowed right now?".

Every one of these must hold, re-read from the database at the moment of enqueue (the last four again just before the send,
and before every retry of it):
  - COMPANION_COACH_PROACTIVE on, the runner on COMPANION_COACH_PROACTIVE_ALLOWLIST (empty = nobody) as well as the chat allowlist, and
    the chat gate passes (a paused or ops-paused runner never gets one);
  - the sends kill switch is off and it is not the runner's quiet hours;
  - nothing proactive was started for them today (local day), and no chat job is open or the runner wrote in the last 2 h;
  - no urgent / wellbeing / injury / ill health flag, and no red triage in the last 72 h (the redflag rail and triage window);
  - the heat heads-up is a training nudge: it also waits out `Briefings.blocked` (care windows, a recent injury word) and an
    amber triage in the last 72 h. The niggle check-back is not a training nudge, but runs in amber mode (the validator then
    refuses paces and push-on advice).

Idempotence is the job's msg_mac ("proactive:<trigger>:<user id>:<key>", UNIQUE, so one runner's trigger never blocks another's): a trigger fires once, even after a failed model call
(no retry: a stale "how's the knee" is worse than none). A failed model call sends nothing; the job is cancelled, never the
"couldn't answer" template. Logging: one line per decision with the tester tag, trigger, job id and outcome, never text.
"""
from __future__ import annotations

import contextlib
import logging
import threading
import time
from datetime import datetime, timedelta
from typing import Any

from .. import db, heat
from ..convo.weather import OpenMeteo, cell
from ..rails import tag
from ..timeutil import in_quiet, iso, parse_iso, to_local
from . import budget, validator
from .briefing import BLOCKING_FLAGS

log = logging.getLogger("companion")

NIGGLE_AFTER_H = 48
NIGGLE_WITHIN_H = 48      # a check-back later than this after it was due is stale
RACE_AFTER_H = 2
RACE_WITHIN_H = 36
RUN_AFTER_MIN = 10
RUN_WITHIN_H = 12
RUN_MIN_M = 1000
RUN_CHIPS = "Good one|Tough one|Tell you more"
DAY_FROM_MIN = 6 * 60 + 30
DAY_UNTIL_MIN = 12 * 60
DAY_SILENT_DAYS = 3
DAY_CHIPS = "Sounds good|Need to change it"
DAY_ASK_CHIPS = "Going well|Tough week"
HEAT_FROM_MIN = 17 * 60   # the heads-up goes out from 5 pm local, until the runner's quiet hours start
HEAT_HOUR = 7             # the forecast hour for the session (the usual start time is not used)
OPEN_CHAT_STATES = ("pending", "running", "merged", "replied", "sending")
IN_CONVERSATION_H = 2     # the runner wrote this recently: the conversation is theirs
TRIAGE_HOURS = 72
STALE_RUNNING_S = 300
NIGGLE_CHIPS = "Better|Same|Worse"
RACE_CHIPS = "Felt great|Tough one|Tell you all"
HEAT_CHIPS = "Go earlier|Keep it as planned"


def _hm(seconds: int) -> str:
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


class NeedForecast(Exception):
    """decide() wants a forecast it was not given: the caller fetches it outside any transaction and decides again."""

    def __init__(self, key: tuple, lat: float, lon: float, zone: str, day: Any):
        super().__init__("forecast")
        self.key, self.lat, self.lon, self.zone, self.day = key, lat, lon, zone, day


def note(text: str) -> str:
    return f"<host_note>{text}</host_note>"


class Proactive:
    def __init__(self, coach: Any):
        self.coach = coach
        self.svc, self.s = coach.svc, coach.s
        self.weather: Any = None    # tests put a fake here; None builds the Open-Meteo wrapper on first use

    # ------------------------------------------------------------------------------------------ timer
    def run_forever(self, stop: threading.Event) -> None:
        from ..timeutil import now_utc
        while not stop.wait(self.s.coach_proactive_tick_s):
            try:
                self.tick(now_utc())
            except Exception as e:   # keep the timer alive
                log.error("coach proactive tick failed: %s", type(e).__name__)

    @property
    def enabled(self) -> bool:
        return bool(self.s.coach_proactive and self.coach.enabled)

    def _wx(self) -> Any:
        if self.weather is None:
            self.weather = OpenMeteo(self.svc.http)
        return self.weather

    # ------------------------------------------------------------------------------------------ tick
    def tick(self, now: datetime, limit: int = 20) -> int:
        """One pass over the allowlisted runners: for each, at most one proactive message is started and sent. -> messages sent."""
        if not self.enabled or self.svc._kill_switch():
            return 0
        self.recover(now)
        with db.ro(self.s.db_path) as c:
            uids = [r["id"] for r in c.execute(
                "SELECT id FROM users WHERE checkin_consent >= ? AND paused=0 AND COALESCE(ops_paused,0)=0 ORDER BY id",
                (self.s.coach_consent_required,))]
        sent = 0
        for uid in uids:
            if sent >= limit:
                break
            try:
                sent += 1 if self.consider(uid, now) else 0
            except Exception as e:
                log.error("coach proactive failed user=%s: %s", uid[:6], type(e).__name__)
        return sent

    def recover(self, now: datetime) -> None:
        """A proactive job left running (a crash) is cancelled, never re-run: its moment has gone."""
        cut = iso(now - timedelta(seconds=STALE_RUNNING_S + self.s.coach_job_deadline_tool_s))
        with db.tx(self.s.db_path) as c:
            budget.release_stale(c, now)
            c.execute("UPDATE coach_jobs SET state='cancelled', outcome='recovered' WHERE kind='proactive' AND state='running' "
                      "AND COALESCE(claimed_at, '') < ?", (cut,))

    def cancel_stranded(self) -> int:
        """At startup, flag on or off: every proactive job still 'running' belongs to a process that is gone. Cancelled."""
        with db.tx(self.s.db_path) as c:
            return c.execute("UPDATE coach_jobs SET state='cancelled', outcome='restart' WHERE kind='proactive' AND state='running'").rowcount

    def send_allowed(self, job_id: int, now: datetime) -> bool:
        """The last check before a proactive reply goes out, first send and every retry. True for any other kind of job. A job
        that fails it is cancelled and its stored reply dropped: a held message is not sent late."""
        with db.ro(self.s.db_path) as c:
            j = c.execute("SELECT kind, state, user_id, created_at FROM coach_jobs WHERE id=?", (job_id,)).fetchone()
        if not j or j["kind"] != "proactive" or j["state"] not in ("replied", "running"):
            return True
        why = self._hold_reason(j["user_id"], parse_iso(j["created_at"]), now)
        if why is None:
            return True
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE coach_jobs SET state='cancelled', outcome=?, reply=NULL WHERE id=? AND state IN ('replied','running')",
                      (f"held:{why}", job_id))
            c.execute("DELETE FROM coach_messages WHERE job_id=? AND role='coach'", (job_id,))   # the model never sees what the runner did not get
        log.info("coach proactive job=%s held: %s", job_id, why)
        return False

    def _hold_reason(self, uid: str, created: datetime, now: datetime) -> str | None:
        if not self.enabled:
            return "off"
        if self.svc._kill_switch():
            return "kill_switch"
        with db.ro(self.s.db_path) as c:
            why = self.coach.gate(c, uid)
            u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            if why is None and u is not None and not self.coach.allowlisted(u, self.s.coach_proactive_allowlist):
                why = "proactive_allowlist"
            if why is None and u is not None and c.execute(
                    "SELECT 1 FROM coach_jobs WHERE user_id=? AND kind IN ('chat','briefing') AND created_at>?",
                    (uid, iso(created))).fetchone():
                return "runner_wrote"
        if why is not None:
            return why
        qs, qe = self.svc._quiet(dict(u))
        if in_quiet(now, u["zone_id"] or "UTC", qs, qe):
            return "quiet_hours"
        if u["last_inbound_at"] and parse_iso(u["last_inbound_at"]) > created:
            return "runner_wrote"
        return None

    # ------------------------------------------------------------------------------------------ decide
    def consider(self, uid: str, now: datetime) -> bool:
        """Decide for one runner and, when there is a reason and nothing forbids it, run it. -> True when a message was sent.
        The forecast (a network call) is fetched between two transactions, never inside one: the first only reads, the second
        decides again on fresh data and enqueues."""
        wx: dict = {}
        for _ in range(2):
            with db.ro(self.s.db_path) as c:
                try:
                    plan = self.decide(c, uid, now, wx)
                except NeedForecast as need:
                    plan = need
            if isinstance(plan, NeedForecast):
                wx[plan.key] = self._wx().heat_at(plan.lat, plan.lon, plan.zone, plan.day, HEAT_HOUR)
                continue
            break
        else:
            return False
        if plan is None:
            return False
        with db.tx(self.s.db_path) as c:
            try:
                plan = self.decide(c, uid, now, wx)   # again, under the write lock: another tick or a message may have landed
            except NeedForecast:
                return False
            if plan is None:
                return False
            key, trigger, message, mode, user = plan
            cur = c.execute("INSERT OR IGNORE INTO coach_jobs (user_id, msg_mac, kind, state, created_at, claimed_at, attempts, prompt_hash) "
                            "VALUES (?,?,?,?,?,?,1,?)",
                            (uid, key, "proactive", "running", iso(now), iso(now), self.coach.prompt.prompt_hash))
            if cur.rowcount == 0:
                return False
            job_id = cur.lastrowid
            history = self._history(c, uid)
            chars = len(self.coach.prompt.text) + sum(len(h["content"]) for h in history) + len(message)
            ledger_id, why = budget.reserve(c, self.s, uid, job_id, budget.estimate(self.s, chars, first=True), now,
                                            self.coach.prompt.prompt_hash, user["zone_id"], purpose="proactive")
            if ledger_id is None:
                c.execute("UPDATE coach_jobs SET state='cancelled', outcome=? WHERE id=?", (f"cap:{why}", job_id))
                log.info("coach proactive tester=%s trigger=%s skipped: %s", tag(user["tester_no"]), trigger, why)
                return False
        from .chat import Claimed
        job = Claimed(job_id, uid, [job_id], ledger_id, chars, history, message, None, user["zone_id"] or "UTC", mode, trusted=True)
        t0 = time.monotonic()
        try:
            with self.coach._heartbeat(uid):
                res = self.coach._agent(job, now)
        except Exception as e:
            log.error("coach proactive run failed job=%s: %s", job_id, type(e).__name__)
            self._cancel(job_id, f"error:{type(e).__name__}")
            with contextlib.suppress(Exception):
                self.coach._settle(ledger_id, now, None, "error", None)
            return False
        if res.reply is None:
            self._cancel(job_id, res.outcome)
            log.info("coach proactive tester=%s trigger=%s job=%s no message: %s", tag(user["tester_no"]), trigger, job_id, res.outcome)
            return False
        body = res.reply
        if self.coach._show_cost(uid):
            body += f"\n\n<i>· {res.cost_usd * 100:.1f}¢ · {res.calls} call{'s' if res.calls != 1 else ''} · {time.monotonic() - t0:.0f} s</i>"
        reply = validator.with_chips(body, res.chips)
        with db.tx(self.s.db_path) as c:
            j = c.execute("SELECT state FROM coach_jobs WHERE id=?", (job_id,)).fetchone()
            if not j or j["state"] != "running":
                return False
            c.execute("UPDATE coach_jobs SET state='replied', reply=?, reply_source='llm', outcome=?, replied_at=? WHERE id=?",
                      (reply, f"{trigger}:{res.outcome}", iso(now), job_id))
            self.coach._message(c, uid, job_id, "coach", reply, now)
        # The model took time: check the world as it is now (quiet hours, kill switch, gate, did the runner write?) in send_job.
        ok = self.coach.send_job(job_id, now + timedelta(seconds=time.monotonic() - t0))
        log.info("coach proactive tester=%s trigger=%s job=%s outcome=%s sent=%s", tag(user["tester_no"]), trigger, job_id, res.outcome, ok)
        return ok

    def _cancel(self, job_id: int, why: str) -> None:
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE coach_jobs SET state='cancelled', outcome=? WHERE id=? AND state='running'", (why, job_id))

    def _history(self, c, uid: str) -> list[dict]:
        from .chat import alternate
        return alternate([{"role": "user" if r["role"] == "runner" else "assistant", "content": r["text"]}
                          for r in reversed(c.execute(
                              "SELECT m.role, m.text FROM coach_messages m LEFT JOIN coach_jobs j ON j.id = m.job_id "
                              "WHERE m.user_id=? AND COALESCE(j.kind, 'chat') <> 'safety' AND COALESCE(j.reply_source, '') <> 'safety' "
                              "ORDER BY m.id DESC LIMIT ?", (uid, self.s.coach_history)).fetchall())])

    def decide(self, c, uid: str, now: datetime, wx: dict | None = None) -> tuple[str, str, str, str | None, dict] | None:
        """-> (msg_mac, trigger, host note, injury mode, user row) for the one message to send, or None. Reads only. `wx` holds
        forecasts already fetched (key -> (temp, dew) or None); a heat trigger that needs one not in it raises NeedForecast."""
        if self.coach.gate(c, uid) is not None:
            return None
        u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        if not u or not self.coach.allowlisted(u, self.s.coach_proactive_allowlist):
            return None
        user = dict(u)
        zone = user["zone_id"] or "UTC"
        qs, qe = self.svc._quiet(user)
        if in_quiet(now, zone, qs, qe):
            return None
        # one a day, counting anything proactive that was started (a cancelled one never reached the runner)
        if c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND kind='proactive' AND state<>'cancelled' AND created_at>=? LIMIT 1",
                     (uid, budget.day_start(now, zone))).fetchone():
            return None
        if c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND kind IN ('chat','briefing') AND state IN ('pending','running','merged') LIMIT 1",
                     (uid,)).fetchone():
            return None
        if user.get("last_inbound_at") and parse_iso(user["last_inbound_at"]) > now - timedelta(hours=IN_CONVERSATION_H):
            return None
        marks = ",".join("?" * len(BLOCKING_FLAGS))
        if c.execute(f"SELECT 1 FROM health_flags WHERE user_id=? AND state='active' AND kind IN ({marks})", (uid, *BLOCKING_FLAGS)).fetchone():
            return None
        window = iso(now - timedelta(hours=TRIAGE_HOURS))
        if c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND triage IN ('red','red72') AND COALESCE(replied_at, created_at) > ? LIMIT 1",
                     (uid, window)).fetchone():
            return None
        for trigger in (self._niggle, self._run, self._race, self._heat, self._day):
            out = trigger(c, user, zone, now, window, wx or {})
            if out is not None:
                key, message, mode = out
                key = f"proactive:{key.split(':')[1]}:{user['id']}:{key.split(':', 2)[2]}"
                if c.execute("SELECT 1 FROM coach_jobs WHERE msg_mac=?", (key,)).fetchone():
                    continue
                return key, key.split(":")[1], message, mode, user
        return None

    # ------------------------------------------------------------------------------------------ the five triggers
    def _niggle(self, c, user: dict, zone: str, now: datetime, window: str, wx: dict):
        j = c.execute("SELECT id, COALESCE(replied_at, created_at) AS t FROM coach_jobs WHERE user_id=? AND kind='chat' "
                      "AND state IN ('replied','sending','sent') AND (niggle IN ('amber','green') OR triage='amber') "
                      "ORDER BY id DESC LIMIT 1", (user["id"],)).fetchone()
        if not j:
            return None
        t = parse_iso(j["t"])
        if not (t + timedelta(hours=NIGGLE_AFTER_H) <= now < t + timedelta(hours=NIGGLE_AFTER_H + NIGGLE_WITHIN_H)):
            return None
        text = ("PROACTIVE, started by the server: the runner has not just written to you. About two days ago they told you about a "
                "niggle and you went through it with them. Open with one short, warm check-back on how it feels now, in your own words "
                "(the earlier chat is above). One question at most, one to three lines. No training, pace or plan advice, no diagnosis, "
                "no medicines. If it is worse, say you will go through it again once they tell you. Finish with the quick replies "
                f"<chips>{NIGGLE_CHIPS}</chips>.")
        return f"proactive:niggle:{j['id']}", note(text), "amber"

    def _run(self, c, user: dict, zone: str, now: datetime, window: str, wx: dict):
        """A debrief of the latest uploaded run. Idempotent per run (proactive:run:<user>:<run id>); one a day comes from decide."""
        r = c.execute("SELECT * FROM runs WHERE user_id=? AND real_upload=1 AND type<>'race' AND distance_m>=? "
                      "AND end_utc <= ? AND end_utc >= ? ORDER BY end_utc DESC LIMIT 1",
                      (user["id"], RUN_MIN_M, iso(now - timedelta(minutes=RUN_AFTER_MIN)),
                       iso(now - timedelta(hours=RUN_WITHIN_H)))).fetchone()
        if not r:
            return None
        r = dict(r)
        # Amber mode (no paces, no push-on advice) when a recent triage was amber or a care window / injury word applies; the
        # next-session line is then left out as well: that is a training nudge, like the heat heads-up.
        amber = bool(c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND triage='amber' AND COALESCE(replied_at, created_at) > ? LIMIT 1",
                               (user["id"], window)).fetchone()) or bool(self.coach.briefing.blocked(c, user["id"], now))
        prior = [dict(x) for x in c.execute(
            "SELECT start_utc, type, session_name, distance_m, duration_s, pace_s_per_km, feel FROM runs WHERE user_id=? "
            "AND COALESCE(real_upload,1)=1 AND start_utc < ? ORDER BY start_utc DESC LIMIT 3", (user["id"], r["start_utc"]))]

        def pace(v):
            return None if not v else f"{int(v // 60)}:{int(v % 60):02d}/km"

        facts = [f"{round(r['distance_m'] / 1000, 2):g} km in {_hm(r['duration_s'])}"]
        if r["session_name"]:
            facts.append(f"session: {r['session_name']}" + (" (goal reached)" if r["goal_reached"] == 1 else
                                                           " (goal not reached)" if r["goal_reached"] == 0 else ""))
        if r["pace_s_per_km"]:
            facts.append(f"pace {pace(r['pace_s_per_km'])}")
        if r["true_pace_s_per_km"]:
            facts.append(f"true pace {pace(r['true_pace_s_per_km'])}")
        if r["zone_min"]:
            facts.append(f"minutes in each heart rate zone: {r['zone_min']}")
        if r["feel"]:
            facts.append(f"how it felt, as the runner tapped it: {r['feel']}")
        if r["pb"]:
            facts.append(f"personal best flag: {r['pb']}")
        if r["verdict"]:
            facts.append(f"the app's verdict: {r['verdict']}")
        lines = []
        for x in prior:
            d = to_local(parse_iso(x["start_utc"]), zone).strftime("%a %d %b")
            bits = [f"{round(x['distance_m'] / 1000, 1):g} km", _hm(x["duration_s"])]
            if x["session_name"]:
                bits.append(x["session_name"])
            if x["pace_s_per_km"]:
                bits.append(pace(x["pace_s_per_km"]))
            if x["feel"]:
                bits.append(f"felt {x['feel']}")
            lines.append(f"{d}: " + ", ".join(bits))
        nxt = ""
        if not amber and r["plan_next_day"]:
            nm = r["plan_next_session_name"] or r["plan_next_type"] or "session"
            nxt = f" The app's next planned session: {nm} on {r['plan_next_day']}."
        day = to_local(parse_iso(r["start_utc"]), zone).strftime("%A")
        text = (f"PROACTIVE, started by the server: the runner finished a run on {day}. Facts from the app: " + "; ".join(facts) + ". "
                + ("Their previous runs, newest first: " + " | ".join(lines) + ". " if lines else "This is their first run on record. ")
                + nxt
                + " Write a short debrief in your own words: ONE specific observation about this run (use get_run and "
                "get_recent_runs for detail, and only figures a tool or these facts give; compare with the earlier runs when it "
                "says something). "
                + ("Do not give paces, a plan or push-on advice: the runner is in a care window, so keep it to the observation and "
                   "a gentle check-in. " if amber else
                   "Then ONE concrete line about the next session, from the plan the tools return (get_plan), never invented. ")
                + "If coach_memory in your turn holds something relevant (a goal, a schedule limit), use it and say where it came "
                "from in plain words, once; never recite it. Two to four lines in all, no medical talk. "
                f"Finish with the quick replies <chips>{RUN_CHIPS}</chips>.")
        return f"proactive:run:{r['run_id']}", note(text), "amber" if amber else None

    def _race(self, c, user: dict, zone: str, now: datetime, window: str, wx: dict):
        r = c.execute("SELECT run_id, start_utc, end_utc, distance_m, duration_s FROM runs WHERE user_id=? AND type='race' "
                      "AND end_utc <= ? AND end_utc >= ? ORDER BY end_utc DESC LIMIT 1",
                      (user["id"], iso(now - timedelta(hours=RACE_AFTER_H)), iso(now - timedelta(hours=RACE_WITHIN_H)))).fetchone()
        if not r:
            return None
        day = to_local(parse_iso(r["start_utc"]), zone).strftime("%A")
        km = round(r["distance_m"] / 1000, 1)
        text = (f"PROACTIVE, started by the server: the runner finished a race on {day}: {km:g} km in {_hm(r['duration_s'])}. Open a "
                "debrief: a short, warm congratulation that fits how it went (use get_run for the detail, and only figures a tool "
                "returns), then one question about how it felt. One to four lines. Do not prescribe recovery or the next block now. "
                f"Finish with the quick replies <chips>{RACE_CHIPS}</chips>.")
        return f"proactive:race:{r['run_id']}", note(text), None

    def _heat(self, c, user: dict, zone: str, now: datetime, window: str, wx: dict):
        local = to_local(now, zone)
        if local.hour * 60 + local.minute < HEAT_FROM_MIN:   # quiet hours were already ruled out in decide
            return None
        if self.coach.briefing.blocked(c, user["id"], now):
            return None
        if c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND triage='amber' AND COALESCE(replied_at, created_at) > ? LIMIT 1",
                     (user["id"], window)).fetchone():
            return None   # an amber window: no training nudges
        _a, planned, _u, today, res = self.svc._ci_state(c, user, now, answers=self.svc._ci_consented(c, user["id"]))
        tomorrow = today + timedelta(days=1)
        if res is None or res.type != "quality" or res.day != tomorrow:
            return None
        area = c.execute("SELECT lat, lon FROM convo_area WHERE user_id=? ORDER BY rowid DESC LIMIT 1", (user["id"],)).fetchone() \
            if user.get("weather_optin") else None
        if not area:
            return None
        lat, lon = cell(area["lat"], area["lon"])
        fkey = (lat, lon, zone, tomorrow)
        if fkey not in wx:
            raise NeedForecast(fkey, lat, lon, zone, tomorrow)
        td = wx[fkey]
        if td is None:
            return None
        f = heat.slowdown_fraction(td[0], td[1])
        if f is not None and f < heat.LINE_MIN_FRACTION:
            return None
        name = (planned.session_name if planned is not None and planned.session_name else "quality session")
        facts = (f"{tomorrow.strftime('%A')} at {HEAT_HOUR:02d}:00 the forecast is {td[0]} C with a dew point of {td[1]} C"
                 + (", too hot to compare paces" if f is None else f", about {round(f * 100, 1):g}% slower than in the cool"))
        text = (f"PROACTIVE, started by the server: tomorrow's session is {name}. The forecast: {facts}. Give a short heads-up the "
                "evening before: run it by effort, not pace, or move it to a cooler hour. Use only these figures. One to three "
                f"lines, no medical talk. Finish with the quick replies <chips>{HEAT_CHIPS}</chips>.")
        return f"proactive:heat:{tomorrow.isoformat()}", note(text), None

    def _day(self, c, user: dict, zone: str, now: datetime, window: str, wx: dict):
        """The morning message for a day the coach has not already spoken on. Once per local date."""
        local = to_local(now, zone)
        minute = local.hour * 60 + local.minute
        if not (DAY_FROM_MIN <= minute < DAY_UNTIL_MIN):   # quiet hours were already ruled out in decide
            return None
        uid = user["id"]
        today = local.date()
        amber = bool(c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND triage='amber' AND COALESCE(replied_at, created_at) > ? LIMIT 1",
                               (uid, window)).fetchone()) or bool(self.coach.briefing.blocked(c, uid, now))
        _a, planned, usual, _t, res = self.svc._ci_state(c, user, now, answers=self.svc._ci_consented(c, uid))
        key = f"proactive:day:{today.isoformat()}"
        if res is None:
            # no plan and no default week: only a check-in, and only for a runner who has been quiet
            if c.execute("SELECT 1 FROM coach_messages WHERE user_id=? AND role='runner' AND ts > ? LIMIT 1",
                         (uid, iso(now - timedelta(days=DAY_SILENT_DAYS)))).fetchone():
                return None
            if user.get("last_inbound_at") and parse_iso(user["last_inbound_at"]) > now - timedelta(days=DAY_SILENT_DAYS):
                return None
            text = ("PROACTIVE, started by the server: the runner has not written to you for a few days and you do not know their plan. "
                    "Open with one short, warm question: how is the week looking? One to two lines, no advice. Finish with the quick "
                    f"replies <chips>{DAY_ASK_CHIPS}</chips>.")
            return key, note(text), "amber" if amber else None
        rest_today = res.day != today
        if rest_today:
            # a rest day after a run is the run debrief's: it already spoke (or skipped on a quiet or capped day)
            y = (local - timedelta(days=1)).date()
            for r in c.execute("SELECT start_utc FROM runs WHERE user_id=? AND COALESCE(real_upload,1)=1 AND start_utc >= ? "
                               "ORDER BY start_utc DESC LIMIT 6", (uid, iso(now - timedelta(days=2)))):
                if to_local(parse_iso(r["start_utc"]), zone).date() == y:
                    return None
        monday = today - timedelta(days=today.weekday())
        done = sum(1 for r in c.execute("SELECT start_utc, distance_m FROM runs WHERE user_id=? AND COALESCE(real_upload,1)=1 AND "
                                        "start_utc >= ?", (uid, iso(now - timedelta(days=8)))).fetchall()
                   if r["distance_m"] >= RUN_MIN_M and to_local(parse_iso(r["start_utc"]), zone).date() >= monday)
        last = c.execute("SELECT start_utc, distance_m, duration_s, session_name FROM runs WHERE user_id=? AND COALESCE(real_upload,1)=1 "
                         "ORDER BY start_utc DESC LIMIT 1", (uid,)).fetchone()
        week = f"runs done since Monday: {done}" + (f" (usual run days a week: {len(usual)})" if usual else "")
        if last:
            ld = to_local(parse_iso(last["start_utc"]), zone).strftime("%A %d %b")
            week += (f"; last run {ld}: {round(last['distance_m'] / 1000, 1):g} km in {_hm(last['duration_s'])}"
                     + (f", {last['session_name']}" if last["session_name"] else ""))
        else:
            week += "; no run on record yet"
        pl = res.planned
        if rest_today:
            today_line = (f"today is a rest day in the plan; the next session is on {res.day.strftime('%A')}"
                          + (" and its details are in get_plan" if not amber else ""))
        else:
            name = pl.session_name if pl is not None and pl.session_name and res.type == pl.type else None
            bits = [name or {"easy": "an easy run", "long": "a long run", "quality": "a quality session"}.get(res.type, "a session")]
            if pl is not None and res.type == pl.type:
                if pl.distance_m:
                    bits.append(f"{round(pl.distance_m / 1000, 1):g} km")
                elif pl.minutes:
                    bits.append(f"{pl.minutes} min")
                if pl.pace_lo_s and pl.pace_hi_s and not amber:
                    bits.append(f"target pace {int(pl.pace_lo_s // 60)}:{int(pl.pace_lo_s % 60):02d} to "
                                f"{int(pl.pace_hi_s // 60)}:{int(pl.pace_hi_s % 60):02d} per km")
            today_line = "today's session is " + ", ".join(bits) + ("; it was moved to today" if res.moved else "")
        text = (f"PROACTIVE, started by the server: it is the runner's morning and you have not written today. Facts from the plan "
                f"and the app: {today_line}. How the week is tracking: {week}. "
                "Write a short good-morning in your own words: what today is, in one line (use get_plan for the detail, and only "
                "figures a tool or these facts give), then one line on how the week is going. "
                + ("Do not give paces or push-on advice: the runner is in a care window, so keep it gentle and do not push the "
                   "session. " if amber else "")
                + "If coach_memory in your turn holds something relevant, use it and say where it came from in plain words, once; "
                "never recite it. Two to four lines, no medical talk. "
                f"Finish with the quick replies <chips>{DAY_CHIPS}</chips>.")
        return key, note(text), "amber" if amber else None
