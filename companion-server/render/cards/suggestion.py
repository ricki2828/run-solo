"""Suggestion card: tomorrow's session, the reason, and a weather chip."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html

SESSION_WORDS = {"easy": "Easy run", "long": "Long run", "tempo": "Tempo", "interval": "Intervals",
                 "rest": "Rest day", "recover": "Easy run", "quality": "Quality day"}


def build_suggestion_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    kind = str(facts.get("type", "easy"))
    colour = brand.RUN_TYPE_COLOUR.get(kind, brand.SCORE["aerobic"])
    name = P.esc(facts.get("session") or SESSION_WORDS.get(kind, "Run"), 24)
    if facts.get("distance_km"):
        hero_v, hero_u = P.fmt_km(float(facts["distance_km"])).replace(".0", ""), "KM"
    else:
        hero_v, hero_u = P.fmt_dur(float(facts["duration_s"]))[:-3] if facts.get("duration_s") else "", "MIN"
    reason = P.esc(facts.get("reason", ""), 130)
    chip = P.weather_chip(facts.get("weather"), brand.INK, brand.HAIRLINE)
    when = P.date_label(facts.get("date_local"))
    css = P.base_css(brand.GROUND, brand.INK) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{brand.QUIET};letter-spacing:.14em}}
.name{{left:{P.PAD}px;top:222px;font-size:230px;line-height:.86;color:{colour};width:936px}}
.hero{{left:{P.PAD - 8}px;top:560px;display:flex;align-items:baseline;gap:20px}}
.hero .n{{font-size:420px;line-height:.78}}
.hero .u{{font-size:72px;color:{colour}}}
.bar{{left:{P.PAD}px;top:930px;width:936px;height:8px;background:{colour};border-radius:4px}}
.reason{{left:{P.PAD}px;top:975px;width:900px;font-size:44px;line-height:1.25;font-weight:500;text-wrap:pretty}}
.chip{{left:{P.PAD}px;top:1160px}}
"""
    body = f"""{P.header(False, when, brand.QUIET)}
<div class="abs cap tag">TOMORROW</div>
<div class="abs saira name">{name}</div>
<div class="abs hero"><span class="saira n">{hero_v}</span><span class="saira u">{hero_u}</span></div>
<div class="abs bar"></div>
<div class="abs reason">{reason}</div>
<div class="abs chip">{chip}</div>"""
    return P.doc(css, body)


def render_suggestion(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_suggestion_html(facts, memory), P.W, P.H)
