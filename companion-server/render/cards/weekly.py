"""Weekly recap, direction B: an aerobic-green hero block, day bars on a white panel, lane blocks for the score moves. The week's km as the hero, day bars in km, coloured by zone share of time, the score moves, the best moment."""
from __future__ import annotations

from datetime import date
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


def _type_colour(d: Mapping[str, Any]) -> str:
    return brand.CARD_TYPE_COLOUR.get(str(d.get("type")), brand.LANE["aerobic"])


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
            else:  # a run with no heart-rate zones: still a km bar, in its run-type colour
                y -= full
                parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(full - 2, 1):.1f}" fill="{_type_colour(d)}"/>')
            parts.append(f'<text x="{x + bw / 2:.1f}" y="{y - 10:.1f}" text-anchor="middle" font-family="{brand.SAIRA}" '
                         f'font-weight="800" font-size="32" fill="{brand.INK}">{P.fmt_km(km)}</text>')
        else:
            parts.append(f'<rect x="{x:.1f}" y="{height - 58:.1f}" width="{bw:.1f}" height="6" fill="{brand.HAIRLINE}"/>')
        parts.append(f'<text x="{x + bw / 2:.1f}" y="{height - 10}" text-anchor="middle" font-family="{brand.SCHIBSTED}" '
                     f'font-weight="600" font-size="24" letter-spacing="2" fill="{brand.QUIET}">{DAYS[i]}</text>')
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(parts)}</svg>'


AMBER = brand.ZONE_RAMP[2]   # the big-jump outline: a warning, never vermillion (that is "slower")


def _load_words(facts: Mapping[str, Any]) -> str:
    """The same words as the app's weekly story: a band and a percent, never a ratio."""
    band, pct, load, usual = facts.get("band"), int(facts.get("pct") or 0), facts.get("load") or 0, facts.get("usual_load") or 0
    if band == "usual":
        return "About your usual week"
    if band == "lighter":
        return f"{pct}% less than your usual week"
    return "About double your usual week" if usual and load / usual >= 1.9 else f"{pct}% more than your usual week"


def _week_label(iso_day: Any) -> str:
    try:
        d = date.fromisoformat(str(iso_day))
    except ValueError:
        return ""
    return f"{d.day} {d.strftime('%b').upper()}"


def _load_bars(facts: Mapping[str, Any], width: int, height: int) -> str:
    """Six weeks of load, oldest first, the last one this week. Bar height is load; each bar is split by the share of
    that week's load that came from each heart-rate zone, and the part with no heart rate is the easy-run colour. A
    paused week is a hairline stub. The dashed line is the usual week."""
    weeks = list(facts.get("weeks") or [])[-6:]
    usual = float(facts.get("usual_load") or 0)
    gutter = 236   # room on the right for the usual label
    base, top = height - 40, 24
    room = base - top
    peak = max([float(w.get("load") or 0) for w in weeks if not w.get("paused")] + [usual, 1.0])
    slot = (width - gutter) / max(len(weeks), 1)
    bw = slot * 0.62
    parts = []
    for i, w in enumerate(weeks):
        x = i * slot + (slot - bw) / 2
        cx = x + bw / 2
        this = i == len(weeks) - 1
        if w.get("paused"):
            parts.append(f'<rect x="{x:.1f}" y="{base - 6}" width="{bw:.1f}" height="6" fill="{brand.HAIRLINE}"/>')
            parts.append(f'<text x="{cx:.1f}" y="{base - 16}" text-anchor="middle" font-family="{brand.SCHIBSTED}" font-weight="600" '
                         f'font-size="18" letter-spacing="1" fill="{brand.QUIET}">PAUSED</text>')
        else:
            h = max(room * float(w.get("load") or 0) / peak, 4 if w.get("load") else 0)
            if h:
                y = base
                zones = [float(v) for v in (w.get("zone_share") or [])][:5] + [0.0] * 5
                segs = [(brand.ZONE_RAMP[k], zones[k]) for k in range(5)] + [(brand.CARD_TYPE_COLOUR["easy"], float(w.get("nohr_share") or 0))]
                for colour, sh in segs:
                    if sh <= 0:
                        continue
                    sh_h = h * sh
                    y -= sh_h
                    parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(sh_h, 1):.1f}" fill="{colour}"/>')
                if this:
                    if facts.get("band") == "bigJump":
                        parts.append(f'<rect x="{x - 8:.1f}" y="{base - h - 8:.1f}" width="{bw + 16:.1f}" height="{h + 8:.1f}" rx="6" fill="none" stroke="{AMBER}" stroke-width="6"/>')
                    parts.append(f'<rect x="{x - 2:.1f}" y="{base - h - 2:.1f}" width="{bw + 4:.1f}" height="{h + 2:.1f}" fill="none" stroke="{brand.INK}" stroke-width="4"/>')
        parts.append(f'<text x="{cx:.1f}" y="{height - 10}" text-anchor="middle" font-family="{brand.SCHIBSTED}" font-weight="{800 if this else 600}" '
                     f'font-size="22" letter-spacing="1" fill="{brand.INK if this else brand.QUIET}">{_week_label(w.get("monday"))}</text>')
    if usual > 0:
        uy = base - room * usual / peak
        end = width - gutter + 16
        parts.append(f'<line x1="0" y1="{uy:.1f}" x2="{end}" y2="{uy:.1f}" stroke="{brand.QUIET}" stroke-width="3" stroke-dasharray="10 8"/>')
        parts.append(f'<text x="{end + 12}" y="{uy + 8:.1f}" font-family="{brand.SCHIBSTED}" font-weight="700" font-size="26" '
                     f'letter-spacing="1" fill="{brand.QUIET}">USUAL {int(round(usual))}</text>')
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(parts)}</svg>'


