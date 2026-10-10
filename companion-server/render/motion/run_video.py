"""Run video: route draws itself, splits rise in zone colours, the verdict lands, Lap Line R signs off."""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from . import _tokens as T
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


@dataclass
class Verdict:
    kind: str  # faster | slower | holding | pb
    hero: float  # the number that counts up (e.g. seconds per km gained)
    decimals: int = 0
    unit: str = "S/KM"
    context: str = ""  # small caps line above the word, e.g. "VS YOUR LAST 10K"
    caption: str = ""  # one dry sentence under the number
    word: str | None = None


@dataclass
class RunVideoSpec:
    kind_label: str  # "EASY RUN"
    date_label: str  # "SAT 10 OCT"
    route: list  # [(lat, lon), ...] or x/y when latlon=False
    distance_km: float
    duration_s: float
    splits: list[Split]
    verdict: Verdict
    run_type: str = "AEROBIC"  # AEROBIC | SPEED | MID | LONG: colour when there is no HR
    flood_zone: int | None = None  # 1..5 for hard runs: the full zone flood
    signoff: str = "Same time next run."
    latlon: bool = True


WORDS = {"faster": "FASTER", "slower": "SLOWER", "holding": "HOLDING", "pb": "NEW PB"}


def _star(cx, cy, r):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * 0.42
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


