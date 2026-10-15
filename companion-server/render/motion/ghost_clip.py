"""Ghost race clip: today against the old best along the relative elevation profile, about 6 s, silent, 1080x1350.

The same facts as the trail record card (render/protocol.py TRAIL_KEYS): `elev_profile` is metres relative to the start,
`ghost_gap` is signed seconds along the same progress (POSITIVE = ahead of the old best). No map, no coordinates, no
dates; the trail's name is drawn only when the caller sent it (the runner's place opt-in).

How the race is drawn. Your clock runs 0..Y (today's best-measure time). You pass progress p at p*Y; the ghost passes the
same point `gap(p)` seconds later, so while you lead the ghost is behind you on the hill. The race clock keeps running
until the ghost finishes, so "level at the line" is something you watch. The last gap sample is pinned to the board's own
margin, so the number the clip lands on is the number on the record card.

Drawn with the motion kit (PIL), not Chromium: no browser on a tight host, and the render worker still runs it serially
under its video timeout.
"""
from __future__ import annotations

import bisect
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

from .. import brand
from ..cards.trail import CALM, _band, _grades, _smooth
from ._common import MINT_DARK, VERMILLION_DARK, M, RIGHT, fmt_dur
from ._draw import FPS, SS, W, Canvas, clamp, in_out_cubic, lerp, mix, out_cubic, seg
from ._draw import grot as _grot
from ._draw import saira as _saira

DURATION = 6.0
N_FRAMES = int(round(DURATION * FPS))

GHOST_SPREAD = 8.0      # the ghost's lead or lag on the hill is drawn this many times larger, or the two dots sit on one another
RACE = (0.45, 4.25)      # the clock runs
LAND = 4.25              # you are over the line; the ghost may still be running
HOOK = (4.8, 5.3)        # the hook replaces "YOU VS YOUR BEST"
FOOT = (5.0, 5.5)

PANEL_X0, PANEL_X1 = 48, W - 48
PX0, PX1 = 92, W - 92            # the profile and gap chart span
PROFILE_TOP, PROFILE_BASE = 808, 984
GAP_MID = 1092
GAP_AMP = 62
LABEL_Y = 1214
BAKED = 600                       # dense samples for the race maths
WHITE = "#FFFFFF"


def saira(px: int):
    """The canvas draws at SS x, so a font is built at SS x its 1x size (the other videos' px are half what they read as)."""
    return _saira(px * SS)


def grot(px: int, wght: int = 600):
    return _grot(px * SS, wght)


@dataclass
class GhostClipSpec:
    profile: list[int]
    gap: list[int]                 # signed seconds, + = ahead; the last sample is the board margin
    today_s: int                   # the app's best-measure time for today
    best_s: int                    # the old best (the ghost's finish)
    attempt: int
    distance_km: float | None = None
    clock_s: int | None = None     # raw duration, small underneath
    baro: bool = False
    name: str | None = None        # place opt-in only

    def __post_init__(self):
        if len(self.profile) < 8 or len(self.gap) < 2:
            raise ValueError("ghost clip needs a profile and a gap series")
        if self.today_s <= 0 or self.best_s <= 0:
            raise ValueError("ghost clip needs both times")


def spec_from_facts(f: Mapping[str, Any]) -> GhostClipSpec:
    """Raises ValueError when the facts cannot carry a race (no profile, no gap, no other run to race)."""
    rows = [dict(r) for r in f.get("trail_board") or []]
    today = next((r for r in rows if r.get("today")), None)
    others = [r for r in rows if not r.get("today")]
    profile, gap = f.get("elev_profile"), f.get("ghost_gap")
    if not (today and others and isinstance(profile, list) and isinstance(gap, list)):
        raise ValueError("no ghost to race")
    gap = [int(x) for x in gap]
    best = min(r["time_s"] for r in others)
    gap[-1] = best - today["time_s"]    # the card's own margin: one number everywhere
    return GhostClipSpec(
        profile=[int(x) for x in profile], gap=gap, today_s=int(today["time_s"]), best_s=int(best), attempt=int(today["attempt"]),
        distance_km=float(f["distance_km"]) if f.get("distance_km") else None,
        clock_s=int(f["duration_s"]) if f.get("duration_s") else None,
        baro=f.get("elev_src") == "baro", name=f.get("trail_name") or None)


