"""Personal touches: one short, true line a card may carry.

Every touch is computed from the runner's own data (the facts layer); the text comes from
`voice.TOUCHES` with the numbers passed as slots. A policy decides which one, if any, goes on a
card: at most one per card, a per-kind and per-key cool-down, and a rotation so the same kind does
not come round twice in a row.
"""
from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Callable, Mapping, Sequence

from ..facts import fmt_km, fmt_pace
from ..timeutil import parse_iso, to_local
from . import voice

MILESTONE_RUNS = (10, 25, 50, 100, 150, 200, 250, 300, 400, 500, 750, 1000)
MILESTONE_KM = (100, 250, 500, 1000, 1500, 2000, 2500, 3000, 4000, 5000)
STREAK_AT = (3, 4, 6, 8, 10, 12, 16, 20, 26, 52)
DEFAULT_WEEKLY_TARGET = 2
BREAK_DAYS = 10  # a gap this long is a break; the third run back after one is a comeback
PLACE_AT = (3, 4, 5, 25, 75)  # plus every 10th: a regular spot is not news every time

# Days before the same kind may appear again. 0 = no kind cool-down.
KIND_COOLDOWN = {
    "milestone_runs": 0, "milestone_km": 0, "new_place": 0, "comeback": 0, "feel_echo": 0,
    "race_countdown": 6, "race_month": 13, "plan_week": 6, "last_year": 27, "place": 4, "streak": 9,
    "best_month": 13, "year_best": 20, "sunrise": 13, "zone2_week": 6,
}
# Kinds whose key may fire only once, ever. Others: the key repeats after KEY_COOLDOWN_DAYS.
ONCE_PER_KEY = {"milestone_runs", "milestone_km", "new_place", "comeback", "streak", "best_month", "feel_echo"}
KEY_COOLDOWN_DAYS = {"place": 14, "year_best": 40, "last_year": 27}
# These matter enough to skip the "not two cards in a row" gap.
BYPASS_GAP = {"milestone_runs", "milestone_km", "new_place", "comeback", "feel_echo"}
# Tried in this order; the first one that passes the policy wins.
PRIORITY = ("milestone_runs", "milestone_km", "new_place", "comeback", "feel_echo", "best_month", "year_best",
            "last_year", "race_countdown", "race_month", "plan_week", "place", "streak", "sunrise", "zone2_week")
PUSHY = frozenset({"streak", "race_countdown", "race_month", "plan_week"})  # dropped while softening
ROTATE_AVOID = 2  # do not reuse either of the last two touch kinds while another candidate exists


@dataclass(frozen=True)
class Touch:
    kind: str
    key: str
    slots: dict[str, str]


@dataclass
class Usage:
    """What the policy needs from the convo log."""
    variants: dict[str, datetime] = field(default_factory=dict)        # variant_id -> last used
    touches: list[tuple[datetime, str, str]] = field(default_factory=list)  # (ts, kind, key), oldest first
    cards_since_touch: int = 99
    feel_refs: set = field(default_factory=set)  # runs whose Hard tap an evening suggestion already answered


@dataclass
class Ctx:
    run: Mapping[str, Any]
    history: Sequence[Mapping[str, Any]]  # prior runs, newest first, the whole record
    memory: Mapping[str, str]
    now: datetime
    sunrise_local: datetime | None = None  # sunrise at the run's place on the run's day, if known
    sunrise_count: int = 0                 # sunrise runs already logged (excluding this one)
    prev_situation: str | None = None      # the situation of the previous run's card, if it had one
    feel_refs: frozenset = frozenset()     # runs whose feel tap has already been answered
    soften: bool = False                   # a recent run note was flagged (companion.notes): no push-style touches

    @property
    def zone(self) -> str:
        return self.run.get("zone_id") or "UTC"

    def when(self, r: Mapping[str, Any]) -> datetime:
        v = r["start_utc"]
        return v if isinstance(v, datetime) else parse_iso(v)

    def local(self, r: Mapping[str, Any]) -> datetime:
        return to_local(self.when(r), r.get("zone_id") or self.zone)


WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def ordinal(n: int) -> str:
    suffix = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def _pace(r: Mapping[str, Any]) -> float | None:
    return r.get("true_pace_s_per_km") or r.get("pace_s_per_km")


def _week(local: datetime) -> tuple[int, int]:
    y, w, _ = local.isocalendar()
    return y, w


