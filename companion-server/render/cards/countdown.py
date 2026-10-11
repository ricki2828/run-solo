"""Race countdown: days to go as the one hero, the plan's weeks as a row of blocks."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html


def build_countdown_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    # The coach only knows whole weeks ("7 weeks to race day"), so it sends weeks; a full date feed would send days.
    weeks_mode = facts.get("days_to_race") is None and facts.get("weeks_to_race") is not None
    days = int(facts["weeks_to_race"] if weeks_mode else facts["days_to_race"])
    colour = brand.SCORE["speed"]
    quiet = brand.QUIET
    weeks_total = int(facts.get("plan_weeks") or 0)
    weeks_done = int(facts.get("weeks_done") or 0)
    blocks = ""
    if weeks_total:
        w = (936 - 8 * (weeks_total - 1)) / weeks_total
        blocks = "".join(
            f'<rect x="{i * (w + 8):.1f}" y="0" width="{w:.1f}" height="34" rx="4" fill="{colour if i < weeks_done else brand.HAIRLINE}"/>'
            for i in range(weeks_total))
        blocks = f'<svg width="936" height="34" viewBox="0 0 936 34">{blocks}</svg>'
    unit = ("WEEK" if days == 1 else "WEEKS") if weeks_mode else ("DAY" if days == 1 else "DAYS")
    name = P.esc(facts.get("race_name", "Race day"), 30)
    sub = P.esc(facts.get("race_line", ""), 70)
    css = P.base_css(brand.GROUND, brand.INK) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{colour};letter-spacing:.14em}}
.name{{left:{P.PAD}px;top:222px;font-size:132px;line-height:.9;width:936px}}
.hero{{left:{P.PAD - 14}px;top:400px;font-size:640px;line-height:.78;white-space:nowrap}}
.unit{{left:{P.PAD}px;top:900px;font-size:120px;line-height:1;color:{colour}}}
.sub{{left:{P.PAD}px;top:1056px;width:936px;font-size:44px;line-height:1.25;font-weight:500}}
.blocks{{left:{P.PAD}px;top:1200px}}
.cap2{{left:{P.PAD}px;top:1248px;font-size:22px;color:{quiet}}}
"""
    cap2 = f"WEEK {weeks_done} OF {weeks_total}" if weeks_total else ""
    body = f"""{P.header(False, P.esc(memory.get('name', ''), 20).upper(), quiet)}
<div class="abs cap tag">RACE COUNTDOWN</div>
<div class="abs saira name">{name}</div>
<div class="abs saira hero">{days}</div>
<div class="abs saira unit">{unit} TO GO</div>
<div class="abs sub">{sub}</div>
<div class="abs blocks">{blocks}</div>
<div class="abs cap cap2">{cap2}</div>"""
    return P.doc(css, body)


def render_race_countdown(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_countdown_html(facts, memory), P.W, P.H)