def _interp(values: Sequence[float], x: float) -> float:
    """values at evenly spaced positions 0..1, read at x."""
    pos = clamp(x) * (len(values) - 1)
    lo = int(pos)
    hi = min(len(values) - 1, lo + 1)
    return values[lo] + (values[hi] - values[lo]) * (pos - lo)


def gap_text(s: int) -> str:
    """Seconds under a minute, m:ss from 60 (the hero and the hook say it the same way)."""
    return f"{s} S" if s < 60 else f"{s // 60}:{s % 60:02d}"


def hook_lines(spec: GhostClipSpec) -> tuple[str, str]:
    """The two lines of the hook, from the gap series: how far down the run got, and where it finished."""
    gap, n = spec.gap, len(spec.gap)
    final = spec.best_s - spec.today_s
    low_i = min(range(n), key=lambda i: gap[i])
    low = gap[low_i]
    if spec.distance_km:
        km = f"{spec.distance_km * low_i / (n - 1):.1f}".rstrip("0").rstrip(".")
        where = f"AT {km} KM"
    else:
        where = "ON THE WAY"
    down = f"DOWN {gap_text(-low)} {where}." if low <= -5 else None
    if final > 0:
        if down:
            return down, "WON IT AT THE LINE." if final < 10 else f"HOME {gap_text(final)} CLEAR."
        if low >= -2:
            return "AHEAD ALL THE WAY.", f"{gap_text(final)} FASTER."
        if final >= 10:
            return "PULLED AWAY.", f"{gap_text(final)} FASTER."
        return "NECK AND NECK.", f"{gap_text(final)} FASTER AT THE LINE."
    if final == 0:
        return down or "NECK AND NECK.", "LEVEL AT THE LINE."
    return "THE GHOST HELD ON.", f"{gap_text(-final)} OFF YOUR BEST."


