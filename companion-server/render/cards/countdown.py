"""Race countdown: days to go as the one hero, the plan's weeks as a row of blocks, on a lane-tinted block (direction B)."""
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
    colour = brand.LANE["speed"]
    quiet = brand.QUIET
    weeks_total = int(facts.get("plan_weeks") or 0)
    weeks_done = int(facts.get("weeks_done") or 0)
    blocks = ""
    if weeks_total:
        w = (936 - 8 * (weeks_total - 1)) / weeks_total
        blocks = "".join(
            f'<rect x="{i * (w + 8):.1f}" y="0" width="{w:.1f}" height="44" rx="10" fill="{colour if i < weeks_done else brand.HAIRLINE}"/>'
            for i in range(weeks_total))
        blocks = f'<svg width="936" height="44" viewBox="0 0 936 44">{blocks}</svg>'
    unit = ("WEEK" if days == 1 else "WEEKS") if weeks_mode else ("DAY" if days == 1 else "DAYS")
    # "Race day" says the race is today: only for zero. Otherwise the goal's name, or "Your race".
    name = P.esc(facts.get("race_name") or ("Race day" if days == 0 else "Your race"), 30)
    sub = P.esc(facts.get("race_line", ""), 70)
    cap2 = f"WEEK {weeks_done} OF {weeks_total}" if weeks_total else ""
    tint = brand.tint(colour)
    block = (f'<div class="abs" style="left:{P.BX}px;top:168px;width:{P.BW}px;height:820px;border-radius:{P.RADIUS}px;'
             f'background:{tint};overflow:hidden"><div class="abs" style="left:0;top:0;width:100%;height:16px;background:{colour}"></div>'
             f'<div class="abs cap" style="left:40px;top:50px;font-size:28px;letter-spacing:.14em;color:{brand.INK_SECONDARY}">RACE COUNTDOWN</div>'
             f'<div class="abs saira" style="left:40px;top:100px;width:{P.BW - 80}px;font-size:120px;line-height:.9;color:{brand.INK}">{name}</div>'
             f'<div class="abs" style="left:32px;bottom:30px;display:flex;align-items:baseline;gap:24px;white-space:nowrap">'
             f'<span class="saira" style="font-size:520px;line-height:.78;color:{brand.INK}">{days}</span>'
             f'<span class="saira" style="font-size:96px;line-height:1;color:{brand.INK}">{unit} TO GO</span></div></div>')
    sub_html = (f'<div class="abs" style="left:{P.BX + 40}px;top:1012px;width:{P.BW - 80}px;font-size:42px;line-height:1.25;font-weight:500;'
                f'color:{brand.INK}">{sub}</div>')
    row = (f'<div class="abs blocks" style="left:{P.PAD}px;top:1176px">{blocks}</div>'
           f'<div class="abs cap cap2" style="left:{P.PAD}px;top:1236px;font-size:24px;color:{quiet}">{cap2}</div>')
    body = P.header(False, P.esc(memory.get('name', ''), 20).upper(), quiet) + block + sub_html + row
    css = P.base_css(brand.GROUND, brand.INK)
    return P.doc(css, body)


def render_race_countdown(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_countdown_html(facts, memory), P.W, P.H)
