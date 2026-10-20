"""Coach session briefing (C2b, server PR S): a spoken briefing TEMPLATE for the runner's next planned session.

The server never renders a number. The model writes words with slots ({pace}, {minutes}, ...); the app fills the slots on
the device from the same values it uses for the in-run cues (eng-review #1), in the runner's own units. This module:

  facts      the session (latest upload's plan_next_*, else the coach week), recent like-for-like runs, recent check-in
             answers (enumerated values, no free text), coach memory (enumerated). Nothing the runner typed.
  generate   Sonnet through the SAME request helper as the coach chat (ZDR provider block, reasoning effort low and
             excluded, no temperature, usage included, refusal reason logged), one call, at most one retry. It sends the chat's tool list with tool_choice 'none' (tools are part of the
             provider's cache prefix, so this shares the chat's cached prefix; the model cannot call a tool).
  validate   closed vocabulary: no digits, no number words from two upward, only known slots, word cap on the RENDERED
             text (each slot counted at its worst case), no dashes (#8, #9).
  store      coach_briefings, UNIQUE (user_id, session_ref), coalesced on facts_hash.
  serve      GET /v1/me/briefing re-checks every gate on every call (#3): 200 / 202 pending / 204.

Safety (#4): an active urgent, wellbeing (self-harm), injury or illness flag means no briefing at all (GET 204, queued
jobs cancelled). Injury is the simplest of the two options in the review (a fixed line or 204): it is 204 here, and the
app then speaks its own start line. The model never improvises around a health flag.

Jobs ride in coach_jobs with kind='briefing' (one worker thread, persisted, claimed with the same gate as chat).

---------------------------------------------------------------------------------------------------------------------
SLOT SET (the contract for the Kotlin renderer; every slot renders as spoken words, in the runner's units)
  {session}   the session's name as it is spoken ("Norwegian four by four"). Present only when the plan names the session.
              Worst case 4 words.
  {pace}      the target work pace, the same value as VoiceCoachConfig.targetPaceSecPerKm, in the runner's units
              ("five ten per kilometre" / "eight twenty per mile"). Present only for a quality session with a pace.
              Worst case 6 words.
  {minutes}   the planned duration ("forty five minutes"). Present only when the plan holds minutes. Worst case 4 words.
  {distance}  the planned distance in the runner's units ("ten point five kilometres"). Present only when the plan holds a
              distance. Worst case 5 words.
  {reps}      the work reps, spoken WITH the word reps ("four reps"). Present only for a session whose name or id carries
              "NxM". Worst case 2 words. The template must not add a unit or the word rep(s) after it.
A template only ever uses slots listed in its facts (`available_slots`); the validator rejects any other. Cap: 28 words
rendered (about 10 s). Kotlin re-counts after rendering and falls back (never truncates).
---------------------------------------------------------------------------------------------------------------------
FINGERPRINT (#2): the app matches a cached briefing to the session it actually starts with a content hash.
  canonical string  "v1|kind=<easy|long|quality>|min=<int or empty>|dist_m=<int or empty>|reps=<int or empty>|
                     pace_lo=<int or empty>|pace_hi=<int or empty>"  (one line, fields in exactly this order, `|` joined)
  numbers           every number is converted with round-half-up, floor(x + 0.5), then written as a plain decimal integer
                    (minutes, metres, reps and paces alike; a whole number is unchanged, 29.5 becomes 30);
                    an absent value is the empty string; `kind` is the plan's kind (a session made easy is "easy")
  fingerprint       lowercase hex of the first 16 characters of SHA-256 over the UTF-8 canonical string
  fixture           tests/fixtures/briefing_fingerprint.json (inputs -> canonical -> expected hash), tested here and to be
                    tested by the Dart side against the same file.
  Note: plan_next carries no rep count, so the server takes `reps` from an "NxM" in the session id or name (norwegian_4x4
  -> 4) and leaves it empty otherwise. The Dart side must derive reps the same way for a plan session (or both ends add
  the field to the upload); a mismatch is only a missed match, which falls back to the app's own line.
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import re
import time
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from .. import db
from .. import checkins as ci
from ..timeutil import iso, now_utc, parse_iso, to_local
from . import budget
from .tools import MEMORY_KEYS, ReadTools

log = logging.getLogger("companion")

WORD_CAP = 28
# Worst-case spoken length of each slot, in words. The validator counts a slot at this length (#9).
SLOT_WORDS = {"session": 4, "pace": 6, "minutes": 4, "distance": 5, "reps": 2}
SLOT_DOC = {
    "session": "the session's name, spoken by the app (a named session only)",
    "pace": "the target work pace, spoken by the app (a quality session with a pace only)",
    "minutes": "the planned duration, spoken by the app (only when the plan has minutes)",
    "distance": "the planned distance, spoken by the app (only when the plan has a distance)",
    "reps": "how many work reps, spoken by the app with the word reps, like four reps (an NxM session only)",
}
BLOCKING_FLAGS = ("urgent", "wellbeing", "injury", "ill")   # urgent = urgent medical, wellbeing = self-harm words
INJURY_DAYS = 7           # the chat safety classifier's injury sighting blocks briefings for this long
SCREEN_INJURY = "clear:injury"   # coach_jobs.screen when the classifier saw an injury but no red flag (chat.py writes it)
MAX_ATTEMPTS = 2           # the first call plus one retry, both in the ledger
RECENT_DAYS = 42
STALE_GRACE_S = 30
MAX_CHARS = 400
FINGERPRINT_VERSION = "v1"

# Warm-up and structure rules that must survive into the briefing (review #10). Matched on the session id or name.
SESSION_RULES = (
    (re.compile(r"norwegian|4x4", re.I),
     ["Warm up as long as you like before the first rep; there is no rush into the work.",
      "The reps are hard but even; the jog between them is a real recovery."]),
)
REPS_RE = re.compile(r"(?<!\d)(\d{1,2})\s*x\s*\d", re.I)


# ------------------------------------------------------------------------------------------------- spec + fingerprint
@dataclass(frozen=True)
class Spec:
    ref: str
    kind: str                 # easy | long | quality
    minutes: int | None
    distance_m: int | None
    reps: int | None
    pace_lo: float | None
    pace_hi: float | None
    name: str | None
    session_id: str | None
    day: str
    week: int | None
    weeks: int | None
    moved: bool
    easier: bool


def _round_half_up(x: float) -> int:
    return int(math.floor(x + 0.5))


def canonical(kind: str, minutes: int | None, distance_m: int | None, reps: int | None,
              pace_lo: float | None, pace_hi: float | None) -> str:
    def f(v: Any) -> str:
        return "" if v is None else str(_round_half_up(v))
    p = f
    return (f"{FINGERPRINT_VERSION}|kind={kind}|min={f(minutes)}|dist_m={f(distance_m)}|reps={f(reps)}"
            f"|pace_lo={p(pace_lo)}|pace_hi={p(pace_hi)}")


def fingerprint(kind: str, minutes: int | None = None, distance_m: int | None = None, reps: int | None = None,
                pace_lo: float | None = None, pace_hi: float | None = None) -> str:
    return hashlib.sha256(canonical(kind, minutes, distance_m, reps, pace_lo, pace_hi).encode()).hexdigest()[:16]


def spec_fingerprint(s: Spec) -> str:
    return fingerprint(s.kind, s.minutes, s.distance_m, s.reps, s.pace_lo, s.pace_hi)


def reps_from(session_id: str | None, name: str | None) -> int | None:
    for text in (session_id, name):
        m = REPS_RE.search(text or "")
        if m:
            return int(m.group(1))
    return None


# ------------------------------------------------------------------------------------------------- validator (#8, #9)
STEMS = ("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen "
         "nineteen twenty thirty forty fourty fifty sixty seventy eighty ninety hundred thousand million dozen zero").split()
ORDINALS = ("second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth "
            "sixteenth seventeenth eighteenth nineteenth twentieth thirtieth fortieth fiftieth sixtieth seventieth eightieth "
            "ninetieth hundredth thousandth").split()
# A token made only of number stems (plus a plural or -th ending) is a number word: "twentyfive", "fours", "tens", "dozens", "hundreds".
_STEM_ALT = "|".join(sorted(STEMS, key=len, reverse=True))
NUMBERISH_RE = re.compile(rf"^(?:(?:{_STEM_ALT})+|(?:twent|thirt|fort|fift|sixt|sevent|eight|ninet)(?:ies|ieth))(?:s|th|ths)?$")
QUANTITY = frozenset(("twice thrice double doubles triple triples couple couples pair pairs few several handful bunch "
                      "half halves quarter quarters another extra single once trio quartet duo").split())
# Roman numerals (a fullwidth or compatibility form such as U+2163 folds to "IV"). "i" alone is a pronoun and stays allowed.
ROMAN = frozenset("ii iii iv v vi vii viii ix xi xii xiii xiv xv xvi xvii xviii xix xx".split())
EXTRA_REP_RE = re.compile(r"\b(?:more|extra|another|additional)\s+(?:reps?|strides?|sets?)\b", re.I)
UNITS = frozenset(("hour hours minute minutes min mins second seconds sec secs mile miles metre metres meter meters yard yards "
                   "lap laps k").split())
SLOT_RE = re.compile(r"\{([A-Za-z_]+)\}")
ABBREV_RE = re.compile(r"(?<![A-Za-z])(?:x|km|bpm|hr)(?![A-Za-z])|/km", re.I)   # Z2 is caught as a digit
ZONE_ONE_RE = re.compile(r"\bzone\s+one\b", re.I)
REPS_UNIT_RE = re.compile(r"\{reps\}\W*([A-Za-z]+)")


def number_word(tok: str) -> bool:
    return tok in ORDINALS or tok in QUANTITY or tok in ROMAN or bool(NUMBERISH_RE.match(tok))


def check_template(text: str, allowed: set[str] | frozenset[str]) -> str | None:
    """None when the template is acceptable, else the reject class: empty | length | slot | digit | dash | number_word |
    unit | abbrev | cap. Numbers and units exist only inside slots (a slot speaks its own unit, {reps} says "four reps"), so
    outside a slot there is no digit, no number word (one, twenty-five, fours, tens, dozens, twice, half, a few, several,
    a pair, a quarter), and no unit word (hour, minute, mile, kilometre, metre). The word cap is on the rendered text."""
    text = unicodedata.normalize("NFKC", text or "")   # fullwidth letters, vulgar fractions and roman numeral signs fold first
    if not text.strip():
        return "empty"
    if len(text) > MAX_CHARS:
        return "length"
    for m in SLOT_RE.finditer(text):
        if m.group(1) not in SLOT_WORDS or m.group(1) not in allowed:
            return "slot"
    bare = SLOT_RE.sub(" ", text)
    if "{" in bare or "}" in bare:
        return "slot"
    if re.search(r"\d", bare):
        return "digit"
    if any(ch in text for ch in "\u2014\u2013\u2012\u2015\u2212"):
        return "dash"
    if ZONE_ONE_RE.search(bare) or EXTRA_REP_RE.search(bare):
        return "number_word"
    toks = re.findall(r"[a-z]+", bare.lower())
    if any(number_word(t) for t in toks):
        return "number_word"
    if any(t in UNITS or t.startswith("kilomet") for t in toks):
        return "unit"
    for m in REPS_UNIT_RE.finditer(text):   # {reps} already says "reps"
        nxt = m.group(1).lower()
        if nxt in ("rep", "reps") or nxt in UNITS or nxt.startswith("kilomet") or number_word(nxt):
            return "slot"
    if ABBREV_RE.search(bare):
        return "abbrev"
    if rendered_words(text) > WORD_CAP:
        return "cap"
    return None


def rendered_words(text: str) -> int:
    """Words once every slot is filled at its worst-case spoken length."""
    spaced = SLOT_RE.sub(lambda m: " ".join(["w"] * SLOT_WORDS.get(m.group(1), 6)), text)
    return len(re.findall(r"\S+", spaced))


def tidy(raw: str) -> str:
    t = " ".join(unicodedata.normalize("NFKC", raw).split())
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "\"'":
        t = t[1:-1].strip()
    return t


# ------------------------------------------------------------------------------------------------- instruction
INSTRUCTION = """Write the spoken briefing this runner hears through their earbuds right before they start. You are their coach and you are talking, not texting.

