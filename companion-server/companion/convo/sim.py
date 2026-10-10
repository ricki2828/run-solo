"""Month simulator: a 40s runner in Singapore who travels to Milos, through the real Service.

It drives the production code (ingest, outbox, quiet hours, caps, buttons) with a virtual clock, fake
Telegram and fake weather, then writes a markdown transcript of every message with the card or
video that would attach. `check()` asserts the house rules over what was actually sent.

    python -m companion.convo.sim [--out PATH]
"""
from __future__ import annotations

import argparse
import json
import random
import re
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from .. import db
from ..channels import Inbound
from ..config import Settings
from ..service import RunIn, Service
from ..timeutil import UTC, in_quiet, iso, parse_iso, to_local, week_key
from ..writer import NUM_WORDS, numbers_in
from . import touches as T
from .suggest import EVENING_END_MIN, EVENING_START_MIN
from .weather import Forecast, RunWeather

SG, GR = "Asia/Singapore", "Europe/Athens"
START_DAY = date(2026, 10, 5)      # Monday
END_DAY = date(2026, 11, 15)       # Sunday, six weeks later
RACE_DAY = date(2026, 12, 6)
HEATWAVE = (date(2026, 10, 12), date(2026, 10, 17))
MILOS = (date(2026, 10, 22), date(2026, 10, 30))
QUIET = (21 * 60 + 30, 7 * 60)
DEFAULT_OUT = Path.home() / "Files/RunSupreme/previews/convo/month-transcript.md"
CHAT = "424242"

ZONES = {  # minutes by zone for a typical session of the type
    "easy": {"z1": 4, "z2": 30, "z3": 3}, "long": {"z1": 5, "z2": 75, "z3": 15},
    "tempo": {"z1": 6, "z2": 12, "z3": 10, "z4": 14}, "interval": {"z1": 8, "z2": 18, "z3": 6, "z4": 5, "z5": 4},
    "race": {"z1": 5, "z2": 4, "z3": 4, "z4": 9, "z5": 4}, "run": {"z1": 5, "z2": 22, "z3": 10, "z4": 3}, "trail": {"z1": 4, "z2": 28, "z3": 18, "z4": 8},
}
PACE = {"easy": 355, "long": 366, "tempo": 322, "interval": 345, "race": 308, "run": 361, "trail": 430}
LOCALITY = {"easy": "East Coast Park", "long": "MacRitchie", "tempo": "Bishan", "interval": "Marina Bay",
            "race": "Marina Bay", "run": "Bishan", "trail": "Kastro loop"}


@dataclass
class Plan:
    day: date
    at: str                 # local HH:MM
    type: str
    km: float
    pace: float | None = None
    zone: str = SG
    locality: str | None = None
    climb: int | None = None
    pb: str | None = None
    load: str | None = None
    verdict: str | None = None
    feel: str | None = None  # what the runner taps afterwards, if anything
    true_pace: bool = True


# The month. Everything a card says comes from these numbers, nothing else.
MONTH = [
    Plan(date(2026, 10, 6), "06:30", "easy", 7.0, 355),
    Plan(date(2026, 10, 8), "06:00", "interval", 7.5, 345, feel="hard"),
    Plan(date(2026, 10, 10), "06:15", "long", 16.0, 366, feel="right"),
    Plan(date(2026, 10, 13), "06:30", "easy", 7.0, 388, true_pace=False, feel="hard"),      # heat slowdown
    Plan(date(2026, 10, 15), "06:00", "tempo", 8.0, 326, true_pace=False),
    Plan(date(2026, 10, 17), "05:45", "long", 12.0, 388, true_pace=False, feel="hard"),     # heat, shortened
    Plan(date(2026, 10, 19), "06:30", "tempo", 6.0, 322),
    Plan(date(2026, 10, 20), "06:30", "race", 5.0, 306, pb="5k", feel="hard"),              # PB 5K
    Plan(date(2026, 10, 21), "06:30", "easy", 6.0, 368, load="high"),                       # heavy legs after the PB
    Plan(date(2026, 10, 22), "07:20", "easy", 6.0, 372, zone=GR, locality="Plaka", climb=140),  # new city, hills
    Plan(date(2026, 10, 24), "07:30", "trail", 8.0, 432, zone=GR, locality="Kastro loop", climb=320, verdict="baselineSet"),
    Plan(date(2026, 10, 26), "07:10", "trail", 7.0, 425, zone=GR, locality="Kastro loop", climb=300),
    Plan(date(2026, 10, 28), "07:25", "easy", 7.0, 373, zone=GR, locality="Plaka"),
    Plan(date(2026, 10, 29), "07:30", "trail", 8.0, 415, zone=GR, locality="Kastro loop", climb=315, feel="right"),
    # a missed week (2 Nov to 8 Nov), then the comeback
    Plan(date(2026, 11, 9), "06:30", "easy", 5.0, 360, feel="hard"),
    Plan(date(2026, 11, 11), "06:30", "easy", 6.0, 376),
    Plan(date(2026, 11, 12), "06:30", "run", 6.0, 361),
    Plan(date(2026, 11, 13), "06:30", "easy", 7.0, 355, feel="easy"),
    Plan(date(2026, 11, 14), "06:15", "long", 14.0, 368, feel="right"),
]
TRAVEL = [(datetime(2026, 10, 21, 23, 0, tzinfo=ZoneInfo(SG)), GR), (datetime(2026, 10, 30, 21, 0, tzinfo=ZoneInfo(GR)), SG)]
ANSWERS = {"goal_type": "half", "race_month": "2026-12", "usual_days": "both", "niggle_area": "calf",
           "runs_per_week": "3", "surface": "mix", "time_of_day": "early", "run_why": "headspace"}


