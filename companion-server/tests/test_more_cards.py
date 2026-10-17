"""Suggestion, milestone, race countdown and monthly poster cards: facts persisted when the coach decides, rendered through a
fake worker, text on any failure, the caps, the replay caption rule and the protocol allow-list.

Nothing here needs Chromium: the worker is a recording client (the same protocol check the real client runs), and every
date is pinned (a test must never depend on the weekday it runs on)."""
import json
import socket
import sqlite3
import threading
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from companion import db
from companion.channels import ChannelError
from companion.media import MediaError, MediaRenderer, month_facts
from companion.render_client import RenderClient, RenderError
from companion.service import RunIn, Service
from companion.timeutil import iso
from conftest import coach_week, Fakes, OWNER, make_settings
from render import protocol as P
from render.worker import Worker

UTC = timezone.utc
NOW = datetime(2026, 10, 13, 12, 0, tzinfo=UTC)          # a Tuesday
FIRST = datetime(2026, 10, 1, 9, 15, tzinfo=UTC)          # a Thursday: the poster window for September
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64
UID = "u_cards"


class Rec:
    """A fake render worker with the real request check in front of it, so a fact the protocol refuses fails here too."""

    def __init__(self, fail=()):
        self.sent: list[tuple[str, dict]] = []
        self.fail = set(fail)

    def card(self, kind, facts):
        try:
            P.encode_request("card", kind, dict(facts))
        except P.ProtocolError as e:
            raise RenderError(e.code) from None
        if kind in self.fail:
            raise RenderError("unavailable")
        self.sent.append((kind, json.loads(json.dumps(facts))))
        return PNG

    def video(self, kind, facts):
        raise RenderError("unavailable")

    def kinds(self):
        return [k for k, _ in self.sent]


class Env:
    def __init__(self, tmp_path, rec, channel="telegram", **over):
        self.fakes = Fakes()
        self.rec = rec
        self.s = make_settings(tmp_path, media_enabled=True, checkins_enabled=False, weather_enabled=False, openrouter_key=None, **over)
        self.svc = Service(self.s, httpx.Client(transport=httpx.MockTransport(self.fakes.handler)))
        self.svc.media = MediaRenderer(client=rec)
        with db.tx(self.s.db_path) as c:
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, "
                      "utc_offset_min, last_inbound_at) VALUES (?,?,?,?,?,?,?,?,?)",
                      (UID, channel, OWNER, "2026-09-01T00:00:00Z", "1", "2026-09-01T00:00:00Z", "UTC", 0,
                       "2026-09-01T00:00:00Z"))
            c.execute("INSERT INTO devices (token_hash, user_id, created_at) VALUES ('h', ?, '2026-09-01T00:00:00Z')", (UID,))

    def run(self, i, start, typ="easy", km=7.0, **extra):
        p = {"run_id": f"r{i:02d}", "type": typ, "start_utc": start.isoformat(), "utc_offset_min": 0, "zone_id": "UTC",
             "duration_s": int(km * 360), "distance_m": int(km * 1000), "pace_s_per_km": 360.0,
             "true_pace_s_per_km": 358.0, "verdict": "holding", **extra}
        self.svc.ingest_run(UID, RunIn.model_validate(p), NOW)
        return p["run_id"]

    def quiet_outbox(self):
        """History only: the seeded runs get no card."""
        with db.tx(self.s.db_path) as c:
            c.execute("UPDATE outbox SET state='done'")

    def user(self):
        with db.ro(self.s.db_path) as c:
            return dict(c.execute("SELECT * FROM users WHERE id=?", (UID,)).fetchone())

    def q(self, sql, *a):
        c = sqlite3.connect(self.s.db_path)
        c.row_factory = sqlite3.Row
        return [dict(r) for r in c.execute(sql, a).fetchall()]

    def methods(self):
        return self.fakes.tg_methods()

    def photos(self):
        return [b for m, b in self.fakes.tg if m == "sendPhoto"]

    def texts(self):
        return self.fakes.tg_texts()


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path, Rec())


