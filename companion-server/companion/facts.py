"""Facts engine: pure functions, no I/O. Picks what is worth saying (or nothing).

The LLM only phrases what this module returns; every number it may use appears in the
fact texts below, which is what the writer's grounding check enforces.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any, Mapping, Sequence

from .convo.questions import ENUMS as _EXTENDED_ENUMS
from .timeutil import UTC, parse_iso, to_local

HARD_TYPES = frozenset({"tempo", "interval", "race"})
FLOOD_SHARE = 0.4  # share of zone time in Z4 and Z5 that makes a run hard
TEMPO_LIGHT_SHARE = 0.15  # a tempo with no feel tap reads light only below this Z4+Z5 share

# The app records one of these (RecordMode). The coach's rules speak easy | long | tempo | interval | race.
APP_TYPES = frozenset({"intervals", "cooper", "laps", "free", "trail"})
LONG_MIN_KM = 12.0
LONG_EASY_MULT = 1.5
LONG_MIN_S = 75 * 60
TEMPO_MIN_S, TEMPO_MAX_S = 20 * 60, 60 * 60
TRAIL_TEMPO_Z45_SHARE = 0.5  # on a trail climbs push HR into Z3-Z4 at an easy effort: tempo needs mostly Z4+Z5


def hard_zone_share(run: Mapping[str, Any]) -> float | None:
    """Share of the zone time spent in Z4 and Z5, or None without zone data. Reads zone_min as the run row stores it."""
    z = _zones(run)
    total = sum(z.values())
    return (z.get(4, 0) + z.get(5, 0)) / total if total else None


def is_steady_trail(run: Mapping[str, Any]) -> bool:
    """An easy-typed trail run with more than half its zone time in Z3 is steady, not easy: the card's label and its
    words both say so."""
    if run.get("app_type") != "trail" or run.get("type") != "easy":
        return False
    z = _zones(run)
    total = sum(z.values())
    return bool(total) and z.get(3, 0) / total > 0.5


ROAD_STEADY_Z3_SHARE = 0.5   # a road run is steady when more than half of it is Z3 ...
ROAD_STEADY_Z45_MAX = 0.15   # ... and under this share is Z4+Z5 (more than that is tempo territory, not steady)


def is_steady_road(run: Mapping[str, Any]) -> bool:
    """An easy-typed road run (a free run) with more than half its zone time in Z3 and under 15% in Z4+Z5 is steady, not
    easy: the same split as the steady trail run, so the card never calls a Z3 run easy."""
    if run.get("app_type") not in (None, "", "free") or run.get("type") != "easy":
        return False
    z = _zones(run)
    total = sum(z.values())
    return bool(total) and z.get(3, 0) / total > ROAD_STEADY_Z3_SHARE and (z.get(4, 0) + z.get(5, 0)) / total < ROAD_STEADY_Z45_MAX


def _zones(run: Mapping[str, Any]) -> dict[int, float]:
    raw = run.get("zone_min")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raw = {}
    z: dict[int, float] = {}
    for k, v in (raw or {}).items():
        digits = "".join(ch for ch in str(k) if ch.isdigit())
        if digits and isinstance(v, (int, float)) and 1 <= int(digits) <= 6:
            z[int(digits)] = z.get(int(digits), 0.0) + float(v)
    return z


def is_hard_run(run: Mapping[str, Any]) -> bool:
    """Whether a run was hard: the one definition the run card, the Next line, the evening suggestion and the default
    coach week all use.

    An interval session or a race/test effort is hard. Otherwise the runner's own feel tap decides first: Easy or Right
    is never hard, whatever the zones say, and Hard on a tempo run is hard. With no tap, any run with 40%+ of its time in
    Z4 and Z5 is hard, and a tempo (the coach's type for mostly Z3-Z4 time) is hard unless Z4+Z5 is under 15%: a real
    threshold run counts, a mostly-Z3 one does not. With no zones and no tap, a tempo falls back to its type."""
    typ, feel = run.get("type"), run.get("feel")
    if typ in ("interval", "race"):
        return True
    if feel in ("easy", "right"):
        return False
    share = hard_zone_share(run)
    if share is not None and share >= FLOOD_SHARE:
        return True
    if typ == "tempo":
        return feel == "hard" or share is None or share >= TEMPO_LIGHT_SHARE
    return False


def infer_coach_type(app_type: str, *, distance_m: float, duration_s: float, zone_min: Mapping[str, float] | None,
                     pb: str | None, history: Sequence[Mapping[str, Any]], has_reps: bool = False,
                     reps_done: int | None = None, work_pace: float | None = None) -> str:
    """The coach's type for a run, from the app's type plus the facts. A type already in the coach's vocabulary
    passes through. `history` is the earlier runs, newest first, carrying the coach types already inferred.

    intervals -> interval (free when no rep was done and no work pace: the workout was stopped early); cooper -> race (a test effort); laps -> interval when it has reps or work/recovery splits
    (`has_reps`; the app does not upload them today, so laps is easy for now), else easy. free / trail -> race when
    PB-flagged, else long (distance >= max(1.5 x the typical easy run, 12 km) or 75+ min), else tempo (free: most time in
    Z3-Z4 over 20-60 min; trail: most time in Z4+Z5, since climbs push an easy effort into Z3), else easy."""
    if app_type not in APP_TYPES:
        return app_type
    if app_type == "intervals" and not reps_done and not work_pace:
        app_type = "free"  # a workout stopped before any work rep: a free run, not an interval session
    if app_type == "intervals":
        return "interval"
    if app_type == "cooper":
        return "race"
    if app_type == "laps":
        return "interval" if has_reps else "easy"
    if pb:
        return "race"
    easy = [h["distance_m"] for h in history[:80] if h.get("type") == "easy" and h.get("distance_m")][:5]
    typical_km = sorted(easy)[len(easy) // 2] / 1000 if easy else 0.0
    if distance_m / 1000 >= max(LONG_EASY_MULT * typical_km, LONG_MIN_KM) or duration_s >= LONG_MIN_S:
        return "long"
    zm = zone_min or {}
    total = sum(zm.values())
    if app_type == "trail":
        # Climbs lift HR into Z3 at an easy effort, and the raw pace is not comparable to road pace, so a trail run
        # is a tempo only when most of it is in Z4+Z5 (a real threshold effort even with the grade).
        if total > 0 and (zm.get("z4", 0) + zm.get("z5", 0)) / total >= TRAIL_TEMPO_Z45_SHARE and TEMPO_MIN_S <= duration_s <= TEMPO_MAX_S:
            return "tempo"
        return "easy"
    if total > 0 and (zm.get("z3", 0) + zm.get("z4", 0)) / total > 0.5 and TEMPO_MIN_S <= duration_s <= TEMPO_MAX_S \
            and (zm.get("z4", 0) + zm.get("z5", 0)) / total >= TEMPO_LIGHT_SHARE:   # mostly Z3 with no real Z4+Z5 is steady, not tempo
        return "tempo"
    return "easy"

# The app's built-in interval sessions (SessionCatalogue names) -> what the session trains. Only these names ever go
# into a fact or the model prompt: a name the runner typed for their own session is free text, so it is stored (to
# compare like with like) but the coach speaks of an "interval session".
SESSION_PURPOSE = {
    "Norwegian 4x4": "VO2 max",
    "30/30s": "speed",
    "1-minute reps": "speed",
    "Pyramid": "VO2 max",
    "Tempo intervals": "threshold",
    "Yasso 800s": "marathon prep",
    "1 km repeats": "5k to 10k pace",
}
_REPS_400_RE = re.compile(r"^\d{1,2} × 400 m$")  # "8 × 400 m": the 400s session names its rep count
# A goal run (one continuous effort at a distance or time, e.g. "10K goal"): the app names it from its own goal, never
# from typed text, so only this shape is accepted (GoalCatalogue.nameFor / Settings.goalName: "5K", "Half", "12.3 km",
# "7.5 mi", "45 min", "1 hour", "1 h 15 min").
_GOAL_NAME = r"(?:\d{1,2}K|Half|Marathon|\d{1,3}\.\d (?:km|mi)|\d{1,2} min|1 hour|\d{1,2} h(?: \d{1,2} min)?) goal"
_GOAL_RE = re.compile(f"^{_GOAL_NAME}$")
GOAL_NAME_IN_TEXT_RE = re.compile(rf"\b{_GOAL_NAME}\b", re.I)  # a goal name inside a headline (writer.clean)
GOAL_PURPOSE = "goal effort"
GENERIC_SESSION = "interval session"
REP_BAND_S = 10  # the app's rep band: reps this close count as "within"


def known_session(name: str | None) -> tuple[str, str] | None:
    """(name, purpose) for a built-in session name, else None."""
    if not name:
        return None
    if name in SESSION_PURPOSE:
        return name, SESSION_PURPOSE[name]
    if _REPS_400_RE.match(name):
        return name, "speed"
    if _GOAL_RE.match(name):
        return name, GOAL_PURPOSE
    return None


def is_goal_run(run: Mapping[str, Any]) -> bool:
    """A goal run: it goes up as a free run, named by its goal ("10K goal")."""
    k = known_session(run.get("session_name"))
    return bool(k) and k[1] == GOAL_PURPOSE


def stopped_early(run: Mapping[str, Any]) -> bool:
    """An interval session the runner started and stopped before the first rep: stored as a free run (infer_coach_type),
    app_type intervals, a built-in session name, no reps and no work pace. Context only: never judged as the session."""
    k = known_session(run.get("session_name"))
    return run.get("app_type") == "intervals" and bool(k) and k[1] != GOAL_PURPOSE \
        and not run.get("reps_done") and not run.get("work_pace_s_per_km")


def named_run(run: Mapping[str, Any]) -> bool:
    """A run whose session the app named and the card must say which: a goal effort."""
    return is_goal_run(run)


def session_label(run: Mapping[str, Any]) -> str:
    """"Norwegian 4x4 (VO2 max session)", or "Interval session" for an unknown or custom name."""
    k = known_session(run.get("session_name"))
    return f"{k[0]} ({k[1]} session)" if k else GENERIC_SESSION.capitalize()


def session_noun(run: Mapping[str, Any]) -> str:
    """How an earlier run of the same session is named in a comparison."""
    k = known_session(run.get("session_name"))
    return k[0] if k else f"similar {GENERIC_SESSION}"


def is_session_run(run: Mapping[str, Any]) -> bool:
    """An interval run whose app sent the work pace: it is judged on that, never on the whole-run average."""
    return run.get("type") == "interval" and bool(run.get("work_pace_s_per_km"))


def spread_text(run: Mapping[str, Any]) -> str:
    sp = run.get("rep_spread_s")
    if sp is None or (run.get("reps_done") or 0) < 2:
        return ""
    sp = round(sp)
    return f", within {sp} s" if sp <= REP_BAND_S else f", spread {sp} s"


TYPE_LABEL = {
    "easy": "easy run", "long": "long run", "tempo": "tempo run",
    "interval": "interval session", "race": "race",
}
APP_TYPE_LABEL = {"trail": "trail run", "cooper": "Cooper test"}  # app types whose own name beats the coach type
TRAIL_SESSION_LABEL = {"easy": "easy trail run", "tempo": "tempo trail run", "long": "long trail run"}


def run_label(run: Mapping[str, Any]) -> str:
    """What the run is called in a fact. A trail run keeps "trail" as the place and names the session the coach knows
    (easy, tempo, long): "tempo trail run". Other app types keep their own name (Cooper test)."""
    app = run.get("app_type") or ""
    if app == "trail":
        if is_steady_trail(run):
            return "steady trail run"
        return TRAIL_SESSION_LABEL.get(run.get("type") or "", "trail run")
    if is_steady_road(run):
        return "steady run"
    return APP_TYPE_LABEL.get(app) or TYPE_LABEL.get(run.get("type"), "run")

VERDICT_TEXT = {  # app wire name (VerdictHeadline.name) -> the verdict copy; noVerdict is silent
    "faster": "faster", "holding": "holding", "slower": "slower", "noRealChange": "no real change",
    "baselineSet": "baseline set", "indoorRun": "indoor run",
}
PB_LABEL = {
    "5k": "5 km best", "10k": "10 km best", "half": "half marathon best",
    "longest": "longest run", "fastest_km": "fastest km",
}
# Verdicts that say "this run has nothing to be compared with". The server's own match (same type, similar distance) is
# looser than the app's, so without this a runner's second run on a new route got "Faster today" off a gap the app refused.
NO_COMPARISON_VERDICTS = {"noVerdict", "baselineSet", "indoorRun"}
LOAD_ALERT = {"high", "very_high"}
LOAD_FRESH_H = 48   # a run's load_state steers the evening suggestion only this long: rest brings the acute load down
SLOW_DAY_S_PER_KM = 10  # a day at least this much slower is called slow, plainly
DELTA_MIN_S_PER_KM = 3
MIN_DURATION_S = 300
MIN_DISTANCE_M = 1000
QUIET_CARD_GAP_H = 18  # without anything notable, stay silent if we sent a card this recently


@dataclass(frozen=True)
class Fact:
    id: str
    text: str


@dataclass(frozen=True)
class Suggestion:
    kind: str
    reason: str
    text: str


@dataclass(frozen=True)
class FactsResult:
    facts: tuple[Fact, ...]
    suggestion: Suggestion | None
    tone: str  # pb | slow | steady
    say_nothing: bool
    reason: str
    session: Mapping[str, str] | None = None  # name + purpose of an interval session, for the model prompt


def fmt_pace(s: float) -> str:
    total = int(round(s))
    return f"{total // 60}:{total % 60:02d}"


def fmt_km(m: float) -> str:
    return f"{m / 1000:.1f}"


def _when(r: Mapping[str, Any]) -> datetime:
    v = r["start_utc"]
    return v if isinstance(v, datetime) else parse_iso(v)


def _metric(r: Mapping[str, Any], use_true: bool) -> float | None:
    if use_true:
        return r.get("true_pace_s_per_km")
    return r.get("pace_s_per_km")


def comparable(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """Most recent prior run of the same type, 0.8x-1.25x the distance, within 60 days, with a pace. An interval run
    with a work pace is matched on the same session name and work pace instead."""
    if not run.get("distance_m"):
        return None
    if run.get("type") == "interval" and not is_session_run(run):
        return None   # an interval run with no reps detected has no work pace: the whole-run average is not a comparison
    t0 = _when(run)
    if is_session_run(run):
        # An interval session is compared on its work pace, against the same session only (whatever the total
        # distance); a run with no work pace on record is not a comparison, and never the whole-run average.
        name = run.get("session_name")
        for h in history:
            if h["type"] == run["type"] and name and h.get("session_name") == name and h.get("work_pace_s_per_km") \
                    and timedelta(0) < t0 - _when(h) <= timedelta(days=60):
                return h
        return None
    for h in history:  # newest first
        if h["type"] != run["type"] or not h.get("distance_m"):
            continue
        if (h.get("app_type") == "trail") != (run.get("app_type") == "trail"):
            continue   # like with like: a trail run is only ever compared with a trail run
        ratio = h["distance_m"] / run["distance_m"]
        if not 0.8 <= ratio <= 1.25:
            continue
        if not timedelta(0) < t0 - _when(h) <= timedelta(days=60):
            continue
        if _metric(h, True) is not None and _metric(run, True) is not None:
            return h
        if _metric(h, False) is not None and _metric(run, False) is not None:
            return h
    return None


def pace_pair(run: Mapping[str, Any], prev: Mapping[str, Any]) -> tuple[float, float]:
    """(this run's pace, the earlier run's) on the basis `comparable` matched on: work pace for an interval session,
    else True Pace when both have it, else pace."""
    if is_session_run(run):
        return run["work_pace_s_per_km"], prev["work_pace_s_per_km"]
    use_true = _metric(prev, True) is not None and _metric(run, True) is not None
    return _metric(run, use_true), _metric(prev, use_true)


def pace_basis(run: Mapping[str, Any], prev: Mapping[str, Any]) -> str:
    """The basis `pace_pair` compares on: work | true | raw."""
    if is_session_run(run):
        return "work"
    return "true" if _metric(prev, True) is not None and _metric(run, True) is not None else "raw"


def verdict_delta(run: Mapping[str, Any], delta: int) -> int | None:
    """The pace gap the card may state, given the app's own verdict (which owns the direction). A directional verdict
    keeps only a gap that points the same way; holding / no real change keeps only a gap too small to be a direction.
    Anything else would put "no real change" over "9 s/km faster"."""
    v = run.get("verdict")
    if v in NO_COMPARISON_VERDICTS:
        return None   # the app said it could not compare this run (baseline, other route, noisy GPS, indoor): no gap either
    if v in ("faster", "slower"):
        want = -1 if v == "faster" else 1
        return delta if delta * want >= DELTA_MIN_S_PER_KM else None
    if v in ("holding", "noRealChange"):
        return delta if abs(delta) < DELTA_MIN_S_PER_KM else None
    return delta


def counts_as_hard(run: Mapping[str, Any]) -> bool:
    """For spacing hard days: a run is hard if the card calls it hard, the runner tapped Hard, whatever its type, or 40%+
    of it was in Z4 and Z5 (a threshold run tapped Right is still a hard day for the legs, though the card never calls
    it hard)."""
    if is_hard_run(run) or run.get("feel") == "hard":
        return True
    share = hard_zone_share(run)
    return share is not None and share >= FLOOD_SHARE


def days_since_hard(history: Sequence[Mapping[str, Any]], now: datetime) -> int | None:
    for h in history:
        if counts_as_hard(h):
            return (now - _when(h)).days
    return None


def _recent_count(history: Sequence[Mapping[str, Any]], now: datetime, days: int) -> int:
    return sum(1 for h in history if timedelta(0) <= now - _when(h) <= timedelta(days=days))


def suggest_after_run(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]]) -> Suggestion | None:
    now = _when(run)
    if run.get("load_state") in LOAD_ALERT:
        return Suggestion("easy_next", "load", "Your recent load is above your usual week. An easy day would fit next; your call.")
    if is_hard_run(run):
        return Suggestion("recover", "hard_today", "That was a hard session, so an easy day next lets it land.")
    gap = days_since_hard(history, now)
    if gap is not None and gap >= 6 and _recent_count(history, now, 14) >= 3:
        return Suggestion("quality", "gap", f"It has been {gap} days since your last hard session, so one this week fits.")
    return None


def _tomorrow_word(local_day: date, usual: frozenset[int] | None) -> str:
    """"tomorrow", or "on Monday" when tomorrow is not one of the runner's usual days (the next usual day instead)."""
    d = local_day + timedelta(days=1)
    if usual is None or d.weekday() in usual:
        return "tomorrow"
    for _ in range(7):
        d += timedelta(days=1)
        if d.weekday() in usual:
            return f"on {d.strftime('%A')}"
    return "tomorrow"


def next_line(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]], *, soften: bool = False,
              usual: frozenset[int] | None = None) -> str:
    """The fixed closing line of a post-run card: what to do next and when. Deterministic, never written by the model.
    The app's plan wins when it names the next session, unless it puts a push tomorrow after a hard run, high load, a
    hard feel or a flagged note (the evening suggestion turns that push easy too). Otherwise those, a long run, a run
    back after a break or a runner's first fortnight mean easy next, and a long gap since the last hard session means
    one is due tomorrow (the same gap the evening suggestion uses). `usual` is the runner's usual weekdays: with it, a
    fallback line never says "tomorrow" for a day they do not run, and a comeback run is never followed by more than
    the comeback run itself."""
    from .convo.suggest import GAP_DAYS, NEW_RUNNER_DAYS, session_parts, whole_km
    from .convo.touches import BREAK_DAYS
    when = _when(run)
    parts = session_parts("easy_load", history, when)
    easy = f"easy {parts[1]} km" if parts else "an easy run"
    ease = soften or run.get("feel") == "hard" or run.get("load_state") in LOAD_ALERT or is_hard_run(run)
    nxt, day = run.get("plan_next_type"), run.get("plan_next_day")
    local = to_local(when, run.get("zone_id") or "UTC")
    tmrw = _tomorrow_word(local.date(), usual)
    if nxt in ("easy", "long", "quality") and day:
        word = {"easy": "easy", "long": "long run", "quality": "quality session"}[nxt]
        if nxt != "easy" and run.get("plan_next_session_name"):
            word = run["plan_next_session_name"]   # the session's own name where the plan has one
        km = (f" {int(run['plan_next_m']) // 1000} km" if run["plan_next_m"] % 1000 == 0 else f" {fmt_km(run['plan_next_m'])} km") if run.get("plan_next_m") else ""
        lo, hi = run.get("plan_next_pace_lo"), run.get("plan_next_pace_hi")
        if nxt == "quality" and lo and hi:   # every card shows the work pace where there is one, and says it is True Pace
            km += f" at {fmt_pace(lo)}-{fmt_pace(hi)}/km true pace"
        try:
            gap = (datetime.fromisoformat(day).date() - local.date()).days
        except ValueError:
            gap = None
        stale = gap is not None and gap < 0          # a plan day already gone says nothing about what is next
        blocked = ease and nxt != "easy" and (gap is None or gap <= 1)
        if not stale and not blocked:
            if gap == 1:
                return f"Next: {word}{km} tomorrow"
            if gap is not None and gap > 1:
                return f"Next: {word}{km} on {datetime.fromisoformat(day).strftime('%A')}"
            return f"Next: {word}{km} as planned"
    if ease or run.get("type") == "long":
        return f"Next: {easy} {tmrw}"
    if history and (when - _when(history[0])).days >= BREAK_DAYS:
        # back after a break: build back before any push, and never further than the run just done
        if parts and run.get("distance_m"):
            easy = f"easy {min(int(parts[1]), whole_km(run['distance_m']))} km"
        return f"Next: {easy} {tmrw}"
    if history and len(history) < 60 and when - _when(history[-1]) < timedelta(days=NEW_RUNNER_DAYS):
        return f"Next: {easy} {tmrw}"   # first fortnight: no push yet, as the evening suggestion
    gap = days_since_hard(history, when)
    if gap is not None and gap >= GAP_DAYS:
        q = session_parts("gap", history, when)
        if q:
            return f"Next: {q[0]} {q[1]} km {tmrw}"
        return f"Next: one harder session {tmrw}"
    return f"Next: {easy} {tmrw}"


