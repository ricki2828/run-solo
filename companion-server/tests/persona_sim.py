"""Four weeks x 3 personas through the real Service (check-ins ON, templates only, no model, no media).

The driver behind test_persona_coherence.py. Persona A is the trail runner (Mon/Wed/Fri evenings, taps the feel row and
every question), B a fresh runner with two runs, C a lapsed runner who comes back in week three. Each card is recorded
the moment it is sent, together with what Home (`next_session`) said at that instant, so the test can hold every message
that names a session to the same answer.
"""
from __future__ import annotations

import json
import random
import tempfile
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

from companion import db
from companion.channels import Inbound
from companion.config import Settings
from companion.convo.sim import QUIET, FakeWeather, Net
from companion.service import RunIn, Service
from companion.timeutil import UTC, iso, parse_iso, to_local

SG = "Asia/Singapore"
START = date(2026, 10, 19)   # a Monday
DAYS = 28


def hm(d: date, t: str, z: str) -> datetime:
    h, m = t.split(":")
    return datetime(d.year, d.month, d.day, int(h), int(m), tzinfo=ZoneInfo(z))


def runin(rid, day, t, typ, km, pace, true_pace, zones, zone=SG, **kw) -> RunIn:
    s = hm(day, t, zone)
    return RunIn.model_validate({
        "run_id": rid, "type": typ, "start_utc": s.astimezone(UTC).isoformat(),
        "utc_offset_min": int(s.utcoffset().total_seconds() // 60), "zone_id": zone,
        "duration_s": round(km * pace), "distance_m": round(km * 1000), "pace_s_per_km": float(pace),
        "true_pace_s_per_km": float(true_pace), "zone_min": zones, "locality": None,
        "area_lat": 1.3, "area_lon": 103.8, **kw})


TRAIL_Z = {"z1": 1.0, "z2": 7.0, "z3": 18.0, "z4": 1.5}
EASY_Z = {"z1": 4, "z2": 30, "z3": 3}


def persona_trail(rng: random.Random) -> dict:
    """Mon/Wed/Fri trail evenings, a few Saturdays in the past, one skipped Friday; taps everything."""
    hist, plan, i, d = [], [], 0, START - timedelta(days=24)
    while d < START:
        if d.weekday() in (0, 2, 4) or (d.weekday() == 5 and rng.random() < .3):
            hist.append(("h%02d" % i, d, "18:30", "trail", 4.7 + rng.uniform(-.2, .2), 363 + rng.uniform(-6, 6),
                         329 + rng.uniform(-4, 4), TRAIL_Z))
            i += 1
        d += timedelta(days=1)
    for k in range(DAYS):
        d = START + timedelta(days=k)
        if d.weekday() in (0, 2, 4) and d != date(2026, 10, 30):
            plan.append(("r%02d" % k, d, "18:30", "trail", 4.7 + rng.uniform(-.2, .3), 362 + rng.uniform(-6, 6),
                         329 + rng.uniform(-5, 4), TRAIL_Z, rng.choice(["right", "right", "hard", None])))
    return dict(name="trail", hist=hist, plan=plan, memory={"goal_type": "fitness"}, consent_day=-10, taps=True)


def persona_fresh(rng: random.Random) -> dict:
    plan = [("f00", START + timedelta(days=3), "07:00", "easy", 3.2, 410, 405, EASY_Z, None),
            ("f01", START + timedelta(days=6), "07:10", "easy", 3.8, 400, 396, EASY_Z, None)]
    return dict(name="fresh", hist=[], plan=plan, memory={}, consent_day=0, taps=False)


def persona_lapsed(rng: random.Random) -> dict:
    hist, i = [], 0
    last = START - timedelta(days=12)
    d = last - timedelta(days=60)
    while d <= last:
        if d.weekday() in (1, 3, 5):
            km = {1: 6.0, 3: 6.5, 5: 12.0}[d.weekday()] + rng.uniform(-.4, .4)
            hist.append(("l%02d" % i, d, "06:30", "easy", km, 350 + rng.uniform(-5, 5) + (10 if d.weekday() == 5 else 0),
                         346, EASY_Z))
            i += 1
        d += timedelta(days=1)
    plan = [("lc0", START + timedelta(days=19), "06:30", "easy", 4.0, 372, 368, EASY_Z, None),   # back on Sat 7 Nov
            ("lc1", START + timedelta(days=22), "06:30", "easy", 5.0, 365, 361, EASY_Z, None)]
    return dict(name="lapsed", hist=hist, plan=plan, memory={"goal_type": "half", "usual_days": "weekdays"},
                consent_day=-70, taps=False)


@dataclass
class Sent:
    at: datetime            # UTC
    local: datetime
    kind: str
    headline: str
    body: str
    run_id: str | None
    home: dict | None       # next_session()["next_session"] at that instant
    error: str | None = None


@dataclass
class Sim:
    persona: dict
    wd: Path
    log: list[Sent] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.rng = random.Random(3)
        self.net = Net()
        self.toasts: list[str] = []   # the text of every tap's toast (answerCallbackQuery)

        def handler(req: httpx.Request) -> httpx.Response:
            if req.url.path.endswith("answerCallbackQuery") and req.content:
                self.toasts.append(json.loads(req.content).get("text") or "")
            return self.net.handler(req)

        s = Settings(db_path=str(self.wd / "sim.db"), pepper=b"s" * 32, allowed_ids=frozenset({"telegram:424242"}),
                     telegram_token="1:FAKE", telegram_bot="RSBot", telegram_webhook_secret="x" * 16,
                     openrouter_key=None, default_quiet=QUIET, weather_enabled=True, checkins_enabled=True)
        self.svc = Service(s, httpx.Client(transport=httpx.MockTransport(handler)))
        self.svc.weather = FakeWeather()
        t0 = hm(START + timedelta(days=self.persona["consent_day"]), "12:00", SG).astimezone(UTC)
        with db.tx(s.db_path) as c:
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, "
                      "utc_offset_min, last_inbound_at, weather_optin, tester_no) "
                      "VALUES ('u_sim','telegram','424242',?,?,?,?,?,?,1,1)",
                      (iso(t0), "1", iso(t0), SG, 480, iso(t0)))
            c.execute("INSERT INTO devices (token_hash, user_id, created_at) VALUES ('x','u_sim',?)", (iso(t0),))
        self.uid = "u_sim"
        self.svc.set_checkin_consent(self.uid, 2)
        with db.tx(s.db_path) as c:
            for k, v in self.persona["memory"].items():
                self.svc._memory_set(c, self.uid, k, v, t0)
        for (rid, d, t, typ, km, pace, tp, z) in self.persona["hist"]:
            r = runin(rid, d, t, typ, km, pace, tp, z)
            self.svc.ingest_run(self.uid, r, r.start_utc + timedelta(seconds=r.duration_s + 40000))
        with db.tx(s.db_path) as c:
            c.execute("DELETE FROM outbox")
            c.execute("DELETE FROM quota")
            c.execute("DELETE FROM cards")
            c.execute("DELETE FROM msglog")
        self.seen: set[str] = set()
        self.press = 0

    def tap(self, card: dict, code: str | None = None, action: str | None = None, now: datetime | None = None) -> None:
        self.press += 1
        if code:
            with db.ro(self.svc.s.db_path) as c:
                sl = c.execute("SELECT message_id FROM checkin_slots WHERE card_id=?", (card["card_id"],)).fetchone()
            self.svc.handle_inbound(Inbound("telegram", "424242", f"t{self.press}", card_id=card["card_id"],
                                            callback_id=f"cb{self.press}",
                                            callback_message_id=sl["message_id"] if sl else None, code=code), now)
            return
        for i, b in enumerate(json.loads(card["buttons_json"])):
            if b["action"] == action:
                self.svc.handle_inbound(Inbound("telegram", "424242", f"t{self.press}", card_id=card["card_id"],
                                                button_idx=i, callback_id=f"cb{self.press}", callback_message_id="1"), now)
                return

    def react(self, now: datetime, feel_by_run: dict) -> None:
        with db.ro(self.svc.s.db_path) as c:
            rows = [dict(r) for r in c.execute("SELECT * FROM cards WHERE sent_at IS NOT NULL ORDER BY sent_at, rowid")]
        for card in rows:
            if card["card_id"] in self.seen:
                continue
            self.seen.add(card["card_id"])
            sent = parse_iso(card["sent_at"])
            try:
                home = self.svc.next_session(self.uid, sent)["next_session"]
                err = None
            except Exception as e:   # recorded, and the test fails on it
                home, err = None, repr(e)
            self.log.append(Sent(sent, to_local(sent, SG), card["kind"], card["headline"], card["body"], card["run_id"], home, err))
            if not self.persona["taps"]:
                continue
            at = sent + timedelta(minutes=3)
            k = card["kind"]
            if k == "run":
                if feel_by_run.get(card["run_id"]):
                    self.tap(card, action=f"feel:{feel_by_run[card['run_id']]}", now=at)
            elif k == "question":
                btns = json.loads(card["buttons_json"])
                if btns:
                    self.tap(card, action=btns[0]["action"], now=at)
            elif k == "ci_ready":
                self.tap(card, code="r.normal", now=at)
            elif k == "ci_today":
                self.tap(card, code="t.go", now=at)
            elif k == "ci_shape":
                self.tap(card, code="s.3", now=at)
            elif k in ("trust", "ellis"):
                btns = json.loads(card["buttons_json"])
                if btns:
                    self.tap(card, action=btns[0]["action"], now=at)

    def go(self, until: date | None = None) -> "Sim":
        """Run the four weeks, or only the days before `until`."""
        feels, events = {}, []
        for (rid, d, t, typ, km, pace, tp, z, feel) in self.persona["plan"]:
            r = runin(rid, d, t, typ, km, pace, tp, z)
            events.append((r.start_utc + timedelta(seconds=r.duration_s + 5), "run", r))
            feels[rid] = feel
        for k in range(DAYS):
            d = START + timedelta(days=k)
            if until and d >= until:
                break
            for mins in range(5 * 60, 24 * 60, 15):
                events.append((hm(d, f"{mins // 60:02d}:{mins % 60:02d}", SG).astimezone(UTC), "tick", None))
        events.sort(key=lambda e: (e[0], e[1] == "tick"))
        for at, kind, r in events:
            if until and to_local(at, SG).date() >= until:
                break
            if kind == "run":
                self.svc.ingest_run(self.uid, r, at)
            self.svc.tick(at)
            self.react(at, feels)
        return self


def simulate(name: str, until: date | None = None, tweak=None) -> Sim:
    """One persona through the real Service. `tweak(persona)` edits it first (a different tap on one run, say)."""
    persona = {"trail": persona_trail, "fresh": persona_fresh, "lapsed": persona_lapsed}[name](random.Random(11))
    if tweak:
        tweak(persona)
    return Sim(persona, Path(tempfile.mkdtemp(prefix=f"persona-{name}-"))).go(until)
