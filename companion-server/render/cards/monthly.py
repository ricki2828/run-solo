"""Monthly poster, 1080x1920: route shapes as small multiples, the month's km as the hero, the best run."""
from __future__ import annotations

import calendar
from datetime import date
from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html

COLS = 4


def _hm(s: float) -> str:
    return f"{int(s // 3600)} h {int(s % 3600 // 60):02d}"

MAX_RUNS = 24


def build_monthly_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    ink, quiet = brand.INK, brand.QUIET
    runs = list(facts.get("runs") or [])[:MAX_RUNS]
    rows = max(1, -(-len(runs) // COLS))
    cell_w = 936 / COLS
    cell_h = min(214.0, 760 / rows)
    cells = []
    for i, r in enumerate(runs):
        col = brand.RUN_TYPE_COLOUR.get(str(r.get("type")), brand.SCORE["aerobic"])
        svg = P.route_svg(r.get("route") or [], int(cell_w - 28), int(cell_h - 28), col, 5, brand.GROUND, pad=8, start_dot=False)
        x, y = (i % COLS) * cell_w, (i // COLS) * cell_h
        cells.append(f'<div class="abs" style="left:{x + 14:.0f}px;top:{y + 14:.0f}px">{svg}</div>')
    best = facts.get("best_run") or {}
    best_html = ""
    if best.get("text"):
        best_html = (f'<div class="cap" style="font-size:24px;color:{quiet};margin-bottom:10px">BEST RUN</div>'
                     f'<div style="font-size:46px;line-height:1.18;font-weight:600;text-wrap:pretty">{P.esc(best["text"], 110)}</div>')
    stats = [(str(facts.get("run_count", len(runs))), "RUNS"), (_hm(float(facts.get("duration_s", 0))), "ON THE MOVE")]
    if facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " m", "CLIMB"))
    stat_html = "".join(
        f'<div><div class="saira" style="font-size:84px;line-height:1">{P.esc(v)}</div>'
        f'<div class="cap" style="font-size:22px;color:{quiet}">{P.esc(l)}</div></div>' for v, l in stats)
    grid_top = 700
    css = P.base_css(brand.GROUND, ink, P.W, P.POSTER_H) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{quiet};letter-spacing:.14em}}
.month{{left:{P.PAD}px;top:222px;font-size:150px;line-height:.9}}
.hero{{left:{P.PAD - 10}px;top:410px;display:flex;align-items:baseline;gap:20px}}
.hero .n{{font-size:330px;line-height:.78}}
.hero .u{{font-size:64px;color:{brand.SCORE['aerobic']}}}
.grid{{left:{P.PAD}px;top:{grid_top}px;width:936px;height:{cell_h * rows:.0f}px}}
.stats{{left:{P.PAD}px;top:1500px;width:936px;display:flex;justify-content:space-between}}
.best{{left:{P.PAD}px;top:1668px;width:936px}}
"""
    body = f"""{P.header(False, P.esc(memory.get('name', ''), 20).upper(), quiet)}
