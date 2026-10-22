"""propose_plan_change, and the buttons, the /memory command and the location share that go with it (coach PR4).

Proposal. The coach never changes the plan itself. `propose_plan_change` writes a `coach_proposals` row (pending) and, once the
reply is sent, a short message with Confirm / Decline buttons follows. Confirm turns the row into the server's override of the
runner's next session: `apply_overrides` is called by `_ci_state`, so the cards, Home and GET /v1/me/next-session all read it,
and the app shows it with the same `moved` flag a check-in move gets. Rules enforced here, in code, not in the prompt:
  - never proposed (nor confirmed) while a niggle is being looked at: an amber / red / red72 coach job in the last 72 h, a
    triage_check amber or red in this very job, or an active injury / urgent flag;
  - one pending proposal per runner; a new one supersedes the old;
  - a tap is idempotent: only a pending row changes state, so a second Confirm or a Decline after a Confirm does nothing;
  - a proposal older than 24 h, or for a session that is no longer the runner's next one, cannot apply.

Location. When find_care returns need_place the coach says so and a one-shot "Share location" keyboard follows. The location
message that answers it is used in memory for one OSM lookup and dropped: the only row kept is `coach_loc_wait` (the kind of
care wanted and a time), consumed by the answer. Nothing here logs coordinates or place names.
"""
from __future__ import annotations

import contextlib
import logging
from dataclasses import replace
from datetime import date, datetime, timedelta

from .. import redflag
from ... import db
from ...channels import ChannelError
from ...checkins import Resolved
from ...checkin_copy import WORD
from ...timeutil import iso, now_utc, parse_iso, to_local

log = logging.getLogger("companion")

RULES = ("- propose_plan_change: the plan-change line above no longer applies to this tool. It does not change anything: it "
         "queues a proposal and the runner gets Confirm and Decline buttons right after your reply. Use it when a session should "
         "move to another day (change move, to_day a weekday or a date) or be made easy (change easier). Say what you proposed "
         "and that it is theirs to confirm; never say it has happened. It refuses while the runner has pain or an injury "
         "being looked at: then suggest nothing about the plan. A tool that refuses is final. "
         "find_care returning need_place: ask for their suburb, and tell them they can also tap the Share location button.")

PROPOSAL_TTL = timedelta(hours=24)
TRIAGE_WINDOW = timedelta(hours=72)    # the same 72 h chat.TRIAGE_HOURS uses
LOC_WAIT_TTL = timedelta(minutes=30)
MAX_AHEAD_DAYS = 13
DAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
HELD_OFF = "Let's hold off on plan changes while that niggle is being looked at."

# ------------------------------------------------------------------------------------------------ the triage window


def in_triage_window(c, uid: str, now: datetime) -> bool:
    """True while a plan change must not be offered or applied: amber or red injury talk in the last 72 h (the turn's own
    words, a red, a red72 follow-up, or a triage_check tool result recorded by `after_tool`), or an active injury / urgent flag."""
    if c.execute("SELECT 1 FROM coach_jobs WHERE user_id=? AND triage IN ('amber','red','red72') AND created_at > ? LIMIT 1",
                 (uid, iso(now - TRIAGE_WINDOW))).fetchone():
        return True
    return c.execute("SELECT 1 FROM health_flags WHERE user_id=? AND kind IN ('injury','urgent') AND state='active' LIMIT 1",
                     (uid,)).fetchone() is not None


def after_tool(svc, job_id: int | None, uid: str, name: str, result: dict, now: datetime) -> None:
    """Called by the chat loop after each extension tool. Never raises. Records what later tools in the same job (and the next
    72 h) must know: a triage_check amber / red, and a find_care that has no place to search."""
    try:
        if name == "triage_check" and result.get("ok") and result.get("level") in ("amber", "red") and job_id:
            with db.tx(svc.s.db_path) as c:
                c.execute("UPDATE coach_jobs SET triage='amber' WHERE id=? AND triage IS NULL", (job_id,))
        elif name == "find_care" and result.get("ok") and result.get("need_place"):
            with db.tx(svc.s.db_path) as c:
                c.execute("INSERT INTO coach_loc_wait (user_id, job_id, kind, prompted, created_at) VALUES (?,?,?,0,?) "
                          "ON CONFLICT(user_id) DO UPDATE SET job_id=excluded.job_id, kind=excluded.kind, prompted=0, "
                          "created_at=excluded.created_at", (uid, job_id, str(result.get("kind") or "physio"), iso(now)))
    except Exception as e:   # bookkeeping must never take the job down
        log.warning("coach after_tool %s failed: %s", name, type(e).__name__)