def seed_for_suggestion(e: Env):
    """A tempo nine days back, then easy runs: the gap since a hard session is the honest reason for tomorrow."""
    e.run(1, datetime(2026, 10, 4, 7, 0, tzinfo=UTC), "tempo", 8.0)
    e.run(2, datetime(2026, 10, 6, 7, 0, tzinfo=UTC))
    e.run(3, datetime(2026, 10, 8, 7, 0, tzinfo=UTC))
    e.run(4, datetime(2026, 10, 11, 7, 0, tzinfo=UTC))
    e.run(5, datetime(2026, 9, 20, 7, 0, tzinfo=UTC))   # a runner under two weeks in gets no quality push (M6)
    e.quiet_outbox()
    coach_week(e.svc, none=True)   # no coach week to follow: these tests are about the gap reason


# ---------------------------------------------------------------- suggestion

def test_suggestion_facts_are_stored_with_the_card_and_rendered(env):
    seed_for_suggestion(env)
    cid = env.svc._build_evening_card(UID, "2026-10-13", NOW)
    assert cid
    plan = json.loads(env.q("SELECT media_json FROM convo_cards WHERE card_id=?", cid)[0]["media_json"])
    assert plan["card"] == "suggestion" and plan["video"] is False
    assert plan["facts"] == {"type": "tempo", "session": "Tempo", "distance_km": 8, "date_local": "2026-10-14",
                             "reason": "It has been 9 days since your last hard session."}
    assert env.svc._send_card(env.user(), cid, NOW)
    assert env.rec.sent == [("suggestion", plan["facts"])]
    (photo,) = env.photos()
    assert photo["_files"]["photo"][1] == PNG
    card = env.q("SELECT headline, body FROM cards WHERE card_id=?", cid)[0]
    assert photo["caption"] == f"{card['headline']}\n{card['body']}"
    # the buttons the text card had ride the picture
    rm = photo["reply_markup"]
    kb = json.loads(rm)["inline_keyboard"] if isinstance(rm, str) else rm["inline_keyboard"]
    assert [b["text"] for row in kb for b in row] == ["Sounds good", "Not this week"]


def test_every_number_on_the_suggestion_picture_is_in_the_text(env):
    seed_for_suggestion(env)
    cid = env.svc._build_evening_card(UID, "2026-10-13", NOW)
    body = env.q("SELECT body FROM cards WHERE card_id=?", cid)[0]["body"]
    f = json.loads(env.q("SELECT media_json FROM convo_cards")[0]["media_json"])["facts"]
    assert str(f["distance_km"]) in body and "9 days" in body
    assert set(f) <= P.KIND_FACT_KEYS["suggestion"]


@pytest.mark.parametrize("name,label", [("Tempo", "Tempo"), (None, "Quality session")])
def test_a_coach_week_session_tomorrow_keeps_its_picture(env, name, label):
    """The evening card that follows the coach week names the planned session, and its picture shows that session."""
    seed_for_suggestion(env)
    coach_week(env.svc, "quality", distance_m=7000, name=name)
    cid = env.svc._build_evening_card(UID, "2026-10-13", NOW)
    assert env.q("SELECT situation FROM convo_cards WHERE card_id=?", cid)[0]["situation"] == "sugg_plan_session"
    f = json.loads(env.q("SELECT media_json FROM convo_cards WHERE card_id=?", cid)[0]["media_json"])["facts"]
    assert f == {"type": "tempo", "session": label, "distance_km": 7, "date_local": "2026-10-14", "reason": "Part of your plan."}
    assert "7 km" in env.q("SELECT body FROM cards WHERE card_id=?", cid)[0]["body"]
    assert env.svc._send_card(env.user(), cid, NOW) and env.rec.kinds() == ["suggestion"]


def test_suggestion_falls_back_to_text_when_the_worker_fails(tmp_path):
    e = Env(tmp_path, Rec(fail={"suggestion"}))
    seed_for_suggestion(e)
    cid = e.svc._build_evening_card(UID, "2026-10-13", NOW)
    assert e.svc._send_card(e.user(), cid, NOW)
    assert e.methods() == ["sendMessage"] and not e.photos()
    assert "Sounds good" in json.dumps(e.fakes.tg[-1][1]["reply_markup"])