How it must read:
- One short paragraph, plain words for text to speech. First sentence names the kind of run ({kind_say}), so they know what they are about to do.
- Then, in a sentence or two, how to tackle it. It must match the targets in the facts: easy means relaxed and conversational, never push; long means steady, patient start, save it for the end; quality means controlled start, hold the target on the work, jog the recoveries.
- Keep every rule in `rules` (for example a warm-up that is as long as they like).
- Informal and warm, the voice from your skill. No emoji, no hype, no markdown.
- Never give medical advice and never mention pain, injury or illness.

Numbers and units: you may NOT write any digit, any number word at all ("one", "two", "ten", "twenty five", "fours", "tens", "dozens", "third", "twice", "a couple of", "a few", "several", "a pair", "half", "a quarter"), any unit word (hour, minute, mile, kilometre, metre), or x, km, /km, bpm, HR, Z2. The only way to say a number is a slot, written in curly braces. The slots you may use are exactly: {slots}. The app speaks each slot in the runner's own units and each slot already carries its own unit or word ("forty five minutes", "ten point five kilometres", "four reps", "five ten per kilometre"), so never write a unit or the word "reps" next to a slot. Never describe a number in other words and never use a slot that is not in the list.
No dashes of any kind (use a comma or a full stop). At most {cap} words, counting each slot as its longest spoken form ({slot_cost}).