# ------------------------------------------------------------------------------------------------ the tool
def _parse_day(text: str, today: date) -> date:
    t = (text or "").strip().lower()
    if t == "today":
        return today
    if t == "tomorrow":
        return today + timedelta(days=1)
    if t[:3] in DAYS and t.isalpha():
        ahead = (DAYS[t[:3]] - today.weekday()) % 7
        return today + timedelta(days=ahead)
    try:
        return date.fromisoformat(t)
    except ValueError:
        raise ValueError("to_day must be a weekday name, tomorrow or a date like 2026-10-24") from None


def _session_name(planned, res) -> str:
    if planned is not None and planned.session_name and planned.type == res.type:
        return planned.session_name
    return WORD.get(res.type, "run").lower()


def _day_word(d: date) -> str:
    return d.strftime("%A")


def _day_taken(c, uid: str, to: date, zone_id) -> bool:
    if c.execute("SELECT 1 FROM coach_proposals WHERE user_id=? AND state='confirmed' AND to_day=?", (uid, to.isoformat())).fetchone():
        return True
    lo = datetime.combine(to - timedelta(days=1), datetime.min.time()).isoformat() + "Z"
    hi = datetime.combine(to + timedelta(days=2), datetime.min.time()).isoformat() + "Z"
    for r in c.execute("SELECT start_utc FROM runs WHERE user_id=? AND start_utc BETWEEN ? AND ?", (uid, lo, hi)):
        if to_local(parse_iso(r["start_utc"]), zone_id).date() == to:
            return True
    return False


def label_for(change: str, name: str, frm: date, to: date | None) -> str:
    if change == "move" and to is not None:
        return f"Move {_day_word(frm)}'s {name} to {_day_word(to)}"
    return f"Make {_day_word(frm)}'s {name} an easy run"


def call(name: str, args: dict, ctx) -> dict:
    if name != "propose_plan_change":
        raise ValueError("unknown tool")
    svc, uid, now = ctx.svc, ctx.user_id, ctx.now
    change = args["change"]
    with db.tx(svc.s.db_path) as c:
        u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        if not u:
            raise ValueError("no runner")
        if in_triage_window(c, uid, now):
            raise ValueError(HELD_OFF + " Do not suggest plan changes; point them to a physio or GP if they ask.")
        cur = svc._coach_next(c, dict(u), now)
        if cur is None:
            raise ValueError("there is no next session to change")
        planned, res = cur
        today = to_local(now, u["zone_id"]).date()
        to = None
        if change == "move":
            if not args.get("to_day"):
                raise ValueError("a move needs to_day")
            to = _parse_day(args["to_day"], today)
            if to == res.day:
                raise ValueError("that is already the day")
            if not (today <= to <= today + timedelta(days=MAX_AHEAD_DAYS)):
                raise ValueError("pick a day within the next two weeks")
        elif res.type == "easy":
            raise ValueError("that session is already easy")
        if to is not None and _day_taken(c, uid, to, u["zone_id"]):
            raise ValueError("that day already has a run or a confirmed move: ask the runner whether to double up or pick another day")
        label = label_for(change, _session_name(planned, res), res.day, to)
        c.execute("UPDATE coach_proposals SET state='superseded', decided_at=? WHERE user_id=? AND state='pending'", (iso(now), uid))
        pid = c.execute("INSERT INTO coach_proposals (user_id, job_id, change, from_day, to_day, label, created_at) "
                        "VALUES (?,?,?,?,?,?,?)",
                        (uid, ctx.job_id, change, res.day.isoformat(), to.isoformat() if to else None, label, iso(now))).lastrowid
    return {"proposal_id": pid, "proposed": label, "status": "awaiting_the_runners_confirmation",
            "note": "Nothing has changed. The runner gets Confirm and Decline buttons right after your reply. Say what you "
                    "proposed and that it is their call; never say it is done."}


# ------------------------------------------------------------------------------------------------ the override
def apply_overrides(c, uid: str, planned, res, today: date):
    """The runner's next session with their confirmed proposals applied. Read-only. `res` is what the check-in answers resolved
    (None when the app's planned day has gone by); a proposal only applies to the session that was the next one when it was made."""
    rows = c.execute("SELECT change, from_day, to_day FROM coach_proposals WHERE user_id=? AND state='confirmed' "
                     "ORDER BY decided_at, id", (uid,)).fetchall()
    for r in rows:
        try:
            frm = date.fromisoformat(r["from_day"])
            to = date.fromisoformat(r["to_day"]) if r["to_day"] else None
        except ValueError:
            continue
        base = res
        if base is None and planned is not None and planned.day == frm:
            base = Resolved(planned.type, planned.day, False, planned.day, False, planned)   # its own day has passed
        if base is None or base.day != frm:
            continue
        if r["change"] == "move" and to is not None and to >= today:
            res = replace(base, day=to, moved=True)
        elif r["change"] == "easier" and base.type != "easy":
            res = replace(base, type="easy", easier=True)
    return res