def suggest_evening(history: Sequence[Mapping[str, Any]], now: datetime) -> Suggestion | None:
    """The evening-before suggestion (Telegram only). Needs a reason from the rules."""
    if not history:
        return None
    last = history[0]
    if _recent_count(history, now, 14) < 3:
        return None
    if last.get("load_state") in LOAD_ALERT and (now - _when(last)) <= timedelta(hours=LOAD_FRESH_H):
        return Suggestion("easy_next", "load", "Your recent load is above your usual week. An easy day or a rest day tomorrow would fit; your call.")
    if is_hard_run(last) and (now - _when(last)) <= timedelta(hours=40):
        return Suggestion("recover", "hard_recent", "Your last run was a hard one, so keep tomorrow easy.")
    gap = days_since_hard(history, now)
    if gap is not None and gap >= 5:
        return Suggestion("quality", "gap", f"It has been {gap} days since your last hard session, so tomorrow suits one.")
    return None


def build_facts(run: Mapping[str, Any], history: Sequence[Mapping[str, Any]],
                memory: Mapping[str, str], *, last_card_age_h: float | None = None) -> FactsResult:
    """`history` is the user's prior runs, newest first, excluding `run`."""
    dist, dur = run.get("distance_m") or 0, run.get("duration_s") or 0
    if dur < MIN_DURATION_S or dist < MIN_DISTANCE_M:
        return FactsResult((), None, "steady", True, "junk")

    label = run_label(run)
    pace = run.get("pace_s_per_km")
    prev = comparable(run, history)
    true_basis = prev is not None and not is_session_run(run) and pace_basis(run, prev) == "true"
    session_run = is_session_run(run)
    if session_run:
        # Name the session and its purpose and give its work pace; the whole-run pace (recoveries included) is left out.
        reps = run.get("reps_done")
        base_txt = f"{session_label(run)}: " + (f"{reps} reps at " if reps else "") + \
            f"{fmt_pace(run['work_pace_s_per_km'])}/km work pace{spread_text(run)}"
    else:
        named = run.get("session_name") and known_session(run.get("session_name"))
        if is_goal_run(run):
            # The headline names the goal and says whether it was reached; the whole-run pace is a plain fact of the run.
            reached = {1: ", goal reached", 0: ", goal not reached"}.get(run.get("goal_reached"), "")
            head = f"{named[0]} run"
        else:
            head, reached = label.capitalize(), ""
        base_txt = f"{head}: {fmt_km(dist)} km in {round(dur / 60)} min"
        if pace and not true_basis:  # a true-pace comparison below must not sit beside the raw pace
            base_txt += f" at {fmt_pace(pace)}/km"
        base_txt += reached
    base = Fact("base", base_txt)

    worthy: list[Fact] = []
    tone = "steady"

    verdict = VERDICT_TEXT.get(run.get("verdict") or "")
    if verdict:
        worthy.append(Fact("verdict", f"Verdict: {verdict}"))  # the app's own wording, never reworded

    if run.get("pb") in PB_LABEL:
        worthy.append(Fact("pb", f"New personal best: {PB_LABEL[run['pb']]}"))
        tone = "pb"

    if prev is not None:
        now_p, prev_p = pace_pair(run, prev)
        delta = round(now_p - prev_p)
        if session_run:
            what, unit = f"your last {session_noun(run)}", f"{fmt_pace(prev_p)}/km work pace"
        else:
            what, unit = f"your last similar {label}", f"{fmt_pace(prev_p)}/km"
            if true_basis:  # one basis, said out loud: both paces are True Pace
                unit = f"on true pace, {fmt_pace(now_p)}/km now and {fmt_pace(prev_p)}/km then"
        shown = verdict_delta(run, delta)
        if shown is not None:
            if abs(shown) >= DELTA_MIN_S_PER_KM:
                word = "slower" if shown > 0 else "faster"
                worthy.append(Fact("delta", f"{abs(shown)} s/km {word} than {what} ({unit})"))
                if shown >= SLOW_DAY_S_PER_KM and tone != "pb":
                    tone = "slow"
            else:
                worthy.append(Fact("delta", f"Level with {what} ({unit})"))

    if run.get("load_state") in LOAD_ALERT:
        worthy.append(Fact("load", "This week's load is " + ("well above" if run["load_state"] == "very_high" else "above") + " your usual week"))

    pk = run.get("plan_kind")
    if pk:
        txt = f"Plan day: {pk}"
        if run.get("plan_target_m"):
            txt += f", {fmt_km(run['plan_target_m'])} km planned, {fmt_km(dist)} km run"
        if run.get("plan_weeks_to_race") is not None:
            txt += f", {run['plan_weeks_to_race']} weeks to race"
        if run.get("plan_week") and run.get("plan_weeks") and run["plan_week"] <= run["plan_weeks"]:
            txt += f", week {run['plan_week']} of {run['plan_weeks']} of the plan"
        worthy.append(Fact("plan", txt))

    if not worthy and last_card_age_h is not None and last_card_age_h < QUIET_CARD_GAP_H:
        return FactsResult((), None, tone, True, "nothing_new")

    picked = worthy[:3]
    if session_run:
        picked = [base, *worthy[:2]]  # the model must always be told which session this was
        if run.get("recovery_pace_s_per_km") and len(picked) < 3:
            picked.append(Fact("recovery", f"Recovery pace {fmt_pace(run['recovery_pace_s_per_km'])}/km"))
    elif len(picked) < 2 or named_run(run):
        picked = [base, *[f for f in picked if f is not base]][:3]
    if stopped_early(run):   # plain context, no work-pace judgement and no session headline
        picked = [base, Fact("session", f"Started {run['session_name']}, stopped before the first rep"),
                  *[f for f in picked if f is not base]][:3]
    if run.get("feel") and len(picked) < 3:
        picked.append(Fact("feel", f"You rated it {run['feel']}"))

    session = None
    if session_run:
        k = known_session(run.get("session_name"))
        session = {"name": k[0], "purpose": k[1]} if k else {"purpose": GENERIC_SESSION}
    elif is_goal_run(run):
        k = known_session(run["session_name"])
        session = {"name": k[0], "purpose": k[1]}
    return FactsResult(tuple(picked), suggest_after_run(run, history), tone, False, "ok", session)


