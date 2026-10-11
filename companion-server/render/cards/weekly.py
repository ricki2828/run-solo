"""Weekly recap: the week's km as the hero, day bars in km, coloured by zone share of time, the score moves, the best moment."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html

SCORE_ORDER = ("aerobic", "speed", "mid", "long")
DAYS = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")


def _day_km(d: Mapping[str, Any]) -> float:
    try:
        return max(0.0, float(d.get("distance_km") or 0))
    except (TypeError, ValueError):
        return 0.0


def _bars(days: list[Mapping[str, Any]], width: int, height: int) -> str:
    """Bar height is the day's km; the zone colours split it by each zone's share of that day's moving time."""
    peak = max([_day_km(d) for d in days[:7]] + [0.1])
    n = 7
    slot = width / n
    bw = slot * 0.62
    top_pad = 44  # room for the km label above the tallest bar
    room = height - 52 - top_pad
    parts = []
    for i in range(n):
        d = days[i] if i < len(days) else {}
        x = i * slot + (slot - bw) / 2
        km = _day_km(d)
        z = P.zone_seconds({"zone_s": d.get("zone_s")})
        zt = sum(z)
        y = height - 52
        if km > 0:
            full = room * km / peak
            if zt > 0:
                for k, v in enumerate(z):
                    if v <= 0:
                        continue
                    h = full * v / zt
                    y -= h
                    parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(h - 2, 1):.1f}" fill="{brand.ZONE_RAMP[k]}"/>')
            else:  # a run with no heart-rate zones: still a km bar, in a neutral colour
                y -= full
                parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(full - 2, 1):.1f}" fill="{brand.QUIET}"/>')
            parts.append(f'<text x="{x + bw / 2:.1f}" y="{y - 10:.1f}" text-anchor="middle" font-family="{brand.SAIRA}" '
                         f'font-weight="800" font-size="32" fill="{brand.INK}">{P.fmt_km(km)}</text>')
        else:
            parts.append(f'<rect x="{x:.1f}" y="{height - 58:.1f}" width="{bw:.1f}" height="6" fill="{brand.HAIRLINE}"/>')
        parts.append(f'<text x="{x + bw / 2:.1f}" y="{height - 10}" text-anchor="middle" font-family="{brand.SCHIBSTED}" '
                     f'font-weight="600" font-size="24" letter-spacing="2" fill="{brand.QUIET}">{DAYS[i]}</text>')
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(parts)}</svg>'


def build_weekly_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    ink, quiet = brand.INK, brand.QUIET
    moves = facts.get("score_moves") or {}
    chips = []
    for key in SCORE_ORDER:
        if key not in moves:
            continue
        mv = float(moves[key])
        col = brand.SCORE[key]
        arrow = brand.MINT if mv > 0 else (brand.VERMILLION if mv < 0 else quiet)
        chips.append(
            f'<div style="flex:1"><div style="height:8px;background:{col};border-radius:4px;margin-bottom:14px"></div>'
            f'<div class="cap" style="font-size:22px;color:{quiet}">{key}</div>'
            f'<div class="saira" style="font-size:64px;line-height:1;color:{arrow}">{P.signed(mv)}</div></div>')
    best = facts.get("best_moment") or {}
    best_html = ""
    if best.get("text"):
        best_html = (f'<div class="cap" style="font-size:22px;color:{quiet};margin-bottom:8px">BEST MOMENT</div>'
                     f'<div style="font-size:38px;line-height:1.2;font-weight:600">{P.esc(best["text"], 110)}</div>')
    week = P.esc(facts.get("week_label", ""), 24)
    css = P.base_css(brand.GROUND, ink) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{quiet};letter-spacing:.14em}}
.hero{{left:{P.PAD - 8}px;top:214px;display:flex;align-items:baseline;gap:20px}}
.hero .n{{font-size:330px;line-height:.78}}
.hero .u{{font-size:64px;color:{brand.SCORE['aerobic']}}}
.sub{{left:{P.PAD}px;top:500px;font-size:34px;font-weight:600;color:{quiet}}}
.bars{{left:{P.PAD}px;top:556px}}
.moves{{left:{P.PAD}px;top:964px;width:936px;display:flex;gap:28px}}
.best{{left:{P.PAD}px;top:1146px;width:936px}}
"""
    sub = f"{facts.get('runs', 0)} runs / {P.fmt_dur(float(facts.get('duration_s', 0)))} on the move"
    body = f"""{P.header(False, P.esc(memory.get('name', ''), 20).upper(), quiet)}
<div class="abs cap tag">{week}</div>
<div class="abs hero"><span class="saira n">{P.fmt_km(float(facts['distance_km']))}</span><span class="saira u">KM</span></div>
<div class="abs sub">{P.esc(sub, 60)}</div>
<div class="abs bars">{_bars(list(facts.get('days') or []), 936, 380)}</div>
<div class="abs moves">{''.join(chips)}</div>
<div class="abs best">{best_html}</div>"""
    return P.doc(css, body)


def render_weekly_recap(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_weekly_html(facts, memory), P.W, P.H)