# ------------------------------------------------------------------------------------------------ after the reply
def _send_quiet(fn, *a, **kw):
    with contextlib.suppress(ChannelError):
        return fn(*a, **kw)


def after_reply(coach, ch, ref: str, uid: str, job_id: int) -> None:
    """Called once a reply is fully sent. Sends the Confirm / Decline message for a proposal made in this job, the one-shot
    location keyboard, and refreshes the rolling summary. Never raises."""
    try:
        svc = coach.svc
        with db.tx(svc.s.db_path) as c:
            props = [dict(r) for r in c.execute("SELECT id, label FROM coach_proposals WHERE user_id=? AND job_id=? "
                                                 "AND state='pending' AND offered=0", (uid, job_id))]
            wait = c.execute("SELECT 1 FROM coach_loc_wait WHERE user_id=? AND job_id=? AND prompted=0", (uid, job_id)).fetchone()
            old = c.execute("SELECT 1 FROM coach_loc_wait WHERE user_id=? AND job_id<>? AND prompted=1", (uid, job_id)).fetchone()
            if old:   # the runner carried on in words (typed a place): the request is over, take its keyboard away
                c.execute("DELETE FROM coach_loc_wait WHERE user_id=? AND job_id<>? AND prompted=1", (uid, job_id))
            for p in props:
                c.execute("UPDATE coach_proposals SET offered=1 WHERE id=?", (p["id"],))
            if wait:
                c.execute("UPDATE coach_loc_wait SET prompted=1 WHERE user_id=?", (uid,))
        for p in props:
            _send_quiet(ch.send_text, ref, f"Proposed change: {p['label']}. Nothing changes until you confirm (this stays open for "
                        "24 hours).", buttons=[[("Confirm", f"cp:{p['id']}:y"), ("Decline", f"cp:{p['id']}:n")]])
        if old and not wait and getattr(ch, "supports_html", False):
            _send_quiet(ch.send_text, ref, "No need to share a location now.", remove_keyboard=True)
        if wait and getattr(ch, "supports_html", False):
            _send_quiet(ch.send_text, ref, "Tap the button to share where you are, or just type your suburb. I use it once to look "
                        "up places near you and don't keep it.", request_location=True)
    except Exception as e:
        log.warning("coach after_reply failed: %s", type(e).__name__)


def refresh_memory(svc, uid: str) -> None:
    """The rolling summary: a model call, so the coach worker runs it after the reply is out. Never raises."""
    try:
        from . import memory
        memory.refresh_if_due(svc, uid, now_utc())
    except Exception as e:
        log.warning("coach memory refresh failed: %s", type(e).__name__)


def purge(c, uid: str) -> None:
    """Consent withdrawn (and DELETE, which cascades): memory, proposals and any waiting location request go."""
    for t in ("coach_memory", "coach_proposals", "coach_loc_wait"):
        c.execute(f"DELETE FROM {t} WHERE user_id=?", (uid,))


# ------------------------------------------------------------------------------------------------ taps and commands
def _gate_ok(svc, uid: str, allow_paused: bool = False) -> bool:
    g = svc.coach.gate_for(uid)
    return g is None or (allow_paused and g == "paused")


def _ack(ch, inb, toast: str) -> None:
    fn = getattr(ch, "ack_chip", None)
    if fn:
        with contextlib.suppress(Exception):
            fn(inb, toast)


def handle_inbound(svc, ch, inb, now: datetime) -> bool:
    """Route a coach proposal / memory button, a location share or the /memory command. True when taken (nothing else runs)."""
    special = inb.action is not None or inb.location is not None
    if not special and (inb.card_id is not None or inb.text.strip().lower() not in ("/memory", "memory")):
        return False
    if not svc.coach.enabled:
        return special   # a stale button or a stray location pin is ignored; the word /memory keeps its ordinary path
    user = svc._user_by_ref(inb.channel, inb.ref)
    if not user:
        return special
    if inb.action is not None:
        if svc._seen(inb, now):
            return True
        if inb.action.startswith("cp:"):
            _tap_proposal(svc, ch, inb, user, now)
        else:
            from . import memory
            memory.tap(svc, ch, inb, user, now)
        return True
    if inb.location is not None:
        if not svc._seen(inb, now):
            _location(svc, ch, inb, user, now)
        return True
    # "/memory"
    if not _gate_ok(svc, user["id"], allow_paused=True):
        return False   # an ungated runner gets the ordinary path
    if svc._seen(inb, now):
        return True
    from . import memory
    memory.show(svc, ch, inb.ref, user["id"], now)
    return True


