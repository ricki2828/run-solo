"""Trail cards, direction B (14-Oct-2026): TRAIL BOARD (your own runs of one trail, ranked) and TRAIL RECORD (a new best, with
the ghost gap drawn over the elevation profile). Lane colour is the trail lane blue; cyan only ever marks a best.

Every fact is a bounded whole number, a fixed enum or the opt-in trail name (see render/protocol.py TRAIL_KEYS):
the profile is metres relative to the start, the board rows are attempt numbers and pace-normalised times. No coordinates,
no dates. `ghost_gap` is signed seconds, POSITIVE = ahead of the old best. The gradient is words and one hue (darker = steeper), computed here over a 250 m window so it does not stripe, and drawn only for a barometer
profile (`elev_src` = baro); a GPS profile (or none stated) is smoothed and drawn as a calm single-tone line, with no steepness claims.
"""
from __future__ import annotations

from typing import Any, Mapping, Sequence

from .. import brand
from . import _parts as P
from ._engine import render_html

LANE = brand.LANE["long"]
FLOOD = brand.ZONE_FLOOD[3]    # the record card's flood, as the PB cards use for their ground
DEEP = "#0B3F5C"               # the steepest band
BANDS = (("FLAT", 0.04, brand.tint(LANE, 0.28)), ("STEADY", 0.09, brand.tint(LANE, 0.55)), ("STEEP", 0.15, LANE),
         ("VERY STEEP", 9.9, DEEP))
WINDOW_M = 250
COUNT_WORDS = {2: "TWO", 3: "THREE", 4: "FOUR", 5: "FIVE", 6: "SIX", 7: "SEVEN", 8: "EIGHT", 9: "NINE", 10: "TEN", 11: "ELEVEN",
               12: "TWELVE", 13: "THIRTEEN", 14: "FOURTEEN", 15: "FIFTEEN", 16: "SIXTEEN", 17: "SEVENTEEN", 18: "EIGHTEEN",
               19: "NINETEEN", 20: "TWENTY"}
RANK_WORDS = {1: "FASTEST", 2: "SECOND FASTEST", 3: "THIRD FASTEST"}
SHAPE_WORDS = {"out_and_back": "OUT AND BACK", "loop": "LOOP", "one_way": "ONE WAY"}
MAX_ROWS = 5


def _ordinal(n: int) -> str:
    suffix = "TH" if 10 <= n % 100 <= 20 else {1: "ST", 2: "ND", 3: "RD"}.get(n % 10, "TH")
    return f"{n}{suffix}"


def _band(g: float) -> tuple[str, str]:
    g = abs(g)
    for word, top, colour in BANDS:
        if g < top:
            return word, colour
    return BANDS[-1][0], BANDS[-1][2]


def _grades(profile: Sequence[int], dist_m: float) -> list[float]:
    """Slope of each segment over a ~250 m window (a fraction, signed), so one noisy sample never stripes the profile."""
    n = len(profile)
    dx = max(dist_m, 1.0) / (n - 1)
    win = max(1, round(WINDOW_M / 2 / dx))
    out = []
    for i in range(n - 1):
        a, b = max(0, i - win + 1), min(n - 1, i + win)
        out.append((profile[b] - profile[a]) / ((b - a) * dx))
    return out


def _gap_text(s: int) -> str:
    s = abs(int(s))
    return f"{s} S" if s < 60 else f"{s // 60}:{s % 60:02d}"


def _gap_words(s: int) -> str:
    s = abs(int(s))
    return f"{s} seconds" if s < 60 else f"{s // 60} min {s % 60:02d} s"


CALM = brand.tint(LANE, 0.22)


def _smooth(profile: Sequence[int], k: int = 2) -> list[int]:
    """A moving average (GPS altitude is noisy): the shape of the trail, not its jitter."""
    n = len(profile)
    return [round(sum(profile[max(0, i - k):i + k + 1]) / len(profile[max(0, i - k):i + k + 1])) for i in range(n)]


