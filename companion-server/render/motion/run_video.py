"""Run video: route draws itself, splits rise in zone colours, the verdict lands, Lap Line R signs off."""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from .. import brand
from ._common import M, RIGHT, Theme, fmt_dur, fmt_pace, header, signoff
from ._draw import (FPS, H, W, Canvas, clamp, grot, in_out_cubic, lerp, mix, out_back, out_cubic, out_quart, saira,
                    seg)
from ._geom import fit, head, prepare_route

DURATION = 13.5
N_FRAMES = int(round(DURATION * FPS))

# timeline (seconds)
ROUTE = (0.35, 3.55)
SHRINK = (3.95, 4.65)
BARS0, BARS_END = 4.45, 7.0
EXIT1 = (7.55, 7.95)
WORD_T = 8.05
HERO = (8.5, 10.2)
EXIT2 = (11.0, 11.4)
SIGN_T = 11.45


@dataclass
class Split:
    label: str
    pace_s: float  # seconds per km
    zone: int | None = None  # 1..5, None when there is no HR
    dist_km: float = 1.0  # the last split is usually a partial km


@dataclass
class Verdict:
    kind: str  # faster | slower | holding | pb | done (neutral)
    hero: float  # the number that counts up (e.g. seconds per km gained)
    decimals: int = 0
    unit: str = "S/KM"
    context: str = ""  # small caps line above the word, e.g. "VS YOUR LAST 10K"
    caption: str = ""  # one dry sentence under the number
    word: str | None = None
    # the facts the hero is derived from: pace (s/km) for faster/slower/holding, total seconds for pb
    old: float | None = None
    new: float | None = None
    fmt: str = "num"  # "num", or "mss" when the hero is a duration in seconds shown as m:ss


@dataclass
class RunVideoSpec:
    kind_label: str  # "EASY RUN"
    date_label: str  # "SAT 10 OCT"
    route: list  # [(lat, lon), ...] or x/y when latlon=False (the app's shape grid, y down)
    distance_km: float
    duration_s: float
    splits: list[Split]
    verdict: Verdict
    run_type: str = "AEROBIC"  # AEROBIC | SPEED | MID | LONG: colour when there is no HR
    flood_zone: int | None = None  # 1..5 for hard runs: the full zone flood
    signoff: str = "Same time next run."
    latlon: bool = True
    reps: list[Split] | None = None  # interval sessions: one bar per rep (pace_s = rep time) instead of per km

    def __post_init__(self):
        self.validate()

    def validate(self):
        """One facts object: every number on screen must agree with the others."""
        v = self.verdict
        if v.kind not in WORDS:
            raise ValueError(f"unknown verdict kind {v.kind}")
        if self.reps:
            if not self.splits:
                self.splits = []
            return self._validate_verdict(v)
        if not self.splits:
            raise ValueError("no splits")
        if len(self.splits) != math.ceil(self.distance_km - 0.02):
            raise ValueError(f"{len(self.splits)} splits for {self.distance_km} km: show every km")
        d = sum(x.dist_km for x in self.splits)
        if abs(d - self.distance_km) > 0.05:
            raise ValueError(f"splits cover {d:.2f} km, run is {self.distance_km} km")
        t = sum(x.dist_km * x.pace_s for x in self.splits)
        if abs(t - self.duration_s) > 0.015 * self.duration_s:
            raise ValueError(f"splits sum to {t:.0f}s, run is {self.duration_s:.0f}s")
        self._validate_verdict(v)

    def _validate_verdict(self, v):
        if v.old is not None or v.new is not None:
            if v.old is None or v.new is None:
                raise ValueError("verdict needs both old and new")
            want = self.duration_s if v.kind == "pb" else self.duration_s / self.distance_km
            if abs(v.new - want) > 0.6:
                raise ValueError(f"verdict new={v.new} does not match the run ({want:.1f})")
            if round(abs(round(v.old) - round(v.new)), v.decimals) != round(v.hero, v.decimals):
                raise ValueError(f"hero {v.hero} != |old {v.old} - new {v.new}|")
        elif v.kind == "pb":
            raise ValueError("a PB verdict needs old and new so the hero can be checked")


