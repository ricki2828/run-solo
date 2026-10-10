"""Monthly poster, 1080x1920: route shapes as small multiples, the month's km as the hero, the best run."""
from __future__ import annotations

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


def render_monthly_poster(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_monthly_html(facts, memory), P.W, P.POSTER_H)