def _zone_minutes(r: Mapping[str, Any]) -> dict[int, float]:
    """zone number -> minutes, from {"z2": 12.5} / {"Z2": ..} / {"2": ..} keys."""
    raw = r.get("zone_min")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raw = {}
    out: dict[int, float] = {}
    for k, v in (raw or {}).items():
        digits = "".join(ch for ch in str(k) if ch.isdigit())
        if digits and isinstance(v, (int, float)) and 1 <= int(digits) <= 6:
            out[int(digits)] = out.get(int(digits), 0.0) + float(v)
    return out


def hard_share(r: Mapping[str, Any]) -> float | None:
    z = _zone_minutes(r)
    total = sum(z.values())
    return (z.get(4, 0) + z.get(5, 0)) / total if total else None


def calendar_days(first: datetime, last: datetime, zone_id: str | None) -> int:
    """Calendar days from the first run's local date to the last one's, both counted: 9 Nov to 12 Nov is 4."""
    return (to_local(last, zone_id).date() - to_local(first, zone_id).date()).days + 1


def hard_minutes(r: Mapping[str, Any]) -> int:
    z = _zone_minutes(r)
    return round(z.get(4, 0) + z.get(5, 0))


# --- the touches ----------------------------------------------------------------------------

def milestone_runs(c: Ctx) -> Touch | None:
    n = len(c.history) + 1
    return Touch("milestone_runs", f"runs:{n}", {"n": str(n)}) if n in MILESTONE_RUNS else None


def milestone_km(c: Ctx) -> Touch | None:
    before = sum(h.get("distance_m") or 0 for h in c.history) / 1000
    after = before + (c.run.get("distance_m") or 0) / 1000
    crossed = [t for t in MILESTONE_KM if before < t <= after]
    return Touch("milestone_km", f"km:{crossed[-1]}", {"total_km": str(crossed[-1])}) if crossed else None


def new_place(c: Ctx) -> Touch | None:
    loc = c.run.get("locality")
    if not loc or len(c.history) < 5:
        return None
    if any(h.get("locality") == loc for h in c.history):
        return None
    zones = Counter(h.get("zone_id") for h in c.history)
    if c.run.get("zone_id") == zones.most_common(1)[0][0]:
        return None  # a new suburb at home is not "a new city"
    return Touch("new_place", f"place:{loc}", {"place": loc})


def returning(c: Ctx) -> bool:
    """True while the runner is inside the first 14 days back from a break (10+ days without a run)."""
    runs = [c.run, *c.history]
    for i in range(len(runs) - 1):
        if (c.when(runs[i]) - c.when(runs[i + 1])).days >= BREAK_DAYS:
            return (c.when(c.run) - c.when(runs[i])).days <= 14
    return False


def comeback(c: Ctx) -> Touch | None:
    """The third run back after a break (10+ days), inside 14 days of coming back."""
    runs = [c.run, *c.history]  # newest first
    for i in range(len(runs) - 1):
        gap = (c.when(runs[i]) - c.when(runs[i + 1])).days
        if gap >= BREAK_DAYS:
            n = i + 1  # runs since (and including) the first one back
            if n != 3:
                return None
            days = calendar_days(c.when(runs[i]), c.when(c.run), c.zone)
            if days > 14:
                return None
            return Touch("comeback", f"comeback:{c.local(runs[i]).date().isoformat()}",
                         {"n": str(n), "days_txt": plural(days, "day")})
    return None


def feel_echo(c: Ctx) -> Touch | None:
    """The runner tapped Hard on an easy run at an easy effort. Say so on the next card."""
    if not c.history:
        return None
    prev = c.history[0]
    if prev["run_id"] in c.feel_refs or prev.get("feel") != "hard" or prev["type"] != "easy" or (c.when(c.run) - c.when(prev)).days > 4:
        return None
    share = hard_share(prev)
    if share is not None and share >= 0.15:
        return None  # it really was hard
    cause = {"slower_heat": "Heat.", "slower_load": "Load is high.", "slower_hills": "Hills."}.get(
        c.prev_situation or "", "Worth watching.")
    return Touch("feel_echo", f"feel:{prev['run_id']}", {"weekday": WEEKDAYS[c.local(prev).weekday()], "cause": cause})


