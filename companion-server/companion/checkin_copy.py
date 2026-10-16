"""Every word of a check-in, as fixed templates. Nothing here is ever written or rephrased by a model (eng-review A2):
the lines that use a runner's answers (including sore and ill) are built here and appended after the writer has finished.

`render` is a pure function of the slot and its stage, so an edit can be re-built from the database at any time
(a 429 retry, a "message is not modified" check, a fresh message after the old one was deleted) and the text never has
to be stored. Plain, casual, no em dashes.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Sequence

Button = tuple[str, str]       # (label, callback code from checkins.CODES)
Keyboard = list[list[Button]]

WORD = {"easy": "Easy run", "long": "Long run", "quality": "Quality session"}


@dataclass(frozen=True)
class Ctx:
    """What a check-in message is about. `label` is the planned session ("Quality session, 6 km")."""
    label: str | None = None
    when: str | None = None            # "around 7:00"
    moved_to: date | None = None
    easier: bool = False
    original_word: str | None = None   # what the plan had, when "flat" made it easy
    heat_s_km: int | None = None       # extra s/km on an easy pace in today's forecast heat; the morning card only
    work_pace_s: float | None = None   # the planned quality session's work pace (True Pace s/km); the morning card only


def session_label(typ: str, minutes: int | None, distance_m: int | None, name: str | None = None) -> str:
    """"Quality session, 6 km", or with the session's own name when the coach knows it: "Norwegian 4x4, 6 km"."""
    word = name or WORD.get(typ, "Run")
    if distance_m:
        return f"{word}, {max(1, int(distance_m / 1000 + 0.5))} km"   # half up: a 4.5 km plan is "5 km", never banker's "4"
    if minutes:
        return f"{word}, {minutes} min"
    return word


def day_label(d: date) -> str:
    return f"{d:%a} {d.day}"


def _kb(*rows: Sequence[Button]) -> Keyboard:
    return [list(r) for r in rows]


def ready(stage: str | None, c: Ctx) -> tuple[str, str, Keyboard]:
    label = c.label or "Tomorrow's run"
    if stage is None:
        return (f"{label} tomorrow", "How's the body?",
                _kb([("Fresh", "r.fresh"), ("Normal", "r.normal"), ("Flat", "r.flat")],
                    [("Sore somewhere", "r.sore"), ("Not tomorrow", "r.not")]))
    again = _kb([("Change", "r.chg")])
    if stage in ("fresh", "normal"):
        return ("Locked in", f"{label}{', ' + c.when if c.when else ''}. See you then.", again)
    if stage == "flat":
        was = f" instead of the {c.original_word.lower()}" if c.original_word else ""
        return ("Easy it is", f"Flat legs, so tomorrow is an easy run{was}. Keep it conversational.", again)
    if stage == "sore":
        move = f" {label} moves to {day_label(c.moved_to)}." if c.moved_to else ""
        return ("Rest tomorrow", "Sore somewhere, so tomorrow is off and the next few days stay light."
                f"{move} If it's still there after that, get it looked at.", again)
    move = f"{label} moves to {day_label(c.moved_to)}." if c.moved_to else "Tomorrow is off."
    return ("Moved", move, again)


def pace_clause(s_km: float | None) -> str:
    """" · 4:48/km work pace", or nothing when the app sent no pace."""
    if not s_km:
        return ""
    s = round(s_km)
    return f" · {s // 60}:{s % 60:02d}/km work pace"


def heat_line(s_km: int | None) -> str:
    return f"\nHot one: about +{s_km} s/km on easy pace." if s_km else ""