def test_a_suggestion_card_without_stored_facts_stays_text(env):
    """A card written before the facts were kept (or any plan without them) is text, never a guess."""
    seed_for_suggestion(env)
    cid = env.svc._build_evening_card(UID, "2026-10-13", NOW)
    with db.tx(env.s.db_path) as c:
        c.execute("UPDATE convo_cards SET media_json=? WHERE card_id=?",
                  (json.dumps({"card": "suggestion", "reason": "gap", "touch_card": None, "video": False}), cid))
    assert env.svc._send_card(env.user(), cid, NOW)
    assert not env.photos() and env.rec.sent == []


def test_suggestion_cap_is_unchanged_two_a_week_and_no_third_picture(env):
    seed_for_suggestion(env)
    built = [env.svc._build_evening_card(UID, f"2026-10-1{d}", NOW) for d in (3, 4, 5)]
    assert [b is not None for b in built] == [True, True, False]
    for cid in built:
        if cid:
            env.svc._send_card(env.user(), cid, NOW)
    assert env.rec.kinds() == ["suggestion", "suggestion"]


def test_the_facts_are_in_the_runners_export(env):
    seed_for_suggestion(env)
    cid = env.svc._build_evening_card(UID, "2026-10-13", NOW)
    env.svc._send_card(env.user(), cid, NOW)
    me = env.svc.get_me(UID, NOW)
    (m,) = [x for x in me["messages_sent_30d"] if x["kind"] == "evening"]
    assert m["picture_facts"] == {"facts": json.loads(env.q("SELECT media_json FROM convo_cards")[0]["media_json"])["facts"]}
    assert "media_json" not in m


def test_deleting_the_user_deletes_the_facts(env):
    seed_for_suggestion(env)
    env.svc._build_evening_card(UID, "2026-10-13", NOW)
    env.svc.delete_me(UID)
    assert env.q("SELECT COUNT(*) n FROM convo_cards")[0]["n"] == 0


# ---------------------------------------------------------------- milestone and countdown

def ten_runs(e: Env):
    for i in range(9):
        e.run(i + 1, datetime(2026, 10, 1, 7, 0, tzinfo=UTC) + timedelta(days=i))
    e.quiet_outbox()
    return e.run(10, NOW - timedelta(hours=2))


def test_the_tenth_run_sends_a_milestone_picture_after_the_run_card(env):
    ten_runs(env)
    env.svc.run_outbox(NOW + timedelta(seconds=1))
    assert env.rec.kinds() == ["share"]
    plan = json.loads(env.q("SELECT media_json FROM convo_cards")[0]["media_json"])
    assert plan["touch_card"] == "milestone"
    assert plan["touch_facts"] == {"kind": "runs", "value": 10, "line": "Double digits."}
    env.svc.run_outbox(NOW + timedelta(seconds=2))
    assert env.rec.kinds() == ["share", "milestone"]
    first, second = env.photos()
    assert first["caption"] and "caption" not in second and "reply_markup" not in second   # media only, no buttons
    assert second["_files"]["photo"][1] == PNG
    assert env.q("SELECT state FROM outbox WHERE kind='followup'") == [{"state": "done"}]


def test_a_milestone_picture_that_fails_leaves_the_text_to_stand(tmp_path):
    e = Env(tmp_path, Rec(fail={"milestone"}))
    ten_runs(e)
    e.svc.run_outbox(NOW + timedelta(seconds=1))
    e.svc.run_outbox(NOW + timedelta(seconds=2))
    assert len(e.photos()) == 1                                    # the run card; no second picture
    body = e.q("SELECT body FROM cards WHERE kind='run'")[0]["body"]
    assert "10" in body.split("\n\n")[-1]                         # the touch line is still in the card's text
    assert e.q("SELECT state FROM outbox WHERE kind='followup'") == [{"state": "skipped"}]


def test_a_refused_milestone_upload_is_dropped_not_retried(env, monkeypatch):
    from companion.channels import TelegramChannel
    ten_runs(env)
    env.svc.run_outbox(NOW + timedelta(seconds=1))

    def refuse(self, ref, card, mode):
        raise ChannelError("telegram sendPhoto: http 400", permanent=True)
    monkeypatch.setattr(TelegramChannel, "send_followup", refuse)
    env.svc.run_outbox(NOW + timedelta(seconds=2))
    assert env.q("SELECT state FROM outbox WHERE kind='followup'") == [{"state": "skipped"}]