def build_weekly_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    memory = memory or {}
    ink, quiet = brand.INK, brand.QUIET
    has_load = isinstance(facts.get("load"), (int, float)) and isinstance(facts.get("weeks"), list) and len(facts["weeks"]) > 0
    num = 64 if has_load else 80   # the load panel takes room from the score chips
    moves = facts.get("score_moves") or {}
    chips = []
    for key in SCORE_ORDER:
        if key not in moves:
            continue
        mv = float(moves[key])
        col = brand.LANE[key]
        arrow = brand.MINT if mv > 0 else (brand.VERMILLION if mv < 0 else quiet)
        chips.append(
            f'<div style="flex:1;min-width:0;position:relative;border-radius:34px;overflow:hidden;background:{brand.tint(col)};padding:34px 22px 0 26px">'
            f'<div style="position:absolute;left:0;top:0;width:100%;height:12px;background:{col}"></div>'
            f'<div class="cap" style="font-size:22px;color:{brand.INK_SECONDARY}">{key}</div>'
            f'<div class="saira" style="font-size:{num}px;line-height:1.05;color:{arrow}">{P.signed(mv)}</div></div>')
    best_top, best_h = (1200, 120) if has_load else (1140, 150)
    best = facts.get("best_moment") or {}
    best_html = ""
    if best.get("text"):
        best_html = (f'<div class="abs" style="left:{P.BX}px;top:{best_top}px;width:{P.BW}px;height:{best_h}px;border-radius:{P.RADIUS}px;background:#FFFFFF;'
                     f'border:2px solid {brand.HAIRLINE};overflow:hidden"><div class="abs cap" style="left:40px;top:22px;font-size:22px;color:{quiet}">BEST MOMENT</div>'
                     f'<div class="abs" style="left:40px;top:56px;width:{P.BW - 80}px;font-size:36px;line-height:1.2;font-weight:600">{P.esc(best["text"], 110)}</div></div>')
    week = P.esc(facts.get("week_label", ""), 24)
    sub = f"{facts.get('runs', 0)} runs / {P.fmt_dur(float(facts.get('duration_s', 0)))} on the move"
    pace = []
    for key, label in (("pace_s_per_km", "AVG /KM"), ("quickest_pace_s_per_km", "QUICKEST")):
        if isinstance(facts.get(key), (int, float)) and facts[key] > 0:
            pace.append(f'<span style="display:flex;align-items:baseline;gap:10px"><span class="saira" style="font-size:50px;color:{brand.INK}">'
                        f'{P.fmt_pace(float(facts[key]))}</span><span class="cap" style="font-size:22px;color:{brand.INK}">{label}</span></span>')
    load_line = (f'<div class="abs" style="left:40px;top:128px;width:{P.BW - 80}px;font-size:30px;font-weight:600;color:{brand.INK}">'
                 f'LOAD {int(round(facts["load"]))} \u00b7 {P.esc(_load_words(facts), 48)}</div>') if has_load else ""
    overlay = (f'<div class="abs" style="right:40px;top:92px;display:flex;flex-direction:column;align-items:flex-end;gap:8px">{"".join(pace)}</div>'
               f'<div class="abs" style="left:40px;top:78px;font-size:34px;font-weight:600;color:{brand.INK}">{P.esc(sub, 60)}</div>{load_line}')
    block = P.hero_block(168, 360, tag=week, headline="", value=P.fmt_km(float(facts['distance_km'])), unit="KM", size=190 if has_load else 225, overlay=overlay,
                         ground=brand.LANE["aerobic"], fg=brand.INK, soft=brand.INK)
    if has_load:   # a load panel under the day bars; everything below it moves down
        bars = P.panel(552, 300, f'<div class="abs bars" style="position:static">{_bars(list(facts.get("days") or []), P.INNER, 270)}</div>')
        bars += P.panel(868, 170, f'<div class="abs loadbars" style="position:static">{_load_bars(facts, P.INNER, 170)}</div>')
        chips_top, chips_h = 1054, 130
    else:
        bars = P.panel(552, 370, f'<div class="abs bars" style="position:static">{_bars(list(facts.get("days") or []), P.INNER, 340)}</div>')
        chips_top, chips_h = 946, 170
    moves_html = f'<div class="abs moves" style="left:{P.BX}px;top:{chips_top}px;width:{P.BW}px;height:{chips_h}px;display:flex;gap:16px">{"".join(chips)}</div>'
    body = P.header(False, P.esc(memory.get('name', ''), 20).upper(), quiet) + block + bars + moves_html + best_html
    css = P.base_css(brand.GROUND, ink)
    return P.doc(css, body)


def render_weekly_recap(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_weekly_html(facts, memory), P.W, P.H)
