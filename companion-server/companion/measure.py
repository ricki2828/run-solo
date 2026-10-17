"""Phase A measurement: what a consented runner does is counted by kind (never content), and the two survey questions.

inbound_events(user_id, kind, ts): tap | note | feedback | command | text | miniapp_open. Logged only for a runner who has
agreed to consent v2, after the per-chat limiter. Kept EVENT_RETENTION_DAYS, deleted with the runner, left out of backups.

survey_answers: the trust question (kind "trust", ref = the recap it is about, asked the day after the recap) and the Sean Ellis question (kind "ellis",
ref "once"), as fixed options. Both are an unprompted question with a keyboard, so each claims the day's one question
(question_cap) like every other question; neither is ever sent to a model.
"""
from __future__ import annotations

import json
import secrets
from datetime import datetime, timedelta

from . import db
from .convo import engine as cv_engine
from .timeutil import iso, now_utc, parse_iso, to_local

EVENT_KINDS = frozenset({"tap", "note", "feedback", "command", "text", "miniapp_open"})
EVENT_RETENTION_DAYS = 120
MINIAPP_OPEN_GAP_MIN = 30        # a Mini App that refreshes is one open, not many

TRUST_ACTION = "trust"           # trust:spot | trust:mostly | trust:not
TRUST_OPTIONS = (("spot", "Spot on"), ("mostly", "Mostly"), ("not", "Not really"))
TRUST_HEAD = "One question"
TRUST_LINE = "Did last week's coaching get you right?"
TRUST_WINDOW_DAYS = 6          # the recap goes out Sunday; the question may follow until the next Saturday
SURVEY_START_MIN, SURVEY_END_MIN = 19 * 60 + 30, 21 * 60   # evening: a morning or post-run check-in that day has already taken the question
TRUST_THANKS = "Thanks, that helps."

# "Not really" gets one follow-up card in the same chat: what was off. Fixed options, kept like the trust answer.
WHY_OFF_ACTION = "whyoff"        # whyoff:generic | numbers | timing | other
WHY_OFF_OPTIONS = (("generic", "Too generic"), ("numbers", "Wrong numbers"), ("timing", "Bad timing"), ("other", "Something else"))
WHY_OFF_HEAD = "What was off?"
WHY_OFF_LINE = "One tap and I'll pass it on."
WHY_OFF_THANKS = "Thanks, passed on."
WHY_OFF_OTHER = "Tell me what was off, in your own words."

ELLIS_ACTION = "ellis"           # ellis:very | ellis:somewhat | ellis:not | ellis:stopped
ELLIS_OPTIONS = (("very", "Very disappointed"), ("somewhat", "Somewhat"), ("not", "Not disappointed"),
                 ("stopped", "I've stopped using it"))
ELLIS_HEAD = "One question"
ELLIS_TEXT = "If the coach went away tomorrow, how would you feel?"
ELLIS_FROM_DAY, ELLIS_TO_DAY = 21, 27     # days after the runner joined; asked once in this window
ELLIS_START_MIN, ELLIS_END_MIN = SURVEY_START_MIN, SURVEY_END_MIN
ELLIS_RUN_ID = "ellis"

SURVEY_VALUES = {
    "trust": frozenset(v for v, _ in TRUST_OPTIONS),
    "ellis": frozenset(v for v, _ in ELLIS_OPTIONS),
}


def purge_surveys(c, now: datetime, end: str, force: bool = False) -> int:
    """Delete every survey answer from the test's last day on (`end` is Settings.test_end_date, a YYYY-MM-DD date), or at
    once with force. Runs on the caller's connection. Returns the rows removed; the answers are kept only until then."""
    if not force and now.date().isoformat() < end:
        return 0
    return c.execute("DELETE FROM survey_answers").rowcount