def _resample(values: Sequence[int], n: int) -> list[float]:
    """The ghost gap on the profile's x positions: a line through the points at the same progress."""
    m = len(values)
    out = []
    for i in range(n):
        pos = i / (n - 1) * (m - 1)
        lo = int(pos)
        hi = min(m - 1, lo + 1)
        out.append(values[lo] + (values[hi] - values[lo]) * (pos - lo))
    return out


def profile_svg(profile: Sequence[int], dist_m: float, w: int, h: int, *, pad_top: int = 40, pad_bot: int = 8,
                turn_idx: int | None = None, turn_word: str = "HIGH POINT", labels: bool = True, gap: Sequence[int] | None = None,
                gap_final: int | None = None, label_size: int = 30, baro: bool = True) -> str:
    """The elevation profile filled in grade bands. `gap` is signed seconds along the run (positive = ahead of the old
    best) and draws as a line over the profile, ahead drawn below the ghost's dashed baseline."""
    if not baro:
        profile = _smooth(profile)
    n = len(profile)
    lo, hi = min(profile), max(profile)
    span = max(hi - lo, 20)
    sx = lambda i: i / (n - 1) * w  # noqa: E731
    sy = lambda e: pad_top + (1 - (e - lo) / (span * 1.05)) * (h - pad_top - pad_bot)  # noqa: E731
    grades = _grades(profile, dist_m)
    parts = []
    for i in range(n - 1):
        col = _band(grades[i])[1] if baro else CALM
        x0, x1 = sx(i), sx(i + 1) + 0.6
        parts.append(f'<polygon points="{x0:.1f},{h} {x0:.1f},{sy(profile[i]):.1f} {x1:.1f},{sy(profile[i + 1]):.1f} {x1:.1f},{h}" fill="{col}"/>')
    line = " ".join(f"{sx(i):.1f},{sy(e):.1f}" for i, e in enumerate(profile))
    parts.append(f'<polyline points="{line}" fill="none" stroke="{brand.INK}" stroke-width="4" stroke-linejoin="round"/>')
    font = f'font-family="{brand.SAIRA}" font-weight="800"'
    if labels:
        top_i = turn_idx if turn_idx is not None else max(range(n), key=lambda i: profile[i])
        xs, ys = sx(top_i), sy(profile[top_i])
        climbed = round(profile[top_i] - profile[0])
        anchor = "start" if xs < 150 else ("end" if xs > w - 150 else "middle")
        parts.append(f'<circle cx="{xs:.1f}" cy="{ys:.1f}" r="11" fill="#fff" stroke="{brand.INK}" stroke-width="5"/>')
        parts.append(f'<text x="{xs:.1f}" y="{ys - 22:.1f}" text-anchor="{anchor}" {font} font-size="{label_size}" fill="{brand.INK}">'
                     f'{P.esc(turn_word, 12)} · {max(0, round(climbed))} M</text>')
        steep = max(range(n - 1), key=lambda i: abs(grades[i]))
        word, _ = _band(grades[steep])
        if baro and word in ("STEEP", "VERY STEEP"):
            pct = round(min(abs(grades[steep]), 0.35) * 100)
            xv, yv = sx(steep + 0.5), (sy(profile[steep]) + sy(profile[steep + 1])) / 2
            left = xv > 260
            x2, y2 = (xv - 70, yv - 46) if left else (xv + 70, yv - 46)
            parts.append(f'<line x1="{xv:.1f}" y1="{yv - 8:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{brand.INK}" stroke-width="3"/>')
            parts.append(f'<text x="{x2 + (-8 if left else 8):.1f}" y="{y2 - 4:.1f}" text-anchor="{"end" if left else "start"}" {font} '
                         f'font-size="{label_size}" fill="{brand.INK}">{word} · {pct}%</text>')
    if gap:
        g = _resample(gap, n)
        mid, amp = h * 0.30, h * 0.24
        top_g = max(max(abs(v) for v in g), 1)
        gy = lambda v: mid + v / top_g * amp  # noqa: E731  (positive gap = ahead = below the baseline)
        pts = " ".join(f"{sx(i):.1f},{gy(v):.1f}" for i, v in enumerate(g))
        parts.append(f'<line x1="0" x2="{w}" y1="{mid:.1f}" y2="{mid:.1f}" stroke="{brand.INK}" stroke-width="2" stroke-dasharray="6 8" opacity=".55"/>')
        parts.append(f'<polygon points="0,{mid:.1f} {pts} {w},{mid:.1f}" fill="{brand.MINT}" opacity=".22"/>')
        parts.append(f'<polyline points="{pts}" fill="none" stroke="{brand.MINT}" stroke-width="7" stroke-linejoin="round" stroke-linecap="round"/>')
        parts.append(f'<text x="{w - 4}" y="{mid - 12:.1f}" text-anchor="end" {font} font-size="26" fill="{brand.QUIET}">GHOST (OLD BEST)</text>')
        final = gap_final if gap_final is not None else gap[-1]
        end_y = gy(g[-1])
        word = "AHEAD" if final >= 0 else "BEHIND"
        col = brand.MINT if final >= 0 else brand.VERMILLION
        parts.append(f'<text x="{w - 4}" y="{end_y + 36:.1f}" text-anchor="end" {font} font-size="32" fill="{col}">'
                     f'YOU {_gap_text(final)} {word}</text>')
    return f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}">{"".join(parts)}</svg>'


