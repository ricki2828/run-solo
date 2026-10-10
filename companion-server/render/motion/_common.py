"""Theme, header and sign-off shared by the run and weekly videos."""
from __future__ import annotations

from .. import brand
from ._draw import (H, W, Canvas, clamp, grot, in_out_cubic, lerp, mix, out_back, out_cubic, rgb, saira, seg)

# Motion-only derivations for text on the zone floods: brand.py's light-ground colours lose contrast on a dark flood.
MINT_DARK, VERMILLION_DARK = "#5BE0AE", "#FF7B54"
SCORES_DARK = {"AEROBIC": "#7BDB4F", "SPEED": "#FF5AAE", "MID": "#B79BFF", "LONG": "#5CC0FF"}
SCORES_LIGHT = {k.upper(): v for k, v in brand.SCORE.items()}
LAP_LIGHT = "#0098B2"  # the Arc on mark-on-light.svg; the file's fill, used to find the lap line to wipe

M = 72  # side margin
RIGHT = W - M


class Theme:
    """Effort-adaptive ground: light for easy runs, a zone flood for hard ones."""

    def __init__(self, flood_zone: int | None = None):
        self.flood = flood_zone is not None
        if self.flood:
            if not 1 <= flood_zone <= 5:
                raise ValueError("flood_zone must be 1..5")
            self.ground = brand.ZONE_FLOOD[flood_zone - 1]
            self.ink = brand.BONE
            self.quiet = mix(self.ground, brand.BONE, 0.68)
            self.hair = mix(self.ground, brand.BONE, 0.16)
            self.mint, self.verm = MINT_DARK, VERMILLION_DARK
            self.scores = SCORES_DARK
            self.mark = "mark-on-dark"
            self.wordmark = "wordmark-on-dark"
        else:
            self.ground = brand.GROUND
            self.ink = brand.INK
            self.quiet = brand.QUIET
            self.hair = brand.HAIRLINE
            self.mint, self.verm = brand.MINT, brand.VERMILLION
            self.scores = SCORES_LIGHT
            self.mark = "mark-on-light"
            self.wordmark = "wordmark-on-light"

    def canvas(self) -> Canvas:
        return Canvas(self.ground)

    def fade(self, colour, a):
        """Colour as seen at opacity a over the (flat) ground."""
        return mix(self.ground, colour, a)


def fmt_dur(seconds: float) -> str:
    s = int(round(seconds))
    h, r = divmod(s, 3600)
    m, sec = divmod(r, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"


def fmt_pace(sec_per_km: float) -> str:
    s = int(round(sec_per_km))
    return f"{s // 60}:{s % 60:02d}"


def header(cv: Canvas, th: Theme, label: str, sub: str, a: float = 1.0):
    if a <= 0:
        return
    cv.text((M, 128), label, grot(44, 700), th.fade(th.ink, a), tracking=5)
    cv.text((M, 180), sub, grot(36, 500), th.fade(th.quiet, a), tracking=3)
    cv.vector(th.mark, RIGHT - 49, 82, 58, alpha=a)


def signoff(cv: Canvas, th: Theme, t: float, t0: float, line: str):
    """Lap Line R lands, the lap line runs through it, wordmark and one dry line follow."""
    p_r = out_cubic(seg(t, t0, t0 + 0.55))
    p_line = in_out_cubic(seg(t, t0 + 0.35, t0 + 1.0))
    p_word = out_cubic(seg(t, t0 + 0.75, t0 + 1.3))
    p_text = seg(t, t0 + 1.15, t0 + 1.7)
    mh = 330
    mw = 330 * 622 / 740
    cv.vector(th.mark, (W - mw) / 2, 430 + (1 - p_r) * 40, mh, alpha=p_r, wipe={LAP_LIGHT: 0.30 + 0.70 * p_line,
                                                                                brand.ARC: 0.30 + 0.70 * p_line})
    wh = 74
    ww = wh * 5762 / 756
    cv.vector(th.wordmark, (W - ww) / 2, 850 + (1 - p_word) * 24, wh, alpha=p_word)
    cv.text((W / 2, 1010), line, grot(44, 500), th.fade(th.quiet, p_text), anchor="ms")