def test_a_race_countdown_sends_the_weeks_to_go(env):
    for i in range(4):
        env.run(i + 1, datetime(2026, 10, 2, 7, 0, tzinfo=UTC) + timedelta(days=2 * i))
    env.quiet_outbox()
    env.run(5, NOW - timedelta(hours=2), plan_weeks_to_race=7)
    env.svc.run_outbox(NOW + timedelta(seconds=1))
    env.svc.run_outbox(NOW + timedelta(seconds=2))
    assert env.rec.sent[-1] == ("race_countdown", {"weeks_to_race": 7})
    assert len(env.photos()) == 2
    assert "7 weeks" in env.q("SELECT body FROM cards WHERE kind='run'")[0]["body"]


def test_the_countdown_title_is_the_goal_and_never_race_day_unless_zero(env):
    from companion.convo import engine
    from companion.convo.touches import Touch
    from render.cards.countdown import build_countdown_html
    t = Touch("race_countdown", "race:7", {"weeks_txt": "7 weeks"})
    titles = {"5k": "5 km", "10k": "10 km", "half": "Half marathon", "marathon": "Marathon"}
    for goal, title in titles.items():
        assert engine.touch_card_facts(t, {"goal_type": goal})[1] == {"weeks_to_race": 7, "race_name": title}
    for mem in ({}, {"goal_type": "fitness"}, {"goal_type": "unknown"}):
        assert engine.touch_card_facts(t, mem)[1] == {"weeks_to_race": 7}
    for facts in ({"weeks_to_race": 7}, {"weeks_to_race": 1}, {"weeks_to_race": 7, "race_name": "Half marathon"},
                  {"days_to_race": 61}):
        assert "race day" not in build_countdown_html(facts).lower()
    assert "YOUR RACE" in build_countdown_html({"weeks_to_race": 7}).upper()
    assert "HALF MARATHON" in build_countdown_html({"weeks_to_race": 7, "race_name": "Half marathon"}).upper()
    assert "race day" in build_countdown_html({"weeks_to_race": 0}).lower()


def test_the_stored_countdown_facts_carry_the_goal(env):
    for i in range(4):
        env.run(i + 1, datetime(2026, 10, 2, 7, 0, tzinfo=UTC) + timedelta(days=2 * i))
    env.quiet_outbox()
    with db.tx(env.s.db_path) as c:
        c.execute("INSERT INTO memory (user_id, key, value, updated_at) VALUES (?,?,?,?)", (UID, "goal_type", "half", iso(NOW)))
    env.run(5, NOW - timedelta(hours=2), plan_weeks_to_race=7)
    env.svc.run_outbox(NOW + timedelta(seconds=1))
    env.svc.run_outbox(NOW + timedelta(seconds=2))
    assert env.rec.sent[-1] == ("race_countdown", {"weeks_to_race": 7, "race_name": "Half marathon"})


def test_a_month_to_race_stays_text(env):
    """race_month ("2 months away") is not a countdown: no picture, and nothing is stored for one."""
    from companion.convo import engine
    from companion.convo.touches import Touch
    assert engine.touch_card_facts(Touch("race_month", "race_month:2", {"months_txt": "2 months"})) == (None, None)
    assert engine.touch_card_facts(Touch("streak", "streak:3", {"streak": "3"})) == (None, None)


def test_km_milestone_facts():
    from companion.convo import engine
    from companion.convo.touches import Touch
    kind, facts = engine.touch_card_facts(Touch("milestone_km", "km:1000", {"total_km": "1000"}))
    assert kind == "milestone" and facts == {"kind": "distance_km", "value": 1000, "line": "A thousand kilometres."}
    for (k, v), line in engine.MILESTONE_LINE.items():
        assert len(line) <= 40 and "—" not in line                 # fits the card; no em dashes


def test_whatsapp_never_gets_the_second_picture(tmp_path):
    e = Env(tmp_path, Rec(), channel="whatsapp")
    ten_runs(e)
    with db.tx(e.s.db_path) as c:
        c.execute("UPDATE users SET last_inbound_at=?", (iso(NOW),))
    e.svc.run_outbox(NOW + timedelta(seconds=1))
    assert e.q("SELECT COUNT(*) n FROM outbox WHERE kind='followup'")[0]["n"] == 0
    assert e.rec.sent == []