def _legend() -> str:
    items = "".join(f'<span style="display:flex;align-items:center;gap:6px"><i style="width:18px;height:18px;border-radius:5px;'
                    f'background:{c}"></i>{word}</span>' for word, _, c in BANDS)
    return (f'<div class="abs" style="right:30px;top:24px;display:flex;gap:16px;font-size:20px;font-weight:700;letter-spacing:.06em;'
            f'color:{brand.INK_SECONDARY}">{items}</div>')


def _profile_of(facts: Mapping[str, Any]) -> list[int] | None:
    p = facts.get("elev_profile")
    if isinstance(p, list) and len(p) >= 8:   # a GPS-only profile can be a few noisy points: under 8 the card says nothing about it
        return [int(x) for x in p]
    return None


def _board(facts: Mapping[str, Any]) -> list[dict[str, Any]]:
    rows = [dict(r) for r in facts["trail_board"]]
    rows.sort(key=lambda r: (r["time_s"], r["attempt"]))
    return rows


def _rank(row: Mapping[str, Any], rows: Sequence[Mapping[str, Any]], n: int) -> int | None:
    """The app's rank when it sent one. Otherwise ranked among the rows sent, but only when the board holds every run of the
    trail (n <= rows); a board that is a slice of a longer history cannot say where a run stands, so there is no rank."""
    if row.get("rank"):
        return int(row["rank"])
    if n > len(rows):
        return None
    return 1 + sum(1 for r in rows if r["time_s"] < row["time_s"])


def _name_tag(facts: Mapping[str, Any], fallback: str) -> str:
    """The trail's name is a place: it is drawn only when the caller sent it (the runner's place opt-in)."""
    name = facts.get("trail_name")
    return P.esc(name, 30) if name else fallback


def _shape_line(facts: Mapping[str, Any]) -> str:
    bits = []
    if facts.get("distance_km"):
        bits.append(f"{P.fmt_km(float(facts['distance_km']))} KM")
    if facts.get("trail_shape") in SHAPE_WORDS:
        bits.append(SHAPE_WORDS[facts["trail_shape"]])
    return " ".join(bits)


def _fit(text: str, sizes: tuple[tuple[int, int], ...]) -> int:
    for limit, size in sizes:
        if len(text) <= limit:
            return size
    return sizes[-1][1]


def _shown(rows: list[dict[str, Any]], n: int) -> list[tuple[int | None, dict[str, Any]]]:
    """(rank or None, row) for at most MAX_ROWS rows: the best rows, and today's row whenever it would otherwise be cut."""
    ranked = [(_rank(r, rows, n), r) for r in rows]
    if len(ranked) <= MAX_ROWS:
        return ranked
    head = ranked[:MAX_ROWS - 1]
    tail = [x for x in ranked[MAX_ROWS - 1:] if x[1].get("today")]
    return head + (tail[:1] if tail else ranked[MAX_ROWS - 1:MAX_ROWS])


