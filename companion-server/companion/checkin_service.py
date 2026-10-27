"""Service side of the check-ins (stream S1): planning, the at-most-once send, taps that edit the message in place,
the read-only next-session payload for the app, and the 14-day purge.

Mixed into `service.Service`. Rules it enforces (eng-review 13-Oct):
  A2  no check-in value reaches the writer: this module never imports it, the answers sit in their own tables (not in
      `memory`, which feeds the writer's digest) and every line is a checkin_copy template.
  C1  at most one unprompted question with a keyboard per runner local day, claimed through the unique key of
      `question_cap` before the send. The weekly question and the evening suggestion claim the same row.
  C2  a coach-initiated send claims `checkin_slots (user, slot, local date)` first and stores the message id after; a
      slot past its window is dropped, never deferred.
  C3  the run card edits the morning card into the result; "not modified" is success; any other failure sends a fresh
      card and updates the stored message id.
  P1  answers, slots and the cap ledger go after 14 days (`purge_checkins`), with the user on DELETE, out of the
      nightly backup (backup.PRIVATE_TABLES) and into the export (`checkins`).
"""
from __future__ import annotations

import dataclasses
import logging
import re
import secrets
from datetime import date, datetime, timedelta
from typing import Any

from . import checkin_copy as cc
from . import checkins as ci
from . import db
from . import default_week as dw
from . import heat
from . import quest as cv_quest
from .channels import ChannelError
from .coach.ext import actions as coach_actions
from .timeutil import in_quiet, iso, now_utc, parse_iso, quiet_end_utc, to_local

log = logging.getLogger("companion")

CI_KINDS = ("ci", "ci_edit")
LINE_LOOKBACK_DAYS = 3
COACH_LINE_KINDS = ("run", "evening", "recap", "monthly")
WEEK_DEBOUNCE_S = 45   # a burst of runs and taps becomes one render of the week card
DAY_NAMES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


def ci_types() -> frozenset[str]:
    return frozenset({"easy", "long", "tempo", "interval", "race", "cooper", "trail", "rest"})


def _sep(*parts: object) -> str:
    return "|".join(str(p) for p in parts)


