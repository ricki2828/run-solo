"""Share image for friends, 9:16 (1080x1920). Whitelist only: a field renders when facts['share'] says so, otherwise it is not in the HTML.

No location of any kind (route shape, place, date and time of day) unless the runner opted in to it.

Two looks, picked by `choose_style`:
  route  the route poster: dark ground, the route glowing in the zone colour of each stretch, one hero number, small stats.
  flood  the zone flood: full-bleed zone colour and a giant number. Used for PBs, races and hard sessions (the same rule as
         the post-run card, `_parts.effort_mode`) and as the fallback whenever the route poster would have nothing to show:
         no route, route not opted in, or a route that is a straight line.
"""
from __future__ import annotations

import functools
from typing import Any, Mapping, Sequence

from .. import brand
from . import _parts as P
from ._engine import render_html
from .post_run import TYPE_WORDS

SW, SH = 1080, 1920
MARGIN = 70                       # side margin; the hero number never goes outside it
BOX_W = SW - 2 * MARGIN
POSTER_BG = "#0B0D10"
MUTED = "#8B939D"
MIN_ASPECT = 0.20                 # a route whose short side is under 20% of its long side is a strip, not a shape
MIN_POINTS = 6


# --- hero number fitting ---------------------------------------------------------------

@functools.lru_cache(maxsize=1)
def _font_path() -> str:
    return str(brand.FONT_DIR / "SairaExtraCondensed-ExtraBold.ttf")


@functools.lru_cache(maxsize=None)
def _unit_width(text: str) -> float:
    """Advance width of `text` in Saira ExtraBold at 1000 px (so width at size s is this * s / 1000)."""
    from PIL import ImageFont
    return float(ImageFont.truetype(_font_path(), 1000).getlength(text.upper()))


def text_width(text: str, size: float) -> float:
    return _unit_width(text) * size / 1000.0


def fit_size(text: str, max_size: int, width: float = BOX_W, extra: float = 0.0) -> int:
    """Largest font size (<= max_size) at which `text` (plus `extra` px beside it) fits `width`, with a 3% safety."""
    unit = _unit_width(text) / 1000.0
    if unit <= 0:
        return max_size
    return max(24, min(max_size, int((width * 0.97 - extra) / unit)))


# --- route -----------------------------------------------------------------------------

def _route_points(facts: Mapping[str, Any], w: int, h: int, pad: float) -> list[tuple[float, float]]:
    """The run's route fitted into w x h, smoothed. [] when the facts carry none or it is not a shape worth drawing."""
    if facts.get("route_xy"):
        raw, planar = facts["route_xy"], True
    elif facts.get("route"):
        raw, planar = facts["route"], False
    else:
        return []
    pts = P.project_route(P.collapse_out_and_back(raw, planar), w, h, pad, planar=planar)
    if len(pts) < MIN_POINTS:
        return []
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    sx, sy = max(xs) - min(xs), max(ys) - min(ys)
    if min(sx, sy) < MIN_ASPECT * max(sx, sy, 1e-9):
        return []
    return P._chaikin(pts)


def route_usable(facts: Mapping[str, Any]) -> bool:
    """Route opted in AND a real shape (not absent, not a straight out-and-back line)."""
    s = facts.get("share") or {}
    return bool(s.get("route")) and bool(_route_points(facts, 1000, 1000, 0))


def choose_style(facts: Mapping[str, Any]) -> str:
    """'route' for an everyday run with a drawable, opted-in route; 'flood' for PB, race, hard sessions and anything without a route."""
    if P.effort_mode(facts)[0] == "flood":
        return "flood"
    return "route" if route_usable(facts) else "flood"


def _zone_at(splits: Sequence[Mapping[str, Any]], t: float, fallback: int) -> int:
    total = sum(float(s["km"]) for s in splits) or 1.0
    acc = 0.0
    for s in splits:
        acc += float(s["km"])
        if t <= acc / total:
            return int(s["zone"])
    return int(splits[-1]["zone"]) if splits else fallback


