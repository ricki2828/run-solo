"""Shared building blocks: base CSS, route polyline, zone strip, formatting, escaping."""
from __future__ import annotations

import html
import math
from typing import Any, Mapping, Sequence

from .. import brand

W, H = 1080, 1350
POSTER_H = 1920
PAD = 72


def esc(v: Any, limit: int = 80) -> str:
    s = "" if v is None else str(v)
    if len(s) > limit:
        s = s[: limit - 1].rstrip() + "."
    return html.escape(s, quote=True)


def fmt_pace(s: float) -> str:
    t = int(round(s))
    return f"{t // 60}:{t % 60:02d}"


def fmt_dur(s: float) -> str:
    t = int(round(s))
    h, m, sec = t // 3600, (t % 3600) // 60, t % 60
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def fmt_km(km: float) -> str:
    return f"{km:.1f}"


def thousands(n: float) -> str:
    return f"{int(round(n)):,}"


def base_css(bg: str, fg: str, width: int = W, height: int = H) -> str:
    return f"""{brand.font_css()}
*{{box-sizing:border-box;margin:0;padding:0}}
html,body{{width:{width}px;height:{height}px;overflow:hidden}}
body{{background:{bg};color:{fg};font-family:'{brand.SCHIBSTED}',sans-serif;position:relative}}
.saira{{font-family:'{brand.SAIRA}',sans-serif;font-weight:800;text-transform:uppercase}}
.cap{{text-transform:uppercase;letter-spacing:.09em;font-weight:600}}
.abs{{position:absolute}}
"""


def doc(css: str, body: str) -> str:
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{body}</body></html>"


# --- zones -----------------------------------------------------------------------------

def zone_seconds(facts: Mapping[str, Any]) -> list[float]:
    z = facts.get("zone_s") or []
    out = [max(0.0, float(x)) for x in z][:5]
    return out + [0.0] * (5 - len(out))


def effort_mode(facts: Mapping[str, Any]) -> tuple[str, int]:
    """('flood'|'light', zone 1..5). Flood for intervals, tempo, races, PBs and Z4/Z5-dominant runs."""
    z = zone_seconds(facts)
    total = sum(z)
    hard_share = (z[3] + z[4]) / total if total else 0.0
    hard_type = facts.get("type") in ("interval", "tempo", "race")
    flood = bool(facts.get("pb")) or hard_type or hard_share >= 0.4
    if not total:
        return ("flood", 4) if flood else ("light", 2)
    if facts.get("type") == "interval" or hard_type:
        zone = max((i + 1 for i in range(5) if z[i] / total >= 0.10), default=4)
        zone = max(zone, 4) if flood and facts.get("type") in ("interval", "race") else zone
    else:
        zone = max(range(5), key=lambda i: z[i]) + 1
        if flood:
            zone = max(zone, 4)
    return ("flood" if flood else "light", zone)


def zone_strip(z: Sequence[float], width: int, height: int, gap: int = 4, radius: int = 0, stroke: str | None = None) -> str:
    total = sum(z)
    if not total:
        return ""
    x = 0.0
    avail = width - gap * (sum(1 for v in z if v > 0) - 1)
    rects = []
    for i, v in enumerate(z):
        if v <= 0:
            continue
        w = avail * v / total
        st = f' stroke="{stroke}" stroke-width="2"' if stroke else ""
        rects.append(f'<rect x="{x:.1f}" y="0" width="{w:.1f}" height="{height}" rx="{radius}" fill="{brand.ZONE_RAMP[i]}"{st}/>')
        x += w + gap
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(rects)}</svg>'


# --- route -----------------------------------------------------------------------------

def _dp(points: list[tuple[float, float]], eps: float) -> list[tuple[float, float]]:
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = math.hypot(dx, dy)
    best, idx = -1.0, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        d = abs(dy * px - dx * py + x2 * y1 - y2 * x1) / norm if norm else math.hypot(px - x1, py - y1)
        if d > best:
            best, idx = d, i
    if best <= eps:
        return [points[0], points[-1]]
    return _dp(points[: idx + 1], eps)[:-1] + _dp(points[idx:], eps)