def fmt_hero(v, val: float) -> str:
    if v.fmt == "mss":
        s = int(round(val))
        return f"{s // 60}:{s % 60:02d}"
    return f"{val:.{v.decimals}f}"


RUN_TYPE = {"easy": "AEROBIC", "long": "LONG", "tempo": "MID", "interval": "SPEED", "race": "SPEED"}


def spec_from_facts(f: dict, signoff: str = "Same time next run.") -> "RunVideoSpec":
    """Build the spec from the shared run-facts dict (same schema as the cards: distance_km, duration_s,
    pace_s_per_km, zone_s, route, verdict, headline, hero, pb_detail) plus `splits`."""
    from datetime import datetime

    dist, dur = float(f["distance_km"]), float(f["duration_s"])
    if "pace_s_per_km" in f and abs(f["pace_s_per_km"] - dur / dist) > 2:
        raise ValueError(f"pace {f['pace_s_per_km']} s/km does not match {dur}s over {dist} km")
    if not f.get("splits"):
        raise ValueError("run facts need splits ({km, pace_s, zone}) to draw the bars")
    zs = list(f.get("zone_s") or [])
    hard = bool(f.get("pb")) or f.get("type") in ("interval", "race") or (
        sum(zs) > 0 and (zs[3] + zs[4]) / sum(zs) >= 0.4)
    flood = None
    if hard:
        flood = 5 if (len(zs) == 5 and zs[4] > zs[3]) else 4
    reps = None
    if f.get("type") == "interval" and f.get("reps"):
        rp = f["reps"]  # [{time_s, zone}, ...]
        times = [r["time_s"] for r in rp]
        h = f.get("hero")
        if h and isinstance(h.get("value"), str) and ":" in h["value"]:
            m, s_ = h["value"].split(":")
            if abs(int(m) * 60 + int(s_) - sum(times) / len(times)) > 1:
                raise ValueError("hero rep average disagrees with the rep times")
        reps = [Split(str(i + 1), float(r["time_s"]), r.get("zone"), 0.4) for i, r in enumerate(rp)]
    # facts splits are {km: length of the split, pace_s, zone}; the last one is usually a partial km
    splits = []
    for i, x in enumerate(f["splits"]):
        km = float(x["km"])
        splits.append(Split(str(i + 1) if km >= 0.995 else f"{dist:.1f}", float(x["pace_s"]), x.get("zone"), km))
    when = datetime.fromisoformat(f["start_local"])
    if f.get("pb"):
        pbd = f["pb_detail"]
        v = Verdict("pb", abs(pbd["delta_s"]), 0, "SEC", context=str(pbd["label"]).upper(),
                    caption=f.get("headline", ""), old=pbd["previous_s"], new=dur)
    elif f["verdict"] == "done":
        # no comparison to draw: the distance is the hero, and the word is the session, never a pace claim
        v = Verdict("done", dist, 2, "KM", context="DISTANCE", caption=f.get("headline", ""), word=f["title"].upper())
    else:
        h = f.get("hero")
        if h:
            val = h["value"]
            secs = (int(val.split(":")[0]) * 60 + int(val.split(":")[1])) if isinstance(val, str) and ":" in val else float(val)
            v = Verdict(f["verdict"], secs, 0, str(h.get("unit", "")), fmt="mss" if isinstance(val, str) and ":" in val else "num",
                        context="AVERAGE REP" if reps else "AVERAGE PACE", caption=f.get("headline", ""))
        else:
            v = Verdict(f["verdict"], dur / dist, 0, "/KM AVG", fmt="mss", context="AVERAGE PACE",
                        caption=f.get("headline", ""))
    return RunVideoSpec(
        kind_label=f["title"].upper(), date_label=when.strftime("%a %-d %b").upper(),
        route=f["route_xy"] if f.get("route_xy") else f["route"], latlon=not f.get("route_xy"),
        distance_km=dist, duration_s=dur, splits=splits, verdict=v, run_type=RUN_TYPE.get(f.get("type"), "AEROBIC"),
        flood_zone=flood, signoff=signoff, reps=reps)


# "done" is the neutral kind for a run with no comparison: it claims nothing about pace against last time
WORDS = {"faster": "FASTER", "slower": "SLOWER", "holding": "HOLDING", "pb": "NEW PB", "done": "DONE"}