def _route_svg(facts: Mapping[str, Any], w: int, h: int, pad: float, stroke: float, glow: bool, mono: str | None = None) -> str:
    pts = _route_points(facts, w, h, pad)
    if not pts:
        return ""
    n = len(pts)
    splits = facts.get("splits") or []
    base_zone = P.effort_mode(facts)[1]
    step = max(1, n // 90)
    idx = list(range(0, n - 1, step)) + [n - 1]
    segs = []
    for a, b in zip(idx, idx[1:]):
        z = _zone_at(splits, (a + b) / 2 / (n - 1), base_zone) if splits else base_zone
        d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts[a:b + 1])
        segs.append((d, mono or brand.ZONE_RAMP[max(1, min(5, z)) - 1]))
    halo = ""
    if glow:
        halo = '<g filter="url(#gl)" opacity=".85">' + "".join(
            f'<path d="{d}" stroke="{c}" stroke-width="{stroke * 1.7:.1f}" stroke-linecap="round" fill="none"/>' for d, c in segs) + "</g>"
    body = "".join(f'<path d="{d}" stroke="{c}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round" fill="none"/>' for d, c in segs)
    dot = f'<circle cx="{pts[0][0]:.1f}" cy="{pts[0][1]:.1f}" r="{stroke * .9:.1f}" fill="#fff"/>' if glow else ""
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}"><defs><filter id="gl" x="-20%" y="-20%" width="140%" height="140%">'
            f'<feGaussianBlur stdDeviation="{stroke * 1.4:.1f}"/></filter></defs>{halo}{body}{dot}</svg>')


# --- what the card says ----------------------------------------------------------------

TIME_PBS = ("5k", "10k", "half")   # a longest run is its distance, and the run's time is not a fastest km's time


def hero(facts: Mapping[str, Any], s: Mapping[str, Any]) -> tuple[str, str]:
    """(value, unit). A distance PB leads with its time when the runner shares time; otherwise distance."""
    if facts.get("pb") in TIME_PBS and s.get("time") and facts.get("duration_s"):
        return P.fmt_dur(float(facts["duration_s"])), f"{P.fmt_km(float(facts['distance_km']))} KM"
    return P.fmt_km(float(facts["distance_km"])), "KM"


def _stats(facts: Mapping[str, Any], s: Mapping[str, Any], hero_is_time: bool) -> list[tuple[str, str]]:
    stats: list[tuple[str, str]] = []
    reps = facts.get("reps")
    if reps and s.get("reps"):  # intervals: reps replace the session's average pace, which says little
        stats.append((str(len(reps)), "REPS"))
        if facts.get("work_pace_s_per_km"):
            stats.append((P.fmt_pace(float(facts["work_pace_s_per_km"])), "/KM WORK"))
        else:
            stats.append((P.fmt_dur(float(min(r["time_s"] for r in reps))), "BEST REP"))
    if s.get("time") and not hero_is_time:
        stats.append((P.fmt_dur(float(facts["duration_s"])), "TIME"))
    if s.get("pace", True) and facts.get("pace_s_per_km") and not reps:
        stats.append((P.fmt_pace(float(facts["pace_s_per_km"])), "/KM"))
    if s.get("hr") and facts.get("avg_hr"):
        stats.append((P.thousands(facts["avg_hr"]), "BPM"))
    if s.get("climb") and facts.get("climb_m"):
        stats.append((P.thousands(facts["climb_m"]) + " M", "CLIMB"))
    return stats[:3]


def _label(facts: Mapping[str, Any], s: Mapping[str, Any]) -> str:
    """The small line above the number. A run's title can be a place, so it shows only with the place opt-in."""
    if facts.get("pb"):
        detail = facts.get("pb_detail") or {}
        return P.esc(detail.get("label") or "PERSONAL BEST", 30)
    if s.get("place"):
        label = P.esc(facts.get("title", "Run"), 30)
        if facts.get("place_note"):
            label += f" / {P.esc(facts['place_note'], 30)}"
        return label
    return P.esc(TYPE_WORDS.get(str(facts.get("type")), "Run"), 30)


def _stat_row(stats: Sequence[tuple[str, str]], size: int, cap: int, colour_cap: str) -> str:
    return "".join(f'<div><div class="saira" style="font-size:{size}px;line-height:1">{P.esc(v, 12)}</div>'
                   f'<div class="cap" style="font-size:{cap}px;color:{colour_cap};margin-top:8px">{P.esc(l, 12)}</div></div>' for v, l in stats)


def _who_when(memory: Mapping[str, Any], s: Mapping[str, Any], facts: Mapping[str, Any]) -> str:
    who = P.esc(memory.get("name", ""), 20).upper() if s.get("name") else ""
    when = P.date_label(facts.get("start_local")) if s.get("date") else ""
    return " / ".join(x for x in (who, when) if x)


# --- the two looks ---------------------------------------------------------------------