def best_month(c: Ctx) -> Touch | None:
    me = c.local(c.run)
    ym = (me.year, me.month)
    totals: Counter = Counter()
    for h in c.history:
        d = c.local(h)
        totals[(d.year, d.month)] += (h.get("distance_m") or 0) / 1000
    prior_months = [t for k, t in totals.items() if k != ym]
    if len(prior_months) < 2:
        return None
    before = totals.get(ym, 0.0)
    after = before + (c.run.get("distance_m") or 0) / 1000
    best_before = max(prior_months)
    if before <= best_before < after:  # this run is the one that crosses it
        return Touch("best_month", f"best_month:{ym[0]}-{ym[1]:02d}", {"month_km": f"{after:.0f}"})
    return None


def year_best(c: Ctx) -> Touch | None:
    d = c.run.get("distance_m") or 0
    if not d or c.run.get("pb") or c.run.get("work_pace_s_per_km"):  # an interval run's whole-run pace is no yardstick
        return None
    # one basis, said out loud: True Pace when the run has one (and then only runs with one are compared), else the average
    key = "true_pace_s_per_km" if c.run.get("true_pace_s_per_km") else "pace_s_per_km"
    p = c.run.get(key)
    if p is None:
        return None
    year = c.local(c.run).year
    same = [h for h in c.history
            if h.get("distance_m") and 0.8 <= h["distance_m"] / d <= 1.25 and h.get(key) is not None
            and c.local(h).year == year]
    if len(same) < 4 or p >= min(h[key] for h in same):
        return None
    basis = " true pace" if key == "true_pace_s_per_km" else ""
    return Touch("year_best", f"year_best:{round(d / 1000)}", {"pace": fmt_pace(p), "cnt": str(len(same) + 1), "basis": basis})


def last_year(c: Ctx) -> Touch | None:
    d, p = c.run.get("distance_m") or 0, _pace(c.run)
    if not d or p is None or c.run.get("work_pace_s_per_km"):
        return None
    t0 = c.when(c.run)
    best = None
    for h in c.history:
        gap = abs((t0 - c.when(h)).days - 365)
        if gap <= 3 and h["type"] == c.run["type"] and h.get("distance_m") and 0.7 <= h["distance_m"] / d <= 1.4 and _pace(h) is not None:
            if best is None or gap < best[0]:
                best = (gap, h)
    if best is None:
        return None
    h = best[1]
    slots = {"pace": fmt_pace(p), "ly_pace": fmt_pace(_pace(h)), "ly_km": fmt_km(h["distance_m"])}
    diff = round(_pace(h) - p)
    if abs(diff) >= 3:
        slots.update(ly_cmp_s=str(abs(diff)), ly_dir="faster" if diff > 0 else "slower")
    return Touch("last_year", f"last_year:{c.local(h).date().isoformat()}", slots)


def race(c: Ctx) -> Touch | None:
    w = c.run.get("plan_weeks_to_race")
    if w is not None and 0 < w <= 20:
        return Touch("race_countdown", f"race:{w}", {"weeks_txt": plural(w, "week")})
    rm = c.memory.get("race_month")
    if rm and rm != "none" and w is None:
        y, m = int(rm[:4]), int(rm[5:])
        me = c.local(c.run)
        months = (y - me.year) * 12 + (m - me.month)
        if 1 <= months <= 8:
            return Touch("race_month", f"race_month:{months}", {"months_txt": plural(months, "month")})
    return None


def plan_week(c: Ctx) -> Touch | None:
    """Where the run sits in the app's plan ('week 3 of 4 of your plan'). The week comes from the app, never a guess;
    the key is the week, so it can say each week once at most."""
    wk, wks = c.run.get("plan_week"), c.run.get("plan_weeks")
    if not wk or not wks or wk > wks:
        return None
    return Touch("plan_week", f"planwk:{wk}", {"why": f"week {wk} of {wks} of your plan"})


def place(c: Ctx) -> Touch | None:
    loc = c.run.get("locality")
    if not loc:
        return None
    prior = [h for h in c.history if h.get("locality") == loc]
    n = len(prior) + 1
    if n not in PLACE_AT and n % 10:
        return None
    slots = {"ord": ordinal(n), "place": loc}
    paces = [_pace(h) for h in prior if _pace(h) is not None and not h.get("work_pace_s_per_km")]
    if len(paces) >= 2 and not c.run.get("work_pace_s_per_km"):
        slots["place_pace"] = fmt_pace(sum(paces) / len(paces))
    return Touch("place", f"place:{loc}", slots)