# ---------------------------------------------------------------- monthly poster

def september(e: Env):
    plan = [(1, "easy", 6.0), (3, "interval", 7.5), (6, "long", 14.0), (9, "easy", 5.0), (14, "tempo", 8.0),
            (20, "easy", 6.5), (27, "long", 12.4)]
    for i, (d, t, km) in enumerate(plan):
        e.run(i + 1, datetime(2026, 9, d, 7, 0, tzinfo=UTC), t, km)
    e.quiet_outbox()


def test_the_poster_is_planned_once_on_the_first_for_the_month_just_ended(env):
    september(env)
    assert env.svc.plan_monthly(FIRST.replace(hour=8)) == 0                  # before the window
    assert env.svc.plan_monthly(FIRST) == 1
    assert env.svc.plan_monthly(FIRST + timedelta(minutes=10)) == 0          # already scheduled
    assert env.svc.plan_monthly(FIRST.replace(hour=11)) == 0                 # after the window
    assert env.svc.plan_monthly(FIRST + timedelta(days=1)) == 0              # not the 1st
    (row,) = env.q("SELECT kind, ref FROM outbox WHERE kind='monthly'")
    assert row["ref"] == "2026-09"


def test_poster_goes_out_as_the_route_less_calendar_with_a_fake_worker(env):
    september(env)
    env.svc.plan_monthly(FIRST)
    env.svc.run_outbox(FIRST + timedelta(minutes=1))
    (kind, facts), = env.rec.sent
    assert kind == "monthly"
    assert facts["month_label"] == "September" and facts["run_count"] == 7 and facts["month_start"] == "2026-09-01"
    assert facts["distance_km"] == 59.4
    assert all(set(r) == {"date", "type", "distance_km", "duration_s"} for r in facts["runs"])   # no route, zones or ids
    assert facts["runs"][0] == {"date": "2026-09-01", "type": "easy", "distance_km": 6.0, "duration_s": 2160}
    from render.cards.monthly import has_routes
    assert not has_routes(facts)                                             # so the worker draws the calendar layout
    (photo,) = env.photos()
    card = env.q("SELECT headline, body FROM cards WHERE kind='monthly'")[0]
    assert photo["caption"] == f"{card['headline']}\n{card['body']}" and "7 runs" in card["body"]
    assert "reply_markup" not in photo
    assert env.q("SELECT run_id FROM cards WHERE kind='monthly'") == [{"run_id": "monthly:2026-09"}]


def test_poster_failure_falls_back_to_the_text_card(tmp_path):
    e = Env(tmp_path, Rec(fail={"monthly"}))
    september(e)
    e.svc.plan_monthly(FIRST)
    e.svc.run_outbox(FIRST + timedelta(minutes=1))
    assert e.methods() == ["sendMessage"] and "7 runs" in e.texts()[0]


def test_poster_caps_once_a_month_telegram_only_not_paused_and_never_on_top_of_a_card(tmp_path):
    e = Env(tmp_path, Rec())
    september(e)
    # a card went out an hour ago: wait for a later tick in the window rather than land on top of it
    with db.tx(e.s.db_path) as c:
        c.execute("INSERT INTO cards (card_id, user_id, run_id, kind, headline, body, buttons_json, source, created_at, sent_at) "
                  "VALUES ('c1', ?, 'x', 'run', 'h', 'b', '[]', 'template', ?, ?)",
                  (UID, iso(FIRST - timedelta(hours=1)), iso(FIRST - timedelta(hours=1))))
    assert e.svc.plan_monthly(FIRST) == 0                                    # 09:15, 1 h after that card
    assert e.svc.plan_monthly(FIRST + timedelta(hours=1, minutes=30)) == 0   # 10:45, still inside 3 hours of it
    later = FIRST + timedelta(hours=2, minutes=1)                            # 11:16, 3 h 1 min after it, window still open
    assert e.svc.plan_monthly(later) == 1
    e.svc.run_outbox(later + timedelta(minutes=1))
    assert e.rec.kinds() == ["monthly"]
    # building twice never makes two cards or spends the month twice
    a = e.q("SELECT card_id FROM cards WHERE kind='monthly'")[0]["card_id"]
    assert e.svc._build_monthly_card(UID, "2026-09", later + timedelta(minutes=5)) == a
    assert len(e.q("SELECT * FROM cards WHERE kind='monthly'")) == 1
    assert len(e.q("SELECT * FROM quota WHERE key='monthly:2026-09'")) == 1
    # and a built card means nothing more is planned for the month, however late the tick
    assert e.svc.plan_monthly(later + timedelta(minutes=20)) == 0

    p = Env(tmp_path / "p", Rec())
    september(p)
    with db.tx(p.s.db_path) as c:
        c.execute("UPDATE users SET paused=1")
    assert p.svc.plan_monthly(FIRST) == 0

    w = Env(tmp_path / "w", Rec(), channel="whatsapp")
    september(w)
    assert w.svc.plan_monthly(FIRST) == 0


