"""Kit for the v4 "moment" loops: a dark 6 s silent loop whose last held frame is the still.

Shared grammar: the zone strip is the lap line and the hero number rises out of it (the digits are final from the first
visible pixel, never a rolling number; a milestone's count-up is the one exception, see loop.py), a zone-ramp sweep, a
hairline-first route draw-on with a coloured glow. Frame 0 shows the chrome (mark, date, card name in its colour) and the
content fades back to it at the end, so the loop has no visible seam and the chat preview is never an empty ground.
"""
from __future__ import annotations

from PIL import Image, ImageChops, ImageDraw, ImageFilter

from .. import brand
from ._draw import FPS, H, SS, W, Canvas, clamp, grot, in_out_cubic, mix, out_cubic, out_quart, rgb, saira, seg

DARK = "#0B0D10"
QUIET_D = "#8B939D"
HAIR_D = "#23272D"
LOOP_S = 6.0
N_FRAMES = int(round(LOOP_S * FPS))
FADE_OUT = (5.55, 6.0)   # everything but the chrome fades to the ground, so frame 0 follows the last frame
HOLD = (3.7, FADE_OUT[0])   # every element has landed: one frame, reused (about a third of the loop renders once)
M = 72
ZONE = brand.ZONE_RAMP   # Z1 blue .. Z5 red, the known ramp


def S(px: float):
    """Saira at a 1x pixel size (Canvas fonts are sized in supersampled px)."""
    return saira(int(px * SS))


def G(px: float, w: int = 600):
    return grot(int(px * SS), w)


def fade(ground, col, a):
    return mix(ground, col, clamp(a))


def _lum(c) -> float:
    r, g, b = (rgb(c) if isinstance(c, str) else c)
    f = lambda v: (v / 255) ** 2.2   # noqa: E731
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def ink_on(col) -> str:
    """Whichever of the dark ground and bone reads better on `col`."""
    l = _lum(col)
    return DARK if (l + 0.05) / (_lum(DARK) + 0.05) >= (_lum(brand.BONE) + 0.05) / (l + 0.05) else brand.BONE


def fit_px(s: str, px: int, avail: float, font=S) -> int:
    """The largest size <= px at which s fits in avail (1x px)."""
    w = Canvas.text_width(s, font(px))
    return px if w <= avail else max(20, int(px * avail / w))


def fit_text(s: str, px: int, avail: float, floor: int = 44) -> tuple[str, int]:
    """Shrink to fit, then (only past the floor) cut with an ellipsis. -> (text, size)."""
    size = fit_px(s, px, avail)
    while size < floor and len(s) > 1:
        s = s[:-2].rstrip() + "…"
        size = fit_px(s, px, avail)
    return s, size


