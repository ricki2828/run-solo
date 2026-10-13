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
    colour = brand.CARD_TYPE_COLOUR.get(kind, brand.LANE["aerobic"])
    name = P.esc(facts.get("session") or SESSION_WORDS.get(kind, "Run"), 24)
    if facts.get("distance_km"):
        hero_v, hero_u = P.fmt_km(float(facts["distance_km"])).replace(".0", ""), "KM"
    else:
        hero_v, hero_u = P.fmt_dur(float(facts["duration_s"]))[:-3] if facts.get("duration_s") else "", "MIN"
    reason = P.esc(facts.get("reason", ""), 130)
    chip = P.weather_chip(facts.get("weather"), brand.INK, brand.HAIRLINE)
    when = P.date_label(facts.get("date_local"))
    # the next-session block of the B Home: a lane-tinted block, the session as the big type, the lane colour as its bar
    block = (f'<div class="abs" style="left:{P.BX}px;top:168px;width:{P.BW}px;height:760px;border-radius:{P.RADIUS}px;'
             f'background:{brand.tint(colour)};overflow:hidden"><div class="abs" style="left:0;top:0;width:100%;height:16px;background:{colour}"></div>'
             f'<div class="abs cap" style="left:40px;top:50px;font-size:28px;letter-spacing:.14em;color:{brand.INK_SECONDARY}">TOMORROW</div>'
             f'<div class="abs saira" style="left:40px;top:100px;width:{P.BW - 80}px;font-size:170px;line-height:.86;color:{brand.INK}">{name}</div>'
             f'<div class="abs" style="left:32px;bottom:30px;display:flex;align-items:baseline;gap:20px">'
             f'<span class="saira" style="font-size:380px;line-height:.78;color:{brand.INK}">{hero_v}</span>'
             f'<span class="saira" style="font-size:72px;color:{brand.INK}">{hero_u}</span></div></div>')
    why = (f'<div class="abs" style="left:{P.BX}px;top:952px;width:{P.BW}px;height:{250 if chip else 330}px;border-radius:{P.RADIUS}px;'
           f'background:#FFFFFF;border:2px solid {brand.HAIRLINE};overflow:hidden"><div class="abs" style="left:40px;top:34px;width:{P.BW - 120}px;'
           f'font-size:44px;line-height:1.25;font-weight:500;text-wrap:pretty;color:{brand.INK}">{reason}</div></div>')
    chip_html = f'<div class="abs chip" style="left:{P.BX}px;top:1224px">{chip}</div>' if chip else ""
    body = P.header(False, when, brand.QUIET) + block + why + chip_html
    css = P.base_css(brand.GROUND, brand.INK)
    return P.doc(css, body)


def render_suggestion(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_suggestion_html(facts, memory), P.W, P.H)