def _tap_proposal(svc, ch, inb, user: dict, now: datetime) -> None:
    uid = user["id"]
    _, _, rest = inb.action.partition(":")
    pid_s, _, yn = rest.partition(":")
    pid = int(pid_s)
    toast, said = "That one has moved on.", None
    with db.tx(svc.s.db_path) as c:
        p = c.execute("SELECT * FROM coach_proposals WHERE id=? AND user_id=?", (pid, uid)).fetchone()   # only your own
        if p is None:
            pass
        elif p["state"] != "pending":   # idempotent: a second tap, or the other button after a decision, changes nothing
            toast = {"confirmed": "Already confirmed.", "declined": "Already declined."}.get(p["state"], "That one has expired.")
        elif parse_iso(p["created_at"]) + PROPOSAL_TTL < now:
            c.execute("UPDATE coach_proposals SET state='expired', decided_at=? WHERE id=?", (iso(now), pid))
            toast = "That proposal has expired. Ask me again."
        elif yn == "n":
            c.execute("UPDATE coach_proposals SET state='declined', decided_at=? WHERE id=? AND state='pending'", (iso(now), pid))
            toast, said = "Declined.", "Okay, leaving it as it is."
            svc.coach._message(c, uid, None, "runner", f"Declined: {p['label']}", now)
            svc.coach._message(c, uid, None, "coach", said, now)
        elif not _gate_ok(svc, uid):
            toast = "The coach is paused."
        elif in_triage_window(c, uid, now):
            toast, said = "Holding off for now.", HELD_OFF
        else:
            cur = svc._coach_next(c, user, now)
            if cur is None or cur[1].day.isoformat() != p["from_day"]:   # the session it was about is no longer the next one
                c.execute("UPDATE coach_proposals SET state='expired', decided_at=? WHERE id=?", (iso(now), pid))
                toast, said = "That session has changed.", "That session has changed since I suggested it. Ask me again if you still want it."
            elif c.execute("UPDATE coach_proposals SET state='confirmed', decided_at=? WHERE id=? AND state='pending'",
                           (iso(now), pid)).rowcount == 1:
                toast, said = "Done.", f"Done: {p['label']}."
                svc.coach._message(c, uid, None, "runner", f"Confirmed: {p['label']}", now)
                svc.coach._message(c, uid, None, "coach", said, now)
    _ack(ch, inb, toast)
    if said:
        _send_quiet(ch.send_text, inb.ref, said)


# ------------------------------------------------------------------------------------------------ location
def _location(svc, ch, inb, user: dict, now: datetime) -> None:
    """A shared location answers the waiting find_care request. The position is rounded to about 1 km before anything uses it
    and is never written: a local variable, one OSM lookup, a reply."""
    from . import places
    uid = user["id"]
    with db.tx(svc.s.db_path) as c:
        w = c.execute("SELECT kind, created_at FROM coach_loc_wait WHERE user_id=?", (uid,)).fetchone()
        if w:
            c.execute("DELETE FROM coach_loc_wait WHERE user_id=?", (uid,))   # one shot
        gated = _gate_ok(svc, uid)
    if not gated:
        return
    if not w or parse_iso(w["created_at"]) + LOC_WAIT_TTL < now:
        _send_quiet(ch.send_text, inb.ref, "Thanks, but I wasn't waiting on a location, so I haven't kept it.")
        return
    kind = w["kind"]
    centre = (round(inb.location[0], 2), round(inb.location[1], 2))
    try:
        results = places._search(svc.http, kind, centre)
    except Exception as e:
        log.warning("coach location lookup failed: %s", type(e).__name__)
        _send_quiet(ch.send_text, inb.ref, "I couldn't look that up just now. Type your suburb and I'll try again.")
        return
    lines = [f"Closest {KIND_WORDS.get(kind, 'care')} from OpenStreetMap:"]
    for r in results:
        bits = [f"{r['name']}, {r['distance_km']} km"] + [r[k] for k in ("address", "phone", "website") if r.get(k)]
        lines.append("- " + "; ".join(bits))
    if not results:
        lines.append("Nothing found within 10 km. A map search or your GP is the next step.")
    if kind == "urgent":
        em = redflag.EMERGENCY.get(redflag.country(user.get("zone_id")) or "")
        if em:
            lines.append(f"In an emergency call {em}.")
    lines.append(places.ATTRIBUTION)
    _send_quiet(ch.send_text, inb.ref, "\n".join(lines))
    with db.tx(svc.s.db_path) as c:   # the chat records that it happened, not where or what came back
        svc.coach._message(c, uid, None, "coach", f"(I looked up nearby {KIND_WORDS.get(kind, 'care')} from the location you shared.)", now)


KIND_WORDS = {"physio": "physios", "sports_med": "sports doctors", "gp": "GPs", "urgent": "urgent care"}
