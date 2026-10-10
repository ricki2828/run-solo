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
                  max_points: int = 140) -> list[tuple[float, float]]:
    """[lat, lon] pairs -> simplified x,y fitted into the box, aspect preserved, north up."""
    pts = [(float(p[0]), float(p[1])) for p in route if len(p) >= 2]
    if len(pts) < 2:
        return []
    lat0 = sum(p[0] for p in pts) / len(pts)
    k = math.cos(math.radians(lat0))
    xy = [(lon * k, -lat) for lat, lon in pts]
    minx, maxx = min(p[0] for p in xy), max(p[0] for p in xy)
    miny, maxy = min(p[1] for p in xy), max(p[1] for p in xy)
    span = max(maxx - minx, maxy - miny, 1e-9)
    eps = max(8 / 110540.0, span * 0.012)  # about 8 m, or 1.2% of the span for a long route
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


def collapse_out_and_back(route: Sequence[Sequence[float]]) -> Sequence[Sequence[float]]:
    """If the way back retraces the way out (within ~6% of the route's span), keep the way out only."""
    n = len(route)
    if n < 8:
        return route
    lat0 = sum(p[0] for p in route) / n
    k = math.cos(math.radians(lat0))
    xy = [(p[1] * k, p[0]) for p in route]
    span = max(max(x for x, _ in xy) - min(x for x, _ in xy), max(y for _, y in xy) - min(y for _, y in xy), 1e-9)
    half = n // 2
    mean = sum(math.hypot(xy[i][0] - xy[n - 1 - i][0], xy[i][1] - xy[n - 1 - i][1]) for i in range(half)) / half
    return route[: half + 1] if mean < 0.06 * span else route


def route_svg(route: Sequence[Sequence[float]], width: int, height: int, colour: str, stroke: float,
              dot_ring: str, pad: float = 24, start_dot: bool = True, end_dot: bool = False) -> str:
    pts = project_route(collapse_out_and_back(route), width, height, pad)
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