def weekly_target(memory: Mapping[str, str]) -> int:
    v = memory.get("runs_per_week", "")
    return int(v) if v.isdigit() else DEFAULT_WEEKLY_TARGET


def streak_weeks(c: Ctx) -> int:
    """Consecutive local ISO weeks, ending with the current one, that reached the weekly target."""
    target = weekly_target(c.memory)
    counts: Counter = Counter()
    for r in [c.run, *c.history]:
        counts[_week(c.local(r))] += 1
    cur = c.local(c.run)
    day, n = cur, 0
    while counts.get(_week(day), 0) >= target:
        n += 1
        day -= timedelta(days=7)
    return n


def streak(c: Ctx) -> Touch | None:
    target = weekly_target(c.memory)
    me = _week(c.local(c.run))
    this_week = 1 + sum(1 for h in c.history if _week(c.local(h)) == me)
    if this_week != target:  # fire on the run that completes the week, not every run after
        return None
    s = streak_weeks(c)
    return Touch("streak", f"streak:{s}", {"streak": str(s)}) if s in STREAK_AT else None


def is_sunrise_start(start_local: datetime, sunrise_local: datetime | None) -> bool:
    """A start from 45 minutes before to 20 minutes after sunrise counts as a sunrise run."""
    return sunrise_local is not None and -45 <= (start_local - sunrise_local).total_seconds() / 60 <= 20


def sunrise(c: Ctx) -> Touch | None:
    if not is_sunrise_start(c.local(c.run), c.sunrise_local):
        return None
    n = c.sunrise_count + 1
    return Touch("sunrise", f"sunrise:{n}", {"n": str(n)}) if n >= 2 else None


def zone2_week(c: Ctx) -> Touch | None:
    me = c.local(c.run)
    wk = _week(me)
    total = _zone_minutes(c.run).get(2, 0.0)
    for h in c.history:
        if _week(c.local(h)) == wk:
            total += _zone_minutes(h).get(2, 0.0)
    if total < 60:
        return None
    return Touch("zone2_week", f"zone2:{wk[0]}-{wk[1]}", {"z2_min": str(round(total)), "zname": "zone 2"})


COMPUTE: dict[str, Callable[[Ctx], Touch | None]] = {
    "milestone_runs": milestone_runs, "milestone_km": milestone_km, "new_place": new_place,
    "comeback": comeback, "feel_echo": feel_echo, "best_month": best_month, "year_best": year_best, "last_year": last_year,
    "race_countdown": race, "race_month": race, "plan_week": plan_week, "place": place, "streak": streak, "sunrise": sunrise,
    "zone2_week": zone2_week,
}


def candidates(c: Ctx) -> list[Touch]:
    out, seen = [], set()
    for kind in PRIORITY:
        if c.soften and kind in PUSHY:
            continue
        t = COMPUTE[kind](c)
        if t and t.kind == kind and (t.kind, t.key) not in seen:
            seen.add((t.kind, t.key))
            out.append(t)
    return out


def allowed(t: Touch, u: Usage, now: datetime) -> bool:
    """Cool-down and gap policy for one candidate."""
    if t.kind not in BYPASS_GAP and u.cards_since_touch < 1:
        return False  # never on two cards in a row
    for ts, kind, key in u.touches:
        if kind == t.kind and (now - ts) < timedelta(days=KIND_COOLDOWN.get(t.kind, 0)):
            return False
        if kind == t.kind and key == t.key:
            if t.kind in ONCE_PER_KEY:
                return False
            if (now - ts) < timedelta(days=KEY_COOLDOWN_DAYS.get(t.kind, 30)):
                return False
    return True


def choose(c: Ctx, u: Usage) -> Touch | None:
    ok = [t for t in candidates(c) if allowed(t, u, c.now)]
    if not ok:
        return None
    recent = {k for _, k, _ in u.touches[-ROTATE_AVOID:]}
    fresh = [t for t in ok if t.kind not in recent]
    return (fresh or ok)[0]


def render(t: Touch, u: Usage, now: datetime, seed: str) -> tuple[str, str, str] | None:
    """-> (variant_id, text, allowed numbers source)."""
    return voice.render_touch(t.kind, t.slots, u.variants, now, seed)
