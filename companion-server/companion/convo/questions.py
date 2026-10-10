"""The weekly question set: fixed questions, button answers only, at most one a week.

The quota (one per week) lives in the service; this module only says which question is next.
Answers are enumerated values, so they are safe to show the writer (eng-review B4). The first four
keep the original order and wording so existing memory keeps working.
"""
from __future__ import annotations

from datetime import datetime
from typing import Any, Collection, Mapping, Sequence

GOAL_OPTIONS = [("5k", "5 km"), ("10k", "10 km"), ("half", "Half marathon"),
                ("marathon", "Marathon"), ("fitness", "Fitness"), ("other", "Something else")]
DAYS_OPTIONS = [("weekdays", "Weekdays"), ("weekends", "Weekends"), ("both", "Both")]
NIGGLE_OPTIONS = [("none", "None"), ("calf", "Calf"), ("knee", "Knee"), ("hip", "Hip"),
                  ("foot", "Foot"), ("other", "Other")]
RACE_GOALS = {"5k", "10k", "half", "marathon"}

SURFACE_OPTIONS = [("road", "Road"), ("trail", "Trail"), ("track", "Track"), ("treadmill", "Treadmill"),
                   ("mix", "A mix")]
TIME_OPTIONS = [("early", "Early morning"), ("midday", "Midday"), ("evening", "Evening"), ("varies", "Varies")]
PER_WEEK_OPTIONS = [("2", "2"), ("3", "3"), ("4", "4"), ("5", "5 or more")]
WHY_OPTIONS = [("fitness", "Fitness"), ("headspace", "Headspace"), ("race", "A race"),
               ("social", "Company"), ("weight", "Weight")]

# key -> (question text, options). race_month is built from the date.
EXTENDED: dict[str, tuple[str, list[tuple[str, str]]]] = {
    "surface": ("Where do you mostly run?", SURFACE_OPTIONS),
    "time_of_day": ("What time of day suits you?", TIME_OPTIONS),
    "runs_per_week": ("How many runs a week are you aiming for?", PER_WEEK_OPTIONS),
    "run_why": ("What do you run for, mostly?", WHY_OPTIONS),
}
ENUMS: dict[str, set[str]] = {k: {v for v, _ in opts} for k, (_, opts) in EXTENDED.items()}
ORDER = ("goal_type", "race_month", "usual_days", "niggle_area", "runs_per_week", "surface",
         "time_of_day", "run_why")  # 8 questions; race_month only for race goals


def race_month_options(now: datetime) -> list[tuple[str, str]]:
    out, y, m = [], now.year, now.month
    for _ in range(6):
        out.append((f"{y:04d}-{m:02d}", datetime(y, m, 1).strftime("%b %Y")))
        m += 1
        if m == 13:
            y, m = y + 1, 1
    out.append(("none", "No date yet"))
    return out


REASK_DAYS = 28        # a question nobody answered waits this long before it comes round again
INFER_MIN_RUNS = 10    # with this many runs on record, usual days and time of day are known, not asked


def known_without_asking(history: Sequence[Mapping[str, Any]], plan_weeks: int | None) -> set[str]:
    """Questions the server can already answer from what it holds."""
    known: set[str] = set()
    if plan_weeks is not None:
        known.add("race_month")  # the plan countdown already says when the race is
    if len(history) >= INFER_MIN_RUNS:
        known |= {"usual_days", "time_of_day"}
    return known


def next_weekly_question(memory: Mapping[str, str], now: datetime,
                         skip: Collection[str] = ()) -> dict[str, Any] | None:
    """First question in ORDER that is unanswered and not in `skip` (known, or asked in the last 28 days)."""
    for key in ORDER:
        if key in memory or key in skip:
            continue
        if key == "goal_type":
            return {"key": key, "text": "What are you training for?", "options": GOAL_OPTIONS}
        if key == "race_month":
            if memory.get("goal_type") in RACE_GOALS:
                return {"key": key, "text": "Which month is the race?", "options": race_month_options(now)}
            continue
        if key == "usual_days":
            return {"key": key, "text": "When do you usually run?", "options": DAYS_OPTIONS}
        if key == "niggle_area":
            return {"key": key, "text": "Any niggle at the moment?", "options": NIGGLE_OPTIONS}
        text, opts = EXTENDED[key]
        return {"key": key, "text": text, "options": opts}
    return None