<div class="abs cap tag">MONTH IN RUNS</div>
<div class="abs saira month">{P.esc(facts.get('month_label', ''), 24)}</div>
<div class="abs hero"><span class="saira n">{P.thousands(float(facts['distance_km']))}</span><span class="saira u">KM</span></div>
<div class="abs grid">{''.join(cells)}</div>
<div class="abs stats">{stat_html}</div>
<div class="abs best">{best_html}</div>"""
    return P.doc(css, body)


# --- route-less layout ------------------------------------------------------------------------
# The server never stores routes (privacy), so what it can draw is the month as a calendar: one bar per
# run on its day, height = distance, colour = run type. Inputs are the stored per-run fields only:
# date (YYYY-MM-DD), distance_km, duration_s, type (and zone_s, which the poster does not need).

WEEKDAYS = ("M", "T", "W", "T", "F", "S", "S")
GRID_TOP = 700
HEAD_H = 40
LEGEND_GAP = 24
TYPE_ORDER = ("easy", "long", "tempo", "interval", "race")


def _type_colour(t: Any) -> str:
    return brand.RUN_TYPE_COLOUR.get(str(t), brand.SCORE["aerobic"])


def _run_date(r: Mapping[str, Any]) -> date | None:
    try:
        return date.fromisoformat(str(r.get("date"))[:10])
    except ValueError:
        return None


def has_routes(facts: Mapping[str, Any]) -> bool:
    return any(r.get("route") for r in facts.get("runs") or [])


def build_monthly_calendar_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    ink, quiet = brand.INK, brand.QUIET
    runs = [(d, r) for r in facts.get("runs") or [] if (d := _run_date(r)) is not None]
    if facts.get("month_start"):
        first = date.fromisoformat(str(facts["month_start"])[:10]).replace(day=1)
    else:
        first = (min(d for d, _ in runs) if runs else date.today()).replace(day=1)
    days_in = calendar.monthrange(first.year, first.month)[1]
    lead = first.weekday()
    rows = -(-(lead + days_in) // 7)
    cell_w = 936 / 7
    row_h = min(118.0, (1380 - GRID_TOP - HEAD_H) / rows)
    longest = max([float(r.get("distance_km") or 0) for _, r in runs] + [1.0])
    by_day: dict[int, list[Mapping[str, Any]]] = {}
    for d, r in runs:
        if d.year == first.year and d.month == first.month:
            by_day.setdefault(d.day, []).append(r)
    parts = []
    for i, w in enumerate(WEEKDAYS):
        parts.append(f'<div class="abs cap" style="left:{i * cell_w:.0f}px;top:0;width:{cell_w:.0f}px;text-align:center;'
                     f'font-size:22px;color:{quiet}">{w}</div>')
    bar_room = row_h - 40
    for day in range(1, days_in + 1):
        idx = lead + day - 1
        x, y = (idx % 7) * cell_w, HEAD_H + (idx // 7) * row_h
        parts.append(f'<div class="abs" style="left:{x + 4:.1f}px;top:{y + 4:.1f}px;width:{cell_w - 8:.1f}px;height:{row_h - 8:.1f}px;'
                     f'background:{brand.HAIRLINE};opacity:.55;border-radius:8px"></div>')
        parts.append(f'<div class="abs" style="left:{x + 12:.1f}px;top:{y + 8:.1f}px;font-size:19px;font-weight:600;color:{quiet}">{day}</div>')
        todays = by_day.get(day, [])
        n = len(todays)
        if not n:
            continue
        slot = (cell_w - 24) / n
        bw = min(slot - (6 if n > 1 else 0), 54.0)
        for k, r in enumerate(todays):
            km = float(r.get("distance_km") or 0)
            h = max(10.0, bar_room * km / longest)
            bx = x + 12 + k * slot + (slot - bw) / 2
            parts.append(f'<div class="abs run" data-type="{P.esc(r.get("type"), 16)}" data-km="{km:.1f}" '
                         f'style="left:{bx:.1f}px;top:{y + row_h - 12 - h:.1f}px;width:{bw:.1f}px;height:{h:.1f}px;'
                         f'background:{_type_colour(r.get("type"))};border-radius:6px"></div>')
    legend, seen = [], set()
    types = [t for t in TYPE_ORDER if any(r.get("type") == t for _, r in runs)]
    for t in types:
        col = _type_colour(t)
        if col in seen:
            continue
        seen.add(col)
        label = " / ".join(u for u in types if _type_colour(u) == col)
        legend.append(f'<span style="display:inline-flex;align-items:center;gap:10px;margin-right:30px">'
                      f'<span style="width:20px;height:20px;border-radius:5px;background:{col}"></span>'
                      f'<span class="cap" style="font-size:22px;color:{quiet}">{P.esc(label, 24)}</span></span>')
    legend_top = GRID_TOP + HEAD_H + row_h * rows + LEGEND_GAP
    best = facts.get("best_run") or {}
    best_html = ""
    if best.get("text"):
        best_html = (f'<div class="cap" style="font-size:24px;color:{quiet};margin-bottom:10px">BEST RUN</div>'
                     f'<div style="font-size:46px;line-height:1.18;font-weight:600;text-wrap:pretty">{P.esc(best["text"], 110)}</div>')
    stats = [(str(facts.get("run_count", len(runs))), "RUNS"), (_hm(float(facts.get("duration_s", 0))), "ON THE MOVE")]
    if facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " m", "CLIMB"))
    stat_html = "".join(
        f'<div><div class="saira" style="font-size:84px;line-height:1">{P.esc(v)}</div>'
        f'<div class="cap" style="font-size:22px;color:{quiet}">{P.esc(l)}</div></div>' for v, l in stats)
    css = P.base_css(brand.GROUND, ink, P.W, P.POSTER_H) + f"""
.tag{{left:{P.PAD}px;top:176px;font-size:34px;color:{quiet};letter-spacing:.14em}}
.month{{left:{P.PAD}px;top:222px;font-size:150px;line-height:.9}}
.hero{{left:{P.PAD - 10}px;top:410px;display:flex;align-items:baseline;gap:20px}}
.hero .n{{font-size:330px;line-height:.78}}
.hero .u{{font-size:64px;color:{brand.SCORE['aerobic']}}}
.grid{{left:{P.PAD}px;top:{GRID_TOP}px;width:936px;height:{HEAD_H + row_h * rows:.0f}px}}
.legend{{left:{P.PAD}px;top:{legend_top:.0f}px;width:936px;white-space:nowrap}}
.stats{{left:{P.PAD}px;top:1500px;width:936px;display:flex;justify-content:space-between}}
.best{{left:{P.PAD}px;top:1668px;width:936px}}
"""
    body = f"""{P.header(False, P.esc(memory.get('name', ''), 20).upper(), quiet)}
<div class="abs cap tag">MONTH IN RUNS</div>
<div class="abs saira month">{P.esc(facts.get('month_label', ''), 24)}</div>
<div class="abs hero"><span class="saira n">{P.thousands(float(facts['distance_km']))}</span><span class="saira u">KM</span></div>
<div class="abs grid">{''.join(parts)}</div>
<div class="abs legend">{''.join(legend)}</div>
<div class="abs stats">{stat_html}</div>
<div class="abs best">{best_html}</div>"""
    return P.doc(css, body)


def render_monthly_poster(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    """Route outlines when the facts carry routes (app-side data); otherwise the calendar of bars."""
    html = build_monthly_html(facts, memory) if has_routes(facts) else build_monthly_calendar_html(facts, memory)
    return render_html(html, P.W, P.POSTER_H)
