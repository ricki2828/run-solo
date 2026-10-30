"""PB card, direction B: the zone flood block with the new time in cyan (cyan is only ever PB / best), the old best underneath."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html


def build_pb_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    d = facts.get("pb_detail") or {}
    hero = P.esc((facts.get("hero") or {}).get("value", P.fmt_dur(float(facts["duration_s"]))), 8)
    label = P.esc(d.get("label", "PERSONAL BEST"), 24)
    gain = ""
    if d.get("delta_s") is not None:
        n = abs(int(d["delta_s"]))
        word = "faster" if d["delta_s"] < 0 else "slower"
        gain = f"{n} seconds {word} than before"
    prev = P.fmt_dur(float(d["previous_s"])) if d.get("previous_s") else ""
    colour = brand.CARD_TYPE_COLOUR.get(str(facts.get("type")), brand.LANE["speed"])
    week = facts.get("week_track")
    route = P.facts_route_svg(facts, P.INNER, 170 if week else 200, colour, 10, "#FFFFFF", pad=22, end_dot=True)
    has_route = bool(route)
    items = P.bar_items(facts)
    bars = "" if has_route else P.split_bars(items, P.INNER, 150 if week else 170, brand.INK_SECONDARY)
    if not has_route and not items:
        bars = P.zone_block(P.zone_seconds(facts), P.INNER, brand.INK, brand.INK_SECONDARY, "#FFFFFF", False, bar_h=80)
    stats = [(P.fmt_pace(float(facts["pace_s_per_km"])), "/KM")] if facts.get("pace_s_per_km") else []
    if prev:
        stats.insert(0, (prev, "OLD BEST"))
    if facts.get("avg_hr"):
        stats.append((P.thousands(facts["avg_hr"]), "BPM"))
    visual = (f'<div class="abs route" style="position:static">{route}</div>' if has_route
              else (f'<div class="abs bars" style="position:static">{bars}</div>' if bars else ""))
    top_right = (P.esc(memory.get("name", ""), 20).upper() + " / " if memory.get("name") else "") + P.date_label(facts.get("start_local"))
    body = (P.header(False, top_right, brand.QUIET)
            + P.run_layout(tag="NEW PERSONAL BEST", headline=label, value=hero, unit="", colour=colour, visual=visual, strip="",
                           stats=stats, value_colour=brand.ARC, chip="PB", extra=P.esc(gain, 60), moment=True, week=week,
                           ground=brand.flood_for_zone(P.effort_mode({**facts, "pb": True})[1]), fg=brand.BONE, soft=brand.BONE,
                           chip_bg="rgba(237,234,227,.22)"))
    css = P.base_css(brand.GROUND, brand.INK)
    return P.doc(css, body)


def render_pb(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_pb_html(facts, memory), P.W, P.H)