def today(stage: str | None, c: Ctx, why: str | None = None) -> tuple[str, str, Keyboard]:
    label = c.label or "Today's run"
    if stage is None:
        when = f"Planned for {c.when}." if c.when else "It's on the plan for today."
        return (f"Today: {label}{pace_clause(c.work_pace_s)}", f"{when} Run it, move it or skip it?{heat_line(c.heat_s_km)}",
                _kb([("Run", "t.go"), ("Move", "t.move"), ("Skip", "t.skip")]))
    change = _kb([("Change", "u.undo")])
    if stage == "going":
        return ("Go well", f"{label} is on. Tell me how it went after.", change)
    if stage == "later":   # a retired button; an old message can still carry it
        return ("Later it is", "No rush. It's still on for today.", change)
    if stage == "short":   # the Busy card's "Run 20 min" button
        move = f"{label} moves to {day_label(c.moved_to)}." if c.moved_to else "The planned run waits a day."
        return ("Go well", f"20 easy minutes today. {move} Tell me how it went after.", change)
    if stage == "move":
        move = f"{label} moves to {day_label(c.moved_to)}." if c.moved_to else "The run waits a day."
        return ("Move it", f"A walk, some strength or mobility today counts. {move}", change)
    if why is None:   # skip, reason not given yet
        return ("No problem", "What's up? It changes what I suggest next.",
                _kb([("Tired", "w.tired"), ("Sore", "w.sore"), ("Ill", "w.ill")], [("Busy", "w.busy"), ("Weather", "w.weather")]))
    undo = _kb([("Undo", "u.undo")])
    move = f"{label} moves to {day_label(c.moved_to)}." if c.moved_to else "Today's session is off."
    if why == "ill":
        return ("Rest up", f"{move} I'll keep things light for a week. If you're still unwell after that, see a doctor.",
                undo)
    if why == "sore":
        return ("Moved", f"{move} I'll keep the next 3 days light. If it's still sore after that, get it looked at.", undo)
    if why == "busy":
        return ("Short on time", f"Do 20 easy minutes today instead. {move}",
                _kb([("Run 20 min", "t.short")], [("Undo", "u.undo")]))
    if why == "weather":
        return ("Moved", f"{move} Nothing lost, the weather can wait.", undo)
    return ("Moved", f"{move} I'll keep the next 3 days light.", undo)


def postrun(stage: str | None, c: Ctx) -> tuple[str, str, Keyboard]:
    if stage is None:
        return ("Anything behind that one?", "It ran slower and harder than an easy run usually does.",
                _kb([("Short sleep", "p.sleep"), ("Stressed", "p.stress")], [("Heat", "p.heat"), ("Nothing", "p.none")]))
    if stage in ("sleep", "stress"):
        return ("Noted", "I'll keep the next couple of days easy.", [])
    if stage == "heat":
        return ("Noted", "Heat does that. No change to the plan.", [])
    return ("Okay", "No change then.", [])


def shape(stage: str | None, c: Ctx) -> tuple[str, str, Keyboard]:
    if stage is None:
        return ("Next week", "How many runs are you up for?",
                _kb([("3", "s.3"), ("4", "s.4"), ("5", "s.5"), ("Away", "s.away")]))
    again = _kb([("Change", "s.chg")])
    if stage == "away":
        back = f" Back on {day_label(c.moved_to)}." if c.moved_to else ""
        return ("Away next week", f"Okay, I'll hold your plan and leave you be.{back}", again)
    nxt = f" Next up: {c.label}, {day_label(c.moved_to)}." if c.label and c.moved_to else ""
    return (f"{stage} runs next week", f"Noted.{nxt}", again)


RENDER = {"ready": ready, "today": today, "postrun": postrun, "shape": shape}


# --------------------------------------------------------------- the line a run card may carry afterwards
FATIGUE_PHRASE = {("why", "tired"): "you were tired", ("ready", "flat"): "your legs were flat",
                  ("postrun", "sleep"): "you slept badly", ("postrun", "stress"): "things were stressful"}
CARE_PHRASE = {("why", "sore"): "something was sore", ("ready", "sore"): "something was sore"}
ILL_PHRASE = {("why", "ill"): "you were ill"}


def when_word(then: date, today_: date) -> str:
    days = (today_ - then).days
    return "today" if days <= 0 else "yesterday" if days == 1 else f"on {then:%A}"


def run_line(found: Sequence[tuple[str, str, date]], verdict: str | None, run_day: date) -> str | None:
    """`found`: (kind, value, answer date) answers from the 3 days up to the run. Illness and soreness come first and
    say the same thing every time: ease off, and see someone if it hangs around. A tired, flat, sleepless or stressed
    answer is only echoed on a slower run, where it explains something the numbers cannot."""
    for table, text in ((ILL_PHRASE, "Go easy, and see a doctor if you're not right soon."),
                        (CARE_PHRASE, "Keep it easy until it settles, and get it looked at if it hangs around.")):
        for kind, value, d in sorted(found, key=lambda x: x[2], reverse=True):
            if (kind, value) in table:
                return f"You said {table[(kind, value)]} {when_word(d, run_day)}. {text}"
    if verdict == "slower":
        for kind, value, d in sorted(found, key=lambda x: x[2], reverse=True):
            if (kind, value) in FATIGUE_PHRASE:
                return (f"You said {FATIGUE_PHRASE[(kind, value)]} {when_word(d, run_day)}, and this fits it. "
                        "It reads as fatigue, not lost fitness.")
    return None
