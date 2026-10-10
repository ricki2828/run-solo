"""Weekly recap: seven day-bars stack by zone, the score changes tick up, then the week's best moment."""
from __future__ import annotations

import math
from dataclasses import dataclass

from . import _tokens as T
from ._common import M, RIGHT, Theme, header, signoff
from ._draw import FPS, W, Canvas, clamp, grot, in_out_cubic, lerp, out_back, out_cubic, out_quart, saira, seg

DURATION = 13.5
N_FRAMES = int(round(DURATION * FPS))

BARS0 = 0.55
COMPRESS = (4.3, 5.1)
SCORES0 = 5.0
EXIT1 = (8.2, 8.6)
BEST_T = 8.9
EXIT2 = (11.0, 11.4)
SIGN_T = 11.45


@dataclass
class Day:
    label: str  # "M"
    zone_min: list[float]  # minutes in Z1..Z5; all zero = rest day


@dataclass
class ScoreChange:
    name: str  # AEROBIC | SPEED | MID | LONG
    delta: int  # the week's move; the facts carry moves, not absolute scores


@dataclass
class Best:
    label: str = "BEST MOMENT"
    text: str = ""  # one sentence, wrapped big
    pb: bool = False  # cyan rule when it is a PB


@dataclass
class WeeklySpec:
    week_label: str  # "WEEK 41"
    total_km: float
    runs: int
    total_min: float
    days: list[Day]
    scores: list[ScoreChange]
    best: Best
    signoff: str = "See you next Sunday."
    flood_zone: int | None = None
    title: str = "YOUR WEEK"

    def __post_init__(self):
        if len(self.days) != 7:
            raise ValueError("a week has 7 days")
        mins = sum(sum(d.zone_min) for d in self.days)
        if abs(mins - self.total_min) > 0.02 * self.total_min:
            raise ValueError(f"days add up to {mins:.0f} min, week says {self.total_min:.0f}")
        ran = sum(1 for d in self.days if sum(d.zone_min) > 0)
        if ran != self.runs:
            raise ValueError(f"{ran} days with running but runs={self.runs}")


SCORE_KEYS = ("aerobic", "speed", "mid", "long")
DAY_LABELS = "MTWTFSS"


def weekly_from_facts(f: dict, signoff: str = "See you next Sunday.") -> WeeklySpec:
    """Same schema as the weekly card: week_label, distance_km, runs, duration_s, days[{zone_s}],
    score_moves{aerobic..long}, best_moment{text}. duration_s must equal the days' zone time."""
    days = [Day(DAY_LABELS[i], [x / 60 for x in (d.get("zone_s") or [0] * 5)]) for i, d in enumerate(f["days"])]
    moves = f.get("score_moves") or {}
    best = f.get("best_moment") or {}
    return WeeklySpec(
        week_label=str(f["week_label"]).upper(), total_km=float(f["distance_km"]), runs=int(f["runs"]),
        total_min=f["duration_s"] / 60, days=days,
        scores=[ScoreChange(k.upper(), int(round(moves[k]))) for k in SCORE_KEYS if k in moves],
        best=Best(text=best.get("text", ""), pb=bool(best.get("pb"))), signoff=signoff)


