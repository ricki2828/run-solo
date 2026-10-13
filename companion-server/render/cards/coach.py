"""Coach cards, direction B (13-Oct-2026): the TODAY card, the same card with the result filled in (TODAY_VERDICT), the
MOVED card and the PINNED WEEK card. Lane colour grounds, ink text; mint = faster, vermillion = slower, cyan = a PB
only, violet is never used. Every fact is a number, a fixed enum or a short label, and every label is escaped.
Paces and distances arrive metric (s/km, km); `units: "mi"` converts them for display only."""
from __future__ import annotations

from typing import Any, Mapping

from .. import brand
from . import _parts as P
from ._engine import render_html

KM_PER_MI = 1.609344
TYPE_WORDS = {"easy": "Easy run", "long": "Long run", "tempo": "Tempo", "interval": "Intervals", "race": "Race",
              "cooper": "Cooper test", "trail": "Trail run", "rest": "Rest day"}
DAY_WORDS = {"mon": "MON", "tue": "TUE", "wed": "WED", "thu": "THU", "fri": "FRI", "sat": "SAT", "sun": "SUN"}
DAY_ORDER = tuple(DAY_WORDS)
REASON_WORDS = {"tired": "TIRED", "busy": "BUSY", "sore": "SORE", "travelling": "TRAVELLING", "ill": "ILL",
                "weather": "WEATHER", "missed": "MISSED"}
GAIN_FG = "#FFFFFF"


def _lane(kind: Any) -> str:
    return brand.CARD_TYPE_COLOUR.get(str(kind), brand.BONE if kind == "rest" else brand.LANE["aerobic"])


def _mi(facts: Mapping[str, Any]) -> bool:
    return facts.get("units") == "mi"


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v else None


def _dist(km: float, facts: Mapping[str, Any]) -> str:
    return P.fmt_km(km / KM_PER_MI if _mi(facts) else km)


def _pace(s: float, facts: Mapping[str, Any]) -> str:
    return P.fmt_pace(s * KM_PER_MI if _mi(facts) else s)


def _per(facts: Mapping[str, Any]) -> str:
    return "/MI" if _mi(facts) else "/KM"


def _fit(text: str, sizes: tuple[tuple[int, int], ...]) -> int:
    """Font size for a label by its length: (max_len, size) steps, the last size for anything longer."""
    for limit, size in sizes:
        if len(text) <= limit:
            return size
    return sizes[-1][1]


def _hero(facts: Mapping[str, Any], tag: str, height: int) -> str:
    kind = str(facts.get("type", "easy"))
    name_raw = str(facts.get("session") or TYPE_WORDS.get(kind, "Run"))[:32]
    name = P.esc(name_raw, 32)
    dist, dur = _num(facts.get("distance_km")), _num(facts.get("duration_s"))
    if dist:
        value, unit = _dist(dist, facts).replace(".0", ""), "MI" if _mi(facts) else "KM"
    elif dur:
        value, unit = str(max(1, round(dur / 60))), "MIN"
    else:
        value, unit = "", ""
    ground = _lane(kind)
    when = P.date_label(facts.get("date_local"))
    return P.hero_block(168, height, tag=tag, headline=name, value=value, unit=unit, size=300, ground=ground, fg=brand.INK,
                        soft=brand.INK, headline_size=_fit(name_raw, ((12, 150), (18, 124), (26, 100), (99, 80))),
                        chip=P.esc(when, 14) if when else ""), kind


def _target_text(facts: Mapping[str, Any]) -> tuple[str, str] | None:
    """('4:15-4:20', '/KM WORK') or None when the card carries no pace target."""
    lo, hi = _num(facts.get("target_pace_lo_s")), _num(facts.get("target_pace_hi_s"))
    if lo is None and hi is None:
        return None
    lo = lo if lo is not None else hi
    hi = hi if hi is not None else lo
    text = _pace(lo, facts) if round(lo) == round(hi) else f"{_pace(lo, facts)}-{_pace(hi, facts)}"
    return text, _per(facts) + (" WORK" if facts.get("target_kind") == "work" else "")


def _block(left: int, width: int, top: int, height: int, ground: str, edge: str, inner: str) -> str:
    return (f'<div class="abs" style="left:{left}px;top:{top}px;width:{width}px;height:{height}px;border-radius:{P.RADIUS}px;'
            f'background:{ground};border:{edge};overflow:hidden">{inner}</div>')


