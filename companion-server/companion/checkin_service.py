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

import logging
import secrets
from datetime import date, datetime, timedelta
from typing import Any

from . import checkin_copy as cc
from . import checkins as ci
from . import db
from .channels import ChannelError
from .timeutil import in_quiet, iso, now_utc, parse_iso, quiet_end_utc, to_local

log = logging.getLogger("companion")

CI_KINDS = ("ci", "ci_edit")
LINE_LOOKBACK_DAYS = 3
COACH_LINE_KINDS = ("run", "evening", "recap", "monthly")


def _sep(*parts: object) -> str:
    return "|".join(str(p) for p in parts)


class CheckinMixin:
    s: Any
    channels: dict[str, Any]
    media: Any

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

    def _ci_state(self, c, user: dict, now: datetime):
        """-> (answers, planned, usual weekdays, runner's local today, resolved next session)."""
        uid = user["id"]
        ans = self._ci_answers(c, uid, now)
        planned = ci.planned_from_run(self._ci_latest_run(c, uid))
        usual = self._ci_usual(c, uid)
        today = to_local(now, user["zone_id"]).date()
        return ans, planned, usual, today, ci.resolve(planned, ans, today, usual)

    @staticmethod
    def _ci_when(c, uid: str, user: dict, for_date: date, now: datetime) -> str | None:
        hist = [dict(r) for r in c.execute("SELECT start_utc, zone_id FROM runs WHERE user_id=? ORDER BY start_utc DESC "
                                           "LIMIT 80", (uid,))]
        m = ci.usual_start_min(hist, for_date.weekday(), user["zone_id"], now)
        return None if m is None else f"around {m // 60}:{m % 60:02d}"

    def _ci_ctx(self, c, user: dict, slot: str, for_date: date, now: datetime) -> cc.Ctx:
        ans, planned, usual, _today, res = self._ci_state(c, user, now)
        # the session as it stands now: "flat" has made a hard one easy, so the morning card must not call it hard
        typ = res.type if res and res.day == for_date else planned.type if planned else None
        label = cc.session_label(typ, planned.minutes, planned.distance_m) if planned and typ else None
        if slot == "shape":
            away = ans.get("shape", for_date) == "away"
            back = ci._next_usual(for_date + timedelta(days=7), usual) if away else (res.day if res else None)
            return cc.Ctx(label=label, moved_to=back)
        moved_to = ci._move_from(for_date, ans, usual)
        easier = ans.get("ready", for_date) == "flat" and bool(planned) and planned.type != "easy"
        return cc.Ctx(label=label, when=self._ci_when(c, user["id"], user, for_date, now), moved_to=moved_to,
                      easier=easier, original_word=cc.WORD.get(planned.type) if easier and planned else None)

    @staticmethod
    def _ci_stage(slot: str, ans: ci.Answers, for_date: date) -> tuple[str | None, str | None]:
        """-> (stage, skip reason) the message should show now, from the answers alone."""
        if slot == "today":
            t = ans.get("today", for_date)
            return (t, ans.get("why", for_date)) if t else (None, None)
        return ans.get(slot, for_date), None

    def _ci_text(self, c, user: dict, slot: str, for_date: date, now: datetime):
        ans, *_ = self._ci_state(c, user, now)
        stage, why = self._ci_stage(slot, ans, for_date)
        ctx = self._ci_ctx(c, user, slot, for_date, now)
        head, body, kb = cc.today(stage, ctx, why) if slot == "today" else cc.RENDER[slot](stage, ctx)
        return head, body, kb

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
                "SELECT * FROM users WHERE channel='telegram' AND paused=0 AND last_run_utc >= ?" + who,
                (iso(now - timedelta(days=14)), *args))]
            for u in users:
                try:
                    n += self._ci_plan_user(c, u, now)
                except Exception as e:  # one runner's odd data never stops the others
                    log.error("check-in planning failed: %s", type(e).__name__)
        return n

    def _ci_enqueue(self, c, u: dict, slot: str, for_date: date, due: datetime, now: datetime) -> int:
        deadline = ci.send_deadline(slot, due)
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
        ans, planned, usual, today, res = self._ci_state(c, u, now)
        if planned is None:
            return False
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
            return (to_local(now, u["zone_id"]).weekday() == 6 and for_date == today + timedelta(days=1)
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
            if due <= ci.at_local(today, start_m - ci.TODAY_MIN_LEAD_MIN, u["zone_id"]) and due <= now \
                    and self._ci_wanted(c, u, "today", today, now):
                n += self._ci_enqueue(c, u, "today", today, due, now)
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
        if ch is None or user["channel"] != "telegram" or now >= parse_iso(exp_s):
            return "skipped", None
        uid = user["id"]
        with db.tx(self.s.db_path) as c:
            if c.execute("SELECT 1 FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                         (uid, slot, d_s)).fetchone():
                return "skipped", None   # sent already, or an earlier attempt may have been delivered: at most once
            if not self._ci_wanted(c, user, slot, for_date, now):
                return "skipped", None
            if self._ci_cap_taken(c, uid, now):
                log.info("check-in %s held back: today's question is taken", slot)
                return "skipped", None
            head, body, kb = self._ci_text(c, user, slot, for_date, now)
            when = self._ci_when(c, uid, user, for_date, now)
            self._ci_claim_question(c, uid, slot, now)
            card_id = secrets.token_hex(16)
            c.execute("INSERT INTO checkin_slots (user_id, slot, local_date, card_id, state, claimed_at) VALUES (?,?,?,?,?,?)",
                      (uid, slot, d_s, card_id, "claimed", iso(now)))
            # The card row carries only the neutral question: what a tap changes is rebuilt from the answers, never stored
            c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at) "
                      "VALUES (?,?,?,?,?,?,?,?,?)", (card_id, uid, f"ci:{slot}:{d_s}", f"ci_{slot}", head, body, "[]",
                                                     "template", iso(now)))
            facts = {"session": self._ci_ctx(c, user, slot, for_date, now).label, "when_local": when,
                     "date_local": d_s}
        media = self._ci_media("today", facts) if slot == "today" else None
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
                r = c.execute("SELECT * FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                              (uid, slot, for_date.isoformat())).fetchone()
                srow = dict(r) if r else None
                today = to_local(now, user["zone_id"]).date()
                t = c.execute("SELECT value FROM checkin_answers WHERE user_id=? AND kind='today' AND local_date=?",
                              (uid, for_date.isoformat())).fetchone()
                if (srow is None or srow["card_id"] != card["card_id"] or srow["state"] != "sent"
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

    @staticmethod
    def _ci_apply(c, uid: str, kind: str, value: str, for_date: date, now: datetime) -> None:
        """Record the answer (last write wins). The next session is re-resolved on read, so nothing else is stored."""
        d = for_date.isoformat()
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
        with db.ro(self.s.db_path) as c:
            r = c.execute("SELECT * FROM checkin_slots WHERE user_id=? AND slot=? AND local_date=?",
                          (user["id"], slot, for_date.isoformat())).fetchone()
            if ch is None or r is None or r["state"] != "sent" or not r["message_id"]:
                return False
            srow = dict(r)
            head, body, kb = self._ci_text(c, user, slot, for_date, now)
        text = f"{head}\n{body}"
        try:
            ch.edit_checkin(user["chat_ref"], srow["message_id"], srow["card_id"], text, kb, bool(srow["is_photo"]))
        except ChannelError as e:
            if not e.cant_edit:
                raise
            mid, is_photo = ch.send_checkin(user["chat_ref"], srow["card_id"], text, kb)
            with db.tx(self.s.db_path) as c:
                c.execute("UPDATE checkin_slots SET message_id=?, is_photo=? WHERE card_id=?", (mid, int(is_photo), srow["card_id"]))
        return True

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
        if card.get("kind") != "run" or not card.get("run_id"):
            return card
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
        until = ci.lighter_until(self._ci_answers(c, uid, now), on)
        return until is not None and until >= on

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
            _ans, planned, _usual, _today, res = self._ci_state(c, user, now)
            line = c.execute(
                "SELECT kind, headline, body, sent_at FROM cards WHERE user_id=? AND sent_at IS NOT NULL AND sent_at<=? "
                f"AND kind IN ({','.join('?' * len(COACH_LINE_KINDS))}) ORDER BY sent_at DESC LIMIT 1",
                (uid, iso(now), *COACH_LINE_KINDS)).fetchone()
        session = None
        if res is not None and planned is not None:
            session = {"date": res.day.isoformat(), "type": res.type, "minutes": planned.minutes if not res.easier else None,
                       "distance_m": planned.distance_m if not res.easier else None, "week": planned.week,
                       "weeks": planned.weeks, "moved": res.moved,
                       "original_date": res.original_day.isoformat() if res.moved else None,
                       "label": cc.session_label(res.type, planned.minutes if not res.easier else None,
                                                 planned.distance_m if not res.easier else None)}
        return {"v": 1, "generated_at": iso(now), "next_session": session,
                "coach_line": ({"kind": line["kind"], "headline": line["headline"], "body": line["body"],
                                "sent_at": line["sent_at"]} if line else None)}

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
        return n