class WeeklyVideo:
    def __init__(self, spec: WeeklySpec):
        self.s = spec
        self.th = Theme(spec.flood_zone)
        self.max_min = max(sum(d.zone_min) for d in spec.days) or 1

    def _a_hdr(self, t):
        return 1 - in_out_cubic(seg(t, *EXIT2))

    def frame(self, t: float):
        th, s = self.th, self.s
        cv = th.canvas()
        header(cv, th, s.title, s.week_label, min(self._a_hdr(t), clamp(seg(t, 0, 0.4))))
        a1 = 1 - in_out_cubic(seg(t, *EXIT1))
        if t < EXIT1[1]:
            self._bars(cv, t, a1)
            self._scores(cv, t, a1)
        if EXIT1[1] - 0.05 <= t < EXIT2[1]:
            self._best(cv, t, 1 - in_out_cubic(seg(t, *EXIT2)))
        if t >= SIGN_T:
            signoff(cv, th, t, SIGN_T, s.signoff)
        return cv.finish()

    def _bars(self, cv: Canvas, t: float, a: float):
        th, s = self.th, self.s
        k = in_out_cubic(seg(t, *COMPRESS))
        # hero total
        hp = out_quart(seg(t, 0.5, 3.0))
        size = int(lerp(300, 170, k))
        base_y = lerp(440, 345, k)
        ha = a * clamp(seg(t, 0.2, 0.6))
        f = saira(size)
        w = cv.digits((M - 4, base_y), f"{s.total_km * hp:.1f}", f, th.fade(th.ink, ha))
        cv.text((M + w + 18, base_y), "KM", saira(int(size * 0.36)), th.fade(th.quiet, ha))
        h, m = divmod(int(round(s.total_min)), 60)
        sub = f"{s.runs} RUN{'S' if s.runs != 1 else ''}  /  {h}H {m:02d}M"
        cv.text((M, base_y + (66 if k < 0.5 else 56)), sub, grot(36, 600), th.fade(th.quiet, ha * clamp(seg(t, 1.0, 1.5))),
                tracking=4)
        # bars
        base = lerp(1080, 650, k)
        maxh = lerp(500, 150, k)
        bw = 92
        gap = (RIGHT - M - 7 * bw) / 6
        cv.rect(M, base, RIGHT, base + 3, th.fade(th.hair, a))
        for i, d in enumerate(s.days):
            tot = sum(d.zone_min)
            q = seg(t, BARS0 + i * 0.22, BARS0 + i * 0.22 + 0.8)
            e = out_back(q, 1.05)
            x = M + i * (bw + gap)
            if tot <= 0:
                cv.rect(x + bw * 0.3, base - 8, x + bw * 0.7, base - 2, th.fade(th.quiet, a * clamp(q * 2)), r=3)
            else:
                full = maxh * tot / self.max_min * clamp(e, 0, 1.05)
                y = base
                for z, mins in enumerate(d.zone_min):
                    if mins <= 0:
                        continue
                    sh = full * mins / tot
                    top = y - sh
                    last = z == max(j for j, mm in enumerate(d.zone_min) if mm > 0)
                    if sh > 0.8:
                        cv.rect(x, top, x + bw, y + (1 if not last else 0), th.fade(T.ZONES[z], a),
                                r=14 if last else 0, top_only=True)
                    y = top
                la = a * out_cubic(seg(q, 0.6, 1.0))
                if la > 0 and k < 0.5:
                    cv.text((x + bw / 2, y - 14), f"{int(round(tot))}", saira(44), th.fade(th.ink, la * (1 - k * 2)),
                            anchor="ms")
            cv.text((x + bw / 2, base + 46), d.label, grot(34, 600), th.fade(th.quiet, a * clamp(q * 2)), anchor="ms")
        lg = a * out_cubic(seg(t, 3.2, 3.8)) * (1 - k)
        if lg > 0:
            cv.text((M, 1262), "MINUTES BY ZONE", grot(34, 600), th.fade(th.quiet, lg), tracking=2)
            x = RIGHT - 5 * 104
            for z in range(5):
                cv.rect(x, 1236, x + 26, 1262, th.fade(T.ZONES[z], lg), r=5)
                cv.text((x + 34, 1262), f"Z{z + 1}", grot(34, 600), th.fade(th.quiet, lg))
                x += 104

    def _scores(self, cv: Canvas, t: float, a: float):
        th, s = self.th, self.s
        for i, sc in enumerate(s.scores):
            t0 = SCORES0 + i * 0.4
            q = out_cubic(seg(t, t0, t0 + 0.45))
            if q <= 0:
                continue
            base = 880 + i * 125
            off = (1 - q) * 30
            col = th.scores[sc.name]
            al = a * q
            cv.rect(M, base - 112, RIGHT, base - 109, th.fade(th.hair, al))
            cv.rect(M, base - 90, M + 12, base - 8, th.fade(col, al), r=4)
            cv.text((M + 34, base - 28 + off), sc.name, grot(36, 700), th.fade(th.ink, al), tracking=4)
            d = sc.delta
            val = d * out_quart(seg(t, t0 + 0.3, t0 + 1.5))
            txt = f"{'+' if d > 0 else ''}{int(round(val))}" if d else "0"
            cv.digits((700, base - 4 + off), txt, saira(128), th.fade(col, al), anchor="r")
            da = al * seg(t, t0 + 0.9, t0 + 1.4)
            if da > 0:
                cx, cy, r = 780, base - 52, 24
                if d > 0:
                    cv.poly([(cx - r, cy + r * 0.8), (cx + r, cy + r * 0.8), (cx, cy - r * 0.9)], th.fade(col, da))
                elif d < 0:
                    cv.poly([(cx - r, cy - r * 0.8), (cx + r, cy - r * 0.8), (cx, cy + r * 0.9)], th.fade(col, da))
                else:
                    cv.rect(cx - r, cy - 4, cx + r, cy + 4, th.fade(col, da), r=3)
                    cv.text((cx + 44, base - 28), "HOLD", saira(80), th.fade(col, da))

    def _wrap(self, text, max_lines=6):
        """Largest Saira size whose wrapped lines fit the width and max_lines."""
        words = text.upper().split()
        width = RIGHT - M
        for px in range(320, 90, -6):
            f = saira(px)
            lines, cur = [], ""
            for w in words:
                trial = (cur + " " + w).strip()
                if f.getlength(trial) / 2 <= width:
                    cur = trial
                else:
                    lines.append(cur)
                    cur = w
            lines.append(cur)
            if len(lines) <= max_lines and len(lines) * px * 0.76 <= 760 and all(f.getlength(x) / 2 <= width for x in lines):
                return px, lines
        return 90, lines

    def _best(self, cv: Canvas, t: float, a: float):
        th, b = self.th, self.s.best
        q = seg(t, BEST_T, BEST_T + 0.55)
        e = out_back(q, 1.6)
        al = clamp(q * 2.2) * a
        px, lines = self._wrap(b.text)
        lh = px * 0.76
        block = len(lines) * lh
        top = 700 - block / 2  # centred in the free area under the header
        cv.text((M, top - 70), b.label, grot(40, 700), th.fade(th.quiet, al), tracking=6)
        for i, ln in enumerate(lines):
            la = clamp(seg(t, BEST_T + 0.12 * i, BEST_T + 0.12 * i + 0.45)) * a
            cv.text((M - 6, top + (i + 1) * lh - (1 - out_cubic(clamp(seg(t, BEST_T + 0.12 * i, BEST_T + 0.12 * i + 0.45)))) * 30),
                    ln, saira(px), th.fade(th.ink, la))
        rw = out_cubic(seg(t, BEST_T + 0.15 + 0.12 * len(lines), BEST_T + 0.85 + 0.12 * len(lines)))
        rule = T.PB_CYAN if b.pb else th.scores["AEROBIC"]
        cv.rect(M, top + block + 40, M + (RIGHT - M) * rw, top + block + 56, th.fade(rule, a), r=8)

    def frames(self):
        for i in range(N_FRAMES):
            yield self.frame(i / FPS)


def render_weekly_video(spec: WeeklySpec, out_path):
    from .encode import encode

    return encode(WeeklyVideo(spec).frames(), out_path)
