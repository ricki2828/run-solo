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
    colour = brand.RUN_TYPE_COLOUR.get(str(facts.get("type")), brand.SCORE["aerobic"])
    hero_v, hero_u = P.fmt_km(float(facts["distance_km"])), "KM"
    # the run's title can be a place ("Kastro loop"), so it shows only with the place opt-in
    tag = P.esc(facts.get("title", "Run") if s.get("place") else TYPE_WORDS.get(str(facts.get("type")), "Run"), 30)
    if s.get("place") and facts.get("place_note"):
        tag += f" &nbsp;/&nbsp; {P.esc(facts['place_note'], 40)}"
    route = ""
    if s.get("route") and facts.get("route"):
        route = P.route_svg(facts["route"], 936, 400, colour, 12, brand.GROUND, pad=26, end_dot=False)
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
    stat_html = "".join(
        f'<div style="display:flex;align-items:baseline;gap:12px"><span class="saira" style="font-size:62px">{P.esc(v)}</span>'
        f'<span class="cap" style="font-size:22px;color:{quiet}">{P.esc(l)}</span></div>' for v, l in stats)
    who = P.esc(memory.get("name", ""), 20).upper() if s.get("name") else ""
    when = P.date_label(facts.get("start_local")) if s.get("date") else ""
    # Only text the runner chose for sharing: the card never reuses the post-run headline, which can name a place.
    headline = P.esc(s["headline"], 44) if isinstance(s.get("headline"), str) else ""
    wm = P.wordmark_svg("on-light", 36)
    css = P.base_css(brand.GROUND, ink) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:30px;color:{colour}}}
.head{{left:{P.PAD}px;top:218px;width:936px;font-size:118px;line-height:.9;text-wrap:balance}}
.route{{left:{P.PAD}px;top:430px}}
.hero{{left:{P.PAD - 8}px;top:{850 if route else 480}px;display:flex;align-items:baseline;gap:20px}}
.hero .n{{font-size:{360 if route else 560}px;line-height:.78}}
.hero .u{{font-size:64px;color:{colour}}}
.bar{{left:{P.PAD}px;top:1160px;width:936px;height:8px;background:{colour};border-radius:4px}}
.stats{{left:{P.PAD}px;top:1192px;width:936px;display:flex;gap:56px;align-items:baseline}}
.wm{{left:{P.PAD}px;top:1290px}}
"""
    body = f"""{P.header(False, ' / '.join(x for x in (who, when) if x), quiet)}
<div class="abs cap tag">{tag}</div>
<div class="abs saira head">{headline}</div>
<div class="abs route">{route}</div>
<div class="abs hero"><span class="saira n">{hero_v}</span><span class="saira u">{hero_u}</span></div>
<div class="abs bar"></div>
<div class="abs stats">{stat_html}</div>
<div class="abs wm">{wm}</div>"""
    return P.doc(css, body)


def render_share_card(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_share_html(facts, memory), P.W, P.H)