class MeasureMixin:
    def _log_event(self, user: dict | None, kind: str, now: datetime) -> None:
        """One row: who, what kind, when. Nothing else. A runner who has not agreed to consent v2 leaves no trace."""
        if not user or kind not in EVENT_KINDS or db.origin_active() or user.get("paused"):
            return   # a runner who said STOP is not counted
        with db.tx(self.s.db_path) as c:
            if not self._ci_consented(c, user["id"]):
                return
            if kind == "miniapp_open" and c.execute(
                    "SELECT 1 FROM inbound_events WHERE user_id=? AND kind=? AND ts > ?",
                    (user["id"], kind, iso(now - timedelta(minutes=MINIAPP_OPEN_GAP_MIN)))).fetchone():
                return
            c.execute("INSERT INTO inbound_events (user_id, kind, ts) VALUES (?,?,?)", (user["id"], kind, iso(now)))

    def log_miniapp_open(self, uid: str, now: datetime) -> None:
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT id FROM users WHERE id=?", (uid,)).fetchone()
        self._log_event(dict(u) if u else None, "miniapp_open", now)

    # ------------------------------------------------------------------ trust question (the day after the weekly recap)
    def plan_trust(self, now: datetime | None = None, only_user: str | None = None) -> int:
        """Queue the trust question about last week's cards. It never rides on the recap (Sunday's 19:05 shape check-in
        needs that day's one question): it goes out on the first day after the recap that has no other question, between
        19:30 and 21:00 local, for at most TRUST_WINDOW_DAYS. One outbox row per runner per local day while it is open."""
        from .service import replay_hold
        now = now or now_utc()
        n = 0
        who, args = ((" AND id = ?", (only_user,)) if only_user else (f" AND id NOT IN {replay_hold(now)}", ()))
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND ops_paused=0 AND consent_at IS NOT NULL" + who, args)]
            for u in users:
                loc = to_local(now, u["zone_id"])
                if not (SURVEY_START_MIN <= loc.hour * 60 + loc.minute < SURVEY_END_MIN):
                    continue
                recap = c.execute(
                    "SELECT run_id, created_at FROM cards WHERE user_id=? AND kind='recap' AND created_at > ? "
                    "ORDER BY created_at DESC LIMIT 1", (u["id"], iso(now - timedelta(days=TRUST_WINDOW_DAYS)))).fetchone()
                if not recap or to_local(parse_iso(recap["created_at"]), u["zone_id"]).date() >= loc.date():
                    continue   # no recap in the window, or it is still the recap's own day
                wk = recap["run_id"].split(":", 1)[-1]
                if c.execute("SELECT 1 FROM convo_log WHERE user_id=? AND kind='recap_empty' AND key=?", (u["id"], wk)).fetchone():
                    continue   # an empty week's nudge is not a week of cards to rate
                if c.execute("SELECT 1 FROM cards WHERE user_id=? AND kind='trust' AND run_id=?", (u["id"], recap["run_id"])).fetchone():
                    continue
                if not self._ci_consented(c, u["id"]) or self._ci_cap_taken(c, u["id"], now):
                    continue
                n += c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                               (u["id"], "trust", iso(now), f"trust:{u['id']}:{loc.date().isoformat()}", recap["run_id"])).rowcount
        return n

    def _build_trust_card(self, uid: str, recap_run_id: str, now: datetime) -> str | None:
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='trust'", (uid, recap_run_id)).fetchone()
            if ex:
                return ex["card_id"]
        with db.tx(self.s.db_path) as c:
            if not self._ci_consented(c, uid) or self._ci_cap_taken(c, uid, now):
                return None   # not today; plan_trust tries again tomorrow while the window is open
            self._ci_claim_question(c, uid, "trust", now)
            card_id = secrets.token_hex(16)
            buttons = [{"label": l, "action": f"{TRUST_ACTION}:{v}", "row": 0} for v, l in TRUST_OPTIONS]
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, recap_run_id, "trust", TRUST_HEAD, TRUST_LINE, json.dumps(buttons), "template", iso(now)))
            self._convo_write(c, uid, now, card_id, "trust", cv_engine.MediaPlan("none", False, "trust"), "", [], None)
        return card_id

    def _trust_not_followup(self, c, user: dict, recap_run_id: str, now: datetime) -> None:
        """A "Not really" answer (inside the tap's transaction): queue the one-tap "what was off?" card and tell the ops
        digest. The card is a direct reply to the runner's own tap, so it takes no slot from the daily question cap."""
        from .rails import add_alert, tag
        c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                  (user["id"], "trust_why", iso(now), f"trustwhy:{user['id']}:{recap_run_id}", recap_run_id))
        add_alert(c, f"trust-not:{user['id']}:{recap_run_id}", f"Run Supreme coach: {tag(user.get('tester_no'))} said coaching was not right",
                  "Answered Not really to the weekly trust question. A what-was-off card has been sent.", now)

    def _build_trust_why_card(self, uid: str, recap_run_id: str, now: datetime) -> str | None:
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='trust_why'", (uid, recap_run_id)).fetchone()
            if ex:
                return ex["card_id"]
        with db.tx(self.s.db_path) as c:
            if not self._ci_consented(c, uid):
                return None
            card_id = secrets.token_hex(16)
            buttons = [{"label": l, "action": f"{WHY_OFF_ACTION}:{v}", "row": i // 2} for i, (v, l) in enumerate(WHY_OFF_OPTIONS)]
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, recap_run_id, "trust_why", WHY_OFF_HEAD, WHY_OFF_LINE, json.dumps(buttons), "template", iso(now)))
            self._convo_write(c, uid, now, card_id, "trust_why", cv_engine.MediaPlan("none", False, "trust_why"), "", [], None)
        return card_id

    def _why_off_answer(self, c, user: dict, card: dict, value: str, now: datetime) -> bool:
        from .rails import add_alert, tag
        if card["kind"] != "trust_why" or value not in {v for v, _ in WHY_OFF_OPTIONS} or not self._ci_consented(c, user["id"]):
            return False
        c.execute("INSERT INTO survey_answers (user_id, kind, ref, value, created_at) VALUES (?,?,?,?,?) "
                  "ON CONFLICT(user_id, kind, ref) DO UPDATE SET value=excluded.value, created_at=excluded.created_at",
                  (user["id"], "trust_why", card["run_id"], value, iso(now)))
        label = dict(WHY_OFF_OPTIONS)[value]
        add_alert(c, f"trust-why:{user['id']}:{card['run_id']}", f"Run Supreme coach: {tag(user.get('tester_no'))} says what was off",
                  f"{label}.", now)
        return True

    # ------------------------------------------------------------------ Sean Ellis (once, days 21-27)
    def plan_ellis(self, now: datetime | None = None, only_user: str | None = None) -> int:
        """Queue the one-off question for runners 21-27 days after they joined, between 19:30 and 21:00 local. One outbox row
        per runner per local day, so a day that already had its question tries again the next day, until day 27."""
        from .service import replay_hold
        now = now or now_utc()
        n = 0
        who, args = ((" AND id = ?", (only_user,)) if only_user else (f" AND id NOT IN {replay_hold(now)}", ()))
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND ops_paused=0 AND consent_at IS NOT NULL "
                "AND consent_at <= ? AND consent_at > ?" + who,
                (iso(now - timedelta(days=ELLIS_FROM_DAY)), iso(now - timedelta(days=ELLIS_TO_DAY + 1)), *args))]
            for u in users:
                loc = to_local(now, u["zone_id"])
                if not (ELLIS_START_MIN <= loc.hour * 60 + loc.minute < ELLIS_END_MIN):
                    continue
                if c.execute("SELECT 1 FROM cards WHERE user_id=? AND run_id=? AND kind='ellis'", (u["id"], ELLIS_RUN_ID)).fetchone():
                    continue
                if not self._ci_consented(c, u["id"]) or self._ci_cap_taken(c, u["id"], now):
                    continue
                n += c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                               (u["id"], "ellis", iso(now), f"ellis:{u['id']}:{loc.date().isoformat()}", ELLIS_RUN_ID)).rowcount
        return n

    def _build_ellis_card(self, uid: str, now: datetime) -> str | None:
        with db.ro(self.s.db_path) as c:
            ex = c.execute("SELECT card_id FROM cards WHERE user_id=? AND run_id=? AND kind='ellis'", (uid, ELLIS_RUN_ID)).fetchone()
            if ex:
                return ex["card_id"]
        with db.tx(self.s.db_path) as c:
            if not self._ci_consented(c, uid) or self._ci_cap_taken(c, uid, now):
                return None   # not today; plan_ellis tries again tomorrow while the window is open
            self._ci_claim_question(c, uid, "ellis", now)
            card_id = secrets.token_hex(16)
            buttons = [{"label": l, "action": f"{ELLIS_ACTION}:{v}", "row": i // 2} for i, (v, l) in enumerate(ELLIS_OPTIONS)]
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)",
                      (card_id, uid, ELLIS_RUN_ID, "ellis", ELLIS_HEAD, ELLIS_TEXT, json.dumps(buttons), "template", iso(now)))
            self._convo_write(c, uid, now, card_id, "ellis", cv_engine.MediaPlan("none", False, "ellis"), "", [], None)
        return card_id

    # ------------------------------------------------------------------ answers
    def _survey_answer(self, c, user: dict, card: dict, kind: str, value: str, now: datetime) -> bool:
        """Store one answer in the caller's transaction. False (nothing stored) for an unknown option, the wrong kind of
        card, or a runner who has not agreed to consent v2."""
        want = {"trust": "trust", "ellis": "ellis"}[kind]
        if value not in SURVEY_VALUES[kind] or card["kind"] != want or not self._ci_consented(c, user["id"]):
            return False
        ref = card["run_id"] if kind == "trust" else ELLIS_RUN_ID
        c.execute("INSERT INTO survey_answers (user_id, kind, ref, value, created_at) VALUES (?,?,?,?,?) "
                  "ON CONFLICT(user_id, kind, ref) DO UPDATE SET value=excluded.value, created_at=excluded.created_at",
                  (user["id"], kind, ref, value, iso(now)))
        return True