def test_no_poster_for_a_month_without_runs(env):
    env.run(1, datetime(2026, 9, 29, 7, 0, tzinfo=UTC))                       # a run in the last 62 days, none in October
    env.quiet_outbox()
    assert env.svc.plan_monthly(datetime(2026, 11, 1, 9, 15, tzinfo=UTC)) == 0   # October is empty
    assert env.svc.plan_monthly(FIRST) == 1                                       # September is not


def test_poster_respects_the_kill_switch_and_quiet_hours(tmp_path):
    e = Env(tmp_path, Rec(), default_quiet=(8 * 60, 10 * 60))                # quiet 08:00-10:00 local
    september(e)
    assert e.svc.plan_monthly(FIRST) == 0                                     # planned only outside quiet hours
    e2 = Env(tmp_path / "k", Rec(), sends_paused=True)
    september(e2)
    e2.svc.plan_monthly(FIRST)
    e2.svc.run_outbox(FIRST + timedelta(minutes=1))
    assert e2.fakes.tg == [] and e2.q("SELECT state FROM outbox WHERE kind='monthly'") == [{"state": "pending"}]


def test_month_facts_use_the_local_month_and_ignore_other_months():
    rows = [
        {"start_utc": "2026-09-30T20:00:00Z", "zone_id": "Pacific/Auckland", "type": "easy", "distance_m": 5000, "duration_s": 1800},
        {"start_utc": "2026-10-01T07:00:00Z", "zone_id": "UTC", "type": "easy", "distance_m": 9000, "duration_s": 3000},
    ]
    sept = month_facts("2026-09", rows)
    oct_ = month_facts("2026-10", rows)
    assert sept["run_count"] == 0 and oct_["run_count"] == 2          # 20:00Z on the 30th is 09:00 on 1 Oct in Auckland
    assert [r["date"] for r in oct_["runs"]] == ["2026-10-01", "2026-10-01"]


# ---------------------------------------------------------------- the replay caption rule

def test_a_replayed_touch_picture_carries_the_replay_line_in_its_caption(tmp_path):
    from companion.replay import ReplayChannel, Replayer
    from companion.channels import OutCard, TelegramChannel
    from companion.media import Media
    from test_replay import Env as REnv, UID as RUID
    e = REnv(tmp_path, "t", media_enabled=True)
    inner = e.svc.channels["telegram"]
    assert isinstance(inner, TelegramChannel)
    r = Replayer(e.svc, RUID, [], 0, real_now=lambda: datetime(2026, 10, 1, tzinfo=UTC), out=lambda _l: None)
    r.vnow = datetime(2026, 10, 6, 2, 0, tzinfo=UTC)
    ch = e.svc.channels["telegram"]
    assert isinstance(ch, ReplayChannel)
    ch.send_followup(OWNER, OutCard("abc123", "", "", [], Media(photo=PNG), ()), "touch_card")
    (photo,) = [b for m, b in e.fakes.tg if m == "sendPhoto"]
    assert photo["caption"].startswith("Replay ") and "reply_markup" not in photo


# ---------------------------------------------------------------- the protocol allow-list