def project_route(route: Sequence[Sequence[float]], width: float, height: float, pad: float = 0.0,
                  max_points: int = 140, planar: bool = False) -> list[tuple[float, float]]:
    """[lat, lon] pairs -> simplified x,y fitted into the box, aspect preserved, north up. With `planar` the points
    are already x,y on a shape grid (the app's normalised route, y down): no projection, nothing flipped."""
    pts = [(float(p[0]), float(p[1])) for p in route if len(p) >= 2]
    if len(pts) < 2:
        return []
    if planar:
        xy = pts
    else:
        lat0 = sum(p[0] for p in pts) / len(pts)
        k = math.cos(math.radians(lat0))
        xy = [(lon * k, -lat) for lat, lon in pts]
    minx, maxx = min(p[0] for p in xy), max(p[0] for p in xy)
    miny, maxy = min(p[1] for p in xy), max(p[1] for p in xy)
    span = max(maxx - minx, maxy - miny, 1e-9)
    eps = span * 0.012 if planar else max(8 / 110540.0, span * 0.012)  # about 8 m, or 1.2% of the span for a long route
    simp = _dp(xy, eps)
    while len(simp) > max_points:
        eps *= 1.4
        simp = _dp(xy, eps)
    sx, sy = maxx - minx, maxy - miny
    scale = min((width - 2 * pad) / max(sx, 1e-9), (height - 2 * pad) / max(sy, 1e-9))
    ox = (width - sx * scale) / 2
    oy = (height - sy * scale) / 2
    return [(ox + (x - minx) * scale, oy + (y - miny) * scale) for x, y in simp]


def _chaikin(pts: list[tuple[float, float]], rounds: int = 3) -> list[tuple[float, float]]:
    span = max(max(x for x, _ in pts) - min(x for x, _ in pts), max(y for _, y in pts) - min(y for _, y in pts), 1e-9)
    if math.hypot(pts[0][0] - pts[-1][0], pts[0][1] - pts[-1][1]) < 0.04 * span:  # a loop: smooth around the join
        ring = pts[:-1]
        for _ in range(rounds):
            nxt = []
            for i, (x1, y1) in enumerate(ring):
                x2, y2 = ring[(i + 1) % len(ring)]
                nxt += [(0.75 * x1 + 0.25 * x2, 0.75 * y1 + 0.25 * y2), (0.25 * x1 + 0.75 * x2, 0.25 * y1 + 0.75 * y2)]
            ring = nxt
        return ring + [ring[0]]
    for _ in range(rounds):
        out = [pts[0]]
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            out += [(0.75 * x1 + 0.25 * x2, 0.75 * y1 + 0.25 * y2), (0.25 * x1 + 0.75 * x2, 0.25 * y1 + 0.75 * y2)]
        out.append(pts[-1])
        pts = out
    return pts


def collapse_out_and_back(route: Sequence[Sequence[float]], planar: bool = False) -> Sequence[Sequence[float]]:
    """If the way back retraces the way out (within ~6% of the route's span), keep the way out only."""
    n = len(route)
    if n < 8:
        return route
    if planar:
        xy = [(p[0], p[1]) for p in route]
    else:
        lat0 = sum(p[0] for p in route) / n
        k = math.cos(math.radians(lat0))
        xy = [(p[1] * k, p[0]) for p in route]
    span = max(max(x for x, _ in xy) - min(x for x, _ in xy), max(y for _, y in xy) - min(y for _, y in xy), 1e-9)
    half = n // 2
    mean = sum(math.hypot(xy[i][0] - xy[n - 1 - i][0], xy[i][1] - xy[n - 1 - i][1]) for i in range(half)) / half
    return route[: half + 1] if mean < 0.06 * span else route


def route_svg(route: Sequence[Sequence[float]], width: int, height: int, colour: str, stroke: float,
              dot_ring: str, pad: float = 24, start_dot: bool = True, end_dot: bool = False,
              planar: bool = False) -> str:
    pts = project_route(collapse_out_and_back(route, planar), width, height, pad, planar=planar)
    if not pts:
        return ""
    if len(pts) > 2:
        pts = _chaikin(pts)
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    r = stroke * 1.15
    dots = ""
    if start_dot:
        dots += f'<circle cx="{pts[0][0]:.1f}" cy="{pts[0][1]:.1f}" r="{r:.1f}" fill="{colour}" stroke="{dot_ring}" stroke-width="{stroke * .45:.1f}"/>'
    if end_dot:
        dots += f'<circle cx="{pts[-1][0]:.1f}" cy="{pts[-1][1]:.1f}" r="{r:.1f}" fill="{dot_ring}" stroke="{colour}" stroke-width="{stroke * .6:.1f}"/>'
    return (f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}" fill="none">'
            f'<path d="{d}" stroke="{colour}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"/>{dots}</svg>')