def _poster_html(facts: Mapping[str, Any], memory: Mapping[str, Any], s: Mapping[str, Any]) -> str:
    hv, hu = hero(facts, s)
    stats = _stats(facts, s, bool(facts.get("pb") and hv != P.fmt_km(float(facts["distance_km"]))))
    zone = P.effort_mode(facts)[1]
    rh = int(SH * .52)
    svg = _route_svg(facts, SW, rh, 110, 26, glow=True)
    fs = fit_size(hv, 330, extra=text_width(hu, 330 // 4) + 14 if hu else 0)
    css = P.base_css(POSTER_BG, "#fff", SW, SH) + (
        f".bgd{{position:absolute;inset:0;background:radial-gradient(ellipse at 50% 30%,{brand.flood_for_zone(zone)}66 0%,transparent 60%)}}")
    top = _who_when(memory, s, facts)
    unit = f'<span class="saira" style="font-size:{fs // 4}px;margin-left:14px">{P.esc(hu, 14)}</span>' if hu else ""
    body = f"""<div class="bgd"></div>
<div class="abs" style="left:0;top:{int(SH * .07)}px">{svg}</div>
<div class="abs saira" style="left:{MARGIN}px;top:70px;font-size:34px;letter-spacing:.12em;color:{MUTED}">{_label(facts, s)}</div>
<div class="abs cap" style="right:{MARGIN}px;top:76px;font-size:26px;color:{MUTED}">{top}</div>
<div class="abs" style="left:{MARGIN}px;right:{MARGIN}px;top:{int(SH * .60)}px;line-height:.8;white-space:nowrap"><span class="saira" style="font-size:{fs}px">{P.esc(hv, 10)}</span>{unit}</div>
<div class="abs" style="left:{MARGIN}px;right:{MARGIN}px;bottom:{int(SH * .075)}px;display:flex;justify-content:space-between;align-items:flex-end">
 <div style="display:flex;gap:70px">{_stat_row(stats, 86, 26, MUTED)}</div><div>{brand.mark_svg('on-dark', 64)}</div></div>"""
    return P.doc(css, body)


def _flood_html(facts: Mapping[str, Any], memory: Mapping[str, Any], s: Mapping[str, Any]) -> str:
    hv, hu = hero(facts, s)
    stats = _stats(facts, s, bool(facts.get("pb") and hv != P.fmt_km(float(facts["distance_km"]))))
    ground = brand.flood_for_zone(P.effort_mode(facts)[1])
    pb = bool(facts.get("pb"))
    herocol = brand.ARC if pb else brand.BONE
    fs = fit_size(hv, 820)
    ghost = ""
    if s.get("route"):
        ghost = f'<div class="abs" style="left:0;top:0">{_route_svg(facts, SW, SH, 90, 16, glow=False, mono=brand.tint(brand.BONE, .16, ground))}</div>'
    unit = (f'<div class="saira" style="font-size:{min(fs // 5, 160)}px;margin-top:20px;color:{herocol}">{P.esc(hu, 14)}</div>' if hu else "")
    css = P.base_css(ground, brand.BONE, SW, SH)
    body = f"""{ghost}
<div class="abs saira" style="left:{MARGIN}px;top:70px;font-size:40px;letter-spacing:.14em">{_label(facts, s)}</div>
<div class="abs cap" style="right:{MARGIN}px;top:78px;font-size:26px;opacity:.8">{_who_when(memory, s, facts)}</div>
<div class="abs" style="left:{MARGIN}px;right:{MARGIN}px;top:{int(SH * .17)}px;line-height:.78;white-space:nowrap"><div class="saira" style="font-size:{fs}px;color:{herocol}">{P.esc(hv, 10)}</div>{unit}</div>
<div class="abs" style="left:{MARGIN}px;right:{MARGIN}px;bottom:{int(SH * .08)}px;display:flex;justify-content:space-between;align-items:flex-end">
 <div style="display:flex;gap:56px">{_stat_row(stats, 100, 26, "rgba(237,234,227,.75)")}</div><div>{brand.mark_svg('mono-white', 64)}</div></div>"""
    return P.doc(css, body)


def build_share_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    s = facts.get("share") or {}
    # a runner's own route only ever reaches the page with the route opt-in: strip it from the facts otherwise
    if not s.get("route"):
        facts = {k: v for k, v in facts.items() if k not in ("route", "route_xy")}
    return _poster_html(facts, memory, s) if choose_style(facts) == "route" else _flood_html(facts, memory, s)


def render_share_card(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_share_html(facts, memory), SW, SH)