def _target_block(left: int, width: int, top: int, height: int, text: str, unit: str, size: int, narrow: bool = False) -> str:
    """The narrow variant (beside the result) puts the unit under the caption: the range alone fills the block."""
    cap = f"TARGET" + (f'<span style="margin-left:14px;color:{brand.INK_SECONDARY}">{P.esc(unit, 12)}</span>' if narrow else "")
    unit_html = "" if narrow else f'<span class="saira" style="font-size:52px;color:{brand.INK_SECONDARY}">{P.esc(unit, 12)}</span>'
    inner = (f'<div class="abs cap" style="left:40px;top:34px;font-size:28px;letter-spacing:.14em;color:{brand.QUIET};white-space:nowrap">{cap}</div>'
             f'<div class="abs" style="left:32px;bottom:30px;display:flex;align-items:baseline;gap:16px;white-space:nowrap">'
             f'<span class="saira tgt" style="font-size:{size}px;line-height:.8;color:{brand.INK}">{P.esc(text, 12)}</span>{unit_html}</div>')
    return _block(left, width, top, height, "#FFFFFF", f"2px solid {brand.HAIRLINE}", inner)


def build_today_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    target = _target_text(facts)
    hero, _ = _hero(facts, "TODAY", 640 if target else 1106)
    body = P.header(False, "", brand.QUIET) + hero
    if target:
        body += _target_block(P.BX, P.BW, 840, 434, target[0], target[1], 230)
    return P.doc(P.base_css(brand.GROUND, brand.INK), body)


def _verdict(facts: Mapping[str, Any], result: float, lo: float, hi: float) -> tuple[str, str, str, str]:
    """-> (block ground, text colour, small text colour, delta line). The colour is decided here, from the numbers, so it
    can never disagree with them: faster than the band is mint, slower vermillion, a PB cyan, inside the band neutral."""
    unit = "s/mi" if _mi(facts) else "s/km"
    k = KM_PER_MI if _mi(facts) else 1.0
    if facts.get("pb") is True:
        return brand.INK, brand.ARC, brand.BONE, "A NEW BEST"
    if round(result) < round(lo):
        return brand.MINT, GAIN_FG, GAIN_FG, f"{round((lo - result) * k)} {unit} FASTER"
    if round(result) > round(hi):
        return brand.VERMILLION, GAIN_FG, GAIN_FG, f"{round((result - hi) * k)} {unit} SLOWER"
    return brand.INK, brand.BONE, brand.BONE, "IN RANGE"


def build_today_verdict_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    target = _target_text(facts)
    result = _num(facts.get("result_pace_s"))
    hero, _ = _hero(facts, "DONE", 640 if target and result else 1106)
    body = P.header(False, "", brand.QUIET) + hero
    if target and result:
        lo = _num(facts.get("target_pace_lo_s"))
        hi = _num(facts.get("target_pace_hi_s"))
        lo = lo if lo is not None else hi
        hi = hi if hi is not None else lo
        assert lo is not None and hi is not None
        ground, fg, soft, delta = _verdict(facts, result, lo, hi)
        body += _target_block(P.BX, 440, 840, 434, target[0], target[1], 104, narrow=True)
        ran = _pace(result, facts)
        inner = (f'<div class="abs cap" style="left:40px;top:34px;font-size:28px;letter-spacing:.14em;color:{soft}">YOU RAN</div>'
                 f'<div class="abs" style="left:32px;top:92px;display:flex;align-items:baseline;gap:16px;white-space:nowrap">'
                 f'<span class="saira ran" style="font-size:230px;line-height:.8;color:{fg}">{P.esc(ran, 8)}</span>'
                 f'<span class="saira" style="font-size:52px;color:{soft}">{_per(facts)}</span></div>'
                 f'<div class="abs cap delta" style="left:40px;bottom:36px;font-size:40px;letter-spacing:.1em;color:{fg}">{P.esc(delta, 24)}</div>')
        body += _block(P.BX + 440 + 16, P.BW - 440 - 16, 840, 434, ground, "none", inner)
    elif target:
        body += _target_block(P.BX, P.BW, 840, 434, target[0], target[1], 230)
    return P.doc(P.base_css(brand.GROUND, brand.INK), body)