def facts_route_svg(facts: Mapping[str, Any], width: int, height: int, colour: str, stroke: float, dot_ring: str,
                    pad: float = 24, start_dot: bool = True, end_dot: bool = False) -> str:
    """The run's route for a card: the app's shape (`route_xy`, a unit-box outline) when the facts carry it, else
    `route` (lat/lon, local fixtures and previews only: the worker's protocol never lets coordinates in)."""
    if facts.get("route_xy"):
        return route_svg(facts["route_xy"], width, height, colour, stroke, dot_ring, pad, start_dot, end_dot, planar=True)
    return route_svg(facts.get("route") or [], width, height, colour, stroke, dot_ring, pad, start_dot, end_dot)


def date_label(iso: str | None) -> str:
    if not iso:
        return ""
    from datetime import datetime
    try:
        d = datetime.fromisoformat(str(iso).replace("Z", ""))
    except ValueError:
        return ""
    return d.strftime("%a %-d %b").upper()


def _sun() -> str:
    rays = "".join(
        f'<line x1="{24 + 14 * math.cos(a):.1f}" y1="{24 + 14 * math.sin(a):.1f}" x2="{24 + 21 * math.cos(a):.1f}" '
        f'y2="{24 + 21 * math.sin(a):.1f}" stroke="{{c}}" stroke-width="3.5" stroke-linecap="round"/>'
        for a in [i * math.pi / 4 for i in range(8)])
    return '<circle cx="24" cy="24" r="8.5" fill="{c}"/>' + rays


WEATHER_ICON = {
    "sun": _sun(),
    "cloud": '<path d="M14 34h21a8 8 0 0 0 .8-16A11 11 0 0 0 14.5 20 7 7 0 0 0 14 34Z" fill="{c}"/>',
    "rain": '<path d="M14 28h21a8 8 0 0 0 .8-16A11 11 0 0 0 14.5 14 7 7 0 0 0 14 28Z" fill="{c}"/>'
            '<path d="M17 34l-3 8M25 34l-3 8M33 34l-3 8" stroke="{c}" stroke-width="3.5" stroke-linecap="round"/>',
}


def weather_chip(w: Mapping[str, Any] | None, fg: str, line: str, size: int = 34) -> str:
    if not w:
        return ""
    icon = WEATHER_ICON.get(str(w.get("icon")), WEATHER_ICON["cloud"]).replace("{c}", fg)
    temp = f"{round(float(w['temp_c']))}°" if w.get("temp_c") is not None else ""
    label = esc(w.get("label", ""), 24)
    return (f'<div style="display:inline-flex;align-items:center;gap:14px;border:2px solid {line};border-radius:999px;'
            f'padding:10px 26px 10px 16px;font-size:{size}px;font-weight:600;color:{fg}">'
            f'<svg width="48" height="48" viewBox="0 0 48 48">{icon}</svg><span class="saira" style="font-size:{size + 12}px">{esc(temp)}</span>'
            f'<span>{label}</span></div>')


def header(dark: bool, right: str, quiet: str, mark_h: int = 72) -> str:
    """Mark top-left, small caps label top-right. Absolute-positioned; the page supplies .mark and .when css."""
    mark = brand.mark_svg("on-dark" if dark else "on-light", mark_h)
    return (f'<div class="abs" style="left:{PAD}px;top:60px">{mark}</div>'
            f'<div class="abs cap" style="right:{PAD}px;top:82px;font-size:26px;color:{quiet}">{esc(right, 40)}</div>')


def signed(n: float, unit: str = "") -> str:
    sign = "+" if n > 0 else ("−" if n < 0 else "")
    return f"{sign}{abs(int(round(n)))}{unit}"


def wordmark_svg(variant: str, height: int) -> str:
    s = (brand.BRAND_SVG_DIR / f"wordmark-{variant}.svg").read_text()
    import re
    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', s)
    ratio = float(m.group(1)) / float(m.group(2)) if m else 4.0
    return re.sub(r'width="[\d.]+" height="[\d.]+"', f'width="{round(height * ratio)}" height="{height}"', s, count=1)