def _star(cx, cy, r):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * 0.42
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


class RunVideo:
    def __init__(self, spec: RunVideoSpec):
        spec.validate()
        self.s = spec
        self.th = Theme(spec.flood_zone)
        th = self.th
        route = prepare_route(spec.route, latlon=spec.latlon)
        self.big = fit(route, (M + 20, 255, RIGHT - 20, 835))
        self.mini = fit(route, (M + 6, 245, 372, 450))
        self.accent = th.scores[spec.run_type]
        self.line_col = brand.BONE if th.flood else self.accent
        v = spec.verdict
        self.word = v.word or WORDS[v.kind]
        self.vcol = {"faster": th.mint, "slower": th.verm, "holding": th.ink,
                     "pb": th.ink, "done": self.accent}[v.kind]   # done: the run type's colour
        self.vrule = brand.ARC if v.kind == "pb" else self.vcol
        sp = [x.pace_s for x in spec.splits]
        self.bars = spec.reps or spec.splits
        sp = [x.pace_s for x in self.bars]
        self.speeds = [1000 / p for p in sp]
        self.avg_pace = spec.duration_s / spec.distance_km

    def _a_hdr(self, t):
        return 1 - in_out_cubic(seg(t, *EXIT2))

    # ---- frame ----
    def frame(self, t: float):
        th, s = self.th, self.s
        cv = th.canvas()
        self._hdr = None
        a1 = 1 - in_out_cubic(seg(t, *EXIT1))  # scenes 1+2 contents
        if t < EXIT1[1]:
            self._route_and_stats(cv, t, a1)
            if t >= BARS0 - 0.1:
                self._bars(cv, t, a1)
        if t >= EXIT1[1]:
            header(cv, th, s.kind_label, s.date_label, self._a_hdr(t))
        if t >= WORD_T - 0.05 and t < EXIT2[1]:
            self._verdict(cv, t, 1 - in_out_cubic(seg(t, *EXIT2)))
        if t >= SIGN_T:
            signoff(cv, th, t, SIGN_T, s.signoff)
        return cv.finish()

    # ---- scene 1 + 2: route ----
    def _route_and_stats(self, cv: Canvas, t: float, a: float):
        th, s = self.th, self.s
        p = in_out_cubic(seg(t, *ROUTE))
        k = in_out_cubic(seg(t, *SHRINK))
        pts = [(lerp(a_[0], b_[0], k), lerp(a_[1], b_[1], k)) for a_, b_ in zip(self.big, self.mini)]
        wid = lerp(15, 9, k)
        h = head(pts, p)
        col = th.fade(self.line_col, a)
        gcol = self.accent if not th.flood else (brand.ARC if s.verdict.kind == "pb" else self.accent)
        cv.halo_line(h, wid * 1.3)
        cv.add_glow(gcol, 0.30 * a, 2.5)
        cv.add_glow(gcol, 0.30 * a, 7.0)
        cv.apply_glow()
        header(cv, th, s.kind_label, s.date_label, min(self._a_hdr(t), clamp(seg(t, 0.0, 0.4))))
        # ghost track guides the eye
        cv.line(pts, wid * 0.8, th.fade(th.hair, a))
        cv.line(h, wid, col)
        if th.flood:
            cv.line(h, wid * 0.35, th.fade("#FFFFFF", a))
        # start marker pops, then pulses once
        sp = out_back(seg(t, ROUTE[0], ROUTE[0] + 0.35))
        x0, y0 = pts[0]
        ring = seg(t, ROUTE[0], ROUTE[0] + 0.9)
        if 0 < ring < 1:
            cv.circle(x0, y0, lerp(14, 58, out_cubic(ring)) * (1 if k == 0 else 1 - k * 0.5), outline=th.fade(col, (1 - ring) * 0.6),
                      width=3)
        r_s = lerp(12, 8, k)
        cv.circle(x0, y0, r_s * 1.0 * clamp(sp, 0, 1.3) + 4 * (1 - k) * clamp(sp, 0, 1.3), fill=th.fade(th.ground, a))
        cv.circle(x0, y0, r_s * clamp(sp, 0, 1.3), fill=col)
        # head dot
        if 0 < p < 1:
            cv.circle(h[-1][0], h[-1][1], wid * 0.95, fill=th.fade("#FFFFFF" if th.flood else th.ground, a))
            cv.circle(h[-1][0], h[-1][1], wid * 0.62, fill=col)
        # finish marker
        fp = out_back(seg(t, ROUTE[1] - 0.12, ROUTE[1] + 0.3))
        if fp > 0:
            x1, y1 = pts[-1]
            r_f = lerp(17, 11, k) * clamp(fp, 0, 1.3)
            cv.circle(x1, y1, r_f + 5, fill=th.fade(th.ground, a))
            cv.circle(x1, y1, r_f, outline=th.fade(th.ink, a), width=lerp(5, 4, k))
            cv.circle(x1, y1, r_f * 0.45, fill=th.fade(th.ink, a))
        # tags
        cx = sum(q[0] for q in pts) / len(pts)
        cy = sum(q[1] for q in pts) / len(pts)
        self._tag(cv, pts[0], (cx, cy), "START", ROUTE[0] + 0.1, t, a, k, -0.6)
        self._tag(cv, pts[-1], (cx, cy), "FINISH", ROUTE[1], t, a, k, 0.6)
        # scene 1 big distance, counting with the route
        a_big = a * (1 - in_out_cubic(seg(t, SHRINK[0], SHRINK[0] + 0.45)))
        if a_big > 0:
            dist = s.distance_km * in_out_cubic(seg(t, ROUTE[0], ROUTE[1] - 0.3))
            f = saira(330 * 2 // 2)
            fk = th.fade(th.ink, a_big * clamp(seg(t, 0.2, 0.6)))
            cv.text((M, 1135 + (1 - a_big) * 24), "", f, fk)
            w = cv.digits((M, 1135 + (1 - a_big) * 24), f"{dist:.2f}", f, fk, anchor="l")
            cv.text((M + w + 22, 1135 + (1 - a_big) * 24), "KM", saira(120), th.fade(th.quiet, a_big), anchor="ls")
            q = seg(t, 2.9, 3.4)
            self._stat(cv, M, 1225, fmt_dur(s.duration_s), "TIME", a_big * q, 84)
            for x, (val, lab) in zip((380, 700), self._extra_stats()):
                self._stat(cv, x, 1225, val, lab, a_big * q, 84)
        # scene 2 stats right of the thumbnail
        a_s2 = a * in_out_cubic(seg(t, SHRINK[0] + 0.35, SHRINK[1] + 0.25))
        if a_s2 > 0:
            off = (1 - a_s2) * 24
            f = saira(190)
            w = cv.digits((430, 365 + off), f"{s.distance_km:.2f}", f, th.fade(th.ink, a_s2))
            cv.text((430 + w + 16, 365 + off), "KM", saira(70), th.fade(th.quiet, a_s2))
            self._stat(cv, 430, 430 + off, fmt_dur(s.duration_s), "TIME", a_s2, 64)
            for x, (val, lab) in zip((640, 850) if s.reps else (690,), self._extra_stats()):
                self._stat(cv, x, 430 + off, val, lab, a_s2, 64)

    def _extra_stats(self):
        """Stats after TIME: avg pace for km runs, rep count and best rep for interval sessions."""
        if self.s.reps:
            return [(str(len(self.s.reps)), "REPS"), (fmt_pace(min(r.pace_s for r in self.s.reps)), "BEST")]
        return [(fmt_pace(self.avg_pace), "AVG PACE /KM")]

    def _tag(self, cv, pt, centre, text, t0, t, a, k, rot):
        th = self.th
        q = out_cubic(seg(t, t0, t0 + 0.3)) * a * (1 - k)
        if q <= 0.02:
            return
        f = grot(30, 700)
        w = cv.text_width(text, f, 3) + 30
        ox, oy = pt[0] - centre[0], pt[1] - centre[1]
        ang = math.atan2(oy, ox) + rot
        cx = clamp(pt[0] + math.cos(ang) * 74, M + w / 2, RIGHT - w / 2)
        cy = max(pt[1] + math.sin(ang) * 74, 225)
        cv.rect(cx - w / 2, cy - 24, cx + w / 2, cy + 24, th.fade(th.ink, q), r=24)
        cv.text((cx, cy + 11), text, f, th.fade(th.ground, q), anchor="ms", tracking=3)

    def _stat(self, cv, x, y, value, label, a, size):
        if a <= 0:
            return
        th = self.th
        cv.text((x, y), value, saira(size), th.fade(th.ink, a))
        cv.text((x, y + 44), label, grot(34, 600), th.fade(th.quiet, a), tracking=3)

    # ---- scene 2: splits ----
    def _bars(self, cv: Canvas, t: float, a: float):
        th, s = self.th, self.s
        bars = self.bars
        n = len(bars)
        base, top = 1110, 660
        span = RIGHT - M
        bw = min(96, span / (n * 1.2 - 0.2))
        gap = (span - bw * n) / (n - 1) if n > 1 else 0
        lo, hi = min(self.speeds), max(self.speeds)
        fastest = self.speeds.index(hi)
        cv.rect(M, base, RIGHT, base + 3, th.fade(th.hair, a))
        stagger = min(0.2, 2.1 / n)
        every = 1 if n <= 12 else math.ceil(68 / (bw + gap))
        lab_f = saira(int(clamp(bw * 0.62, 40, 56)))
        cum = 0.0
        for i, sp in enumerate(bars):
            cum += sp.dist_km
            u = (self.speeds[i] - lo) / (hi - lo) if hi > lo else 0.65
            full = (base - top) * (0.34 + 0.66 * u)
            q = seg(t, BARS0 + i * stagger, BARS0 + i * stagger + 0.6)
            hgt = full * clamp(out_back(q, 1.1), 0, 1.06)
            x = M + i * (bw + gap)
            col = brand.ZONE_RAMP[sp.zone - 1] if sp.zone else self.accent
            if th.flood and not sp.zone:
                col = brand.BONE
            if hgt > 1:
                cv.rect(x, base - hgt, x + bw, base, th.fade(col, a), r=min(14, bw * 0.22), top_only=True)
            la = out_cubic(seg(q, 0.55, 1.0)) * a
            show = i % every == 0 or i == fastest or i == n - 1 and every == 1
            best = bool(s.reps) and i == fastest
            if best and hgt > 1:  # the best rep is outlined and tagged
                cv.rect(x - 6, base - hgt - 6, x + bw + 6, base, th.fade(brand.ARC if th.flood else th.ink, a * q),
                        r=min(18, bw * 0.26), top_only=True)
                cv.rect(x, base - hgt, x + bw, base, th.fade(col, a), r=min(14, bw * 0.22), top_only=True)
            if la > 0 and show:
                cv.text((x + bw / 2, base - hgt - (62 if best else 16)), fmt_pace(sp.pace_s), lab_f,
                        th.fade(brand.ARC if (best and th.flood) else th.ink, la), anchor="ms")
                if best:
                    cv.text((x + bw / 2, base - hgt - 22), "BEST", grot(30, 700),
                            th.fade(brand.ARC if th.flood else th.ink, la), anchor="ms", tracking=3)
            if q > 0.2 and (i % every == 0 or i == n - 1):
                lab = ("R" + sp.label) if s.reps else sp.label
                cv.text((x + bw / 2, base + 48), lab, grot(34, 600), th.fade(th.quiet, a * clamp(q * 2)), anchor="ms")
        lg = a * out_cubic(seg(t, BARS_END - 1.2, BARS_END - 0.6))
        if lg > 0:
            cv.text((M, 1262), "TALLER = FASTER", grot(34, 600), th.fade(th.quiet, lg), tracking=2)
            if any(x.zone for x in bars):
                x = RIGHT - 5 * 104
                for z in range(5):
                    cv.rect(x, 1236, x + 26, 1262, th.fade(brand.ZONE_RAMP[z], lg), r=5)
                    cv.text((x + 34, 1262), f"Z{z + 1}", grot(34, 600), th.fade(th.quiet, lg))
                    x += 104

    # ---- scene 3: verdict ----
    def _verdict(self, cv: Canvas, t: float, a: float):
        th, v = self.th, self.s.verdict
        q = seg(t, WORD_T, WORD_T + 0.5)
        e = out_back(q, 1.7)
        al = clamp(q * 2.2) * a
        if v.context:
            cv.text((M, 290), v.context, grot(40, 700), th.fade(th.quiet, al), tracking=5)
        # icon + word, sized to fit the width
        size = lerp(0.82, 1.0, clamp(e, 0, 1.15))
        icon_w = 0 if v.kind == "done" else 190   # the session name stands alone, no icon
        wpx = 340
        while cv.text_width(self.word, saira(wpx)) > RIGHT - M - icon_w and wpx > 120:
            wpx -= 10
        wf = saira(int(wpx * size))
        cap = wpx * 0.70  # Saira cap height ~0.70 em
        isz = cap * 0.62 * size
        wbase = 290 + 56 + cap
        ix, iy = M + 66, wbase - cap / 2
        ic = th.fade(self.vrule if v.kind == "pb" else self.vcol, al)
        if v.kind == "faster":
            cv.poly([(ix - isz / 2, iy + isz * 0.42), (ix + isz / 2, iy + isz * 0.42), (ix, iy - isz * 0.42)], ic)
        elif v.kind == "slower":
            cv.poly([(ix - isz / 2, iy - isz * 0.42), (ix + isz / 2, iy - isz * 0.42), (ix, iy + isz * 0.42)], ic)
        elif v.kind == "holding":
            for dy in (-isz * 0.22, isz * 0.22):
                cv.rect(ix - isz / 2, iy + dy - isz * 0.09, ix + isz / 2, iy + dy + isz * 0.09, ic, r=6)
        elif v.kind == "done":
            pass
        else:
            cv.poly(_star(ix, iy, isz * 0.62), ic)
        cv.text((M + icon_w, wbase + (1 - clamp(e, 0, 1)) * 30), self.word, wf, th.fade(self.vcol, al), anchor="ls")
        # rule wipes across as the word lands
        rw = out_cubic(seg(t, WORD_T + 0.1, WORD_T + 0.75))
        ry = wbase + 34
        cv.rect(M, ry, M + (RIGHT - M) * rw, ry + 16, th.fade(self.vrule, a), r=8)
        # hero number counting up, sized to the widest value so it never changes size mid-count
        txt_max = fmt_hero(v, v.hero)
        hpx = 660
        unit_f = lambda px: saira(int(px * 0.26))  # noqa: E731

        def width(px):
            hf = saira(px)
            pitch = max(hf.getlength(c) for c in "0123456789") / 2
            return sum(pitch if c.isdigit() else hf.getlength(c) / 2 for c in txt_max) + 28 + cv.text_width(v.unit, unit_f(px))

        while width(hpx) > RIGHT - M + 6 and hpx > 200:
            hpx -= 10
        hp = out_quart(seg(t, *HERO))
        txt = fmt_hero(v, v.hero * hp)
        ha = a * clamp(seg(t, HERO[0] - 0.15, HERO[0] + 0.25))
        hbase = ry + 16 + 70 + hpx * 0.70
        hf = saira(hpx)
        w = cv.digits((M - 6, hbase), txt, hf, th.fade(self.vcol if v.kind != "pb" else th.ink, ha))
        cv.text((M + w + 28, hbase), v.unit, unit_f(hpx), th.fade(th.quiet, ha))
        cy = hbase + 78
        if v.kind == "done":   # time is the secondary stat
            d = int(round(self.s.duration_s))
            clock = f"{d // 3600}:{d % 3600 // 60:02d}:{d % 60:02d}" if d >= 3600 else f"{d // 60}:{d % 60:02d}"
            cv.text((M, cy - 8), clock, grot(54, 700), th.fade(th.ink, ha))
            cy += 62
        if v.caption:
            cv.text((M, cy), v.caption, grot(46, 500),
                    th.fade(th.ink, a * clamp(seg(t, HERO[1] - 0.6, HERO[1] - 0.1))))

    def frames(self):
        for i in range(N_FRAMES):
            yield self.frame(i / FPS)


def render_run_video(spec: RunVideoSpec, out_path):
    from .encode import encode

    return encode(RunVideo(spec).frames(), out_path)