GOOD = {
    "suggestion": {"type": "easy", "session": "Easy run", "distance_km": 6, "date_local": "2026-10-14", "reason": "Load is high."},
    "milestone": {"kind": "runs", "value": 100, "line": "Triple digits."},
    "race_countdown": {"weeks_to_race": 7},
    "monthly": {"month_label": "September", "month_start": "2026-09-01", "distance_km": 10.0, "run_count": 1, "duration_s": 3600,
                "runs": [{"date": "2026-09-01", "type": "easy", "distance_km": 10.0, "duration_s": 3600}]},
}


@pytest.mark.parametrize("kind", sorted(GOOD))
def test_the_new_kinds_pass_the_allow_list(kind):
    assert P.check_request({"v": 1, "op": "card", "kind": kind, "facts": GOOD[kind]})[1] == kind
    assert P.encode_request("card", kind, GOOD[kind])


@pytest.mark.parametrize("kind", sorted(GOOD))
@pytest.mark.parametrize("extra", ["run_id", "chat_id", "token", "route", "place_note", "lat", "anything"])
def test_unknown_or_foreign_keys_are_refused(kind, extra):
    bad = {**GOOD[kind], extra: "x"}
    with pytest.raises(P.ProtocolError) as e:
        P.check_request({"v": 1, "op": "card", "kind": kind, "facts": bad})
    assert e.value.code == "bad_request"
    with pytest.raises(P.ProtocolError):
        P.encode_request("card", kind, bad)


def test_a_key_that_is_allowed_for_another_kind_is_still_refused():
    for kind, extra in (("suggestion", {"place_note": "Takapuna"}), ("milestone", {"pace_s_per_km": 340}),
                        ("race_countdown", {"week_label": "Week 1"}), ("monthly", {"best_moment": {"text": "x"}})):
        assert set(extra) <= P.ALLOWED_FACT_KEYS
        with pytest.raises(P.ProtocolError):
            P.check_request({"v": 1, "op": "card", "kind": kind, "facts": {**GOOD[kind], **extra}})


def test_a_route_or_extra_field_inside_a_monthly_run_is_refused():
    for extra in ({"route": [[1.3, 103.8]]}, {"zone_s": [1, 2, 3, 4, 5]}, {"run_id": "r1"}, {"locality": "Takapuna"}):
        facts = {**GOOD["monthly"], "runs": [{**GOOD["monthly"]["runs"][0], **extra}]}
        with pytest.raises(P.ProtocolError):
            P.check_request({"v": 1, "op": "card", "kind": "monthly", "facts": facts})
    with pytest.raises(P.ProtocolError):                                            # a run list on any other kind
        P.check_request({"v": 1, "op": "card", "kind": "milestone", "facts": {**GOOD["milestone"], "runs": []}})
    with pytest.raises(P.ProtocolError):                                            # too many runs
        P.check_request({"v": 1, "op": "card", "kind": "monthly",
                         "facts": {**GOOD["monthly"], "runs": GOOD["monthly"]["runs"] * (P.MONTHLY_MAX_RUNS + 1)}})


@pytest.mark.parametrize("bad", [{"value": "100"}, {"value": True}, {"value": float("nan")}, {"line": 5}, {"line": "x" * 500}])
def test_value_shapes_are_checked(bad):
    with pytest.raises(P.ProtocolError):
        P.check_request({"v": 1, "op": "card", "kind": "milestone", "facts": {**GOOD["milestone"], **bad}})


def test_the_client_refuses_before_it_connects():
    c = RenderClient("/nonexistent/render.sock")
    with pytest.raises(RenderError) as e:
        c.card("suggestion", {**GOOD["suggestion"], "place_note": "Takapuna"})
    assert e.value.code == "bad_request"            # not "unavailable": the request never left


def test_the_worker_side_refuses_too_without_rendering_anything():
    """The worker re-runs the same check on the bytes it receives, before it starts a render."""
    a, b = socket.socketpair()
    body = json.dumps({"v": 1, "op": "card", "kind": "monthly",
                       "facts": {**GOOD["monthly"], "runs": [{**GOOD["monthly"]["runs"][0], "route": [[1, 2]]}]}}).encode()
    a.sendall(len(body).to_bytes(4, "big") + body)
    t = threading.Thread(target=Worker("unused.sock").handle, args=(b,))
    t.start()
    with pytest.raises(P.ProtocolError) as e:
        P.read_response(a, P.PHOTO_MAX_BYTES, 5)
    t.join(5)
    assert e.value.code == "bad_request"
    a.close()
    b.close()