class RunVideo:
    def __init__(self, spec: RunVideoSpec):
        self.s = spec
        self.th = Theme(spec.flood_zone)
        th = self.th
        route = prepare_route(spec.route, latlon=spec.latlon)
        self.big = fit(route, (M + 20, 255, RIGHT - 20, 835))
        self.mini = fit(route, (M + 6, 245, 372, 450))
        self.accent = th.scores[spec.run_type]
        self.line_col = T.BONE if th.flood else self.accent
        v = spec.verdict
        if v.kind not in WORDS:
            raise ValueError(f"unknown verdict kind {v.kind}")
        self.word = v.word or WORDS[v.kind]
        self.vcol = {"faster": th.mint, "slower": th.verm, "holding": th.ink,
                     "pb": th.ink}[v.kind]
        self.vrule = T.PB_CYAN if v.kind == "pb" else self.vcol
        sp = [x.pace_s for x in spec.splits]
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
        gcol = self.accent if not th.flood else (T.PB_CYAN if s.verdict.kind == "pb" else self.accent)
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
            dist = s.distance_km * p
            f = saira(330 * 2 // 2)
            fk = th.fade(th.ink, a_big * clamp(seg(t, 0.2, 0.6)))
            cv.text((M, 1135 + (1 - a_big) * 24), "", f, fk)
            w = cv.digits((M, 1135 + (1 - a_big) * 24), f"{dist:.2f}", f, fk, anchor="l")
            cv.text((M + w + 22, 1135 + (1 - a_big) * 24), "KM", saira(120), th.fade(th.quiet, a_big), anchor="ls")
            q = seg(t, 2.9, 3.4)
            self._stat(cv, M, 1235, fmt_dur(s.duration_s), "TIME", a_big * q, 84)
            self._stat(cv, 430, 1235, fmt_pace(self.avg_pace), "AVG PACE /KM", a_big * q, 84)
        # scene 2 stats right of the thumbnail
        a_s2 = a * in_out_cubic(seg(t, SHRINK[0] + 0.35, SHRINK[1] + 0.25))
        if a_s2 > 0:
            off = (1 - a_s2) * 24
            f = saira(190)
            w = cv.digits((430, 365 + off), f"{s.distance_km:.2f}", f, th.fade(th.ink, a_s2))
            cv.text((430 + w + 16, 365 + off), "KM", saira(70), th.fade(th.quiet, a_s2))
            self._stat(cv, 430, 450 + off, fmt_dur(s.duration_s), "TIME", a_s2, 64)
            self._stat(cv, 700, 450 + off, fmt_pace(self.avg_pace), "AVG PACE /KM", a_s2, 64)

    def _tag(self, cv, pt, centre, text, t0, t, a, k, rot):
        th = self.th
        q = out_cubic(seg(t, t0, t0 + 0.3)) * a * (1 - k)
        if q <= 0.02:
            return
        f = grot(22, 700)
        w = cv.text_width(text, f, 3) + 26
        ox, oy = pt[0] - centre[0], pt[1] - centre[1]
        ang = math.atan2(oy, ox) + rot
        cx = clamp(pt[0] + math.cos(ang) * 74, M + w / 2, RIGHT - w / 2)
        cy = max(pt[1] + math.sin(ang) * 74, 225)
        cv.rect(cx - w / 2, cy - 17, cx + w / 2, cy + 17, th.fade(th.ink, q), r=17)
        cv.text((cx, cy + 8), text, f, th.fade(th.ground, q), anchor="ms", tracking=3)

    def _stat(self, cv, x, y, value, label, a, size):
        if a <= 0:
            return
        th = self.th
        cv.text((x, y), value, saira(size), th.fade(th.ink, a))
        cv.text((x, y + 38 if size > 70 else y + 32), label, grot(24, 600), th.fade(th.quiet, a), tracking=3)

    # ---- scene 2: splits ----
    def _bars(self, cv: Canvas, t: float, a: float):
        th, s = self.th, self.s
        n = len(s.splits)
        base, top = 1130, 655
        span = RIGHT - M
        bw = min(96, span / (n * 1.2 - 0.2))
        gap = (span - bw * n) / max(n - 1, 1) if n > 1 else 0
        if n == 1:
            gap = 0
        lo, hi = min(self.speeds), max(self.speeds)
        fastest = self.speeds.index(hi)
        cv.rect(M, base, RIGHT, base + 3, th.fade(th.hair, a))
        stagger = min(0.2, 2.1 / max(n, 1))
        every = 1 if bw >= 56 else math.ceil(56 / (bw + gap))
        lab_f = saira(int(clamp(bw * 0.62, 34, 50)))
        for i, sp in enumerate(s.splits):
            u = (self.speeds[i] - lo) / (hi - lo) if hi > lo else 0.65
            full = (base - top) * (0.34 + 0.66 * u)
            q = seg(t, BARS0 + i * stagger, BARS0 + i * stagger + 0.6)
            hgt = full * clamp(out_back(q, 1.1), 0, 1.06)
            x = M + i * (bw + gap)
            col = T.ZONES[sp.zone - 1] if sp.zone else self.accent
            if th.flood and not sp.zone:
                col = T.BONE
            if hgt > 1:
                cv.rect(x, base - hgt, x + bw, base, th.fade(col, a), r=min(14, bw * 0.22), top_only=True)
            la = out_cubic(seg(q, 0.55, 1.0)) * a
            if la > 0 and (i % every == 0 or i == fastest):
                is_f = i == fastest
                cv.text((x + bw / 2, base - hgt - 16), fmt_pace(sp.pace_s), lab_f,
                        th.fade(th.ink if is_f else th.quiet if th.flood else th.ink, la), anchor="ms")
            if q > 0.2 and (i % every == 0):
                cv.text((x + bw / 2, base + 46), sp.label, grot(26, 600), th.fade(th.quiet, a * clamp(q * 2)), anchor="ms")
        lg = a * out_cubic(seg(t, BARS_END - 1.2, BARS_END - 0.6))
        if lg > 0:
            cv.text((M, 1262), "TALLER = FASTER", grot(22, 600), th.fade(th.quiet, lg), tracking=3)
            if any(x.zone for x in s.splits):
                x = RIGHT - 5 * 92 - 4
                for z in range(5):
                    cv.rect(x, 1244, x + 20, 1264, th.fade(T.ZONES[z], lg), r=4)
                    cv.text((x + 30, 1264), f"Z{z + 1}", grot(24, 600), th.fade(th.quiet, lg))
                    x += 92

    # ---- scene 3: verdict ----
    def _verdict(self, cv: Canvas, t: float, a: float):
        th, v = self.th, self.s.verdict
        q = seg(t, WORD_T, WORD_T + 0.5)
        e = out_back(q, 1.7)
        al = clamp(q * 2.2) * a
        if v.context:
            cv.text((M, 335), v.context, grot(34, 700), th.fade(th.quiet, al), tracking=5)
        # icon + word
        size = lerp(0.82, 1.0, clamp(e, 0, 1.15))
        wf = saira(int(270 * size))
        isz = 150 * size
        ix, iy = M + isz / 2, 600 - 105
        ic = th.fade(self.vrule if v.kind == "pb" else self.vcol, al)
        if v.kind == "faster":
            cv.poly([(ix - isz / 2, iy + isz * 0.42), (ix + isz / 2, iy + isz * 0.42), (ix, iy - isz * 0.42)], ic)
        elif v.kind == "slower":
            cv.poly([(ix - isz / 2, iy - isz * 0.42), (ix + isz / 2, iy - isz * 0.42), (ix, iy + isz * 0.42)], ic)
        elif v.kind == "holding":
            for dy in (-isz * 0.22, isz * 0.22):
                cv.rect(ix - isz / 2, iy + dy - isz * 0.09, ix + isz / 2, iy + dy + isz * 0.09, ic, r=6)
        else:
            cv.poly(_star(ix, iy, isz * 0.62), ic)
        cv.text((M + 190, 600 + (1 - clamp(e, 0, 1)) * 30), self.word, wf, th.fade(self.vcol, al), anchor="ls")
        # rule wipes across as the word lands
        rw = out_cubic(seg(t, WORD_T + 0.1, WORD_T + 0.75))
        cv.rect(M, 650, M + (RIGHT - M) * rw, 664, th.fade(self.vrule, a), r=7)
        # hero number counting up
        hp = out_quart(seg(t, *HERO))
        val = v.hero * hp
        txt = f"{val:.{v.decimals}f}"
        ha = a * clamp(seg(t, HERO[0] - 0.15, HERO[0] + 0.25))
        hf = saira(540)
        w = cv.digits((M - 6, 1115), txt, hf, th.fade(self.vcol if v.kind != "pb" else th.ink, ha))
        cv.text((M + w + 24, 1115), v.unit, saira(130), th.fade(th.quiet, ha))
        if v.caption:
            cv.text((M, 1205), v.caption, grot(44, 500), th.fade(th.ink, a * clamp(seg(t, HERO[1] - 0.6, HERO[1] - 0.1))))

    def frames(self):
        for i in range(N_FRAMES):
            yield self.frame(i / FPS)


def render_run_video(spec: RunVideoSpec, out_path):
    from .encode import encode

    return encode(RunVideo(spec).frames(), out_path)