def build_moved_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    kind = str(facts.get("type", "easy"))
    colour = _lane(kind)
    name_raw = str(facts.get("session") or TYPE_WORDS.get(kind, "Run"))[:32]
    name = P.esc(name_raw, 32)
    to_day = str(facts.get("to_day", ""))
    next_week = to_day == "next_week"
    value, unit = ("NEXT", "WEEK") if next_week else (DAY_WORDS.get(to_day, ""), "")
    reason = REASON_WORDS.get(str(facts.get("skip_reason", "")), "")
    head = f"{name} moved to"
    hero = P.hero_block(168, 560, tag="MOVED", headline=head, value=value, unit=unit, size=330, ground=brand.INK, fg=brand.BONE,
                        soft=brand.BONE, chip=reason, chip_bg="rgba(237,234,227,.18)",
                        headline_size=_fit(head, ((16, 120), (24, 96), (99, 76))))
    dist, dur = _num(facts.get("distance_km")), _num(facts.get("duration_s"))
    amount = (f"{_dist(dist, facts).replace('.0', '')} {'MI' if _mi(facts) else 'KM'}" if dist
              else (f"{max(1, round(dur / 60))} MIN" if dur else ""))
    inner = (f'<div class="abs" style="left:0;top:0;width:100%;height:16px;background:{colour}"></div>'
             f'<div class="abs cap" style="left:40px;top:50px;font-size:28px;letter-spacing:.14em;color:{brand.INK_SECONDARY}">THE SESSION</div>'
             f'<div class="abs saira" style="left:40px;top:100px;width:{P.BW - 80}px;font-size:{_fit(name_raw, ((14, 150), (99, 100)))}px;'
             f'line-height:.9;color:{brand.INK}">{name}</div>'
             + (f'<div class="abs saira amt" style="right:40px;top:30px;font-size:64px;line-height:1;color:{brand.INK}">{P.esc(amount, 12)}</div>'
                if amount else ""))
    body = P.header(False, "", brand.QUIET) + hero + _block(P.BX, P.BW, 760, 312, brand.tint(colour), "none", inner)
    was = DAY_WORDS.get(str(facts.get("from_day", "")), "")
    now = "NEXT WEEK" if next_week else DAY_WORDS.get(to_day, "")
    if was:
        body += P.stat_blocks([(was, "WAS"), (now, "NOW")], 1104, 170, colour)
    return P.doc(P.base_css(brand.GROUND, brand.INK), body)


# --- pinned week -------------------------------------------------------------------------

def _days(facts: Mapping[str, Any]) -> list[dict[str, Any]]:
    out = []
    for d in list(facts.get("days") or [])[:7]:
        d = d if isinstance(d, Mapping) else {}
        out.append({"type": str(d.get("type", "rest")), "planned": max(0.0, _num(d.get("planned_km")) or 0.0),
                    "done": max(0.0, _num(d.get("done_km")) or 0.0)})
    return out + [{"type": "rest", "planned": 0.0, "done": 0.0}] * (7 - len(out))