def _rows_html(shown: list[tuple[int | None, dict[str, Any]]], best: int, top: int, row_h: int) -> str:
    worst = max(r["time_s"] for _, r in shown)
    lo = best - 60
    out = ""
    prev, at_prev = 0, 0
    for rank, r in shown:
        # a spacer only where ranks are really skipped: after k rows tied on rank p the next rank is p + k, not p + 1
        if prev and rank and rank > prev + at_prev:
            out += (f'<div class="saira" style="height:20px;line-height:14px;padding-left:60px;font-size:34px;color:{brand.QUIET};'
                    f'letter-spacing:.2em">···</div>')
        if rank:
            at_prev = at_prev + 1 if rank == prev else 1
            prev = rank
        t = r["time_s"]
        today = bool(r.get("today"))
        is_best = rank == 1 or (rank is None and t == best)
        gap = t - best
        bar_w = 520 * (1 - (t - lo) / (worst - lo + 120))
        bg = brand.tint(LANE) if today else "#FFFFFF"
        bar = brand.ARC if is_best else (LANE if today else brand.tint(LANE, 0.45))
        label = "TODAY" if today else f"RUN {r['attempt']}"
        chip = (f'<span class="cap" style="font-size:22px;padding:6px 16px;border-radius:99px;background:{brand.ARC};color:{brand.INK}">BEST</span>'
                if is_best else f'<span class="saira" style="font-size:40px;color:{brand.INK_SECONDARY}">+{_gap_text(gap)}</span>')
        out += (f'<div style="display:flex;align-items:center;height:{row_h}px;padding:0 26px;border-radius:24px;background:{bg};margin-bottom:6px">'
                f'<span class="saira" style="width:56px;font-size:44px;color:{brand.QUIET}">{rank or ""}</span>'
                f'<span class="saira" style="width:150px;font-size:40px;color:{brand.INK if today else brand.INK_SECONDARY}">{label}</span>'
                f'<span style="flex:1;height:18px;position:relative"><span class="abs" style="left:0;top:0;height:18px;width:{max(bar_w, 24):.0f}px;'
                f'border-radius:9px;background:{bar}"></span></span>'
                f'<span class="saira" style="width:170px;text-align:right;font-size:46px;color:{brand.INK}">{P.fmt_dur(t)}</span>'
                f'<span style="width:140px;text-align:right">{chip}</span></div>')
    return f'<div class="abs rows" style="left:{P.BX}px;top:{top}px;width:{P.BW}px">{out}</div>'


def _climb_stat(facts: Mapping[str, Any]) -> tuple[str, str] | None:
    return (P.thousands(facts["climb_m"]) + " M", "CLIMB") if facts.get("climb_m") else None