def test_the_worker_maps_every_new_kind_to_its_renderer(tmp_path, monkeypatch):
    import render.cards as cards
    from render.worker import _render_one
    seen = []
    for name in ("render_suggestion", "render_milestone", "render_race_countdown", "render_monthly_poster"):
        monkeypatch.setattr(cards, name, lambda facts, memory, _n=name: seen.append(_n) or PNG)
    for kind in ("suggestion", "milestone", "race_countdown", "monthly"):
        out = tmp_path / f"{kind}.png"
        _render_one("card", kind, GOOD[kind], out)
        assert out.read_bytes() == PNG
    assert seen == ["render_suggestion", "render_milestone", "render_race_countdown", "render_monthly_poster"]


def test_the_cards_accept_exactly_the_facts_the_companion_sends():
    """Builders are pure HTML (no browser): the companion's facts must not trip a missing key."""
    from render.cards.countdown import build_countdown_html
    from render.cards.milestone import build_milestone_html
    from render.cards.monthly import build_monthly_calendar_html
    from render.cards.suggestion import build_suggestion_html
    assert "WEEKS TO GO" in build_countdown_html(GOOD["race_countdown"]).upper()
    assert "WEEK TO GO" in build_countdown_html({"weeks_to_race": 1}).upper()
    assert "61" in build_countdown_html({"days_to_race": 61}) and "DAYS TO GO" in build_countdown_html({"days_to_race": 61}).upper()
    assert "Triple digits." in build_milestone_html(GOOD["milestone"])
    assert "Easy run" in build_suggestion_html(GOOD["suggestion"])
    assert "September" in build_monthly_calendar_html(GOOD["monthly"])


# ---------------------------------------------------------------- the older kinds stay strict

@pytest.mark.parametrize("kind,op", [("light", "card"), ("flood", "card"), ("pb", "card"), ("weekly_recap", "card"),
                                     ("run", "video"), ("weekly", "video")])
def test_the_older_kinds_refuse_the_keys_the_newer_cards_added(kind, op):
    base = {"type": "easy", "distance_km": 5, "duration_s": 100}
    for key in ("session", "reason", "date_local", "kind", "value", "line", "weeks_to_race", "race_name",
                "month_label", "month_start", "run_count"):
        assert key in P.ALLOWED_FACT_KEYS
        with pytest.raises(P.ProtocolError):
            P.check_request({"v": 1, "op": op, "kind": kind, "facts": {**base, key: "x"}})


def test_the_older_kinds_still_accept_exactly_what_the_companion_builds():
    from companion.media import run_facts, week_facts
    row = {"run_id": "r", "type": "easy", "start_utc": "2026-10-10T06:00:00+00:00", "zone_id": "UTC", "distance_m": 7000,
           "duration_s": 2400, "pace_s_per_km": 342.9, "climb_m": 40, "locality": "Takapuna", "verdict": "holding",
           "pb": "5k", "zone_min": {"z1": 5, "z2": 30}}
    for kind in ("light", "flood", "pb"):
        P.check_request({"v": 1, "op": "card", "kind": kind, "facts": run_facts(row, "Steady")})
    wf = week_facts("2026-W41", [{**row, "scores_delta": '{"aerobic": 1}'}])
    P.check_request({"v": 1, "op": "card", "kind": "weekly_recap", "facts": wf})
    P.check_request({"v": 1, "op": "video", "kind": "weekly", "facts": {**wf, "duration_s": 1}})


# ---------------------------------------------------------------- the export holds built-but-unsent cards too

def test_a_built_but_unsent_card_is_in_the_export_with_its_facts(env):
    seed_for_suggestion(env)
    cid = env.svc._build_evening_card(UID, "2026-10-13", NOW)       # built, never sent
    assert cid
    me = env.svc.get_me(UID, NOW)
    (m,) = [x for x in me["messages_sent_30d"] if x["kind"] == "evening"]
    assert m["sent_at"] is None and m["picture_facts"]["facts"]["session"] == "Tempo"
