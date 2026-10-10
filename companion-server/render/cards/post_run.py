"""Post-run card. Light for easy days; the full zone-colour flood for hard runs, intervals and PBs."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html

VERDICT_WORDS = {"faster": "Faster.", "holding": "Holding.", "slower": "Slower.", "noRealChange": "No real change.",
                 "baselineSet": "Baseline set.", "indoorRun": "Indoor run."}
TYPE_WORDS = {"easy": "Easy run", "long": "Long run", "tempo": "Tempo", "interval": "Intervals", "race": "Race"}


def _hero(facts: Mapping[str, Any]) -> tuple[str, str]:
    h = facts.get("hero")
    if h:
        return P.esc(h["value"], 8), P.esc(h.get("unit", ""), 14)
    return P.fmt_km(float(facts["distance_km"])), "KM"


def _headline(facts: Mapping[str, Any]) -> str:
    return P.esc(facts.get("headline") or VERDICT_WORDS.get(str(facts.get("verdict")), ""), 44)


def build_post_run_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    mode, zone = P.effort_mode(facts)
    flood = mode == "flood"
    bg = brand.flood_for_zone(zone) if flood else brand.GROUND
    fg = brand.BONE if flood else brand.INK
    quiet = brand.BONE if flood else brand.QUIET
    accent = brand.BONE if flood else brand.RUN_TYPE_COLOUR.get(str(facts.get("type")), brand.SCORE["aerobic"])
    if flood and facts.get("pb"):
        accent = brand.ARC
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
        stats.append((P.fmt_dur(float(min(r["time_s"] for r in reps))), "BEST REP"))
        if facts.get("avg_hr"):
            stats.append((P.thousands(facts["avg_hr"]), "AVG BPM"))
    else:
        stats.append((P.fmt_dur(float(facts["duration_s"])), "TIME"))
    if facts.get("pace_s_per_km") and not reps:
        stats.append((P.fmt_pace(float(facts["pace_s_per_km"])), "/KM"))
    if reps:
        pass
    elif facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " m", "CLIMB"))
    elif facts.get("avg_hr"):
        stats.append((P.thousands(facts["avg_hr"]), "BPM"))
    stat_html = "".join(
        f'<div style="display:flex;align-items:baseline;gap:12px"><span class="saira" style="font-size:62px">{P.esc(v)}</span>'
        f'<span class="cap" style="font-size:22px;color:{quiet}">{P.esc(l)}</span></div>' for v, l in stats)
    route = P.route_svg(facts.get("route") or [], 936, 420, accent if not flood else brand.BONE, 12,
                        bg, pad=26, end_dot=True)
    strip = P.zone_strip(z, 936, 26, gap=4, radius=4 if not flood else 0, stroke=bg if flood else None)
    who = P.esc(memory.get("name", ""), 20).upper()
    when = P.date_label(facts.get("start_local"))
    top_right = " / ".join(x for x in (who, when) if x)
    css = P.base_css(bg, fg) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:30px;color:{accent}}}
.head{{left:{P.PAD}px;top:218px;width:936px;font-size:118px;line-height:.9;color:{fg};text-wrap:balance}}
.route{{left:{P.PAD}px;top:430px}}
.hero{{left:{P.PAD - 8}px;top:850px;display:flex;align-items:baseline;gap:20px}}
.hero .n{{font-size:360px;line-height:.78}}
.hero .u{{font-size:64px;color:{accent}}}
.strip{{left:{P.PAD}px;top:1168px}}
.stats{{left:{P.PAD}px;top:1214px;width:936px;display:flex;justify-content:space-between;align-items:baseline}}
"""
    body = f"""
{P.header(flood, top_right, quiet)}
<div class="abs cap tag">{tag}</div>
<div class="abs saira head">{_headline(facts)}</div>
<div class="abs route">{route}</div>
<div class="abs hero"><span class="saira n">{hero_v}</span><span class="saira u">{hero_u}</span></div>
<div class="abs strip">{strip}</div>
<div class="abs stats">{stat_html}</div>"""
    return P.doc(css, body)


def render_post_run(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_post_run_html(facts, memory), P.W, P.H)