def build_trail_board_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    rows = _board(facts)
    n = int(facts.get("trail_runs") or len(rows))
    today = next(r for r in rows if r.get("today"))
    rank = _rank(today, rows, n)
    best = rows[0]["time_s"]
    climb = float(facts.get("climb_m") or 0)
    count = COUNT_WORDS.get(n, str(n))
    line1 = f"{count} TIMES UP." if climb >= 50 else f"{count} RUNS."
    if rank is None:
        line2 = ""     # the board is a slice and the app sent no rank: no ordinal rather than a wrong one
    else:
        line2 = ((RANK_WORDS.get(rank) or f"{_ordinal(rank)} FASTEST") + ".") if rank > 1 else "JOINT BEST."
    gap = today["time_s"] - best
    first = next((r for r in rows if r["attempt"] == 1 and not r.get("today")), None)
    sub = f"{_gap_words(gap)} off your best" if gap else "level with your best"
    if first and first["time_s"] > today["time_s"]:
        up = first["time_s"] - today["time_s"]
        sub += f", {_gap_words(up) if up < 60 else str(round(up / 60)) + ' min'} up on run 1"
    tag_raw = str(facts.get("trail_name") or "YOUR TRAIL")[:30]
    shape = _shape_line(facts)
    tag_size = _fit(tag_raw + (" / " + shape if shape else ""), ((38, 28), (46, 24), (99, 20)))
    tag = P.esc(tag_raw, 30) + (f" &nbsp;/&nbsp; {shape}" if shape else "")
    value = P.fmt_dur(today["time_s"])
    line2_html = ("<br>" + P.esc(line2, 24)) if line2 else ""
    hero = (f'<div class="abs" style="left:{P.BX}px;top:160px;width:{P.BW}px;height:420px;border-radius:{P.RADIUS}px;background:{LANE};overflow:hidden">'
            f'<div class="abs cap" style="left:40px;top:34px;font-size:{tag_size}px;letter-spacing:.14em;color:{brand.INK};white-space:nowrap">{tag}</div>'
            f'<div class="abs saira" style="left:40px;top:86px;width:{P.BW - 80}px;font-size:92px;line-height:.9;color:{brand.INK}">{line1}{line2_html}</div>'
            f'<div class="abs" style="left:36px;bottom:30px;right:30px;display:flex;align-items:baseline;gap:18px;white-space:nowrap">'
            f'<span class="saira" style="font-size:{_fit(value, ((5, 150), (99, 120)))}px;line-height:.78;color:{brand.INK}">{value}</span>'
            f'<span style="font-size:{_fit(sub, ((30, 34), (99, 28)))}px;font-weight:600;color:{brand.INK}">{P.esc(sub, 60)}</span></div></div>')
    profile = _profile_of(facts)
    dist_m = float(facts.get("distance_km") or 0) * 1000
    shown = _shown(rows, n)
    if profile:
        baro = facts.get("elev_src") == "baro"
        grad, legend = (" &nbsp;·&nbsp; GRADIENT", _legend()) if baro else ("", "")
        turn_word = "TURN" if facts.get("trail_shape") == "out_and_back" and facts.get("turn_idx") is not None else "HIGH POINT"
        rise = int(facts.get("climb_m") or max(0, max(profile) - profile[0]))
        up = f"{P.thousands(rise)} M UP" if rise > 0 else "FLAT"
        panel = (f'<div class="abs" style="left:{P.BX}px;top:598px;width:{P.BW}px;height:300px;border-radius:{P.RADIUS}px;background:#fff;'
                 f'border:2px solid {brand.HAIRLINE};overflow:hidden">'
                 f'<div class="abs cap" style="left:34px;top:26px;font-size:22px;color:{brand.QUIET}">{up}{grad}</div>{legend}'
                 f'<div class="abs" style="left:24px;top:64px">{profile_svg(profile, dist_m, 936, 232, pad_top=56, turn_idx=facts.get("turn_idx"), turn_word=turn_word, baro=baro)}</div></div>')
        rows_html = _rows_html(shown, best, 916, 66)
    else:   # no usable profile (GPS-only altitude is noisy): the stat blocks take its place, the board moves up
        stats = [(P.fmt_km(float(facts["distance_km"])), "KM")] if facts.get("distance_km") else []
        stats += [s for s in (_climb_stat(facts), (str(n), "RUNS")) if s]
        panel = P.stat_blocks(stats, 606, 170, LANE)
        rows_html = _rows_html(shown, best, 806, 74)
    body = P.header(False, "TRAIL BOARD", brand.QUIET) + hero + panel + rows_html
    return P.doc(P.base_css(brand.GROUND, brand.INK), body)


def _halves(facts: Mapping[str, Any], gap: Sequence[int], profile: Sequence[int] | None) -> list[tuple[int, str]]:
    """Seconds won (+) or lost (-) over the first and second half of the run, with the words for them."""
    m = len(gap)
    out_back = facts.get("trail_shape") == "out_and_back"
    if out_back and profile and facts.get("turn_idx") is not None:
        cut = round(facts["turn_idx"] / (len(profile) - 1) * (m - 1))
    else:
        cut = (m - 1) // 2
    cut = max(1, min(m - 2, cut)) if m > 2 else 1
    g0, gc, g1 = 0, gap[cut], gap[-1]
    if out_back and profile and facts.get("turn_idx") is not None and profile[facts["turn_idx"]] - profile[0] >= 20:
        words = ("ON THE CLIMB", "ON THE WAY DOWN")
    elif out_back:
        words = ("GOING OUT", "COMING BACK")
    else:
        words = ("IN THE FIRST HALF", "IN THE SECOND HALF")
    return [(gc - g0, words[0]), (g1 - gc, words[1])]