class CheckinMixin:
    s: Any
    channels: dict[str, Any]
    media: Any
    _memory_set: Any   # Service's

    # ------------------------------------------------------------------ reading
    @staticmethod
    def _ci_answers(c, uid: str, now: datetime) -> ci.Answers:
        rows = [dict(r) for r in c.execute(
            "SELECT kind, local_date, value, created_at FROM checkin_answers WHERE user_id=? AND created_at>?",
            (uid, iso(now - timedelta(days=ci.RETENTION_DAYS))))]
        return ci.Answers.from_rows(rows)

    @staticmethod
    def _ci_usual(c, uid: str) -> frozenset[int] | None:
        r = c.execute("SELECT value FROM memory WHERE user_id=? AND key='usual_days'", (uid,)).fetchone()
        return ci.usual_weekdays(r["value"] if r else None)

    @staticmethod
    def _ci_latest_run(c, uid: str) -> dict | None:
        r = c.execute("SELECT * FROM runs WHERE user_id=? ORDER BY start_utc DESC LIMIT 1", (uid,)).fetchone()
        return dict(r) if r else None

    @staticmethod
    def _ci_default_planned(c, user: dict, today: date, now: datetime) -> ci.Planned | None:
        uid = user["id"]
        hist = [dict(r) for r in c.execute("SELECT * FROM runs WHERE user_id=? ORDER BY start_utc DESC LIMIT 80", (uid,))]
        memory = {r["key"]: r["value"] for r in c.execute("SELECT key, value FROM memory WHERE user_id=?", (uid,))}
        return dw.next_planned(hist, memory=memory, zone_id=user["zone_id"], today=today, now=now)

    def _ci_state(self, c, user: dict, now: datetime, *, answers: bool = True):
        """-> (answers, planned, usual weekdays, runner's local today, resolved next session). `answers=False` leaves the
        check-in answers out (a runner who has not agreed to that data): the plan and the default week still resolve."""
        uid = user["id"]
        ans = self._ci_answers(c, uid, now) if answers else ci.Answers()
        planned = ci.planned_from_run(self._ci_latest_run(c, uid))
        usual = self._ci_usual(c, uid)
        today = to_local(now, user["zone_id"]).date()
        res = coach_actions.apply_overrides(c, uid, planned, ci.resolve(planned, ans, today, usual), today)   # coach PR4: confirmed proposals
        if res is None:   # no 4-week plan, or its last snapshot has gone by: the default coach week, so there is still a session
            dflt = self._ci_default_planned(c, user, today, now)
            if dflt is not None:
                planned, res = dflt, coach_actions.apply_overrides(c, uid, dflt, ci.resolve(dflt, ans, today, usual), today)
        return ans, planned, usual, today, res

    @staticmethod
    def _ci_when(c, uid: str, user: dict, for_date: date, now: datetime) -> str | None:
        hist = [dict(r) for r in c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? ORDER BY start_utc DESC "
                                           "LIMIT 80", (uid,))]
        if len(hist) < ci.MIN_RUNS_FOR_START_TIME:
            return None   # one or two runs are not a habit: the card says it is on the plan, not when
        m = ci.usual_start_min(hist, for_date.weekday(), user["zone_id"], now)
        return None if m is None else f"around {m // 60}:{m % 60:02d}"

    @staticmethod
    def _ci_session_name(planned: ci.Planned | None, typ: str) -> str | None:
        """The display name when the plan named the session and it is still that session (a session the coach made easy
        is a different one). The app's plan names it, or the default week does from the runner's own runs (default_week)."""
        if planned and planned.session_name and typ == planned.type:
            return planned.session_name
        return None

    def _ci_ctx(self, c, user: dict, slot: str, for_date: date, now: datetime) -> cc.Ctx:
        ans, planned, usual, _today, res = self._ci_state(c, user, now)
        # the session as it stands now: "flat" has made a hard one easy, so the morning card must not call it hard
        typ = res.type if res and res.day == for_date else planned.type if planned else None
        name = self._ci_session_name(planned, typ) if planned and typ else None
        label = cc.session_label(typ, planned.minutes, planned.distance_m, name) if planned and typ else None
        if slot == "shape":
            away = ans.get("shape", for_date) == "away"
            back = ci._next_usual(for_date + timedelta(days=7), usual) if away else (res.day if res else None)
            return cc.Ctx(label=label, moved_to=back)
        moved_to = ci._move_from(for_date, ans, usual)
        easier = ans.get("ready", for_date) == "flat" and bool(planned) and planned.type != "easy"
        return cc.Ctx(label=label, when=self._ci_when(c, user["id"], user, for_date, now), moved_to=moved_to,
                      easier=easier, original_word=cc.WORD.get(planned.type) if easier and planned else None,
                      work_pace_s=self._ci_work_pace(planned, typ))

    @staticmethod
    def _ci_work_pace(planned: ci.Planned | None, typ: str | None) -> float | None:
        """The app's work pace for the planned quality session, the midpoint of its range, or None: no pace sent, or the
        session is no longer the quality one (a "flat" made it easy), so the pace no longer belongs to it."""
        if not planned or typ != "quality" or planned.type != "quality":
            return None
        if planned.pace_lo_s is None or planned.pace_hi_s is None:
            return None
        return (planned.pace_lo_s + planned.pace_hi_s) / 2

    @staticmethod
    def _ci_stage(slot: str, ans: ci.Answers, for_date: date) -> tuple[str | None, str | None]:
        """-> (stage, skip reason) the message should show now, from the answers alone."""
        if slot == "today":
            t = ans.get("today", for_date)
            return (t, ans.get("why", for_date)) if t else (None, None)
        return ans.get(slot, for_date), None

    def _ci_heat(self, user: dict, slot: str, for_date: date, now: datetime) -> int | None:
        """Seconds per km that today's forecast heat adds to the runner's easy pace, for the morning card's "Hot one"
        line, or None. Only the unanswered card carries the line, so nothing is fetched for any other stage. Uses the
        weather the server already has (the opted-in 0.1 degree area and the forecast cache); no new data is stored and
        no answer goes out. Call it outside a write transaction: it may make one network request."""
        if slot != "today" or not self.s.weather_enabled:
            return None
        with db.ro(self.s.db_path) as c:
            ans, *_ = self._ci_state(c, user, now)
            if ans.get("today", for_date) is not None:
                return None
            lat, lon = self._area(c, user["id"], None, now)
            hist = [dict(r) for r in c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? ORDER BY start_utc "
                                               "DESC LIMIT 80", (user["id"],))]
            start_m = ci.usual_start_min(hist, for_date.weekday(), user["zone_id"], now)
            paces = [r["p"] for r in c.execute(
                "SELECT COALESCE(true_pace_s_per_km, pace_s_per_km) p FROM runs WHERE user_id=? AND type='easy' "
                "AND start_utc>=? AND COALESCE(true_pace_s_per_km, pace_s_per_km) IS NOT NULL "
                "ORDER BY start_utc DESC LIMIT 6", (user["id"], iso(now - timedelta(days=42))))]
        if lat is None or lon is None or len(paces) < 2:
            return None
        hr = (start_m // 60) if start_m is not None else 7   # the hour the runner usually starts
        td = self.weather.heat_at(lat, lon, user["zone_id"], for_date, hr)   # (temp C, dew point C) or None
        if td is None:
            return None
        paces.sort()
        return heat.extra_s_per_km(paces[len(paces) // 2], td[0], td[1])

    def _ci_text(self, c, user: dict, slot: str, for_date: date, now: datetime, heat_s_km: int | None = None):
        ans, *_ = self._ci_state(c, user, now)
        stage, why = self._ci_stage(slot, ans, for_date)
        ctx = dataclasses.replace(self._ci_ctx(c, user, slot, for_date, now), heat_s_km=heat_s_km)
        head, body, kb = cc.today(stage, ctx, why) if slot == "today" else cc.RENDER[slot](stage, ctx)
        return head, body, kb

    # ------------------------------------------------------------------ consent gate
    def _ci_consented(self, c, uid: str) -> bool:
        """The app told us this runner agreed to the check-in data (consent version at or above the requirement).
        Missing, old or lowered values all mean no. Read from the database each time, never from a cached user dict."""
        r = c.execute("SELECT checkin_consent FROM users WHERE id=?", (uid,)).fetchone()
        return bool(r and r["checkin_consent"] is not None and r["checkin_consent"] >= self.s.checkin_consent_required)

    def _ci_unpin_weeks(self, uid: str) -> None:
        """Consent withdrawn: the pinned week cards stop being pinned (the pictures stay in the chat; the runner can delete
        them). Best effort: a failed unpin must not fail the withdrawal."""
        ch = self.channels.get("telegram")
        if ch is None:
            return
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT channel, chat_ref FROM users WHERE id=?", (uid,)).fetchone()
            mids = [r["message_id"] for r in c.execute(
                "SELECT message_id FROM checkin_slots WHERE user_id=? AND slot='week' AND state='sent' AND message_id IS NOT NULL",
                (uid,))]
        if u is None or u["channel"] != "telegram":
            return
        for mid in mids:
            try:
                ch.unpin(u["chat_ref"], mid)
            except Exception:
                log.warning("unpin failed user=%s", uid)

    # ------------------------------------------------------------------ the question cap (C1)
    @staticmethod
    def _ci_local_day(c, uid: str, now: datetime) -> str:
        z = c.execute("SELECT zone_id FROM users WHERE id=?", (uid,)).fetchone()
        return to_local(now, z["zone_id"] if z else "UTC").date().isoformat()

    def _ci_cap_taken(self, c, uid: str, now: datetime, local_date: str | None = None) -> bool:
        """`local_date` is for a caller that already holds the runner's local day (the evening card is keyed by it).
        The coach replay (a developer tool walking a virtual clock) neither takes nor leaves a cap row."""
        if db.origin_active():
            return False
        return c.execute("SELECT 1 FROM question_cap WHERE user_id=? AND local_date=?",
                         (uid, local_date or self._ci_local_day(c, uid, now))).fetchone() is not None

    def _ci_claim_question(self, c, uid: str, slot: str, now: datetime, local_date: str | None = None) -> bool:
        """True when this send won today's one question. Callers hold a write transaction (BEGIN IMMEDIATE), so the check
        and the claim are atomic; the unique key is the cap even if two workers ever raced."""
        if db.origin_active():
            return True
        return c.execute("INSERT OR IGNORE INTO question_cap (user_id, local_date, slot, claimed_at) VALUES (?,?,?,?)",
                         (uid, local_date or self._ci_local_day(c, uid, now), slot, iso(now))).rowcount == 1

    # ------------------------------------------------------------------ planning
    def plan_checkins(self, now: datetime | None = None, only_user: str | None = None) -> int:
        """Queue the evening-before readiness question, the morning card, the post-run question and the Sunday shape
        question. Each is a `ci` outbox row keyed (user, slot, date) and carrying its own expiry. Telegram only."""
        from .service import replay_hold   # late: service imports this module
        now = now or now_utc()
        n = 0
        if not self.s.checkins_enabled:
            return 0
        who, args = ((" AND id = ?", (only_user,)) if only_user else (f" AND id NOT IN {replay_hold(now)}", ()))
        with db.tx(self.s.db_path) as c:
            users = [dict(r) for r in c.execute(
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND ops_paused=0 AND last_run_utc >= ? "
                "AND checkin_consent >= ?" + who,
                (iso(now - timedelta(days=14)), self.s.checkin_consent_required, *args))]
            for u in users:
                try:
                    n += self._ci_plan_user(c, u, now)
                except Exception as e:  # one runner's odd data never stops the others
                    log.error("check-in planning failed: %s", type(e).__name__)
        return n

    def _ci_enqueue(self, c, u: dict, slot: str, for_date: date, due: datetime, now: datetime,
                    latest: datetime | None = None) -> int:
        deadline = ci.send_deadline(slot, due, latest)
        if now >= deadline:
            return 0
        if c.execute("SELECT 1 FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                     (u["id"], slot, for_date.isoformat())).fetchone():
            return 0
        return c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                         (u["id"], "ci", iso(due),
                          f"ci:{u['id']}:{slot}:{for_date.isoformat()}",
                          _sep(slot, for_date.isoformat(), iso(deadline)))).rowcount

    def _ci_wanted(self, c, u: dict, slot: str, for_date: date, now: datetime) -> bool:
        """Is this check-in still worth sending right now? The same test plans it and, again, sends it."""
        if not self._ci_consented(c, u["id"]):
            return False   # the app has not said this runner agreed to the check-in data: nothing is asked or sent
        ans, planned, usual, today, res = self._ci_state(c, u, now)
        if planned is None:
            return False
        if slot in ("ready", "today") and ci.ill_covers(ans, for_date):
            return False   # ill: rest. No question and no morning card; the evening hold says the same
        if slot == "ready":
            return (res is not None and res.day == for_date and for_date == today + timedelta(days=1)
                    and ans.get("ready", for_date) is None and ci.worth_asking("ready", planned, ans, for_date, today, usual))
        if slot == "today":
            ran_today = any(to_local(parse_iso(r["start_utc"]), r["zone_id"] or u["zone_id"]).date() == today
                            for r in c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? AND start_utc>=? "
                                               "ORDER BY start_utc DESC LIMIT 5", (u["id"], iso(now - timedelta(days=2)))))
            return (res is not None and res.day == for_date == today and not ran_today
                    and ans.get("today", for_date) is None and ci.worth_asking("today", planned, ans, for_date, today, usual))
        if slot == "shape":
            # "how many runs": once the runner has said a number (here, or on the weekly question) it is not asked again
            known = c.execute("SELECT 1 FROM memory WHERE user_id=? AND key='runs_per_week'", (u["id"],)).fetchone()
            return (to_local(now, u["zone_id"]).weekday() == 6 and for_date == today + timedelta(days=1) and not known
                    and ans.get("shape", for_date) is None and ci.worth_asking("shape", planned, ans, for_date, today, usual))
        if slot == "postrun":
            run = self._ci_latest_run(c, u["id"])
            if not run or not run.get("real_upload") or not ci.run_is_ambiguous(run):
                return False
            day = to_local(parse_iso(run["start_utc"]), run["zone_id"]).date()
            explained = any(
                ans.get(kind, d) in vals and 0 <= (day - d).days <= 2
                for kind, vals in (("why", ("tired", "sore", "ill")), ("ready", ("flat", "sore")),
                                   ("postrun", ci.POSTRUN))
                for d in ans.by[kind])
            return (for_date == day and not explained and ans.get("postrun", day) is None
                    and ci.worth_asking("postrun", planned, ans, day, today, usual))
        return False

    def _ci_plan_user(self, c, u: dict, now: datetime) -> int:
        n = 0
        loc = to_local(now, u["zone_id"])
        minute = loc.hour * 60 + loc.minute
        today = loc.date()
        qs, qe = self._quiet(u)
        quiet_now = in_quiet(now, u["zone_id"], qs, qe)
        # the evening before (Sunday evening belongs to the recap and the shape question)
        if ci.READY_START_MIN <= minute < ci.READY_END_MIN and loc.weekday() != 6 and not quiet_now:
            d = today + timedelta(days=1)
            if self._ci_wanted(c, u, "ready", d, now):
                n += self._ci_enqueue(c, u, "ready", d, now, now)
        # Sunday: how many runs next week
        if ci.SHAPE_START_MIN <= minute < ci.SHAPE_END_MIN and loc.weekday() == 6 and not quiet_now:
            d = today + timedelta(days=1)
            if self._ci_wanted(c, u, "shape", d, now):
                n += self._ci_enqueue(c, u, "shape", d, now, now)
        # the morning of a planned run, a little before the usual start (C4): inside quiet hours it moves to the end of
        # quiet, but never closer to the start than TODAY_MIN_LEAD_MIN, and is dropped rather than sent after the run
        hist = [dict(r) for r in c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? ORDER BY start_utc DESC "
                                           "LIMIT 80", (u["id"],))]
        start_m = ci.usual_start_min(hist, today.weekday(), u["zone_id"], now)
        if start_m is not None:
            due = ci.at_local(today, max(start_m - ci.TODAY_LEAD_MIN, 0), u["zone_id"])
            if in_quiet(due, u["zone_id"], qs, qe):
                due = quiet_end_utc(due, u["zone_id"], qe)
            latest = ci.at_local(today, max(start_m - ci.TODAY_MIN_LEAD_MIN, 0), u["zone_id"])   # C4: never after start - 5 min
            if due <= latest and due <= now and self._ci_wanted(c, u, "today", today, now):
                n += self._ci_enqueue(c, u, "today", today, due, now, latest)
        # after an easy run that came out slower and harder than it should: ask once
        run = self._ci_latest_run(c, u["id"])
        if run and run.get("real_upload") and (now - parse_iso(run["received_at"])).total_seconds() < 3 * 3600 \
                and not quiet_now:
            sent = c.execute("SELECT sent_at FROM cards WHERE user_id=? AND run_id=? AND kind='run'",
                             (u["id"], run["run_id"])).fetchone()
            day = to_local(parse_iso(run["start_utc"]), run["zone_id"]).date()
            if sent and sent["sent_at"] and self._ci_wanted(c, u, "postrun", day, now):
                due = parse_iso(sent["sent_at"]) + timedelta(minutes=ci.POSTRUN_DELAY_MIN)
                if due <= now:
                    n += self._ci_enqueue(c, u, "postrun", day, due, now)
        return n

    # ------------------------------------------------------------------ sending (C2)
    def _ci_media(self, kind: str, facts: dict) -> Any:
        """The picture for a check-in, drawn by the render worker (stream S2). Until that exists, or when it fails, the
        message goes out as text. Never raises."""
        fn = getattr(self.media, "render_checkin", None) if self.s.media_enabled else None
        if fn is None:
            return None
        try:
            return fn(kind, facts)
        except Exception as e:
            log.warning("check-in render failed, text goes out: %s", type(e).__name__)
            return None

    def _ci_deadline(self, ref: str) -> datetime:
        return parse_iso(ref.split("|")[2])

    def _ci_process(self, user: dict, ref: str, now: datetime) -> tuple[str, datetime | None]:
        slot, d_s, exp_s = ref.split("|")
        for_date = date.fromisoformat(d_s)
        ch = self.channels.get("telegram")
        if ch is None or user["channel"] != "telegram" or now >= parse_iso(exp_s) or not self.s.checkins_enabled:
            return "skipped", None   # switched off since it was queued: nothing new goes out
        uid = user["id"]
        with db.ro(self.s.db_path) as c:   # cheap gates first, so a card that will not go out never costs a weather request
            if (c.execute("SELECT 1 FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                          (uid, slot, d_s)).fetchone() or not self._ci_wanted(c, user, slot, for_date, now)
                    or self._ci_cap_taken(c, uid, now)):
                return "skipped", None
        hot = self._ci_heat(user, slot, for_date, now)   # before the write transaction: it may call the weather service
        with db.tx(self.s.db_path) as c:
            if c.execute("SELECT 1 FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                         (uid, slot, d_s)).fetchone():
                return "skipped", None   # sent already, or an earlier attempt may have been delivered: at most once
            if not self._ci_wanted(c, user, slot, for_date, now):
                return "skipped", None
            if self._ci_cap_taken(c, uid, now):
                log.info("check-in %s held back: today's question is taken", slot)
                return "skipped", None
            head, body, kb = self._ci_text(c, user, slot, for_date, now, hot)
            self._ci_claim_question(c, uid, slot, now)
            card_id = secrets.token_hex(16)
            c.execute("INSERT INTO checkin_slots (user_id, slot, local_date, card_id, state, claimed_at) VALUES (?,?,?,?,?,?)",
                      (uid, slot, d_s, card_id, "claimed", iso(now)))
            # The card row carries the unanswered question (and the heat line, a number from the forecast); what a tap
            # changes is rebuilt from the answers, never stored
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)", (card_id, uid, f"ci:{slot}:{d_s}", f"ci_{slot}", head, body, "[]",
                                                     "template", iso(now)))
            facts = self._ci_card_facts(c, user, for_date, now) if slot == "today" else None
        media = self._ci_media("today", facts) if facts else None
        try:
            mid, is_photo = ch.send_checkin(user["chat_ref"], card_id, f"{head}\n{body}", kb, media)
        except ChannelError as e:
            if e.ambiguous:
                log.warning("check-in %s: send outcome unknown, not retried", slot)
                return "skipped", None
            with db.tx(self.s.db_path) as c:   # Telegram refused it: release the claim so a retry may send
                c.execute("DELETE FROM cards WHERE card_id=?", (card_id,))
                c.execute("DELETE FROM checkin_slots WHERE card_id=?", (card_id,))
                c.execute("DELETE FROM question_cap WHERE user_id=? AND local_date=? AND slot=?",
                          (uid, self._ci_local_day(c, uid, now), slot))
            raise
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE checkin_slots SET message_id=?, is_photo=?, state='sent', sent_at=? WHERE card_id=?",
                      (mid, int(is_photo), iso(now), card_id))
            c.execute("UPDATE cards SET sent_at=? WHERE card_id=?", (iso(now), card_id))
            c.execute("INSERT INTO msglog (user_id, ts, direction, kind) VALUES (?,?,?,?)", (uid, iso(now), "out", f"ci_{slot}"))
        return "done", None

    # ------------------------------------------------------------------ taps (edit in place)
    def _ci_tap(self, ch: Any, inb: Any, user: dict, card: dict, now: datetime) -> None:
        uid = user["id"]
        parsed = ci.CODES.get(inb.code or "")
        slot = ci.SLOT_OF_KIND.get(parsed[0]) if parsed else None
        stale = parsed is None or card["kind"] != f"ci_{slot}"
        for_date: date | None = None
        srow: dict | None = None
        if not stale:
            try:
                for_date = date.fromisoformat(card["run_id"].split(":", 2)[2])
            except (ValueError, IndexError):
                stale = True
        if not stale:
            assert parsed is not None and for_date is not None and slot is not None
            kind, value = parsed
            with db.tx(self.s.db_path) as c:
                # consent is read in the same transaction as the answer write, so a withdrawal cannot slip between them
                consented = self._ci_consented(c, uid)
                r = c.execute("SELECT * FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                              (uid, slot, for_date.isoformat())).fetchone()
                srow = dict(r) if r else None
                today = to_local(now, user["zone_id"]).date()
                t = c.execute("SELECT value FROM checkin_answers WHERE user_id=? AND kind='today' AND local_date=?",
                              (uid, for_date.isoformat())).fetchone()
                if (not consented or srow is None or srow["card_id"] != card["card_id"] or srow["state"] != "sent"
                        or (srow["message_id"] and inb.callback_message_id and srow["message_id"] != inb.callback_message_id)
                        or not ci.tap_open(slot, for_date, today)
                        or (kind == "why" and (t is None or t["value"] != "skip"))):   # a reason only follows a skip
                    stale = True
                else:
                    self._ci_apply(c, uid, kind, value, for_date, now)
        if stale:
            ch.answer_callback(inb.callback_id, "That one has moved on.")
            if inb.callback_message_id:
                ch.clear_keyboard(inb.ref, inb.callback_message_id)
            return
        ch.answer_callback(inb.callback_id)   # first: the button stops spinning whatever the edit does
        self._ci_sync_or_queue(user, slot, for_date, now)
        if self.coach.enabled:
            self.coach.briefing.enqueue(uid, now)   # C2b: an answer can change the next session (queued, never generated here)
        if parsed[0] in ("today", "why", "undo", "ready", "shape"):   # only answers that move or soften a session redraw the week
            self._ci_week_enqueue(user, now)

    def _ci_apply(self, c, uid: str, kind: str, value: str, for_date: date, now: datetime) -> None:
        """Record the answer (last write wins). The next session is re-resolved on read, so nothing else is stored,
        except that a number of runs is the runner's answer to the weekly question too: the coach week sizes itself from
        it and neither question comes round again."""
        d = for_date.isoformat()
        if kind == "shape" and value in ("3", "4", "5"):
            self._memory_set(c, uid, "runs_per_week", value, now)
        if kind == "undo":
            c.execute("DELETE FROM checkin_answers WHERE user_id=? AND kind IN ('today','why') AND local_date=?", (uid, d))
        elif value == "":
            c.execute("DELETE FROM checkin_answers WHERE user_id=? AND kind=? AND local_date=?", (uid, kind, d))
        else:
            if kind == "today":
                c.execute("DELETE FROM checkin_answers WHERE user_id=? AND kind='why' AND local_date=?", (uid, d))
            c.execute("INSERT INTO checkin_answers (user_id, kind, local_date, value, created_at) VALUES (?,?,?,?,?) "
                      "ON CONFLICT(user_id, kind, local_date) DO UPDATE SET value=excluded.value, "
                      "created_at=excluded.created_at", (uid, kind, d, value, iso(now)))

    def _ci_sync_or_queue(self, user: dict, slot: str, for_date: date, now: datetime) -> None:
        try:
            self._ci_sync(user, slot, for_date, now)
        except ChannelError as e:
            log.warning("check-in edit failed (%s), retrying from the outbox", "429" if e.rate_limited else "error")
            wait = max(e.retry_after or 0, 5)
            with db.tx(self.s.db_path) as c:
                c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                          (user["id"], "ci_edit", iso(now + timedelta(seconds=wait)),
                           f"cie:{user['id']}:{slot}:{for_date.isoformat()}:{int(now.timestamp())}",
                           _sep(slot, for_date.isoformat())))

    def _ci_sync(self, user: dict, slot: str, for_date: date, now: datetime) -> bool:
        """Make the message show what the answers now say. Rebuilt from the database each time, so it is safe to repeat.
        "Not modified" is success. A message that is gone or cannot be edited (C3) is replaced by a fresh one and the
        stored message id updated. Anything else (429, transport) raises ChannelError."""
        ch = self.channels.get("telegram")
        hot = self._ci_heat(user, slot, for_date, now)
        with db.ro(self.s.db_path) as c:
            if not self._ci_consented(c, user["id"]):
                return False
            r = c.execute("SELECT * FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                          (user["id"], slot, for_date.isoformat())).fetchone()
            if ch is None or r is None or r["state"] != "sent" or not r["message_id"]:
                return False
            srow = dict(r)
            head, body, kb = self._ci_text(c, user, slot, for_date, now, hot)
            pic = self._ci_stage_media(c, user, slot, for_date, now) if srow["is_photo"] else None
        text = f"{head}\n{body}"
        try:
            ch.edit_checkin(user["chat_ref"], srow["message_id"], srow["card_id"], text, kb, bool(srow["is_photo"]), pic)
        except ChannelError as e:
            if not e.cant_edit:
                raise
            mid, is_photo = ch.send_checkin(user["chat_ref"], srow["card_id"], text, kb)
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE checkin_slots SET message_id=?, is_photo=? WHERE card_id=?", (mid, int(is_photo), srow["card_id"]))
        return True

    # ------------------------------------------------------------------ the pictures (stream S2's kinds)
    @staticmethod
    def _ci_card_type(typ: str) -> str:
        return {"quality": "tempo"}.get(typ, typ)

    def _ci_card_facts(self, c, user: dict, for_date: date, now: datetime) -> dict | None:
        """Facts for the today card, in S2's vocabulary (numbers, fixed enums and a short label; the time of day is in
        the message text, not the picture). Nothing from an answer goes in. None when nothing is planned."""
        ans, planned, usual, today, res = self._ci_state(c, user, now)
        if planned is None:
            return None
        typ = res.type if res and res.day == for_date else planned.type
        facts: dict[str, Any] = {"type": self._ci_card_type(typ), "session": cc.WORD.get(typ, "Run"),
                                 "date_local": for_date.isoformat(), "units": "km"}
        if planned.distance_m:
            facts["distance_km"] = round(planned.distance_m / 1000, 1)
        elif planned.minutes:
            facts["duration_s"] = planned.minutes * 60
        work = self._ci_work_pace(planned, typ)
        if work is not None:               # the card's TARGET plate, in the renderer's own vocabulary
            facts["target_pace_lo_s"] = round(planned.pace_lo_s, 1)
            facts["target_pace_hi_s"] = round(planned.pace_hi_s, 1)
            facts["target_kind"] = "work"
        if typ == "easy":
            facts["guide"] = "chatty"      # an easy session never renders the bare block
        elif typ == "long":
            facts["guide"] = "steady"
        return facts

    def _ci_moved_facts(self, c, user: dict, for_date: date, now: datetime) -> dict | None:
        """The MOVED card: where the session went. The reason is deliberately not sent (it stays out of the renderer)."""
        facts = self._ci_card_facts(c, user, for_date, now)
        if facts is None:
            return None
        ans, _p, usual, _t, _r = self._ci_state(c, user, now)
        to = ci._move_from(for_date, ans, usual)
        facts.pop("guide", None)
        facts.pop("date_local", None)
        facts["from_day"] = DAY_NAMES[for_date.weekday()]
        same_week = to is not None and to.isocalendar()[:2] == for_date.isocalendar()[:2]
        facts["to_day"] = DAY_NAMES[to.weekday()] if to is not None and same_week else "next_week"
        return facts

    def _ci_stage_media(self, c, user: dict, slot: str, for_date: date, now: datetime) -> Any:
        """The picture the morning message should show at its current stage: the today card, or the MOVED card once a
        reason has moved the session. Other stages keep the picture they have."""
        if slot != "today":
            return None
        ans, *_ = self._ci_state(c, user, now)
        stage, why = self._ci_stage(slot, ans, for_date)
        if (stage == "skip" and why) or stage in ("move", "short"):
            facts = self._ci_moved_facts(c, user, for_date, now)
            return self._ci_media("moved", facts) if facts else None
        if stage in (None, "skip"):
            facts = self._ci_card_facts(c, user, for_date, now)
            return self._ci_media("today", facts) if facts else None
        return None

    def _ci_verdict_media(self, user: dict, card: dict, slot: dict) -> Any:
        """The result picture for the morning message (today_verdict), from the run itself, with the app's own verdict
        mapped to S2's enum so the picture never disagrees with the coach text. None leaves the ordinary run card
        picture in place."""
        if not slot["is_photo"]:
            return None
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT * FROM runs WHERE user_id=? AND run_id=?", (user["id"], card["run_id"])).fetchone()
        if r is None:
            return None
        run = dict(r)
        facts: dict[str, Any] = {"type": self._ci_card_type(run["type"]), "session": cc.WORD.get(run["type"], "Run"),
                                 "units": "km"}
        if run["distance_m"] >= 10:
            facts["distance_km"] = round(run["distance_m"] / 1000, 2)
        pace = run.get("pace_s_per_km") or run.get("true_pace_s_per_km")
        if pace:
            facts["result_pace_s"] = float(pace)
        verdict = "pb" if run.get("pb") else {"faster": "faster", "slower": "slower", "holding": "in_range",
                                               "noRealChange": "in_range"}.get(run.get("verdict") or "")
        if verdict:
            facts["verdict"] = verdict
        if run.get("pb"):
            facts["pb"] = True
        return self._ci_media("today_verdict", facts)

    # ------------------------------------------------------------------ the pinned week card
    def _ci_week_enqueue(self, user: dict, now: datetime) -> None:
        """Ask the worker to bring this week's pinned card up to date (after a run or a move). It rebuilds from the rows,
        so asking twice is harmless."""
        if not (self.s.checkins_enabled and self.s.media_enabled) or user["channel"] != "telegram":
            return
        monday = (to_local(now, user["zone_id"]).date() - timedelta(days=to_local(now, user["zone_id"]).weekday())).isoformat()
        with db.tx(self.s.db_path) as c:
            if not self._ci_consented(c, user["id"]):
                return
            if c.execute("SELECT 1 FROM outbox WHERE user_id=? AND kind='ci_week' AND ref=? AND state='pending'",
                         (user["id"], monday)).fetchone():
                return   # one render per burst: the queued item draws the newest state when it runs (a render already under way
                # may have missed this change, so only a waiting item counts)
            c.execute("INSERT OR IGNORE INTO outbox (user_id, kind, due_at, dedupe_key, ref) VALUES (?,?,?,?,?)",
                      (user["id"], "ci_week", iso(now + timedelta(seconds=WEEK_DEBOUNCE_S)),
                       f"ciw:{user['id']}:{monday}:{int(now.timestamp())}", monday))

    def _ci_week_facts(self, c, user: dict, monday: date, now: datetime) -> dict:
        uid, zone_id = user["id"], user["zone_id"]
        lo, hi = ci.at_local(monday, 0, zone_id), ci.at_local(monday + timedelta(days=7), 0, zone_id)
        done: dict[int, tuple[str, float]] = {}
        for r in c.execute("SELECT start_utc, zone_id, type, distance_m FROM runs WHERE user_id=? AND start_utc>=? AND start_utc<?",
                           (uid, iso(lo), iso(hi))):
            i = (to_local(parse_iso(r["start_utc"]), r["zone_id"]).date() - monday).days
            typ, km = done.get(i, (r["type"], 0.0))
            done[i] = (r["type"] if r["type"] in ("long", "tempo", "interval", "race") else typ, km + r["distance_m"] / 1000)
        _a, planned, _u, today, res = self._ci_state(c, user, now)
        coming: dict[date, Any] = {}
        if planned and planned.derived:   # the default week: show every planned day, not only the next one
            with db.ro(self.s.db_path) as c2:
                hist = [dict(r) for r in c2.execute("SELECT * FROM runs WHERE user_id=? ORDER BY start_utc DESC LIMIT 80", (uid,))]
                mem = {r["key"]: r["value"] for r in c2.execute("SELECT key, value FROM memory WHERE user_id=?", (uid,))}
            coming = {s_.day: s_ for s_ in dw.build_week(hist, memory=mem, zone_id=zone_id, today=today, now=now)}
        days = []
        for i in range(7):
            d = monday + timedelta(days=i)
            entry: dict[str, Any] = {"type": "rest", "planned_km": 0, "done_km": 0}
            if res and res.day == d and planned:
                entry.update(type=self._ci_card_type(res.type), planned_km=round((planned.distance_m or 0) / 1000, 1))
            elif planned and planned.derived and d in coming:
                s_ = coming[d]
                entry.update(type=self._ci_card_type(s_.type), planned_km=round(s_.distance_m / 1000, 1))
            if i in done:
                entry.update(type=done[i][0] if done[i][0] in ci_types() else "easy", done_km=round(done[i][1], 1))
            days.append(entry)
        iso_week = monday.isocalendar()[1]
        return {"week_label": f"Week {iso_week}", "days": days, "units": "km",
                "today_idx": (today - monday).days if 0 <= (today - monday).days <= 6 else 0}

    def _ci_week_sync(self, user: dict, monday_s: str, now: datetime) -> tuple[str, datetime | None]:
        """Create (once, silently pinned) or update the runner's week card. One message per runner per week: the
        (user, 'week', Monday) slot is claimed before the send, so a retry or a restart cannot post a second one."""
        ch = self.channels.get("telegram")
        if ch is None or user["channel"] != "telegram" or not self.s.media_enabled or not self.s.checkins_enabled:
            return "skipped", None
        monday = date.fromisoformat(monday_s)
        with db.ro(self.s.db_path) as c:
            if not self._ci_consented(c, user["id"]):
                return "skipped", None
            facts = self._ci_week_facts(c, user, monday, now)
            r = c.execute("SELECT * FROM checkin_slots WHERE user_id=? AND slot='week' AND local_date=?",
                          (user["id"], monday_s)).fetchone()
        srow = dict(r) if r else None
        media = self._ci_media("pinned_week", facts)
        if srow is None:
            if media is None or not media.photo:
                return "skipped", None   # a picture or nothing: there is no text stand-in for it
            with db.tx(self.s.db_path) as c:   # claim before the send: one message per runner per week
                if not c.execute("INSERT OR IGNORE INTO checkin_slots (user_id, slot, local_date, state, claimed_at, is_photo) "
                                 "VALUES (?,?,?,?,?,1)", (user["id"], "week", monday_s, "claimed", iso(now))).rowcount:
                    return "skipped", None
            try:
                mid = ch.send_photo(user["chat_ref"], media.photo)
            except ChannelError as e:
                if e.ambiguous:
                    return "skipped", None
                with db.tx(self.s.db_path) as c:
                    c.execute("DELETE FROM checkin_slots WHERE user_id=? AND slot='week' AND local_date=?", (user["id"], monday_s))
                raise
            self._ci_week_pinned(user, monday_s, mid, ch)
            return "done", None
        if srow["state"] != "sent" or not srow["message_id"] or media is None or not media.photo:
            return "skipped", None   # claimed but unknown, or no picture this time: leave the card as it is
        try:
            ch.edit_photo(user["chat_ref"], srow["message_id"], media.photo)
        except ChannelError as e:
            if not e.cant_edit:
                raise
            mid = ch.send_photo(user["chat_ref"], media.photo)   # deleted by the runner: a new one, pinned again (C3)
            self._ci_week_pinned(user, monday_s, mid, ch)
        return "done", None

    def _ci_week_pinned(self, user: dict, monday_s: str, mid: str, ch: Any) -> None:
        with db.tx(self.s.db_path) as c:
            old = c.execute("SELECT message_id FROM checkin_slots WHERE user_id=? AND slot='week' AND local_date<>? AND "
                            "state='sent' ORDER BY local_date DESC LIMIT 1", (user["id"], monday_s)).fetchone()
            c.execute("UPDATE checkin_slots SET message_id=?, state='sent', sent_at=? WHERE user_id=? AND slot='week' AND "
                      "local_date=?", (mid, iso(now_utc()), user["id"], monday_s))
        if old and old["message_id"]:
            ch.unpin(user["chat_ref"], old["message_id"])   # last week's card stops being the pinned one
        ch.pin(user["chat_ref"], mid)

    def _ci_process_edit(self, user: dict, ref: str, now: datetime) -> tuple[str, datetime | None]:
        slot, d_s = ref.split("|")
        self._ci_sync(user, slot, date.fromisoformat(d_s), now)
        return "done", None

    # ------------------------------------------------------------------ the run card becomes the result (C3)
    def _ci_today_slot_for(self, user: dict, card: dict) -> dict | None:
        """The still-open morning message for the day this run card is about, if any."""
        if card["kind"] != "run" or not card.get("run_id"):
            return None
        with db.ro(self.s.db_path) as c:
            if not self._ci_consented(c, user["id"]):
                return None   # consent withdrawn: the result goes out as a plain new card, not as an edit of a check-in
            run = c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? AND run_id=?",
                            (user["id"], card["run_id"])).fetchone()
            if run is None:
                return None
            day = to_local(parse_iso(run["start_utc"]), run["zone_id"]).date().isoformat()
            r = c.execute("SELECT * FROM checkin_slots WHERE user_id=? AND slot='today' AND local_date=? AND state='sent' "
                          "AND message_id IS NOT NULL", (user["id"], day)).fetchone()
        return dict(r) if r else None

    def _ci_consume(self, user: dict, slot: dict, message_id: str, is_photo: bool) -> None:
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE checkin_slots SET state='consumed', message_id=?, is_photo=? WHERE user_id=? AND slot='today' "
                      "AND local_date=?", (message_id, int(is_photo), user["id"], slot["local_date"]))

    def _deliver(self, ch: Any, user: dict, card: dict, out: Any, **kw: Any) -> str:
        """`send_card`, except that a run card first tries to become the morning card of the same day. A second or an
        unplanned run finds no open morning card and is a new message."""
        slot = self._ci_today_slot_for(user, card) if user["channel"] == "telegram" else None
        if slot is None:
            return ch.send_card(user["chat_ref"], out, **kw)
        pic = self._ci_verdict_media(user, card, slot)
        if pic is not None and pic.photo:
            out = dataclasses.replace(out, media=pic)   # the morning picture becomes its own result picture
        has_photo = bool(out.media and out.media.photo)
        try:
            ch.edit_into_card(user["chat_ref"], slot["message_id"], out, bool(slot["is_photo"]))
            mid, photo = slot["message_id"], bool(slot["is_photo"])
        except ChannelError as e:
            if e.rate_limited or e.ambiguous:
                raise   # the whole card item retries; an edit is safe to repeat
            log.warning("today card edit failed (%s), sending the card fresh", e.status)
            mid = ch.send_card(user["chat_ref"], out, **kw)
            photo = has_photo
            ch.clear_keyboard(user["chat_ref"], slot["message_id"])
        self._ci_consume(user, slot, mid, photo)
        return mid

    # ------------------------------------------------------------------ lines that use an answer (templated, A2)
    def _ci_line(self, c, card: dict, now: datetime) -> dict:
        """A run card may carry one templated line about what the runner said in the last 3 days. Built when the card is
        sent and never stored (card.body stays free of it), so it is not kept past the 14 days, and it never goes near
        the writer, which has long finished."""
        if card.get("kind") != "run" or not card.get("run_id") or not self._ci_consented(c, card["user_id"]):
            return card   # no consent: stored answers are never quoted back
        run = c.execute("SELECT start_utc, zone_id, verdict FROM runs WHERE user_id=? AND run_id=?",
                        (card["user_id"], card["run_id"])).fetchone()
        if run is None:
            return card
        day = to_local(parse_iso(run["start_utc"]), run["zone_id"]).date()
        ans = self._ci_answers(c, card["user_id"], now)
        found: list[tuple[str, str, date]] = []
        for kind in ("why", "ready", "postrun"):
            for d, v in ans.by[kind].items():
                age = (day - d).days
                if (kind == "postrun" and 0 < age <= LINE_LOOKBACK_DAYS) or \
                        (kind != "postrun" and 0 <= age <= LINE_LOOKBACK_DAYS):
                    found.append((kind, v, d - timedelta(days=1) if kind == "ready" else d))   # asked the evening before
        line = cc.run_line(found, run["verdict"], day)
        return {**card, "body": f"{card['body']}\n\n{line}"} if line else card

    def _ci_lighter(self, c, uid: str, now: datetime, on: date) -> bool:
        """Is the coach keeping things light on this day? (A skip, a sore evening-before answer, a sleepless or stressed
        post-run answer.) Safety outranks the plan: the evening suggestion then softens."""
        if not self._ci_consented(c, uid):
            return False
        until = ci.lighter_until(self._ci_answers(c, uid, now), on)
        return until is not None and until >= on

    def _ci_evening_held(self, c, uid: str, tomorrow: date, now: datetime) -> bool:
        """True when the evening suggestion must not go: the runner said ill (rest, no nudge) or is away that week, or a
        readiness question for tomorrow is due in the same window and takes the day's one question (P3-6). Also held while a
        health flag (urgent, wellbeing, injury, ill) is active: nothing may be said about training, as in the briefing."""
        if c.execute("SELECT 1 FROM health_flags WHERE user_id=? AND state='active' AND kind IN ('urgent','wellbeing','injury','ill')",
                     (uid,)).fetchone():
            return True
        if not self._ci_consented(c, uid):
            return False   # stored answers are ignored without consent, and no readiness question is coming either
        ans = self._ci_answers(c, uid, now)
        if ci.ill_covers(ans, tomorrow) or ci.away_covers(ans, tomorrow):
            return True
        if not self.s.checkins_enabled:
            return False
        u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        if u is not None:
            loc = to_local(now, u["zone_id"])
            if not ci.READY_START_MIN <= loc.hour * 60 + loc.minute < ci.READY_END_MIN:
                return False   # the readiness question is only planned in its own window
        if u is None or c.execute("SELECT 1 FROM checkin_slots WHERE user_id=? AND slot='ready' AND local_date=?",
                                  (uid, tomorrow.isoformat())).fetchone():
            return False
        return self._ci_wanted(c, dict(u), "ready", tomorrow, now) and not self._ci_cap_taken(c, uid, now)

    # ------------------------------------------------------------------ the app's read-only view
    def next_session(self, uid: str, now: datetime | None = None) -> dict:
        """GET /v1/me/next-session: the coach's next session and the latest coach line. Holds no check-in value: only
        whether the session was moved. Shape (v1) is documented in companion-server/README.md."""
        from .service import NotFound
        now = now or now_utc()
        with db.ro(self.s.db_path) as c:
            u = c.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            if not u:
                raise NotFound()
            user = dict(u)
            ans, planned, _usual, today, res = self._ci_state(c, user, now)
            name_ = self._ci_session_name(planned, res.type) if res else None
            quest = cv_quest.view_for_app(c, uid, today)
            care_weeks = ci.care_weeks(ans, today) if self._ci_consented(c, uid) else []
            keys = self.coach.briefing.match_keys(c, user, now) if res is not None and planned is not None else None
            line = c.execute(
                "SELECT kind, headline, body, sent_at FROM cards WHERE user_id=? AND sent_at IS NOT NULL AND sent_at<=? "
                f"AND kind IN ({','.join('?' * len(COACH_LINE_KINDS))}) ORDER BY sent_at DESC LIMIT 1",
                (uid, iso(now), *COACH_LINE_KINDS)).fetchone()
        session = None
        if res is not None and planned is not None:
            session = {"date": res.day.isoformat(), "type": res.type, "kind": res.type,
                       "name": name_ or cc.WORD.get(res.type), "session_id": ((planned.session_id if planned and planned.type == res.type else None)
                                   or re.sub(r"[^a-z0-9]+", "_", name_.lower()).strip("_")) if name_ else res.type,
                       "name_source": "plan" if name_ else "none", "minutes": planned.minutes if not res.easier else None,
                       "distance_m": planned.distance_m if not res.easier else None, "week": planned.week,
                       "weeks": planned.weeks, "moved": res.moved,
                       "original_date": res.original_day.isoformat() if res.moved else None,
                       "label": cc.session_label(res.type, planned.minutes if not res.easier else None,
                                                 planned.distance_m if not res.easier else None, name_)}
        if session is not None and planned is not None and planned.derived:
            session["derived"] = True   # the coach's default week, not a plan built in the app
        if session is not None and keys is not None:
            # C2b: what the coach's briefing for this session is keyed on, so Start matches it from memory.
            session["session_ref"], session["fingerprint"] = keys["session_ref"], keys["fingerprint"]
            if keys["reps"] is not None:
                session["reps"] = keys["reps"]
        return {"v": 1, "generated_at": iso(now), "next_session": session,
                "coach_line": ({"kind": line["kind"], "headline": line["headline"], "body": line["body"],
                                "sent_at": line["sent_at"]} if line else None),
                "quest": quest, "care_weeks": [d.isoformat() for d in care_weeks],
                "accepts_load": True}   # this server stores a run's `load` and `load_basis`: the app sends them only when it sees this

    # ------------------------------------------------------------------ export and retention (P1)
    def _ci_export(self, c, uid: str, now: datetime) -> list[dict]:
        return [dict(r) for r in c.execute(
            "SELECT kind, local_date, value, created_at FROM checkin_answers WHERE user_id=? AND created_at>? "
            "ORDER BY created_at", (uid, iso(now - timedelta(days=ci.RETENTION_DAYS))))]

    def purge_checkins(self, c, now: datetime, held: str) -> int:
        """Called inside `purge`'s transaction. A row goes once it is older than 14 days: at 14 days it is still kept, at
        15 it is gone (the purge runs hourly). `held` leaves a replayed runner alone, like the other tables."""
        cut = iso(now - timedelta(days=ci.RETENTION_DAYS))
        n = 0
        for tbl, col in (("checkin_answers", "created_at"), ("checkin_slots", "claimed_at"), ("question_cap", "claimed_at")):
            n += c.execute(f"DELETE FROM {tbl} WHERE {col} < ?" + held, (cut,)).rowcount
        # the check-in messages' own text rows carry what an answer resolved to (a label, a moved day): same 14 days
        n += c.execute("DELETE FROM cards WHERE kind LIKE 'ci\\_%' ESCAPE '\\' AND created_at < ?" + held, (cut,)).rowcount
        return n