# --- the weekly learning question -------------------------------------------------------

GOAL_OPTIONS = [("5k", "5 km"), ("10k", "10 km"), ("half", "Half marathon"),
                ("marathon", "Marathon"), ("fitness", "Fitness"), ("other", "Something else")]
DAYS_OPTIONS = [("weekdays", "Weekdays"), ("weekends", "Weekends"), ("both", "Both")]
NIGGLE_OPTIONS = [("none", "None"), ("calf", "Calf"), ("knee", "Knee"), ("hip", "Hip"),
                  ("foot", "Foot"), ("other", "Other")]
RACE_GOALS = {"5k", "10k", "half", "marathon"}
NIGGLE_TTL_DAYS = 56  # health-adjacent: expires after 8 weeks (eng-review C6)
MEMORY_ENUMS = {
    "goal_type": {v for v, _ in GOAL_OPTIONS},
    "usual_days": {v for v, _ in DAYS_OPTIONS},
    "niggle_area": {v for v, _ in NIGGLE_OPTIONS},
    **_EXTENDED_ENUMS,  # the rest of the weekly question set (convo/questions.py)
}


def race_month_options(now: datetime) -> list[tuple[str, str]]:
    out, y, m = [], now.year, now.month
    for _ in range(6):
        out.append((f"{y:04d}-{m:02d}", datetime(y, m, 1).strftime("%b %Y")))
        m += 1
        if m == 13:
            y, m = y + 1, 1
    out.append(("none", "No date yet"))
    return out


