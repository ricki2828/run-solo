"""Post-run card, direction B: light page, a hero block (zone flood for a hard session or PB, lane colour for an everyday run), a lane-tinted visual panel and lane-tinted stat blocks."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html

VERDICT_WORDS = {"faster": "Faster.", "holding": "Holding.", "slower": "Slower.", "noRealChange": "No real change.",
                 "baselineSet": "Baseline set.", "indoorRun": "Indoor run."}
TYPE_WORDS = {"easy": "Easy run", "long": "Long run", "tempo": "Tempo", "interval": "Intervals", "race": "Race",
              "cooper": "Cooper test", "trail": "Trail run"}


def _hero(facts: Mapping[str, Any]) -> tuple[str, str]:
    h = facts.get("hero")
    if h:
        return P.esc(h["value"], 8), P.esc(h.get("unit", ""), 14)
    return P.fmt_km(float(facts["distance_km"])), "KM"


def _headline(facts: Mapping[str, Any]) -> str:
    return P.esc(facts.get("headline") or VERDICT_WORDS.get(str(facts.get("verdict")), ""), 44)


def build_post_run_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    hero_v, hero_u = _hero(facts)
    z = P.zone_seconds(facts)
    title = facts.get("title") or TYPE_WORDS.get(str(facts.get("type")), "Run")
    tag = P.esc(title, 36)
    if facts.get("place_note"):
        tag += f" &nbsp;/&nbsp; {P.esc(facts['place_note'], 40)}"
    stats = []
    reps = facts.get("reps")
    if reps:  # intervals: average pace over the whole session says little, so show the reps
        stats.append((str(len(reps)), "REPS"))
        if facts.get("work_pace_s_per_km"):  # the work pace replaces BEST REP: the row fits three
            stats.append((P.fmt_pace(float(facts["work_pace_s_per_km"])), "/KM WORK"))
        else:
            stats.append((P.fmt_dur(float(min(r["time_s"] for r in reps))), "BEST REP"))
        if facts.get("avg_hr"):
            stats.append((P.thousands(facts["avg_hr"]), "AVG BPM"))
    else:
        stats.append((P.fmt_dur(float(facts["duration_s"])), "TIME"))
    if facts.get("work_pace_s_per_km") and not reps:  # an interval run with no rep times: work pace, not the average
        stats.append((P.fmt_pace(float(facts["work_pace_s_per_km"])), "/KM WORK"))
    elif facts.get("pace_s_per_km") and not reps:
        stats.append((P.fmt_pace(float(facts["pace_s_per_km"])), "/KM"))
    if reps:
        pass
    elif facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " m", "CLIMB"))
    elif facts.get("avg_hr"):
        stats.append((P.thousands(facts["avg_hr"]), "BPM"))
    colour = brand.CARD_TYPE_COLOUR.get(str(facts.get("type")), brand.LANE["aerobic"])
    mode0 = P.effort_mode(facts)[0] == "flood"
    week = facts.get("week_track")
    vh = (180 if mode0 else 260) if week else (200 if mode0 else 300)
    route = P.facts_route_svg(facts, P.INNER, vh, colour, 12, "#FFFFFF", pad=24, end_dot=True)
    strip = P.zone_strip(z, 936, 22, gap=4, radius=6)
    has_route = bool(route)
    items = P.bar_items(facts)
    bars = "" if has_route else P.split_bars(items, P.INNER, vh - 30, brand.INK_SECONDARY)
    zblock = "" if (has_route or items) else P.zone_block(z, P.INNER, brand.INK, brand.INK_SECONDARY, "#FFFFFF", False, bar_h=80)
    if zblock:  # no route and no splits: the zone bar is the visual, so the small strip goes
        bars, strip = zblock, ""
    who = P.esc(memory.get("name", ""), 20).upper()
    when = P.date_label(facts.get("start_local"))
    top_right = " / ".join(x for x in (who, when) if x)
    pb = bool(facts.get("pb"))  # cyan is only ever PB / best
    mode, zone = P.effort_mode(facts)
    moment = mode == "flood"  # hard session, race, PB: the zone flood and the number at full size
    if moment:
        look = dict(ground=brand.flood_for_zone(zone), fg=brand.BONE, soft=brand.BONE, chip_bg="rgba(237,234,227,.22)")
    else:  # an everyday run: its lane colour
        look = dict(ground=colour, fg=brand.INK, soft=brand.INK, chip_bg="rgba(18,20,23,.12)")
    visual = (f'<div class="abs route" style="position:static">{route}</div>' if has_route
              else (f'<div class="abs bars" style="position:static">{bars}</div>' if bars else ""))
    body = (P.header(False, top_right, brand.QUIET)
            + P.run_layout(tag=tag, headline=_headline(facts), value=hero_v, unit=hero_u, colour=colour, visual=visual,
                           strip="" if not visual else strip, stats=stats,
                           value_colour=brand.ARC if pb else None, chip="PB" if pb else "", moment=moment, week=week, **look))
    css = P.base_css(brand.GROUND, brand.INK)
    return P.doc(css, body)


def render_post_run(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_post_run_html(facts, memory), P.W, P.H)
