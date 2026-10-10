"""Milestone card (100th run, 1,000 km): the Z1 flood, the number in Arc cyan, the Lap Line crossing the card.

Z1 navy rather than a hot zone colour: a milestone is not an effort, so it should not borrow the red of a hard run.
Arc cyan on Z1 is 6.95:1; Bone text is 8.8:1.
"""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html


def build_milestone_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    bone, arc = brand.BONE, brand.ARC
    kind = facts.get("kind")
    value = int(facts["value"])
    if kind == "distance_km":
        unit, tag = "KM", "MILESTONE"
        size = 500 if value >= 1000 else 560
        extra = f"{facts.get('runs')} runs since {P.esc(facts.get('since', ''), 16)}" if facts.get("runs") else ""
    else:
        unit, tag = "RUNS", "MILESTONE"
        size = 560
        extra = f"{P.thousands(facts['total_km'])} km since {P.esc(facts.get('since', ''), 16)}" if facts.get("total_km") else ""
    css = P.base_css(brand.flood_for_zone(1), bone) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{arc};letter-spacing:.14em}}
.hero{{left:{P.PAD - 12}px;top:330px;font-size:{size}px;line-height:.8;color:{arc};white-space:nowrap}}
.unit{{left:{P.PAD}px;top:{330 + int(size * .8) + 150}px;font-size:110px;line-height:1}}
.line{{left:0;top:{330 + int(size * .8) + 110}px;width:{P.W}px;height:8px;background:{arc};border-radius:0 4px 4px 0}}
.say{{left:{P.PAD}px;top:1090px;width:936px;font-size:104px;line-height:.92}}
.extra{{left:{P.PAD}px;top:1250px;font-size:34px;font-weight:600}}
"""
    body = f"""{P.header(True, P.esc(memory.get('name', ''), 20).upper(), bone)}
<div class="abs cap tag">{tag}</div>
<div class="abs saira hero">{P.thousands(value)}</div>
<div class="abs line"></div>
<div class="abs saira unit">{unit}</div>
<div class="abs saira say">{P.esc(facts.get('line', ''), 40)}</div>
<div class="abs extra">{P.esc(extra, 60)}</div>"""
    return P.doc(css, body)


def render_milestone(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_milestone_html(facts, memory), P.W, P.H)