def valid_answer(key: str, value: str) -> bool:
    if key == "race_month":
        return value == "none" or (len(value) == 7 and value[4] == "-" and value[:4].isdigit()
                                   and value[5:].isdigit() and 1 <= int(value[5:]) <= 12)
    return value in MEMORY_ENUMS.get(key, ())


def next_question(memory: Mapping[str, str], now: datetime) -> dict[str, Any] | None:
    """First unanswered fixed question: goal, race month (race goals only), usual days, niggle area."""
    if "goal_type" not in memory:
        return {"key": "goal_type", "text": "What are you training for?", "options": GOAL_OPTIONS}
    if memory["goal_type"] in RACE_GOALS and "race_month" not in memory:
        return {"key": "race_month", "text": "Which month is the race?", "options": race_month_options(now)}
    if "usual_days" not in memory:
        return {"key": "usual_days", "text": "When do you usually run?", "options": DAYS_OPTIONS}
    if "niggle_area" not in memory:
        return {"key": "niggle_area", "text": "Any niggle at the moment?", "options": NIGGLE_OPTIONS}
    return None


def tomorrow_is_usual_day(usual: str | None, tomorrow_weekday: int) -> bool:
    """weekday(): Mon=0. Unknown preference means any day is fine."""
    if usual == "weekdays":
        return tomorrow_weekday < 5
    if usual == "weekends":
        return tomorrow_weekday >= 5
    return True