Reply with the briefing text only.

<facts>
{facts}
</facts>"""


def instruction(kind: str, named: bool, slots: list[str], facts: dict, retry_note: str | None = None) -> str:
    """The user turn for one briefing. Shared with coach/evals/run_briefing_evals.py so the eval sends what production sends."""
    kind_say = {"easy": "an easy run", "long": "a long run", "quality": "the named session" if named else "a quality session"}[kind]
    text = INSTRUCTION.format(
        kind_say=kind_say, slots=", ".join("{" + k + "}" for k in slots) if slots else "none, so write no numbers at all",
        cap=WORD_CAP, slot_cost=", ".join(f"{{{k}}} is {SLOT_WORDS[k]}" for k in slots) or "no slots",
        facts=json.dumps(facts, separators=(",", ":"), ensure_ascii=False))
    if retry_note:
        text += f"\n\nYour previous attempt was rejected for this reason: {retry_note}. Write it again and fix exactly that."
    return text


# ------------------------------------------------------------------------------------------------- the service
class Briefings:
    """Facts, generation, storage and serving. `coach` is the CoachChat (gate, request helper, ledger settle)."""

    def __init__(self, coach: Any):
        self.coach = coach
        self.svc, self.s = coach.svc, coach.s

    # -------------------------------------------------------------------------------------- safety + session
    def gate(self, c, uid: str) -> str | None:
        """The chat gate AND the briefing kill switch (COMPANION_COACH_BRIEFING, default off)."""
        if not self.s.coach_briefing:
            return "briefing_off"
        return self.coach.gate(c, uid)

    def blocked(self, c, uid: str, now: datetime) -> bool:
        """True when nothing may be said about training today (#4): an active urgent, wellbeing, injury or ill flag; or the
        runner's own check-ins say ill or sore (a skip because ill or sore, or a sore answer, whose window has not ended);
        or the chat safety classifier saw an injury in the last 7 days. Nothing writes an `injury` or `ill` health flag today,
        so the last two are what actually fire. Reads fresh every time."""
        marks = ",".join("?" * len(BLOCKING_FLAGS))
        if c.execute(f"SELECT 1 FROM health_flags WHERE user_id=? AND state='active' AND kind IN ({marks})",
                     (uid, *BLOCKING_FLAGS)).fetchone():
            return True
        u = c.execute("SELECT zone_id FROM users WHERE id=?", (uid,)).fetchone()
        today = to_local(now, (u["zone_id"] if u else None) or "UTC").date()
        answers = self.svc._ci_answers(c, uid, now)
        if any(end >= today for _start, end in ci.care_windows(answers)):
            return True
        return c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND screen=? AND claimed_at>=?",
                         (uid, SCREEN_INJURY, iso(now - timedelta(days=INJURY_DAYS)))).fetchone() is not None

    def spec_for(self, c, user: dict, now: datetime) -> Spec | None:
        """The runner's next session as it stands: the latest upload's plan_next_*, else the coach week. A session the
        check-ins made easy is easy (no minutes, no pace). None: nothing to brief."""
        _ans, planned, _usual, _today, res = self.svc._ci_state(c, user, now)
        if res is None or planned is None:
            return None
        uid = user["id"]
        if planned.derived:
            ref = f"cw{res.day.strftime('%Y%m%d')}{res.type[0]}"
        else:
            latest = self.svc._ci_latest_run(c, uid) or {}
            ref = latest.get("plan_next_session_ref")
            if not ref:   # the app sent no ref: it has nothing to match a briefing against
                return None
        kind = res.type
        easier = bool(res.easier)
        name = None if easier else self.svc._ci_session_name(planned, kind)
        quality_pace = kind == "quality" and planned.type == "quality" and not easier \
            and planned.pace_lo_s is not None and planned.pace_hi_s is not None
        return Spec(ref=ref, kind=kind, minutes=None if easier else planned.minutes,
                    distance_m=None if easier else planned.distance_m,
                    reps=reps_from(planned.session_id, planned.session_name) if kind == "quality" and not easier else None,
                    pace_lo=planned.pace_lo_s if quality_pace else None, pace_hi=planned.pace_hi_s if quality_pace else None,
                    name=name, session_id=None if easier else planned.session_id, day=res.day.isoformat(),
                    week=planned.week, weeks=planned.weeks, moved=bool(res.moved), easier=easier)

    @staticmethod
    def slots_for(spec: Spec) -> list[str]:
        out = []
        if spec.name:
            out.append("session")
        if spec.pace_lo is not None:
            out.append("pace")
        if spec.minutes is not None:
            out.append("minutes")
        if spec.distance_m is not None:
            out.append("distance")
        if spec.reps is not None:
            out.append("reps")
        return out

    # -------------------------------------------------------------------------------------- facts
    def facts_for(self, c, user: dict, spec: Spec, now: datetime) -> dict:
        uid = user["id"]
        label = {"easy": "easy run", "long": "long run", "quality": "quality session"}[spec.kind]
        rules: list[str] = []
        for rx, lines in SESSION_RULES:
            if spec.kind == "quality" and rx.search(f"{spec.session_id or ''} {spec.name or ''}"):
                rules += lines
        types = {"easy": ("easy",), "long": ("long",), "quality": ("tempo", "interval")}[spec.kind]
        rt = ReadTools(self.svc, [], uid, now)
        rows = c.execute(f"SELECT * FROM runs WHERE user_id=? AND start_utc>=? AND type IN ({','.join('?' * len(types))}) "
                         "ORDER BY start_utc DESC LIMIT 3", (uid, iso(now - timedelta(days=RECENT_DAYS)), *types)).fetchall()
        drop = {"run_id", "app_type", "climb_m", "pb", "load_state"}
        recent = [{k: v for k, v in rt._run_row(r, user["zone_id"]).items() if k not in drop} for r in rows]
        answers = [{"kind": r["kind"], "day": r["local_date"], "value": r["value"]} for r in c.execute(
            "SELECT kind, local_date, value FROM checkin_answers WHERE user_id=? AND created_at>? ORDER BY created_at DESC LIMIT 8",
            (uid, iso(now - timedelta(days=3))))]
        mem = self.svc._memory_get(c, uid, now)
        remembered = {k: mem[k] for k in MEMORY_KEYS if k in mem and k != "niggle_area"}   # a briefing never mentions a niggle
        remembered.pop("run_why", None) if remembered.get("run_why") == "weight" else None
        slots = self.slots_for(spec)
        facts: dict[str, Any] = {
            "kind": spec.kind, "kind_in_words": label,
            "session_name_slot": "{session}" if spec.name else None,
            "available_slots": {k: SLOT_DOC[k] for k in slots},
            "rules": rules,
            "plan": {k: v for k, v in {"week": spec.week, "of_weeks": spec.weeks, "moved_to_another_day": spec.moved or None,
                                       "made_easier_by_the_runners_check_in": spec.easier or None}.items() if v is not None},
            "recent_like_for_like": recent, "recent_checkins": answers, "remembered": remembered,
        }
        return {k: v for k, v in facts.items() if v not in (None, [], {})}

    def facts_hash(self, facts: dict, spec: Spec) -> str:
        blob = json.dumps({"facts": facts, "fp": spec_fingerprint(spec), "prompt": self.coach.prompt.prompt_hash if self.coach.prompt else ""},
                          sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(blob.encode()).hexdigest()[:16]

    def _user(self, c, uid: str) -> dict | None:
        r = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        return dict(r) if r else None

    # -------------------------------------------------------------------------------------- enqueue (after an upload or a check-in)
    def enqueue(self, uid: str, now: datetime | None = None) -> bool:
        """Queue a briefing job unless a gate says no, the session or facts are unchanged since the stored briefing, or a job
        is already waiting (it reads fresh facts when it is claimed). Never raises: the upload and the check-in must not fail
        because of this. -> True when a job was queued."""
        now = now or now_utc()
        try:
            with db.tx(self.s.db_path) as c:
                if self.gate(c, uid) is not None or self.blocked(c, uid, now):
                    return False
                if c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND kind='briefing' AND state='pending'", (uid,)).fetchone():
                    return False
                user = self._user(c, uid)
                spec = self.spec_for(c, user, now) if user else None
                if spec is None:
                    return False
                fh = self.facts_hash(self.facts_for(c, user, spec, now), spec)
                row = c.execute("SELECT facts_hash FROM coach_briefings WHERE user_id=? AND session_ref=?", (uid, spec.ref)).fetchone()
                if row and row["facts_hash"] == fh:
                    return False   # coalesced: nothing the briefing depends on has changed
                c.execute("INSERT INTO coach_jobs (user_id, msg_mac, kind, state, created_at) VALUES (?,?,?,?,?)",
                          (uid, f"brf:{uuid.uuid4().hex}", "briefing", "pending", iso(now)))
        except Exception as e:
            log.error("coach briefing enqueue failed: %s", type(e).__name__)
            return False
        self.coach.wake.set()
        return True

    # -------------------------------------------------------------------------------------- worker
    def recover(self, now: datetime) -> int:
        """A briefing job left running (a restart) gets one more try, then it is dropped (nothing is ever sent for it)."""
        cut = iso(now - timedelta(seconds=self.s.coach_job_deadline_s * MAX_ATTEMPTS + STALE_GRACE_S))
        n = 0
        with db.tx(self.s.db_path) as c:
            for j in c.execute("SELECT id, attempts FROM coach_jobs WHERE kind='briefing' AND state='running' "
                               "AND COALESCE(claimed_at,'') < ?", (cut,)).fetchall():
                n += 1
                if j["attempts"] >= 2:
                    c.execute("UPDATE coach_jobs SET state='failed', outcome='recovered' WHERE id=?", (j["id"],))
                else:
                    c.execute("UPDATE coach_jobs SET state='pending', claimed_at=NULL WHERE id=?", (j["id"],))
        return n

    def step(self, now: datetime) -> bool:
        """One briefing job, if one is waiting. True when something was done."""
        if self.recover(now):
            return True
        claimed = self._claim(now)
        if claimed is None:
            return False
        if claimed is True:
            return True
        try:
            self._run(claimed, now)
        except Exception as e:   # a claimed job never hangs
            log.error("coach briefing failed job=%s: %s", claimed["job_id"], type(e).__name__)
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE coach_jobs SET state='failed', outcome=? WHERE id=? AND state='running'",
                          (f"error:{type(e).__name__}", claimed["job_id"]))
        return True

    def _cancel(self, c, job_id: int, why: str) -> bool:
        c.execute("UPDATE coach_jobs SET state='cancelled', outcome=? WHERE id=?", (why, job_id))
        log.info("coach briefing job=%s cancelled reason=%s", job_id, why)
        return True

    def _claim(self, now: datetime) -> dict | bool | None:
        with db.tx(self.s.db_path) as c:
            budget.release_stale(c, now)
            j = c.execute("SELECT id, user_id FROM coach_jobs WHERE kind='briefing' AND state='pending' ORDER BY id LIMIT 1").fetchone()
            if not j:
                return None
            uid, job_id = j["user_id"], j["id"]
            why = self.gate(c, uid)   # the same gate as chat (plus the kill switch), again at claim
            if why is not None:
                return self._cancel(c, job_id, why)
            if self.blocked(c, uid, now):
                return self._cancel(c, job_id, "health_flag")
            user = self._user(c, uid)
            spec = self.spec_for(c, user, now) if user else None
            if spec is None:
                return self._cancel(c, job_id, "no_session")
            facts = self.facts_for(c, user, spec, now)
            fh = self.facts_hash(facts, spec)
            row = c.execute("SELECT facts_hash FROM coach_briefings WHERE user_id=? AND session_ref=?", (uid, spec.ref)).fetchone()
            if row and row["facts_hash"] == fh:
                return self._cancel(c, job_id, "coalesced")
            zone = user["zone_id"] or "UTC"
            used = c.execute("SELECT COUNT(*) FROM cost_ledger WHERE user_id=? AND purpose='briefing' AND ts>=?",
                             (uid, budget.day_start(now, zone))).fetchone()[0]
            if used + 1 > self.s.coach_briefing_daily:
                return self._cancel(c, job_id, "daily_cap")
            c.execute("UPDATE coach_jobs SET state='running', claimed_at=?, attempts=attempts+1, prompt_hash=? WHERE id=?",
                      (iso(now), self.coach.prompt.prompt_hash, job_id))
            return {"job_id": job_id, "uid": uid, "spec": spec, "facts": facts, "facts_hash": fh, "zone": zone,
                    "cap_left": self.s.coach_briefing_daily - used}

    def _messages(self, job: dict, retry_note: str | None) -> list[dict]:
        spec: Spec = job["spec"]
        text = instruction(spec.kind, bool(spec.name), self.slots_for(spec), job["facts"], retry_note)
        return [self.coach.system_message(), {"role": "user", "content": text}]

    def generate(self, job: dict, now: datetime) -> tuple[str | None, str]:
        """-> (template, outcome). At most MAX_ATTEMPTS model calls, each with its own ledger reservation."""
        spec: Spec = job["spec"]
        allowed = set(self.slots_for(spec))
        deadline = time.monotonic() + self.s.coach_job_deadline_s
        note = None
        outcome = "no_key"
        for attempt in range(MAX_ATTEMPTS):
            if attempt >= job["cap_left"]:
                return None, "daily_cap"
            messages = self._messages(job, note)
            chars = len(json.dumps(messages))
            with db.tx(self.s.db_path) as c:
                ledger_id, why = budget.reserve(c, self.s, job["uid"], job["job_id"], budget.estimate(self.s, chars, first=attempt == 0),
                                                now, self.coach.prompt.prompt_hash, job["zone"], purpose="briefing")
            if ledger_id is None:
                return None, why
            remaining = deadline - time.monotonic()
            if not self.s.openrouter_key or remaining < 1.0:
                self.coach._settle(ledger_id, now, None, "no_key" if not self.s.openrouter_key else "deadline", None)
                return None, "no_key" if not self.s.openrouter_key else "deadline"
            data, why = self.coach._post(self.coach.request_body(messages, True), min(self.s.coach_turn_timeout_s, remaining))
            if data is None:
                self.coach._settle(ledger_id, now, None, why, None)
                return None, why
            provider = data.get("provider") if isinstance(data.get("provider"), str) else None
            self.coach._settle(ledger_id, now, provider, "ok", budget.usage_fields(data.get("usage"), self.s))
            text, bad = self._extract(data)
            if text is not None:
                bad = check_template(text, allowed)
            if bad is None:
                return text, "ok"
            outcome = f"rejected:{bad}"
            note = {"digit": "it contained a digit", "number_word": "it contained a number word or a quantity word",
                    "slot": "it used a slot that is not allowed", "cap": f"it was over {WORD_CAP} words when slots are counted at their longest",
                    "dash": "it contained a dash", "abbrev": "it contained x, km, bpm, HR or a zone code",
                    "empty": "it was empty", "length": "it was far too long"}.get(bad, "it broke a rule")
            log.info("coach briefing job=%s attempt=%d rejected class=%s", job["job_id"], attempt + 1, bad)
        return None, outcome

    @staticmethod
    def _extract(data: dict) -> tuple[str | None, str | None]:
        try:
            choice = data["choices"][0]
            msg = choice["message"]
            content = msg.get("content")
        except (KeyError, IndexError, TypeError, AttributeError):
            return None, "empty"
        if choice.get("finish_reason") == "length":
            return None, "length"
        if isinstance(content, list):
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        if not isinstance(content, str) or not content.strip():
            return None, "empty"
        return tidy(content), None

    def _run(self, job: dict, now: datetime) -> None:
        template, outcome = self.generate(job, now)
        spec: Spec = job["spec"]
        with db.tx(self.s.db_path) as c:
            j = c.execute("SELECT state FROM coach_jobs WHERE id=?", (job["job_id"],)).fetchone()
            if not j or j["state"] != "running" or not c.execute("SELECT 1 FROM users WHERE id=?", (job["uid"],)).fetchone():
                log.info("coach briefing job=%s dropped: runner deleted or job cancelled", job["job_id"])
                return
            if template is None:
                c.execute("UPDATE coach_jobs SET state='failed', outcome=? WHERE id=?", (outcome, job["job_id"]))
                return
            # The runner may have withdrawn, been paused or raised a flag while the model was thinking: nothing is stored.
            why = self.gate(c, job["uid"]) or ("health_flag" if self.blocked(c, job["uid"], now) else None)
            if why is not None:
                self._cancel(c, job["job_id"], why)
                return
            c.execute("INSERT INTO coach_briefings (user_id, session_ref, fingerprint, facts_hash, template, prompt_hash, generated_at) "
                      "VALUES (?,?,?,?,?,?,?) ON CONFLICT(user_id, session_ref) DO UPDATE SET fingerprint=excluded.fingerprint, "
                      "facts_hash=excluded.facts_hash, template=excluded.template, prompt_hash=excluded.prompt_hash, "
                      "generated_at=excluded.generated_at",
                      (job["uid"], spec.ref, spec_fingerprint(spec), job["facts_hash"], template, self.coach.prompt.prompt_hash, iso(now)))
            c.execute("UPDATE coach_jobs SET state='done', outcome='ok' WHERE id=?", (job["job_id"],))
        log.info("coach briefing job=%s stored ref=%s", job["job_id"], spec.ref)

    # -------------------------------------------------------------------------------------- GET /v1/me/briefing
    def serve(self, uid: str, now: datetime | None = None) -> tuple[int, dict | None]:
        """(200, body) | (200, {"status": "suppress"}) | (202, {"status": "pending"}) | (204, None). Every gate is read fresh
        on every call (#3). A closed gate (flag off, not allowlisted, no consent, paused) is 204. With the gates open but a
        safety block (health flag, sore/ill check-in window, injury seen by the chat screen) it is 200 {"status": "suppress"},
        with no reason and no flag kind, so the app also drops its own offline briefing and speaks its plain start line.
        A stored briefing is served only while it matches
        the runner's session as it stands now (same ref and fingerprint) and is younger than the TTL."""
        now = now or now_utc()
        with db.ro(self.s.db_path) as c:
            if self.gate(c, uid) is not None:
                return 204, None
            if self.blocked(c, uid, now):
                return 200, {"status": "suppress"}
            user = self._user(c, uid)
            spec = self.spec_for(c, user, now) if user else None
            if spec is None:
                return 204, None
            row = c.execute("SELECT * FROM coach_briefings WHERE user_id=? AND session_ref=?", (uid, spec.ref)).fetchone()
            if row and row["fingerprint"] == spec_fingerprint(spec) \
                    and now - parse_iso(row["generated_at"]) <= timedelta(hours=self.s.coach_briefing_ttl_h):
                return 200, {"session_ref": row["session_ref"], "fingerprint": row["fingerprint"], "template": row["template"],
                             "generated_at": row["generated_at"], "prompt_hash": row["prompt_hash"]}
            pending = c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND kind='briefing' AND state IN ('pending','running')",
                                (uid,)).fetchone()
        return (202, {"status": "pending"}) if pending else (204, None)