def split_bars(items: Sequence[tuple[float, int, str]], width: int, height: int, label_colour: str) -> str:
    """Bars for splits or reps: (pace or time in s, zone 1..5, label). Faster is taller; colour is the zone."""
    if not items:
        return ""
    vals = [v for v, _, _ in items]
    lo, hi = min(vals), max(vals)
    n = len(items)
    gap = 10 if n <= 12 else 5
    bw = (width - gap * (n - 1)) / n
    label_h = 34 if n <= 16 else 0
    plot = height - label_h
    out = []
    for i, (v, zone, label) in enumerate(items):
        frac = 0.55 if hi == lo else 0.30 + 0.70 * (hi - v) / (hi - lo)
        h = plot * frac
        x = i * (bw + gap)
        out.append(f'<rect x="{x:.1f}" y="{plot - h:.1f}" width="{bw:.1f}" height="{h:.1f}" fill="{brand.ZONE_RAMP[max(1, min(5, zone)) - 1]}"/>')
        if label_h:
            out.append(f'<text x="{x + bw / 2:.1f}" y="{height - 6}" text-anchor="middle" font-family="{brand.SCHIBSTED}" '
                       f'font-weight="600" font-size="22" fill="{label_colour}">{esc(label, 4)}</text>')
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(out)}</svg>'


def bar_items(facts: Mapping[str, Any]) -> list[tuple[float, int, str]]:
    """Reps when the run has them, otherwise per-km splits."""
    reps = facts.get("reps")
    if reps:
        return [(float(r["time_s"]), int(r.get("zone", 4)), str(i + 1)) for i, r in enumerate(reps)]
    return [(float(s["pace_s"]), int(s.get("zone", 3)), str(i + 1)) for i, s in enumerate(facts.get("splits") or [])]


def zone_block(z: Sequence[float], width: int, fg: str, quiet: str, bg: str, flood: bool, bar_h: int = 130) -> str:
    """The zone bar as the card's main visual: a tall proportional bar and a minutes figure under each zone."""
    if not sum(z):
        return ""
    bar = zone_strip(z, width, bar_h, gap=4, radius=0 if flood else 6, stroke=bg if flood else None)
    col_w = width / 5
    cols = "".join(
        f'<div style="width:{col_w:.0f}px"><div style="display:flex;align-items:center;gap:10px">'
        f'<span style="width:18px;height:18px;border-radius:3px;background:{brand.ZONE_RAMP[i]};display:inline-block"></span>'
        f'<span class="cap" style="font-size:22px;color:{quiet}">Z{i + 1}</span></div>'
        f'<div class="saira" style="font-size:64px;line-height:1.05;color:{fg}">{round(v / 60)}'
        f'<span class="cap" style="font-size:22px;margin-left:8px;color:{quiet}">MIN</span></div></div>'
        for i, v in enumerate(z))
    return f'{bar}<div style="display:flex;margin-top:{28 if bar_h > 100 else 18}px">{cols}</div>'


# --- direction B blocks ------------------------------------------------------------------
# Light ground, one violet hero block, lane-tinted blocks, rounded corners (12-Oct-2026).

BX = 48                 # block left edge; blocks are W - 2 * BX wide
BW = W - 2 * BX
RADIUS = 44
INNER = BW - 2 * 24     # a visual that sits inside a panel with 24 px padding


def hero_block(top: int, height: int, *, tag: str, headline: str, value: str, unit: str, size: int,
               value_colour: str | None = None, unit_colour: str | None = None, chip: str = "",
               extra: str = "", headline_size: int = 96, overlay: str = "", pad_bottom: int = 30,
               ground: str = brand.VIOLET, fg: str = brand.ON_VIOLET, soft: str = brand.ON_VIOLET_SOFT,
               chip_bg: str = brand.VIOLET_PANEL) -> str:
    """The big hero block: violet by default (pack, milestone), or the card's own colour (zone flood, lane colour). `tag`, `headline`, `unit` and `extra` are already-escaped HTML."""
    value_colour = value_colour or fg
    unit_colour = unit_colour or soft
    extra_line = (f'<div style="margin-top:14px;font-size:38px;line-height:1.15;font-weight:600;font-family:\'{brand.SCHIBSTED}\',sans-serif;'
                  f'text-transform:none;letter-spacing:0;color:{soft}">{extra}</div>') if extra else ""
    # the gain line sits under the headline in the same column, so a long hero (1:45:12) can never run into it
    head = (f'<div class="abs saira head" style="left:40px;top:92px;width:{BW - 80}px;font-size:{headline_size}px;'
            f'line-height:.92;color:{fg};text-wrap:balance">{headline}{extra_line}</div>') if (headline or extra) else ""
    chip_html = (f'<div class="abs cap" style="right:36px;top:30px;padding:8px 22px;border-radius:999px;font-size:24px;'
                 f'background:{chip_bg};color:{fg}">{chip}</div>') if chip else ""
    return (f'<div class="abs hero" style="left:{BX}px;top:{top}px;width:{BW}px;height:{height}px;border-radius:{RADIUS}px;'
            f'background:{ground};overflow:hidden">'
            f'<div class="abs cap tag" style="left:40px;top:36px;font-size:28px;letter-spacing:.14em;color:{soft}">{tag}</div>'
            f'{chip_html}{head}'
            f'<div class="abs" style="left:32px;bottom:{pad_bottom}px;display:flex;align-items:baseline;gap:20px;white-space:nowrap">'
            f'<span class="saira n" style="font-size:{size}px;line-height:.78;color:{value_colour}">{value}</span>'
            f'<span class="saira u" style="font-size:64px;color:{unit_colour}">{unit}</span></div>'
            f'{overlay}</div>')


