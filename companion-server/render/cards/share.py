"""Share card for friends. Whitelist only: a field renders when facts['share'] says so, otherwise it is not in the HTML.

No location of any kind (route shape, place, date and time of day) unless the runner opted in to it.
"""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html
from .post_run import TYPE_WORDS


def build_share_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    s = facts.get("share") or {}
    ink, quiet = brand.INK, brand.QUIET
    colour = brand.CARD_TYPE_COLOUR.get(str(facts.get("type")), brand.LANE["aerobic"])
    hero_v, hero_u = P.fmt_km(float(facts["distance_km"])), "KM"
    # the run's title can be a place ("Kastro loop"), so it shows only with the place opt-in
    tag = P.esc(facts.get("title", "Run") if s.get("place") else TYPE_WORDS.get(str(facts.get("type")), "Run"), 30)
    if s.get("place") and facts.get("place_note"):
        tag += f" &nbsp;/&nbsp; {P.esc(facts['place_note'], 40)}"
    route = ""
    if s.get("route") and facts.get("route"):
        route = P.route_svg(facts["route"], P.INNER, 300, colour, 12, "#FFFFFF", pad=24, end_dot=False)
    stats = []
    reps = facts.get("reps")
    if reps and s.get("reps"):  # intervals: reps replace the session's average pace, which says little
        stats.append((str(len(reps)), "REPS"))
        if facts.get("work_pace_s_per_km"):
            stats.append((P.fmt_pace(float(facts["work_pace_s_per_km"])), "/KM WORK"))
        else:
            stats.append((P.fmt_dur(float(min(r["time_s"] for r in reps))), "BEST REP"))
    if s.get("time"):
        stats.append((P.fmt_dur(float(facts["duration_s"])), "TIME"))
    if s.get("pace", True) and facts.get("pace_s_per_km") and not reps:
        stats.append((P.fmt_pace(float(facts["pace_s_per_km"])), "/KM"))
    if s.get("hr") and facts.get("avg_hr"):
        stats.append((P.thousands(facts["avg_hr"]), "BPM"))
    if s.get("climb") and facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " m", "CLIMB"))
    who = P.esc(memory.get("name", ""), 20).upper() if s.get("name") else ""
    when = P.date_label(facts.get("start_local")) if s.get("date") else ""
    # Only text the runner chose for sharing: the card never reuses the post-run headline, which can name a place.
    headline = P.esc(s["headline"], 44) if isinstance(s.get("headline"), str) else ""
    wm = P.wordmark_svg("on-light", 36)
    visual = f'<div class="abs route" style="position:static">{route}</div>' if route else ""
    body = (P.header(False, ' / '.join(x for x in (who, when) if x), brand.QUIET)
            + P.run_layout(tag=tag, headline=headline, value=hero_v, unit=hero_u, colour=colour, visual=visual, strip="", stats=stats,
                           ground=colour, fg=brand.INK, soft=brand.INK, chip_bg="rgba(18,20,23,.12)")
            + f'<div class="abs wm" style="left:{P.PAD}px;top:1296px">{wm}</div>')
    css = P.base_css(brand.GROUND, ink)
    return P.doc(css, body)


def render_share_card(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_share_html(facts, memory), P.W, P.H)