class GhostClip:
    def __init__(self, spec: GhostClipSpec):
        self.s = spec
        y = float(spec.today_s)
        self.dense_gap = [_interp(spec.gap, i / (BAKED - 1)) for i in range(BAKED)]
        # when the ghost passes each point (race seconds), forced non-decreasing so the search below is well defined
        run, self.ghost_t = -1e9, []
        for i, v in enumerate(self.dense_gap):
            run = max(run, i / (BAKED - 1) * y + v)
            self.ghost_t.append(run)
        self.total = max(y, float(spec.best_s))
        self.prof = spec.profile if spec.baro else _smooth(spec.profile)
        self.lo = min(self.prof)
        self.span = max(max(self.prof) - self.lo, 20)
        self.grades = _grades(self.prof, (spec.distance_km or 5.0) * 1000)
        self.hook = hook_lines(spec)
        self.final = spec.best_s - spec.today_s
        self.gap_scale = GAP_AMP / max(max(abs(v) for v in spec.gap), 20)

    # ---- race state ---------------------------------------------------------------------------
    def state(self, t: float) -> tuple[float, float, int]:
        """-> (your progress, ghost progress, live gap in seconds) at video time t."""
        k = seg(t, *RACE)
        tau = lerp(k, in_out_cubic(k), 0.3) * self.total
        you = min(1.0, tau / self.s.today_s)
        j = bisect.bisect_right(self.ghost_t, tau)
        if j >= BAKED:
            ghost = 1.0
        elif j == 0:
            ghost = 0.0
        else:
            span = max(self.ghost_t[j] - self.ghost_t[j - 1], 1e-9)
            ghost = (j - 1 + (tau - self.ghost_t[j - 1]) / span) / (BAKED - 1)
        live = self.final if you >= 1.0 else round(_interp(self.dense_gap, you))
        return you, ghost, live

    # ---- drawing ------------------------------------------------------------------------------
    @staticmethod
    def _x(p: float) -> float:
        return PX0 + p * (PX1 - PX0)

    def _y(self, p: float) -> float:
        e = _interp(self.prof, p)
        return PROFILE_BASE - (e - self.lo) / (self.span * 1.05) * (PROFILE_BASE - PROFILE_TOP)

    def _profile(self, cv: Canvas):
        n = len(self.prof)
        for i in range(n - 1):
            col = _band(self.grades[i])[1] if self.s.baro else CALM
            p0, p1 = i / (n - 1), (i + 1) / (n - 1)
            x0, x1 = self._x(p0), self._x(p1) + 0.6
            cv.poly([(x0, PROFILE_BASE + 2), (x0, self._y(p0)), (x1, self._y(p1)), (x1, PROFILE_BASE + 2)], col)
        cv.line([(self._x(i / (n - 1)), self._y(i / (n - 1))) for i in range(n)], 5, brand.INK)

    def _ticks(self, cv: Canvas):
        d = self.s.distance_km
        labels = [(0.0, "Start")]
        if d and d >= 2:
            step = 1 if d <= 7 else 2 if d <= 14 else 5
            k = step
            while k < d - 0.6 * step:
                labels.append((k / d, f"{k} km"))
                k += step
        labels.append((1.0, "Finish"))
        for p, s in labels:
            cv.text((self._x(p), LABEL_Y), s, grot(30, 500), brand.QUIET, anchor="ls" if p == 0 else "rs" if p == 1 else "ms")

    def _gap_chart(self, cv: Canvas, you: float):
        y0 = GAP_MID
        cv.text((PX0, y0 - 40), "AHEAD", saira(34), brand.MINT, anchor="ls")
        cv.text((PX0, y0 + 66), "BEHIND", saira(34), brand.VERMILLION, anchor="ls")
        cv.text((PX1, y0 - 14), "YOUR BEST", saira(30), brand.QUIET, anchor="rs")
        for x in range(PX0, PX1, 22):   # the dashed baseline is the ghost
            cv.rect(x, y0 - 1, min(x + 11, PX1), y0 + 1, mix(WHITE, brand.QUIET, 0.7))
        if you <= 0:
            return
        steps = max(2, int(you * 150))
        vals = [_interp(self.dense_gap, i / steps * you) for i in range(steps + 1)]
        pts = [(self._x(i / steps * you), y0 - v * self.gap_scale) for i, v in enumerate(vals)]
        # one rounding for the colour and the big number: a gap that reads "0 S" is mint in both
        cols = [brand.MINT if round((u + v) / 2) >= 0 else brand.VERMILLION for u, v in zip(vals, vals[1:])]
        for a, b, col in zip(pts, pts[1:], cols):
            cv.poly([(a[0], y0), a, b, (b[0], y0)], mix(WHITE, col, 0.20))
        for a, b, col in zip(pts, pts[1:], cols):
            cv.line([a, b], 8, col)
        cv.circle(pts[-1][0], pts[-1][1], 15, fill=brand.INK)

    def _markers(self, cv: Canvas, you: float, ghost: float, done: bool):
        ghost = clamp(you + (ghost - you) * GHOST_SPREAD)   # drawn spread out; it still lands on the line with you
        gx, gy = self._x(ghost), self._y(ghost)
        yx, yy = self._x(you), self._y(you)
        cv.circle(gx, gy, 19, fill=WHITE, outline=brand.QUIET, width=7)
        cv.circle(yx, yy, 21, fill=brand.ARC if done and self.final > 0 else brand.INK, outline=WHITE, width=5)
        if abs(gx - yx) < 74:   # still close (the start, the line): stack YOU above BEST, both kept inside the panel and off the stroke
            cv.text((min(max(gx, PX0 + 40), PX1 - 40), gy - 38), "BEST", saira(34), brand.QUIET, anchor="ms")
            cv.text((min(max(yx, PX0 + 40), PX1 - 40), min(yy, gy) - 84), "YOU", saira(34), brand.INK, anchor="ms")
        else:
            cv.text((gx, gy - 38), "BEST", saira(34), brand.QUIET, anchor="ms")
            cv.text((yx, yy - 38), "YOU", saira(34), brand.INK, anchor="ms")

    def frame(self, t: float):
        cv = Canvas(brand.GROUND)
        fade = out_cubic(seg(t, 0.0, 0.4))
        you, ghost, live = self.state(t)
        done = you >= 1.0 and t >= LAND
        cv.vector("mark-on-light", M, 56, 66, alpha=fade)
        tag = f"{self.s.name} · run {self.s.attempt}" if self.s.name else f"Run {self.s.attempt}"
        cv.text((RIGHT, 108), tag, grot(34, 600), mix(brand.GROUND, brand.QUIET, fade), anchor="rs")
        # hero block
        cv.rect(PANEL_X0, 150, PANEL_X1, 712, brand.INK, r=56)
        hook = out_cubic(seg(t, *HOOK))
        if hook < 1:
            a = fade * (1 - hook)
            cv.text((M + 28, 262), "YOU VS YOUR BEST", saira(112), mix(brand.INK, brand.BONE, a), anchor="ls")
            cv.text((M + 28, 328), f"Run {self.s.attempt} against the ghost of your best", grot(38, 500),
                    mix(brand.INK, mix(brand.INK, brand.BONE, 0.62), a), anchor="ls")
        if hook > 0:
            rise = (1 - hook) * 26
            cv.text((M + 28, 262 + rise), self.hook[0], saira(112), mix(brand.INK, brand.BONE, hook), anchor="ls")
            cv.text((M + 28, 362 + rise), self.hook[1], saira(112), mix(brand.INK, brand.BONE, hook), anchor="ls")
        colour = brand.ARC if done and self.final > 0 and hook > 0 else (MINT_DARK if live >= 0 else VERMILLION_DARK)
        fg = mix(brand.INK, colour, fade)
        sign = "+" if live > 0 else "-" if live < 0 else ""
        mag = abs(live)
        num = f"{sign}{mag}" if mag < 60 else f"{sign}{mag // 60}:{mag % 60:02d}"
        used = cv.digits((M + 28, 650), num, saira(330), fg, anchor="l")
        if mag < 60:
            cv.text((M + 28 + used + 36, 650), "S", saira(330), fg, anchor="ls")
        if done:
            word = "NEW BEST" if self.final > 0 else "LEVEL" if self.final == 0 else "OFF BEST"
        else:
            word = "AHEAD" if live > 0 else "BEHIND" if live < 0 else "LEVEL"
        cv.text((PANEL_X1 - 52, 650), word, saira(76), mix(brand.INK, brand.BONE if done else colour, fade), anchor="rs")
        # panel: profile with the two markers, then the gap line
        cv.rect(PANEL_X0, 752, PANEL_X1, 1252, brand.HAIRLINE, r=56)
        cv.rect(PANEL_X0 + 2, 754, PANEL_X1 - 2, 1250, WHITE, r=54)
        self._profile(cv)
        self._markers(cv, you, ghost, done)
        self._gap_chart(cv, you)
        self._ticks(cv)
        # footer: the app's measure, the raw clock time small underneath it
        foot = f"{fmt_dur(self.s.today_s)} best-measure time"
        if self.s.clock_s and abs(self.s.clock_s - self.s.today_s) >= 1:
            foot += f", {fmt_dur(self.s.clock_s)} on the clock"
        a = out_cubic(seg(t, *FOOT))
        if a < 1:
            cv.text((M, 1306), "The ghost is your best run of this trail.", grot(30, 500),
                    mix(brand.GROUND, brand.QUIET, (1 - a) * fade), anchor="ls")
        if a > 0:
            cv.text((M, 1306), foot, grot(30, 500), mix(brand.GROUND, brand.QUIET, a), anchor="ls")
        return cv.finish()

    def frames(self):
        for i in range(N_FRAMES):
            yield self.frame(i / FPS)


def render_ghost_clip(spec: GhostClipSpec, out_path):
    from .encode import encode

    return encode(GhostClip(spec).frames(), out_path)
