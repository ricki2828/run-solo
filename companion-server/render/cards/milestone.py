"""Milestone card (100th run, 1,000 km), direction B: the number in white on the violet block, the line under it in a lane block.

Not cyan: cyan is only ever a PB / best, and a milestone is neither.
"""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html


def build_milestone_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    kind = facts.get("kind")
    value = int(facts["value"])
    if kind == "distance_km":
        unit, tag = "KM", "MILESTONE"
        size = 440 if value >= 1000 else 520
        extra = f"{facts.get('runs')} runs since {P.esc(facts.get('since', ''), 16)}" if facts.get("runs") else ""
    else:
        unit, tag = "RUNS", "MILESTONE"
        size = 520
        extra = f"{P.thousands(facts['total_km'])} km since {P.esc(facts.get('since', ''), 16)}" if facts.get("total_km") else ""
    # violet, not cyan: a milestone is not a PB. The number is white on the hero block, the line is a lane block under it.
    block = P.hero_block(168, 760, tag=tag, headline="", value=P.thousands(value), unit=unit, size=size, unit_colour=brand.ON_VIOLET, pad_bottom=70)
    say = (f'<div class="abs" style="left:{P.BX}px;top:952px;width:{P.BW}px;height:300px;border-radius:{P.RADIUS}px;'
           f'background:{brand.tint(brand.LANE["long"])};overflow:hidden"><div class="abs" style="left:0;top:0;width:100%;height:14px;'
           f'background:{brand.LANE["long"]}"></div><div class="abs saira" style="left:40px;top:52px;width:{P.BW - 80}px;font-size:100px;'
           f'line-height:.92;color:{brand.INK};text-wrap:balance">{P.esc(facts.get("line", ""), 40)}</div>'
           f'<div class="abs" style="left:40px;bottom:30px;font-size:34px;font-weight:600;color:{brand.INK_SECONDARY}">{P.esc(extra, 60)}</div></div>')
    body = P.header(False, P.esc(memory.get('name', ''), 20).upper(), brand.QUIET) + block + say
    css = P.base_css(brand.GROUND, brand.INK)
    return P.doc(css, body)


def render_milestone(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_milestone_html(facts, memory), P.W, P.H)
