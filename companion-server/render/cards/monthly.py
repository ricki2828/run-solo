"""Monthly poster, 1080x1920, direction B: route shapes as small multiples, the month's km as the hero, the best run."""
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


def _avg_pace(facts: Mapping[str, Any]) -> float | None:
    try:
        km, dur = float(facts.get("distance_km") or 0), float(facts.get("duration_s") or 0)
    except (TypeError, ValueError):
        return None
    return dur / km if km >= 1 and dur > 0 else None


def _stats(facts: Mapping[str, Any], runs: list) -> list:
    stats = [(str(facts.get("run_count", len(runs))), "RUNS"), (_hm(float(facts.get("duration_s", 0))), "ON THE MOVE")]
    if (pace := _avg_pace(facts)) is not None:  # the month's total time over its total km, from the two numbers the card holds
        stats.append((P.fmt_pace(pace), "AVG /KM"))
    if facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " m", "CLIMB"))
    return stats


def _frame(facts: Mapping[str, Any], memory: Mapping[str, Any], grid_html: str, grid_h: float, legend_html: str, stats: list) -> str:
    """Direction B poster: violet hero block, the month's picture on a white panel, stat blocks, the best run."""
    quiet = brand.QUIET
    legend_h = 56 if legend_html else 0
    panel_h = int(grid_h + 40 + legend_h)
    block = P.hero_block(168, 520, tag="MONTH IN RUNS", headline=P.esc(facts.get("month_label", ""), 24),
                         value=P.thousands(float(facts["distance_km"])), unit="KM", size=250, headline_size=120)
    inner = (f'<div class="abs grid" style="left:{P.BX + 24}px;top:{712 + 20}px;width:{P.INNER}px;height:{int(grid_h)}px">{grid_html}</div>'
             + (f'<div class="abs legend" style="left:{P.BX + 24}px;top:{712 + 20 + int(grid_h) + 14}px;width:{P.INNER}px;white-space:nowrap">{legend_html}</div>'
                if legend_html else ""))
    panel = (f'<div class="abs" style="left:{P.BX}px;top:712px;width:{P.BW}px;height:{panel_h}px;border-radius:{P.RADIUS}px;'
             f'background:#FFFFFF;border:2px solid {brand.HAIRLINE}"></div>' + inner)
    stats_top = 712 + panel_h + 24
    stat_html = P.stat_blocks(stats, stats_top, 150, brand.LANE["aerobic"])
    best = facts.get("best_run") or {}
    best_html = ""
    if best.get("text"):
        best_top = stats_top + 150 + 24
        best_html = (f'<div class="abs best" style="left:{P.BX}px;top:{best_top}px;width:{P.BW}px;height:{min(1880 - best_top, 240)}px;border-radius:{P.RADIUS}px;'
                     f'background:{brand.tint(brand.LANE["aerobic"])};overflow:hidden"><div class="abs" style="left:0;top:0;width:100%;height:12px;'
                     f'background:{brand.LANE["aerobic"]}"></div><div class="abs cap" style="left:40px;top:34px;font-size:24px;color:{brand.INK_SECONDARY}">BEST RUN</div>'
                     f'<div class="abs" style="left:40px;top:76px;width:{P.BW - 80}px;font-size:42px;line-height:1.18;font-weight:600;text-wrap:pretty">'
                     f'{P.esc(best["text"], 110)}</div></div>')
    css = P.base_css(brand.GROUND, brand.INK, P.W, P.POSTER_H)
    return P.doc(css, P.header(False, P.esc(memory.get("name", ""), 20).upper(), quiet) + block + panel + stat_html + best_html)


def build_monthly_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    runs = list(facts.get("runs") or [])[:MAX_RUNS]
    rows = max(1, -(-len(runs) // COLS))
    cell_w = P.INNER / COLS
    cell_h = min(214.0, 590 / rows)
    cells = []
    for i, r in enumerate(runs):
        col = brand.CARD_TYPE_COLOUR.get(str(r.get("type")), brand.LANE["aerobic"])
        svg = P.route_svg(r.get("route") or [], int(cell_w - 28), int(cell_h - 28), col, 5, "#FFFFFF", pad=8, start_dot=False)
        x, y = (i % COLS) * cell_w, (i // COLS) * cell_h
        cells.append(f'<div class="abs" style="left:{x + 14:.0f}px;top:{y + 14:.0f}px">{svg}</div>')
    return _frame(facts, memory, "".join(cells), cell_h * rows, "", _stats(facts, runs))


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
    return brand.CARD_TYPE_COLOUR.get(str(t), brand.LANE["aerobic"])


def _run_date(r: Mapping[str, Any]) -> date | None:
    try:
        return date.fromisoformat(str(r.get("date"))[:10])
    except ValueError:
        return None


def has_routes(facts: Mapping[str, Any]) -> bool:
    return any(r.get("route") for r in facts.get("runs") or [])


def build_monthly_calendar_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    quiet = brand.QUIET
    runs = [(d, r) for r in facts.get("runs") or [] if (d := _run_date(r)) is not None]
    if facts.get("month_start"):
        first = date.fromisoformat(str(facts["month_start"])[:10]).replace(day=1)
    else:
        first = (min(d for d, _ in runs) if runs else date.today()).replace(day=1)
    days_in = calendar.monthrange(first.year, first.month)[1]
    lead = first.weekday()
    rows = -(-(lead + days_in) // 7)
    cell_w = P.INNER / 7
    row_h = min(118.0, (1330 - 732 - HEAD_H) / rows)
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
                     f'background:{brand.GROUND};border-radius:10px"></div>')
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
                         f'background:{_type_colour(r.get("type"))};border-radius:10px"></div>')
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
    return _frame(facts, memory, "".join(parts), HEAD_H + row_h * rows, "".join(legend), _stats(facts, [r for _, r in runs]))


def render_monthly_poster(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    """Route outlines when the facts carry routes (app-side data); otherwise the calendar of bars."""
    html = build_monthly_html(facts, memory) if has_routes(facts) else build_monthly_calendar_html(facts, memory)
    return render_html(html, P.W, P.POSTER_H)