class Frame:
    """A Canvas plus a coloured glow layer (the base Canvas glow is single-colour)."""

    def __init__(self, ground=DARK):
        self.cv = Canvas(ground)
        self.ground = ground
        self.glow: Image.Image | None = None

    def set_base(self, img: Image.Image) -> None:
        self.cv.img = img
        self.cv.d = ImageDraw.Draw(img)

    def glow_draw(self) -> ImageDraw.ImageDraw:
        if self.glow is None:
            self.glow = Image.new("RGB", (W // 4, H // 4), (0, 0, 0))
        return ImageDraw.Draw(self.glow)

    def flush_glow(self, radius: float = 7, gain: float = 1.0) -> None:
        if self.glow is None:
            return
        self.cv.img = screen_glow(self.cv.img, self.glow, radius, gain)
        self.cv.d = ImageDraw.Draw(self.cv.img)
        self.glow = None


def screen_glow(img: Image.Image, glow: Image.Image, radius: float, gain: float = 1.0,
                region: tuple[int, int, int, int] | None = None) -> Image.Image:
    """Blur a quarter-resolution coloured glow, lift it by `gain`, and screen it over img. `region` (1x px, multiples of
    4) limits the work to the box the glow can reach: the upscale and the screen are the slow part of a frame."""
    g = glow.filter(ImageFilter.GaussianBlur(radius))
    if gain != 1.0:
        g = g.point([min(255, int(v * gain)) for v in range(256)] * 3)
    if region is None:
        return ImageChops.screen(img, g.resize(img.size, Image.BILINEAR))
    x0, y0, x1, y1 = region
    up = g.crop((x0 // 4, y0 // 4, x1 // 4, y1 // 4)).resize(((x1 - x0) * SS, (y1 - y0) * SS), Image.BILINEAR)
    box = (x0 * SS, y0 * SS, x1 * SS, y1 * SS)
    img.paste(ImageChops.screen(img.crop(box), up), box[:2])
    return img


def chrome(fr: Frame, label: str, label_col, date: str, a: float = 1.0) -> None:
    """Mark top left, the card's name in its colour (full size, never an eyebrow), the date right."""
    cv = fr.cv
    cv.vector("mark-on-dark", M, 70, 62, alpha=a)
    if date:
        cv.text((W - M, 112), date, G(30, 600), fade(fr.ground, QUIET_D, a), anchor="rs", tracking=3)
    label, px = fit_text(label, 96, W - 2 * M)
    cv.text((M, 228), label, S(px), fade(fr.ground, label_col, a), anchor="ls")


class Hero:
    """A big number that rises out of its lap line. The glyph mask is built once, at the final size and position."""

    def __init__(self, s: str, px: int, x: int, y: int, unit: str = "", unit_px: int | None = None):
        self.s, self.px, self.x, self.y, self.unit = s, px, x, y, unit
        self.unit_px = unit_px or max(20, int(px * 0.26))
        font = S(px)
        bb = font.getbbox(s, anchor="ls")   # relative to the anchor, at supersampled px
        self.ox, self.oy = int(x * SS + bb[0]), int(y * SS + bb[1])
        self.mask = Image.new("L", (bb[2] - bb[0], bb[3] - bb[1]), 0)
        ImageDraw.Draw(self.mask).text((-bb[0], -bb[1]), s, font=font, fill=255)
        self.x0, self.x1 = self.ox / SS, (self.ox + self.mask.width) / SS

    @staticmethod
    def fitted(s: str, x: int, y: int, unit: str, px: int = 400) -> "Hero":
        """Largest hero (<= px) whose number plus its unit fit between the margins."""
        for size in range(px, 60, -8):
            uw = Canvas.text_width(unit, S(max(20, int(size * 0.26)))) + 16 if unit else 0
            if Canvas.text_width(s, S(size)) + uw <= W - x - M:
                return Hero(s, size, x, y, unit)
        return Hero(s, 60, x, y, unit)

    @property
    def cx(self) -> float:
        return (self.x0 + self.x1) / 2

    @property
    def cy(self) -> float:
        return (self.oy + self.mask.height / 2) / SS

    def draw(self, fr: Frame, col, p_rise: float, unit_col=QUIET_D) -> None:
        """Rows are revealed from the baseline up; a revealed row is exactly the final row (all or nothing)."""
        if p_rise <= 0:
            return
        h = self.mask.height
        top = h - int(round(h * out_quart(p_rise)))
        if top < h:
            crop = self.mask.crop((0, top, self.mask.width, h))
            fr.cv.img.paste(rgb(col) if isinstance(col, str) else col, (self.ox, self.oy + top), crop)
        if self.unit and p_rise > 0.6:
            a = seg(p_rise, 0.6, 1.0)
            fr.cv.text((self.x1 + 16, self.y), self.unit, S(self.unit_px), fade(fr.ground, unit_col, a), anchor="ls")


def stats_row(fr: Frame, items, y: int, t: float, t0: float, x0: int = M) -> None:
    """Small stats, staggered 60 ms. items: [(value, label)]."""
    gap = (W - 2 * M) / max(3, len(items))
    for i, (v, lab) in enumerate(items):
        a = out_cubic(seg(t, t0 + i * 0.06, t0 + i * 0.06 + 0.35))
        if a <= 0:
            continue
        x = x0 + i * gap
        fr.cv.text((x, y + (1 - a) * 18), v, S(64), fade(fr.ground, brand.BONE, a))
        fr.cv.text((x, y + 40 + (1 - a) * 18), lab, G(22, 600), fade(fr.ground, QUIET_D, a), tracking=3)


def zone_strip(fr: Frame, zone_s, y: int, p: float, x0: int = M, x1: int = W - M, h: int = 12) -> None:
    """Zone-ramp sweep: time in Z1..Z5 as one bar that grows left to right."""
    tot = sum(zone_s) or 1
    x = x0
    end = x0 + (x1 - x0) * in_out_cubic(clamp(p))
    for z, s_ in enumerate(zone_s):
        w = (x1 - x0) * s_ / tot
        if w <= 0:
            continue
        fr.cv.rect(x, y, min(x + w, end), y + h, ZONE[z])
        x += w
        if x >= end:
            break


def loop_out(img: Image.Image, t: float, keep: Image.Image) -> Image.Image:
    a = seg(t, *FADE_OUT)
    return Image.blend(img, keep, in_out_cubic(a)) if a > 0 else img


class Loop:
    """Subclasses draw one frame at time t. frames() yields N_FRAMES; frame 0 is the chrome-only frame the loop fades back to."""

    def draw(self, fr: Frame, t: float) -> None:
        raise NotImplementedError

    def _img(self, t: float) -> Image.Image:
        fr = Frame()
        self.draw(fr, t)
        return fr.cv.finish()

    def frames(self):
        keep = self._img(0.0)
        held = None
        for i in range(N_FRAMES):
            t = i / FPS
            if i == 0:
                yield keep
            elif HOLD[0] <= t < HOLD[1]:
                held = held or self._img(HOLD[0])
                yield held
            else:
                yield loop_out(self._img(t), t, keep)

    def render(self, out_path):
        from .encode import encode
        return encode(self.frames(), out_path)
