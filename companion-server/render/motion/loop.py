"""Cards v4 moment loops: run (easy, long, tempo, goal, free, intervals, PB), week and milestone.

Each is a 6 s dark silent loop, sent with sendAnimation, whose last held frame is the still. Ported from the
design/cards-v4 prototype. The facts are the ones the run and weekly videos already take (RUN_KEYS, WEEK_KEYS) and the
milestone card's (kind, value, line): no new fact key. The run spec is validated by spec_from_facts, i.e. by
RunVideoSpec.validate (splits against distance and time, the PB hero against old and new).

Colour: a run takes its lane colour from the run type exactly as the video does (goal = MID violet, free/laps = LONG ice
through `type`; intervals and races keep their SPEED colour); cyan appears only on a PB.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import date

from PIL import Image, ImageDraw

from .. import brand
from ._common import SCORES_DARK, fmt_dur, fmt_pace
from ._draw import H, SS, W, Canvas, clamp, in_out_cubic, mix, out_back, out_cubic, out_quart, rgb, seg
from ._geom import fit, head, prepare_route
from ._loopkit import (DARK, HAIR_D, M, QUIET_D, ZONE, Frame, G, Hero, Loop, S, chrome, fade, fit_text, ink_on,
                       screen_glow, stats_row, zone_strip)
from .run_video import spec_from_facts
from .weekly_video import weekly_from_facts

DAY = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")
HERO_Y = 1110
MILESTONE_KINDS = ("distance_km", "runs")
MILESTONE_TICKS = 40
_NO_ROUTE = [[0, 0], [1, 1]]   # spec_from_facts insists on a route; a run without one discards this


# ---- the route, drawn once and extended ---------------------------------------------------------------------------
class RouteLayers:
    """The route onto persistent layers (hairline ground, coloured line plus its mask, quarter-resolution glow) so each
    frame only adds the new segments. The head's dot and glow are the only per-frame drawing."""

    GLOW_REGION = (20, 200, 1060, 860)   # the route box plus the reach of the glow

    def __init__(self, pts, zones):
        self.pts, self.zones, self.n = pts, zones, len(pts)
        size = (W * SS, H * SS)
        self.base = Image.new("RGB", size, rgb(DARK))
        ImageDraw.Draw(self.base).line([(x * SS, y * SS) for x, y in pts], fill=rgb(HAIR_D), width=3 * SS, joint="curve")
        self.lines = Image.new("RGB", size, rgb(DARK))
        self.mask = Image.new("L", size, 0)
        self.glow = Image.new("RGB", (W // 4, H // 4), (0, 0, 0))
        self.k = 0
        self.final: Image.Image | None = None

    def _extend(self, upto: int) -> None:
        ld, md, gd = ImageDraw.Draw(self.lines), ImageDraw.Draw(self.mask), ImageDraw.Draw(self.glow)
        r = 6 * SS
        for i in range(self.k, upto):
            col = rgb(ZONE[self.zones[i + 1] - 1])
            a, b = self.pts[i], self.pts[i + 1]
            seg_ = [(a[0] * SS, a[1] * SS), (b[0] * SS, b[1] * SS)]
            ld.line(seg_, fill=col, width=12 * SS)
            md.line(seg_, fill=255, width=12 * SS)
            ld.ellipse([seg_[1][0] - r, seg_[1][1] - r, seg_[1][0] + r, seg_[1][1] + r], fill=col)
            md.ellipse([seg_[1][0] - r, seg_[1][1] - r, seg_[1][0] + r, seg_[1][1] + r], fill=255)
            gd.line([(a[0] / 4, a[1] / 4), (b[0] / 4, b[1] / 4)], fill=col, width=5)
        self.k = max(self.k, upto)

    def image(self, p: float) -> Image.Image:
        """The frame's route layer at supersampled size, drawn to fraction p."""
        if p >= 1 and self.final is not None:
            return self.final.copy()
        n = self.n
        self._extend(min(n - 1, int(p * (n - 1))))
        if p >= 1:
            self._extend(n - 1)
        img = self.base.copy()
        if p <= 0:
            return img
        drawn = head(self.pts, p)
        hx, hy = drawn[-1]
        g = self.glow.copy()
        if p < 1:
            hz = self.zones[min(int(p * (n - 1)) + 1, n - 1)]
            ImageDraw.Draw(g).ellipse([(hx - 34) / 4, (hy - 34) / 4, (hx + 34) / 4, (hy + 34) / 4],
                                      fill=mix(ZONE[hz - 1], "#FFFFFF", 0.4))
        img = screen_glow(img, g, 6, 1.15, self.GLOW_REGION)
        img.paste(self.lines, (0, 0), self.mask)
        ImageDraw.Draw(img).ellipse([(hx - 11) * SS, (hy - 11) * SS, (hx + 11) * SS, (hy + 11) * SS], fill=rgb(brand.BONE))
        if p >= 1:
            self.final = img
            return img.copy()
        return img


# ---- run ----------------------------------------------------------------------------------------------------------
@dataclass
class RunLoop:
    label: str
    label_col: str
    date: str
    route: list | None          # unit-free polyline, or None (no route opted in: the km bars carry the card)
    route_zone: list | None     # zone per route point (1..5)
    hero: str
    unit: str
    stats: list
    zone_s: list
    bars: list | None = None    # [(seconds, zone, label)]: reps for an interval session, else each km (no route)
    avg_s: float | None = None  # the average the dashed line sits at
    pb: dict | None = None      # {"old_s": 1349, "new_s": 1301, "delta": "48 S"}


def run_loop_from_facts(f: dict) -> RunLoop:
    has_route = bool(f.get("route_xy") or f.get("route"))
    spec = spec_from_facts(f if has_route else {**f, "route_xy": _NO_ROUTE})
    km = spec.distance_km
    lane = SCORES_DARK.get(spec.run_type, brand.BONE)
    zone_s = [float(x) for x in (f.get("zone_s") or [])][:5]
    zone_s += [0.0] * (5 - len(zone_s))
    route = zones = None
    if has_route and not spec.reps and not f.get("pb"):
        route = prepare_route(spec.route, n=420, latlon=spec.latlon)
        bounds, acc = [], 0.0
        for x in spec.splits:
            acc += x.dist_km
            bounds.append((acc / km, x.zone or 2))
        zones = []
        for i in range(len(route)):
            fr_ = i / (len(route) - 1)
            zones.append(next((z for b, z in bounds if fr_ <= b + 1e-9), bounds[-1][1]))
    pace = fmt_pace(spec.duration_s / km)
    pb = bars = avg = None
    if spec.verdict.kind == "pb":
        v = spec.verdict
        pb = {"old_s": float(v.old), "new_s": float(spec.duration_s), "delta": f"{int(round(v.hero))} S"}
        hero, unit = fmt_dur(spec.duration_s), ""
        stats = [(pace, "/KM"), (fmt_dur(v.old), "OLD BEST"), (pb["delta"], "FASTER")]
    elif spec.reps:
        reps = [(r.pace_s, r.zone or 4, fmt_pace(r.pace_s)) for r in spec.reps]
        avg = sum(r[0] for r in reps) / len(reps)
        bars, hero, unit = reps, fmt_pace(avg), "/400 M"
        stats = [(f"{len(reps)}", "REPS"), (f"{km:.1f}", "KM"), (fmt_dur(spec.duration_s), "TIME")]
    else:
        hero, unit = f"{km:.1f}", "KM"
        stats = [(fmt_dur(spec.duration_s), "TIME"), (pace, "/KM")]
        if route is None:   # no route: the km bars, one per split, in their zone colour
            bars = [(x.pace_s, x.zone or 2, fmt_pace(x.pace_s)) for x in spec.splits]
            avg = spec.duration_s / km
    return RunLoop(spec.kind_label, brand.ARC if pb else lane, spec.date_label, route, zones, hero, unit, stats, zone_s,
                   bars, avg, pb)


class RunLoopRenderer(Loop):
    BOX = (110, 290, W - 110, 770)

    def __init__(self, s: RunLoop):
        self.s = s
        self.layers = None
        if s.route:
            self.layers = RouteLayers(fit(s.route, self.BOX), s.route_zone)
        self.hero = Hero.fitted(s.hero, M, HERO_Y, s.unit)

    def _bars(self, fr: Frame, t: float) -> None:
        bars = self.s.bars
        n = len(bars)
        x0, x1, base, top = M + 8, W - M - 8, 720, 330
        gap = 18 if n <= 12 else 6 if n <= 30 else 3
        bw = (x1 - x0 - gap * (n - 1)) / n
        tmax, tmin = max(b[0] for b in bars), min(b[0] for b in bars)
        step = min(0.13, 1.2 / n)

        def hgt(tt):   # taller = faster, a 5 s window so near-equal bars still read as equal
            return 160 + (tmax + 2.5 - tt) / max(5.0, tmax - tmin + 2.5) * (base - top - 160)

        def prog(i):
            return out_back(seg(t, 0.25 + i * step, 0.25 + i * step + 0.45), 1.6)
        glow = False
        for i, (tt, z, _) in enumerate(bars):
            p = prog(i)
            if p > 0 and seg(t, 0.25 + i * step, 0.25 + i * step + 0.25) < 1:
                x = x0 + i * (bw + gap)
                fr.glow_draw().rectangle([x / 4, (base - hgt(tt) * p) / 4, (x + bw) / 4, base / 4], fill=rgb(ZONE[z - 1]))
                glow = True
        if glow:
            fr.flush_glow(8, 0.9)
        for i, (tt, z, lab) in enumerate(bars):
            p = prog(i)
            if p <= 0:
                continue
            h = max(0.0, hgt(tt) * p)
            x = x0 + i * (bw + gap)
            fr.cv.rect(x, base - h, x + bw, base, rgb(ZONE[z - 1]), r=min(10, bw / 3), top_only=True)
            a = seg(t, 0.25 + i * step + 0.3, 0.25 + i * step + 0.55)
            if a > 0 and bw >= 60:   # the label sits inside the bar's top, clear of the average line's dashes
                fr.cv.text((x + bw / 2, base - h + 46), lab, S(34), fade(ZONE[z - 1], ink_on(ZONE[z - 1]), a), anchor="ms")
        pa = in_out_cubic(seg(t, 1.55, 2.0))
        if pa > 0 and self.s.avg_s:
            y = base - hgt(self.s.avg_s)
            x = x0
            while x < x0 + (x1 - x0) * pa:
                fr.cv.rect(x, y - 2, min(x + 18, x0 + (x1 - x0) * pa), y + 2, rgb(brand.BONE))
                x += 30

    def _pb(self, fr: Frame, t: float) -> None:
        """OLD BEST and TODAY as two bars; today's is cyan and shorter (less time), then the burst behind the time."""
        pb = self.s.pb
        x0, x1 = M, W - M
        w_new = clamp(pb["new_s"] / pb["old_s"])
        for j, (lab, secs, col, y, w) in enumerate((("OLD BEST", pb["old_s"], "#3A3F47", 420, 1.0),
                                                   ("TODAY", pb["new_s"], brand.ARC, 560, w_new))):
            pj = out_cubic(seg(t, 0.25 + j * 0.25, 1.0 + j * 0.25))
            if pj <= 0:
                continue
            fr.cv.rect(x0, y, x0 + (x1 - x0) * w * pj, y + 70, rgb(col), r=12)
            fr.cv.text((x0, y - 18), lab, G(24, 700), fade(DARK, QUIET_D, pj), tracking=3)
            fr.cv.text((x0 + (x1 - x0) * w * pj - 20, y + 52), fmt_dur(secs), S(48), fade(col, ink_on(col), pj), anchor="rs")
        cx, cy = self.hero.cx, self.hero.cy
        for k in range(3):
            p = seg(t, 1.25 + k * 0.12, 2.25 + k * 0.12)
            if 0 < p < 1:
                fr.cv.circle(cx, cy, 80 + out_cubic(p) * (520 + k * 80), outline=fade(DARK, brand.ARC, (1 - p) * 0.9),
                             width=6 - k * 1.5)
        p = seg(t, 1.2, 1.9)
        if 0 < p < 1:
            fr.glow_draw().ellipse([(cx - 360) / 4, (cy - 200) / 4, (cx + 360) / 4, (cy + 200) / 4],
                                   fill=mix("#000000", brand.ARC, math.sin(p * math.pi) * 0.55))
            fr.flush_glow(22, 1.0)

    def draw(self, fr: Frame, t: float) -> None:
        s = self.s
        pb = s.pb is not None
        if pb:
            self._pb(fr, t)
        elif s.bars:
            self._bars(fr, t)
        elif self.layers:
            fr.set_base(self.layers.image(in_out_cubic(seg(t, 0.2, 2.5))))
        t_line, t_rise, t_stats = ((0.95, 1.35), (1.15, 1.7), 1.6) if pb else ((2.15, 2.6), (2.35, 2.95), 2.75)
        # the zone strip is the lap line the number rises out of: effort first, then the number
        zone_strip(fr, s.zone_s, HERO_Y + 18, seg(t, *t_line))
        self.hero.draw(fr, brand.ARC if pb else brand.BONE, seg(t, *t_rise))
        stats_row(fr, s.stats, 1238, t, t_stats)
        chrome(fr, s.label, s.label_col, s.date)


# ---- week ---------------------------------------------------------------------------------------------------------
def _week_dates(days) -> str:
    try:
        a, b = date.fromisoformat(days[0]["date"]), date.fromisoformat(days[-1]["date"])
    except (KeyError, ValueError, TypeError, IndexError):
        return ""
    if a.month == b.month:
        return f"{a.day}-{b.day} {b.strftime('%b').upper()}"
    return f"{a.day} {a.strftime('%b').upper()}-{b.day} {b.strftime('%b').upper()}"


class WeekLoopRenderer(Loop):
    def __init__(self, f: dict):
        weekly_from_facts(f)   # validation: every day carries a distance and the zone time adds up
        if not f["distance_km"] or f["distance_km"] <= 0:
            raise ValueError("a week with no distance has no loop")
        self.f = f
        self.label = str(f["week_label"]).upper()[:24]
        self.dates = _week_dates(f["days"])
        km = float(f["distance_km"])
        self.pace = float(f.get("pace_s_per_km") or f["duration_s"] / km)
        self.hero = Hero.fitted(f"{km:.1f}", M, HERO_Y, "KM")

    def draw(self, fr: Frame, t: float) -> None:
        f, days = self.f, self.f["days"]
        x0, x1, base, top = M, W - M, 700, 300
        gap = 22
        bw = (x1 - x0 - gap * 6) / 7
        dmax = max(d["distance_km"] for d in days) or 1
        for i, d in enumerate(days[:7]):
            x = x0 + i * (bw + gap)
            fr.cv.text((x + bw / 2, base + 46), DAY[i], G(22, 700), rgb(QUIET_D), anchor="ms", tracking=3)
            if not d["distance_km"]:
                fr.cv.rect(x, base - 6, x + bw, base, rgb(HAIR_D), r=3)
                continue
            p = out_cubic(seg(t, 0.3 + i * 0.12, 0.3 + i * 0.12 + 0.7))
            if p <= 0:
                continue
            h = (base - top) * d["distance_km"] / dmax * p
            zs = d.get("zone_s") or []
            tot = sum(zs) or 1
            y = base
            for z, s_ in enumerate(zs[:5]):   # stacked Z1 at the bottom, Z5 on top: the ramp climbs with effort
                hh = h * s_ / tot
                if hh > 0:
                    fr.cv.rect(x, y - hh, x + bw, y, rgb(ZONE[z]))
                    y -= hh
            a = seg(t, 0.3 + i * 0.12 + 0.5, 0.3 + i * 0.12 + 0.8)
            if a > 0:
                fr.cv.text((x + bw / 2, base - h - 16), f"{d['distance_km']:.1f}", S(36), fade(DARK, brand.BONE, a),
                           anchor="ms")
        zs = [sum((d.get("zone_s") or [0] * 5)[z] for d in days) for z in range(5)]
        zone_strip(fr, zs, HERO_Y + 18, seg(t, 1.5, 2.0))
        self.hero.draw(fr, brand.BONE, seg(t, 1.8, 2.4))
        stats_row(fr, [(str(f["runs"]), "RUNS"), (fmt_dur(f["duration_s"]), "ON THE MOVE"), (fmt_pace(self.pace), "/KM AVG")],
                  1238, t, 2.4)
        chrome(fr, self.label, brand.BONE, self.dates)


# ---- milestone ----------------------------------------------------------------------------------------------------
def digits_width(s: str, font) -> float:
    """Width of Canvas.digits(s): tabular numerals, every digit one pitch wide."""
    pitch = max(font.getlength(c) for c in "0123456789") / SS
    return sum(pitch if c.isdigit() else font.getlength(c) / SS for c in s)


class MilestoneLoopRenderer(Loop):
    """The one card that counts up: the count is the meaning. A tick lands for each step as the number climbs."""

    COL = SCORES_DARK["MID"]

    def __init__(self, f: dict):
        if f.get("kind") not in MILESTONE_KINDS:
            raise ValueError("unknown milestone kind")
        value = int(f["value"])
        if not 1 <= value <= 999_999:
            raise ValueError("milestone value out of range")
        self.value, self.unit = value, "KM" if f["kind"] == "distance_km" else "RUNS"
        self.line, self.line_px = fit_text(str(f.get("line") or "")[:40], 76, W - 2 * M)
        self.final = f"{value:,}"
        unit_w = Canvas.text_width(self.unit, S(110)) + 16
        self.px = next((px for px in range(400, 60, -8) if digits_width(self.final, S(px)) + unit_w <= W - 2 * M), 60)
        self.num_w = digits_width(self.final, S(self.px))

    def draw(self, fr: Frame, t: float) -> None:
        cv = fr.cv
        p = out_quart(seg(t, 0.3, 2.6))
        v = int(round(self.value * p))
        done = p >= 1
        if t > 0.3:
            cv.digits((M, 760), f"{v:,}", S(self.px), rgb(self.COL) if done else rgb(brand.BONE))
        if done:
            cv.text((M + self.num_w + 16, 760), self.unit, S(110), fade(DARK, QUIET_D, seg(t, 2.6, 2.9)))
            q = seg(t, 2.6, 3.4)
            if 0 < q < 1:
                fr.glow_draw().rectangle([M / 4, 380 / 4, (W - M) / 4, 780 / 4],
                                         fill=mix("#000000", self.COL, math.sin(q * math.pi) * 0.5))
                fr.flush_glow(26, 1.0)
                cv.digits((M, 760), self.final, S(self.px), rgb(self.COL))
        x0, x1, y0 = M, W - M, 960
        tw = (x1 - x0) / MILESTONE_TICKS
        for i in range(int(MILESTONE_TICKS * p)):
            cv.rect(x0 + i * tw, y0, x0 + i * tw + max(2.0, tw * 0.55), y0 + 90, mix("#4A4F57", self.COL, i / MILESTONE_TICKS))
        if self.line:
            cv.text((M, 1260), self.line, S(self.line_px), fade(DARK, brand.BONE, seg(t, 3.0, 3.5)))
        chrome(fr, "LIFETIME", self.COL, "")


# ---- entry points -------------------------------------------------------------------------------------------------
def render_run_loop(facts: dict, out_path):
    return RunLoopRenderer(run_loop_from_facts(facts)).render(out_path)


def render_week_loop(facts: dict, out_path):
    return WeekLoopRenderer(facts).render(out_path)


def render_milestone_loop(facts: dict, out_path):
    return MilestoneLoopRenderer(facts).render(out_path)