def panel(top: int, height: int, inner: str, colour: str | None = None, cls: str = "") -> str:
    """A rounded block holding a visual: lane-tinted when given a lane colour, else white with a hairline."""
    bg = brand.tint(colour) if colour else "#FFFFFF"
    edge = "none" if colour else f"2px solid {brand.HAIRLINE}"
    return (f'<div class="abs {cls}" style="left:{BX}px;top:{top}px;width:{BW}px;height:{height}px;border-radius:{RADIUS}px;'
            f'background:{bg};border:{edge};overflow:hidden"><div class="abs" style="left:24px;top:0;width:{INNER}px;'
            f'height:{height}px;display:flex;align-items:center">{inner}</div></div>')


def stat_blocks(stats: Sequence[tuple[str, str]], top: int, height: int, colour: str, gap: int = 16) -> str:
    """A row of lane-tinted blocks, one number each, the lane colour as a bar across the top."""
    if not stats:
        return ""
    n = len(stats)
    size = 84 if n <= 3 else 60
    items = "".join(
        f'<div style="flex:1;min-width:0;position:relative;border-radius:34px;overflow:hidden;background:{brand.tint(colour)};'
        f'padding:30px 22px 0 26px"><div style="position:absolute;left:0;top:0;width:100%;height:12px;background:{colour}"></div>'
        f'<div class="saira" style="font-size:{size}px;line-height:1;color:{brand.INK};white-space:nowrap">{esc(v)}</div>'
        f'<div class="cap" style="font-size:22px;margin-top:6px;color:{brand.INK_SECONDARY};white-space:nowrap">{esc(l)}</div></div>'
        for v, l in stats)
    return (f'<div class="abs stats" style="left:{BX}px;top:{top}px;width:{BW}px;height:{height}px;display:flex;gap:{gap}px">'
            f'{items}</div>')


def run_layout(*, tag: str, headline: str, value: str, unit: str, colour: str, visual: str, strip: str,
               stats: Sequence[tuple[str, str]], value_colour: str | None = None, chip: str = "",
               extra: str = "", headline_size: int = 96, unit_colour: str | None = None,
               ground: str = brand.VIOLET, fg: str = brand.ON_VIOLET, soft: str = brand.ON_VIOLET_SOFT,
               chip_bg: str = brand.VIOLET_PANEL, moment: bool = False) -> str:
    """Post-run, PB and share cards: a hero block (zone flood, lane colour or violet), a lane-tinted visual panel, a thin
    zone strip, stat blocks. A `moment` (hard session, PB) gets the number at full size and a shorter panel.
    With no visual the hero block takes the space."""
    top = 168
    look = dict(tag=tag, headline=headline, value=value, unit=unit, value_colour=value_colour, unit_colour=unit_colour, chip=chip,
                extra=extra, headline_size=headline_size, ground=ground, fg=fg, soft=soft, chip_bg=chip_bg)
    if visual and moment:
        out = hero_block(top, 620, size=380, **look)
        out += panel(812, 240, visual, colour, "visual")
        if strip:
            out += f'<div class="abs strip" style="left:{PAD}px;top:1068px">{strip}</div>'
    elif visual:
        out = hero_block(top, 520, size=250, **look)
        out += panel(712, 330, visual, colour, "visual")
        if strip:
            out += f'<div class="abs strip" style="left:{PAD}px;top:1062px">{strip}</div>'
    else:
        out = hero_block(top, 920 if stats else 1120, size=520, **look)
    return out + stat_blocks(stats, 1104, 170, colour)