def _won(s: int, words: str, align: str) -> str:
    col = brand.MINT if s >= 0 else brand.VERMILLION
    sign = "+" if s >= 0 else "-"
    return (f'<div class="abs saira" style="{align}:34px;top:60px;font-size:40px;color:{col};white-space:nowrap">'
            f'{sign}{_gap_text(s)} {words}</div>')


def build_trail_record_html(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> str:
    rows = _board(facts)
    today = next(r for r in rows if r.get("today"))
    others = [r for r in rows if not r.get("today")]
    old_best = min(r["time_s"] for r in others) if others else today["time_s"]
    delta = old_best - today["time_s"]
    n = int(facts.get("trail_runs") or len(rows))
    value = P.fmt_dur(today["time_s"])
    tag = f"TRAIL RECORD &nbsp;/&nbsp; RUN {today['attempt']}"
    head_text = "BEAT THE GHOST."
    sub = f"{_gap_words(delta)} faster than your best" if delta > 0 else "A new best"
    profile = _profile_of(facts)
    gap = facts.get("ghost_gap")
    dist_m = float(facts.get("distance_km") or 0) * 1000
    hero_h = 560 if profile else 800
    hero = P.hero_block(160, hero_h, tag=tag, headline=head_text, value=value, unit="", size=_fit(value, ((7, 330), (8, 270), (99, 240))),
                        value_colour=brand.ARC, ground=FLOOD, fg=brand.BONE, soft=brand.BONE, chip=f"BEST OF {n}",
                        chip_bg="rgba(237,234,227,.22)", extra=P.esc(sub, 50), headline_size=98)
    body = P.header(False, str(facts.get("trail_name") or "TRAIL RECORD"), brand.QUIET) + hero
    panel = ""
    if profile and isinstance(gap, list) and len(gap) >= 2:
        halves = _halves(facts, gap, profile)
        panel = (f'<div class="abs" style="left:{P.BX}px;top:740px;width:{P.BW}px;height:340px;border-radius:{P.RADIUS}px;background:#fff;'
                 f'border:2px solid {brand.HAIRLINE};overflow:hidden">'
                 f'<div class="abs cap" style="left:34px;top:26px;font-size:24px;color:{brand.QUIET}">WHERE YOU WON IT</div>'
                 f'{_won(halves[0][0], halves[0][1], "left")}{_won(halves[1][0], halves[1][1], "right")}'
                 f'<div class="abs" style="left:24px;top:76px">'
                 f'{profile_svg(profile, dist_m, 936, 256, pad_top=90, labels=False, gap=gap, gap_final=delta, baro=facts.get("elev_src") == "baro")}</div></div>')
    elif profile:
        baro = facts.get("elev_src") == "baro"
        panel = (f'<div class="abs" style="left:{P.BX}px;top:740px;width:{P.BW}px;height:340px;border-radius:{P.RADIUS}px;background:#fff;'
                 f'border:2px solid {brand.HAIRLINE};overflow:hidden">'
                 f'<div class="abs cap" style="left:34px;top:26px;font-size:24px;color:{brand.QUIET}">{"GRADIENT" if baro else "THE TRAIL"}</div>{_legend() if baro else ""}'
                 f'<div class="abs" style="left:24px;top:70px">'
                 f'{profile_svg(profile, dist_m, 936, 262, pad_top=56, turn_idx=facts.get("turn_idx"), baro=baro)}</div></div>')
    stats = [(P.fmt_dur(old_best), "OLD BEST")]
    if (c := _climb_stat(facts)):
        stats.append(c)
    if facts.get("pace_s_per_km"):
        stats.append((P.fmt_pace(float(facts["pace_s_per_km"])), "/KM"))
    stat_top = 1100 if profile else 1000
    return P.doc(P.base_css(brand.GROUND, brand.INK), body + panel + P.stat_blocks(stats, stat_top, 170, LANE))


def render_trail_board(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_trail_board_html(facts, memory), P.W, P.H)


def render_trail_record(facts: Mapping[str, Any], memory: Mapping[str, Any] | None = None) -> bytes:
    return render_html(build_trail_record_html(facts, memory), P.W, P.H)