def _week_bars(days: list[dict[str, Any]], today: int, facts: Mapping[str, Any], width: int, height: int) -> str:
    """Per day: a pale ghost bar for the plan, a solid bar over it for what was run, both in the day's lane colour.
    A planned day that has passed with nothing run is a dashed outline marked MISSED; the current day is underlined."""
    k = 1 / KM_PER_MI if _mi(facts) else 1.0
    peak = max([max(d["planned"], d["done"]) for d in days] + [0.1])
    slot = width / 7
    bw = slot * 0.66
    label_h, top_pad = 96, 52
    room = height - label_h - top_pad
    base = height - label_h
    parts = []
    for i, d in enumerate(days):
        x = i * slot + (slot - bw) / 2
        cx = x + bw / 2
        col = _lane(d["type"])
        if i == today:
            parts.append(f'<rect x="{i * slot + 2:.1f}" y="0" width="{slot - 4:.1f}" height="{height}" rx="26" fill="{brand.BONE}" opacity=".55"/>')
        ph, dh = room * d["planned"] / peak, room * d["done"] / peak
        missed = d["planned"] > 0 and d["done"] <= 0 and i < today
        if ph > 0:
            if missed:
                parts.append(f'<rect x="{x:.1f}" y="{base - ph:.1f}" width="{bw:.1f}" height="{ph:.1f}" rx="10" fill="none" '
                             f'stroke="{brand.QUIET}" stroke-width="3" stroke-dasharray="10 8"/>')
            else:
                parts.append(f'<rect x="{x:.1f}" y="{base - ph:.1f}" width="{bw:.1f}" height="{ph:.1f}" rx="10" fill="{brand.tint(col, .28)}"/>')
        if dh > 0:
            parts.append(f'<rect x="{x:.1f}" y="{base - dh:.1f}" width="{bw:.1f}" height="{max(dh, 6):.1f}" rx="10" fill="{col}"/>')
        if ph <= 0 and dh <= 0:
            parts.append(f'<rect x="{x:.1f}" y="{base - 6}" width="{bw:.1f}" height="6" fill="{brand.HAIRLINE}"/>')
        top = base - max(ph, dh, 6)
        if d["done"] > 0:
            label = P.fmt_km(d["done"] * k)
        elif d["planned"] > 0:
            label = P.fmt_km(d["planned"] * k)
        else:
            label = ""
        if label:
            colour = brand.INK if d["done"] > 0 else brand.QUIET
            parts.append(f'<text x="{cx:.1f}" y="{max(top - 12, 34):.1f}" text-anchor="middle" font-family="{brand.SAIRA}" font-weight="800" '
                         f'font-size="34" fill="{colour}">{label}</text>')
        parts.append(f'<text x="{cx:.1f}" y="{height - 50}" text-anchor="middle" font-family="{brand.SCHIBSTED}" font-weight="700" '
                     f'font-size="24" letter-spacing="2" fill="{brand.INK if i == today else brand.QUIET}">{DAY_WORDS[DAY_ORDER[i]]}</text>')
        if missed:
            parts.append(f'<text x="{cx:.1f}" y="{height - 16}" text-anchor="middle" font-family="{brand.SCHIBSTED}" font-weight="700" '
                         f'font-size="17" letter-spacing="1" fill="{brand.QUIET}">MISSED</text>')
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(parts)}</svg>'


def build_pinned_week_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    days = _days(facts)
    idx = facts.get("today_idx")
    today = idx if isinstance(idx, int) and not isinstance(idx, bool) and 0 <= idx <= 6 else 0
    k = 1 / KM_PER_MI if _mi(facts) else 1.0
    done = sum(d["done"] for d in days)
    planned = sum(d["planned"] for d in days)
    runs_done = sum(1 for d in days if d["done"] > 0)
    runs_all = sum(1 for d in days if d["planned"] > 0 or d["done"] > 0)
    to_go = sum(max(0.0, d["planned"] - d["done"]) for i, d in enumerate(days) if i >= today)
    unit = "MI" if _mi(facts) else "KM"
    dur = _num(facts.get("duration_s")) or 0.0
    week = P.esc(facts.get("week_label") or "This week", 24)
    plan_line = (f'<div class="abs cap" style="right:40px;top:92px;font-size:34px;letter-spacing:.1em;color:{brand.INK}">'
                 f'OF {P.fmt_km(planned * k)} {unit} PLANNED</div>') if planned > 0 else ""
    hero = P.hero_block(168, 360, tag=week, headline="", value=P.fmt_km(done * k), unit=unit, size=225, overlay=plan_line,
                        ground=brand.BONE, fg=brand.INK, soft=brand.INK)
    bars = P.panel(552, 560, f'<div class="abs wk" style="position:static">{_week_bars(days, today, facts, P.INNER, 520)}</div>')
    stats = [(f"{runs_done}/{runs_all}", "RUNS"), (P.fmt_dur(dur), "ON THE MOVE"), (P.fmt_km(to_go * k), f"{unit} TO GO")]
    body = P.header(False, "PINNED", brand.QUIET) + hero + bars + P.stat_blocks(stats, 1136, 150, brand.INK_SECONDARY)
    return P.doc(P.base_css(brand.GROUND, brand.INK), body)


def render_today(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_today_html(facts, memory), P.W, P.H)


def render_today_verdict(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_today_verdict_html(facts, memory), P.W, P.H)


def render_moved(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_moved_html(facts, memory), P.W, P.H)


def render_pinned_week(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_pinned_week_html(facts, memory), P.W, P.H)