# --- fakes ----------------------------------------------------------------------------------

class Net:
    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.mid = 100

    def handler(self, req: httpx.Request) -> httpx.Response:
        body = json.loads(req.content) if req.content else {}
        self.mid += 1
        if req.url.host == "api.telegram.org":
            if req.url.path.endswith("sendMessage"):
                self.sent.append(body)
            return httpx.Response(200, json={"ok": True, "result": {"message_id": self.mid}})
        return httpx.Response(404)


class FakeWeather:
    """Singapore is warm and showery, with a heatwave; Milos is mild and mostly dry."""

    @staticmethod
    def _sunrise(d: date, zone: str) -> datetime:
        z = ZoneInfo(zone)
        if zone == SG:
            return datetime(d.year, d.month, d.day, 7, 2, tzinfo=z)
        mins = 7 * 60 + 44 + (d.toordinal() - date(2026, 10, 22).toordinal()) * 1
        if d >= date(2026, 10, 25):
            mins -= 60  # the clocks go back
        return datetime(d.year, d.month, d.day, mins // 60, mins % 60, tzinfo=z)

    def at_run(self, locality, zone_id, start_utc, now):
        d = to_local(start_utc, zone_id).date()
        temp = 33 if zone_id == SG and HEATWAVE[0] <= d <= HEATWAVE[1] else 27 if zone_id == SG else 20
        return RunWeather(temp, self._sunrise(d, zone_id))

    def tomorrow(self, locality, zone_id, tomorrow):
        if zone_id == SG:
            if HEATWAVE[0] <= tomorrow <= HEATWAVE[1]:
                return Forecast(33, 5)
            return Forecast(27, [10, 45, 30, 20, 75, 30, 15, 35, 20][tomorrow.toordinal() % 9])
        return Forecast(19, 70 if tomorrow == date(2026, 10, 27) else 10)


# --- history --------------------------------------------------------------------------------

def seed_history(svc: Service, uid: str, rng: random.Random, n: int = 141) -> int:
    """About a year of runs before the month starts, newest last. Ingested, then the cards are dropped."""
    days: list[tuple[date, str]] = []
    d = START_DAY - timedelta(days=1)
    pattern = [(5, "long"), (3, "tempo"), (1, "easy")]  # Sat, Thu, Tue counting back
    while len(days) < n:
        for wd, typ in pattern:
            cand = d - timedelta(days=(d.weekday() - wd) % 7)
            if rng.random() < 0.9 and len(days) < n:
                days.append((cand, typ))
        d -= timedelta(days=7)
    days.sort()
    first = days[0][0]
    for i, (day, typ) in enumerate(days):
        km = {"easy": 6.0, "long": 11.5, "tempo": 6.6}[typ] + rng.uniform(-0.6, 0.6)
        trend = 20 * (1 - (day - first).days / max((days[-1][0] - first).days, 1))  # fitter over the year
        pace = PACE[typ] + trend + rng.uniform(-4, 4) + (8 if typ == "easy" else 0)
        start = datetime(day.year, day.month, day.day, 6, 30, tzinfo=ZoneInfo(SG))
        run = RunIn.model_validate({
            "run_id": f"h{i:04d}", "type": typ, "start_utc": start.astimezone(UTC).isoformat(),
            "utc_offset_min": 480, "zone_id": SG, "duration_s": round(km * pace), "distance_m": round(km * 1000),
            "pace_s_per_km": round(pace, 1), "true_pace_s_per_km": round(pace - 2, 1),
            "zone_min": ZONES[typ], "locality": LOCALITY[typ]})
        svc.ingest_run(uid, run, start.astimezone(UTC) + timedelta(seconds=run.duration_s + 60))
    with db.tx(svc.s.db_path) as c:
        c.execute("DELETE FROM outbox")
        c.execute("DELETE FROM quota")
    return len(days)


# --- the month ------------------------------------------------------------------------------

@dataclass
class Entry:
    at: datetime
    kind: str          # card | tap
    text: str = ""
    card: dict[str, Any] = field(default_factory=dict)


@dataclass
class SimResult:
    entries: list[Entry]
    cards: list[dict]
    violations: list[str]
    transcript: str


def _local_hm(d: date, hm: str, zone: str) -> datetime:
    h, m = hm.split(":")
    return datetime(d.year, d.month, d.day, int(h), int(m), tzinfo=ZoneInfo(zone))


def _zone_on(d: date) -> str:
    return GR if MILOS[0] <= d <= MILOS[1] else SG


def _run_in(p: Plan, idx: int, svc: Service, uid: str) -> RunIn:
    start = _local_hm(p.day, p.at, p.zone)
    pace = p.pace or PACE[p.type]
    weeks = max((RACE_DAY - p.day).days // 7, 0)
    body: dict[str, Any] = {
        "run_id": f"m{idx:03d}", "type": p.type, "start_utc": start.astimezone(UTC).isoformat(),
        "utc_offset_min": int(start.utcoffset().total_seconds() // 60), "zone_id": p.zone,
        "duration_s": round(p.km * pace), "distance_m": round(p.km * 1000), "pace_s_per_km": float(pace),
        "zone_min": ZONES[p.type], "locality": p.locality or LOCALITY[p.type], "pb": p.pb,
        "load_state": p.load, "climb_m": p.climb, "plan_weeks_to_race": weeks,
        "plan_kind": "long" if p.type == "long" else "easy" if p.type == "easy" else "quality"}
    if p.true_pace:
        body["true_pace_s_per_km"] = float(pace) - 3
    body["verdict"] = p.verdict or _verdict(svc, uid, body)
    return RunIn.model_validate(body)


def _verdict(svc: Service, uid: str, body: dict) -> str:
    """Mimic the app's headline from the same comparison the facts engine makes."""
    from ..facts import comparable
    with db.ro(svc.s.db_path) as c:
        hist = svc._history(c, uid, None)
    probe = {**body, "start_utc": parse_iso(body["start_utc"])}
    prev = comparable(probe, hist)
    if prev is None:
        return "noVerdict"
    use_true = prev.get("true_pace_s_per_km") and body.get("true_pace_s_per_km")
    a, b = (body.get("true_pace_s_per_km"), prev["true_pace_s_per_km"]) if use_true else (body["pace_s_per_km"], prev["pace_s_per_km"])
    return "faster" if a - b <= -3 else "slower" if a - b >= 3 else "holding"


class Month:
    def __init__(self, workdir: Path, seed: int = 7):
        self.rng = random.Random(seed)
        self.net = Net()
        s = Settings(db_path=str(workdir / "sim.db"), pepper=b"s" * 32, allowed_ids=frozenset({f"telegram:{CHAT}"}),
                     telegram_token="1:FAKE", telegram_bot="RSBot", telegram_webhook_secret="x" * 16,
                     openrouter_key=None, default_quiet=QUIET)
        self.svc = Service(s, httpx.Client(transport=httpx.MockTransport(self.net.handler)))
        self.svc.weather = FakeWeather()
        now = datetime(2025, 9, 1, tzinfo=UTC)
        with db.tx(s.db_path) as c:
            c.execute("INSERT INTO users (id, channel, chat_ref, created_at, consent_version, consent_at, zone_id, "
                      "utc_offset_min, last_inbound_at) VALUES ('u_sim','telegram',?,?,?,?,?,?,?)",
                      (CHAT, iso(now), "1", iso(now), SG, 480, iso(now)))
        self.uid = "u_sim"
        self.entries: list[Entry] = []
        self.seen: set[str] = set()
        self.press_n = 0
        self.history_n = seed_history(self.svc, self.uid, self.rng)

    # -- persona
    def _press(self, card: dict, label_prefix: str, now: datetime) -> None:
        buttons = json.loads(card["buttons_json"])
        for i, b in enumerate(buttons):
            if b["label"].startswith(label_prefix) or b["action"] == label_prefix:
                self.press_n += 1
                self.svc.handle_inbound(Inbound("telegram", CHAT, f"tg:sim{self.press_n}", card_id=card["card_id"],
                                                button_idx=i, callback_id=f"cb{self.press_n}",
                                                callback_message_id="1"), now)
                self.entries.append(Entry(now, "tap", f"{b['label']}"))
                return

    def react(self, now: datetime, plan: Plan | None) -> None:
        with db.ro(self.svc.s.db_path) as c:
            rows = [dict(r) for r in c.execute("SELECT * FROM cards WHERE user_id=? AND sent_at IS NOT NULL ORDER BY sent_at, rowid", (self.uid,))]
        for card in rows:
            if card["card_id"] in self.seen:
                continue
            self.seen.add(card["card_id"])
            sent = parse_iso(card["sent_at"])
            self.entries.append(Entry(sent, "card", card=card))
            acts = [json.loads(card["buttons_json"])]
            tap_at = sent + timedelta(minutes=3)
            for b in acts[0]:
                kind, _, rest = b["action"].partition(":")
                if kind == "feel" and card["run_id"] and not card["run_id"].startswith(("recap", "evening")):
                    want = next((p.feel for p in MONTH if f"m{MONTH.index(p):03d}" == card["run_id"]), None)
                    if want:
                        self._press(card, f"feel:{want}", tap_at)
                        break
            for b in acts[0]:
                kind, _, rest = b["action"].partition(":")
                if kind == "ans":
                    key, _, val = rest.partition(":")
                    if ANSWERS.get(key) == val and self.press_n % 4 != 3:  # now and then the runner ignores the question
                        self._press(card, b["action"], tap_at + timedelta(minutes=1))
                        break
            for b in acts[0]:
                if b["action"].startswith("sugg:"):
                    pick = "sugg:skip" if self.press_n % 3 == 0 else "sugg:yes"
                    self._press(card, next(x["action"] for x in acts[0] if x["action"].startswith(pick)), tap_at + timedelta(minutes=2))
                    break

    def tick(self, now: datetime) -> None:
        self.svc.plan_evening(now)
        self.svc.plan_recap(now)
        self.svc.run_outbox(now)
        self.react(now, None)

    def go(self) -> None:
        events: list[tuple[datetime, str, Any]] = []
        d = START_DAY
        while d <= END_DAY:
            z = _zone_on(d)
            for hm in ("07:01", "19:05", "20:05", "23:40"):
                events.append((_local_hm(d, hm, z).astimezone(UTC), "tick", None))
            d += timedelta(days=1)
        for i, p in enumerate(MONTH):
            start = _local_hm(p.day, p.at, p.zone)
            end = start + timedelta(seconds=round(p.km * (p.pace or PACE[p.type])))
            events.append(((end + timedelta(minutes=2)).astimezone(UTC), "run", (i, p)))
        for at, zid in TRAVEL:
            events.append((at.astimezone(UTC), "zone", zid))
        events.sort(key=lambda e: (e[0], e[1] == "tick"))
        for at, kind, payload in events:
            if kind == "zone":  # the app posts the new zone when the phone changes it
                self.svc.set_settings(self.uid, None, None, payload)
                continue
            if kind == "run":
                i, p = payload
                self.svc.ingest_run(self.uid, _run_in(p, i, self.svc, self.uid), at)
            self.tick(at + timedelta(seconds=30)) if kind == "run" else self.tick(at)


# --- checks ---------------------------------------------------------------------------------

BAD_WORDS = ("great effort", "—", "–")
UNIT_FOREIGN = re.compile(r"\b(miles?|mi|kilometres?|metres?|kcal)\b", re.I)


def check(cards: list[dict], zone_of: Any, db_path: str) -> list[str]:
    """Violations of the house rules over the cards that were actually sent."""
    v: list[str] = []
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    meta = {r["card_id"]: dict(r) for r in con.execute("SELECT * FROM convo_cards")}
    variants = [dict(r) for r in con.execute("SELECT key, ts FROM convo_log WHERE kind='variant' ORDER BY ts, id")]
    touches = [dict(r) for r in con.execute("SELECT key, ts FROM convo_log WHERE kind='touch' ORDER BY ts, id")]

    # 1. no repeats
    last: dict[str, datetime] = {}
    for r in variants:
        t = parse_iso(r["ts"])
        if r["key"] in last and (t - last[r["key"]]) < timedelta(days=30):
            v.append(f"variant repeated inside 30 days: {r['key']}")
        last[r["key"]] = t
    texts: set[str] = set()
    for c in cards:
        if c["kind"] == "recap" and "missed" in meta[c["card_id"]]["situation"]:
            pass
        t = c["headline"] + "\n" + c["body"].split("\n\n")[0]
        if t in texts:
            v.append(f"identical message twice: {c['headline']!r}")
        texts.add(t)
    seen_touch_text: set[str] = set()
    for c in cards:
        for para in c["body"].split("\n\n")[1:]:
            if para.endswith("?"):
                continue  # the weekly question set repeats by design (until answered)
            if para in seen_touch_text:
                v.append(f"touch line repeated: {para!r}")
            seen_touch_text.add(para)

    # 2. B4: every number comes from the facts behind the card
    for c in cards:
        m = meta.get(c["card_id"])
        if not m:
            v.append(f"card without convo meta: {c['card_id'][:6]}")
            continue
        text = c["headline"] + " " + c["body"]
        if not numbers_in(text) <= numbers_in(m["allowed"]):
            v.append(f"B4 numbers not in facts: {sorted(numbers_in(text) - numbers_in(m['allowed']))} in {text[:60]!r}")
        if NUM_WORDS.search(text):
            v.append(f"spelled-out number {NUM_WORDS.search(text).group(0)!r}: {text[:60]!r}")
        if UNIT_FOREIGN.search(text):
            v.append(f"foreign unit: {text[:60]!r}")
        for b in BAD_WORDS:
            if b in text.lower():
                v.append(f"banned phrase {b!r}: {text[:60]!r}")

    # 3. frequency caps
    per_week: dict[tuple[str, str], int] = {}
    per_day: dict[str, int] = {}
    runs_seen: set[str] = set()
    for c in cards:
        sent = parse_iso(c["sent_at"])
        z = zone_of(sent)
        wk = week_key(sent, z)
        acts = [b["action"] for b in json.loads(c["buttons_json"])]
        if any(a.startswith("sugg:") for a in acts):
            per_week[("sugg", wk)] = per_week.get(("sugg", wk), 0) + 1
        if any(a.startswith("ans:") for a in acts):
            per_week[("question", wk)] = per_week.get(("question", wk), 0) + 1
        per_day[to_local(sent, z).date().isoformat()] = per_day.get(to_local(sent, z).date().isoformat(), 0) + 1
        if c["kind"] == "run":
            if c["run_id"] in runs_seen:
                v.append(f"two cards for run {c['run_id']}")
            runs_seen.add(c["run_id"])
        if sum(1 for a in acts if a.startswith("ans:")) and any(a.startswith("sugg:") for a in acts):
            v.append("question and suggestion on one card")
    for (k, wk), n in per_week.items():
        if n > (2 if k == "sugg" else 1):
            v.append(f"{k} cap broken in {wk}: {n}")
    for day, n in per_day.items():
        if n > 3:
            v.append(f"more than 3 messages on {day}: {n}")
    n_touch = {}
    for t in touches:
        n_touch[t["ts"]] = n_touch.get(t["ts"], 0) + 1
    for c in cards:
        if c["body"].count("\n\n") > 2:
            v.append(f"more than one touch plus question on a card: {c['headline']!r}")

    # 4. quiet hours and windows
    for c in cards:
        sent = parse_iso(c["sent_at"])
        z = zone_of(sent)
        loc = to_local(sent, z)
        if in_quiet(sent, z, *QUIET):
            v.append(f"sent in quiet hours at {loc:%a %d %b %H:%M}: {c['headline']!r}")
        mins = loc.hour * 60 + loc.minute
        if c["kind"] == "evening" and not EVENING_START_MIN <= mins < EVENING_END_MIN:
            v.append(f"evening suggestion outside 20:00-21:00 at {loc:%H:%M}")
        if c["kind"] == "recap" and not (loc.weekday() == 6 and 19 * 60 <= mins < 20 * 60):
            v.append(f"recap not Sunday 19:00 at {loc:%a %H:%M}")

    # 5. touch cool-downs and the gap between touches
    prev: tuple[datetime, str] | None = None
    last_kind: dict[str, datetime] = {}
    for t in touches:
        ts = parse_iso(t["ts"])
        kind = t["key"].split("|")[0]
        cd = T.KIND_COOLDOWN.get(kind, 0)
        if kind in last_kind and (ts - last_kind[kind]) < timedelta(days=cd):
            v.append(f"touch {kind} inside its {cd} day cool-down")
        last_kind[kind] = ts
    return v


def transcript(m: Month, cards: list[dict], violations: list[str]) -> str:
    con = sqlite3.connect(m.svc.s.db_path)
    con.row_factory = sqlite3.Row
    meta = {r["card_id"]: dict(r) for r in con.execute("SELECT * FROM convo_cards")}
    out = [
        "# Run Supreme: a simulated month",
        "",
        f"Runner: a 40s runner based in Singapore, training for a half marathon on {RACE_DAY:%-d %b %Y}, "
        "who spends 22 to 30 October in Milos. "
        f"{m.history_n} earlier runs are already on record. The channel is Telegram, quiet hours are 21:30 to 07:00 local, "
        "and the writer is the template fallback (no model), so this is the voice library as the runner would see it "
        "when the model is off or rejected.",
        "",
        "Month contents: easy runs, 8x400, a PB 5K, a heatwave slowdown, a Kastro trail, a missed week and a comeback, "
        "with feel taps and button replies. Times are the runner's local time.",
        "",
        "Rules checked on every message: no repeats inside 30 days, every number comes from the run facts (B4), "
        "at most 2 suggestions and 1 question a week, at most 3 messages a day, one touch per card, no messages in quiet hours.",
        "",
        f"**Violations: {len(violations)}**" + ("" if not violations else "\n" + "\n".join(f"- {x}" for x in violations)),
        "",
    ]
    day = None
    for e in sorted(m.entries, key=lambda e: e.at):
        z = _zone_for_instant(e.at)
        loc = to_local(e.at, z)
        if loc.date() != day:
            day = loc.date()
            out += ["", f"## {loc:%A %-d %B %Y}", ""]
        if e.kind == "tap":
            out.append(f"> _runner taps **{e.text}**_")
            out.append("")
            continue
        c = e.card
        mt = meta.get(c["card_id"], {})
        media = json.loads(mt.get("media_json", "{}"))
        kind = {"run": "post-run card", "evening": "evening-before suggestion", "recap": "Sunday recap"}[c["kind"]]
        out.append(f"**{loc:%H:%M} · {kind}** · situation `{mt.get('situation')}` · source `{c['source']}`")
        out.append("")
        out.append(f"**{c['headline']}**  ")
        for line in c["body"].split("\n"):
            out.append(line + "  " if line else "")
        buttons = json.loads(c["buttons_json"])
        if buttons:
            out.append("")
            out.append("Buttons: " + " ".join(f"`[{b['label']}]`" for b in buttons))
        vid = "VIDEO" if media.get("video") else "no video"
        out.append("")
        out.append(f"_Attach: card `{media.get('card')}`, {vid} (reason: {media.get('reason')})"
                   + (f"; touch `{mt['touch_kind']}`" if mt.get("touch_kind") else "") + "_")
        out.append("")
    return "\n".join(out) + "\n"


def _zone_for_instant(at: datetime) -> str:
    return _zone_on(at.astimezone(ZoneInfo(SG)).date()) if at < _local_hm(MILOS[0], "00:00", SG).astimezone(UTC) - timedelta(hours=12) \
        else _zone_on(at.astimezone(ZoneInfo(GR)).date())


def run_month(workdir: Path | None = None, seed: int = 7) -> SimResult:
    own = workdir is None
    wd = Path(tempfile.mkdtemp(prefix="convo-sim-")) if own else workdir
    try:
        m = Month(wd, seed)
        m.go()
        with db.ro(m.svc.s.db_path) as c:
            cards = [dict(r) for r in c.execute("SELECT * FROM cards WHERE sent_at IS NOT NULL ORDER BY sent_at, rowid")]
        violations = check(cards, _zone_for_instant, m.svc.s.db_path)
        return SimResult(m.entries, cards, violations, transcript(m, cards, violations))
    finally:
        if own:
            shutil.rmtree(wd, ignore_errors=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    r = run_month(seed=a.seed)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(r.transcript)
    print(f"{len(r.cards)} messages, {len(r.violations)} violations -> {a.out}")
    for x in r.violations:
        print("  -", x)


if __name__ == "__main__":
    main()
