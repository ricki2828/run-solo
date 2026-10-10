"""PB card: always the zone flood, the new time as the one hero, the old best underneath."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html


def build_pb_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    _, zone = P.effort_mode({**facts, "pb": True})
    bg = brand.flood_for_zone(zone)
    bone, arc = brand.BONE, brand.ARC
    d = facts.get("pb_detail") or {}
    hero = P.esc((facts.get("hero") or {}).get("value", P.fmt_dur(float(facts["duration_s"]))), 8)
    label = P.esc(d.get("label", "PERSONAL BEST"), 24)
    gain = ""
    if d.get("delta_s") is not None:
        n = abs(int(d["delta_s"]))
        word = "faster" if d["delta_s"] < 0 else "slower"
        gain = f"{n} seconds {word} than before"
    prev = P.fmt_dur(float(d["previous_s"])) if d.get("previous_s") else ""
    route = P.route_svg(facts.get("route") or [], 936, 330, bone, 8, bg, pad=22, end_dot=True)
    has_route = bool(route)
    bars = "" if has_route else P.split_bars(P.bar_items(facts), 936, 230, bone)
    stats = [(P.fmt_pace(float(facts["pace_s_per_km"])), "/KM")] if facts.get("pace_s_per_km") else []
    if prev:
        stats.insert(0, (prev, "OLD BEST"))
    if facts.get("avg_hr"):
        stats.append((P.thousands(facts["avg_hr"]), "BPM"))
    stat_html = "".join(
        f'<div style="display:flex;align-items:baseline;gap:12px"><span class="saira" style="font-size:62px">{P.esc(v)}</span>'
        f'<span class="cap" style="font-size:22px">{P.esc(l)}</span></div>' for v, l in stats)
    css = P.base_css(bg, bone) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{arc};letter-spacing:.14em}}
.label{{left:{P.PAD}px;top:222px;font-size:132px;line-height:.9;width:936px}}
.hero{{left:{P.PAD - 10}px;top:392px;font-size:560px;line-height:.8;color:{arc};white-space:nowrap}}
.gain{{left:{P.PAD}px;top:850px;font-size:44px;font-weight:600}}
.route{{left:{P.PAD}px;top:905px}}
.bars{{left:{P.PAD}px;top:925px}}
.stats{{left:{P.PAD}px;top:1236px;width:936px;display:flex;justify-content:space-between;align-items:baseline}}
.line{{left:0;top:1190px;width:{P.W}px;height:6px;background:{arc}}}
"""
    body = f"""{P.header(True, (P.esc(memory.get('name', ''), 20).upper() + ' / ' if memory.get('name') else '') + P.date_label(facts.get('start_local')), bone)}
<div class="abs cap tag">NEW PERSONAL BEST</div>
<div class="abs saira label">{label}</div>
<div class="abs saira hero">{hero}</div>
<div class="abs gain">{P.esc(gain, 60)}</div>
{f'<div class="abs route">{route}</div>' if has_route else f'<div class="abs bars">{bars}</div>'}
<div class="abs stats">{stat_html}</div>"""
    return P.doc(css, body)


def render_pb(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_pb_html(facts, memory), P.W, P.H)
