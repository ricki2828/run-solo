"""Drawing kit: easing, colour maths, a 2x supersampled canvas, brand fonts and the Lap Line vectors."""
from __future__ import annotations

import math
import os
import re
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1350
FPS = 30
SS = 2  # supersample factor; downsampled with a box filter

from .. import brand  # noqa: E402

FONT_DIR = Path(os.environ.get("RS_FONT_DIR", brand.FONT_DIR))
SVG_DIR = Path(os.environ.get("RS_BRAND_DIR", brand.BRAND_SVG_DIR))


# ---- easing -----------------------------------------------------------------------------------
def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def seg(t, a, b):
    """Linear 0..1 progress of t inside [a, b]."""
    return clamp((t - a) / (b - a)) if b > a else float(t >= b)


def in_out_cubic(x):
    return 4 * x * x * x if x < 0.5 else 1 - pow(-2 * x + 2, 3) / 2


def out_cubic(x):
    return 1 - pow(1 - x, 3)


def out_quart(x):
    return 1 - pow(1 - x, 4)


def out_back(x, s=1.45):
    c3 = s + 1
    return 1 + c3 * pow(x - 1, 3) + s * pow(x - 1, 2)


def lerp(a, b, t):
    return a + (b - a) * t


# ---- colour -----------------------------------------------------------------------------------
def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def mix(c1, c2, t):
    """Blend colour c1 -> c2 (hex or tuple) by t."""
    a = rgb(c1) if isinstance(c1, str) else c1
    b = rgb(c2) if isinstance(c2, str) else c2
    t = clamp(t)
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# ---- fonts ------------------------------------------------------------------------------------
@lru_cache(maxsize=256)
def saira(px: int):
    return ImageFont.truetype(str(FONT_DIR / "SairaExtraCondensed-ExtraBold.ttf"), int(px))


@lru_cache(maxsize=256)
def grot(px: int, wght: int = 600):
    f = ImageFont.truetype(str(FONT_DIR / "SchibstedGrotesk-Variable.ttf"), int(px))
    f.set_variation_by_axes([wght])
    return f


# ---- Lap Line vectors -------------------------------------------------------------------------
_TOK = re.compile(r"([MLHVCQZ])|(-?\d+(?:\.\d+)?)")


def _flatten(d: str):
    """Absolute SVG path data -> list of closed polygons (curves flattened)."""
    toks = [(m.group(1) or float(m.group(2))) for m in _TOK.finditer(d)]
    i, cmd, cur, start, polys, poly = 0, None, (0.0, 0.0), (0.0, 0.0), [], []

    def num():
        nonlocal i
        v = toks[i]
        i += 1
        return v

    while i < len(toks):
        if isinstance(toks[i], str):
            cmd = toks[i]
            i += 1
            if cmd == "Z":
                if poly:
                    polys.append(poly)
                poly, cur = [], start
                continue
        if cmd == "M":
            if poly:
                polys.append(poly)
            cur = (num(), num())
            start, poly, cmd = cur, [cur], "L"
        elif cmd == "L":
            cur = (num(), num())
            poly.append(cur)
        elif cmd == "H":
            cur = (num(), cur[1])
            poly.append(cur)
        elif cmd == "V":
            cur = (cur[0], num())
            poly.append(cur)
        elif cmd == "Q":
            c, e = (num(), num()), (num(), num())
            for k in range(1, 9):
                t = k / 8
                poly.append(tuple((1 - t) ** 2 * cur[j] + 2 * (1 - t) * t * c[j] + t * t * e[j] for j in (0, 1)))
            cur = e
        elif cmd == "C":
            c1, c2, e = (num(), num()), (num(), num()), (num(), num())
            for k in range(1, 13):
                t = k / 12
                poly.append(tuple(
                    (1 - t) ** 3 * cur[j] + 3 * (1 - t) ** 2 * t * c1[j] + 3 * (1 - t) * t * t * c2[j] + t ** 3 * e[j]
                    for j in (0, 1)))
            cur = e
        else:  # pragma: no cover
            raise ValueError(f"unsupported path command {cmd}")
    if poly:
        polys.append(poly)
    return polys


@lru_cache(maxsize=8)
def _svg_paths(name: str):
    svg = (SVG_DIR / f"{name}.svg").read_text()
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    paths = [(re.search(r'fill="([^"]+)"', m).group(1), re.search(r' d="([^"]+)"', m).group(1))
             for m in re.findall(r"<path[^>]+>", svg)]
    return vb[2], vb[3], [(fill, _flatten(d)) for fill, d in paths]


@lru_cache(maxsize=32)
def vector_masks(name: str, height_px: int):
    """Rasterise an SVG's paths (even-odd) to L masks at height_px*SS. -> (w, [(fill, mask)])."""
    vw, vh, paths = _svg_paths(name)
    s = height_px * SS * 2 / vh  # raster at 2x the canvas, then average down for smooth edges
    size = (int(math.ceil(vw * s)) // 2 * 2, int(height_px * SS * 2))
    out = []
    for fill, polys in paths:
        acc = Image.new("1", size, 0)
        for poly in polys:
            m = Image.new("1", size, 0)
            ImageDraw.Draw(m).polygon([(x * s, y * s) for x, y in poly], fill=1)
            acc = ImageChops.logical_xor(acc, m)
        out.append((fill, acc.convert("L").reduce(2)))
    return size[0] / SS / 2, out


# ---- canvas -----------------------------------------------------------------------------------
class Canvas:
    """A flat-ground RGB canvas drawn at SS x. All public coordinates are 1x pixels."""

    def __init__(self, ground):
        self.ground = rgb(ground) if isinstance(ground, str) else ground
        self.img = Image.new("RGB", (W * SS, H * SS), self.ground)
        self.d = ImageDraw.Draw(self.img)
        self.halo = Image.new("L", (W // 4, H // 4), 0)  # glow source, 1/4 res
        self._halo_d = ImageDraw.Draw(self.halo)
        self.glows = []

    # shapes
    def rect(self, x0, y0, x1, y1, fill, r=0, top_only=False):
        if x1 - x0 < 1 or y1 - y0 < 1:
            return
        if y1 - y0 < 3:
            r = 0
        box = [x0 * SS, y0 * SS, x1 * SS - 1, y1 * SS - 1]
        if r > 0:
            r = min(r, (y1 - y0) / 2, (x1 - x0) / 2)
            self.d.rounded_rectangle(box, radius=r * SS, fill=fill,
                                     corners=(True, True, not top_only, not top_only))
        else:
            self.d.rectangle(box, fill=fill)

    def circle(self, cx, cy, r, fill=None, outline=None, width=0):
        self.d.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS],
                       fill=fill, outline=outline, width=int(round(width * SS)))

    def poly(self, pts, fill):
        self.d.polygon([(x * SS, y * SS) for x, y in pts], fill=fill)

    def line(self, pts, width, fill, round_caps=True):
        p = [(x * SS, y * SS) for x, y in pts]
        if len(p) >= 2:
            self.d.line(p, fill=fill, width=int(round(width * SS)), joint="curve")
        if round_caps and p:
            r = width * SS / 2
            for q in (p[0], p[-1]):
                self.d.ellipse([q[0] - r, q[1] - r, q[0] + r, q[1] + r], fill=fill)

    def halo_line(self, pts, width):
        if len(pts) >= 2:
            self._halo_d.line([(x / 4, y / 4) for x, y in pts], fill=255, width=max(1, int(round(width / 4))),
                              joint="curve")

    def halo_dot(self, cx, cy, r):
        self._halo_d.ellipse([(cx - r) / 4, (cy - r) / 4, (cx + r) / 4, (cy + r) / 4], fill=255)

    def add_glow(self, colour, strength, radius):
        """Queue a blurred-halo composite of the halo layer."""
        self.glows.append((rgb(colour) if isinstance(colour, str) else colour, strength, radius))

    # text
    def text(self, xy, s, font, fill, anchor="ls", tracking=0.0):
        """Draw s at 1x xy. `font` is a 1x-size font factory result built via fonts()."""
        x, y = xy
        f = font
        if not tracking:
            self.d.text((x * SS, y * SS), s, font=f, fill=fill, anchor=anchor)
            return
        w = self.text_width(s, f, tracking)
        if anchor[0] == "m":
            x -= w / 2
        elif anchor[0] == "r":
            x -= w
        for ch in s:
            self.d.text((x * SS, y * SS), ch, font=f, fill=fill, anchor="l" + anchor[1])
            x += f.getlength(ch) / SS + tracking
        return

    @staticmethod
    def text_width(s, f, tracking=0.0):
        return sum(f.getlength(c) / SS + tracking for c in s) - tracking if tracking else f.getlength(s) / SS

    def digits(self, xy, s, font, fill, anchor="l", pitch=None):
        """Tabular numerals so a counting number never jitters. anchor l|r|m on x, baseline y."""
        x, y = xy
        pitch = pitch or max(font.getlength(c) for c in "0123456789") / SS
        widths = [pitch if c.isdigit() else font.getlength(c) / SS for c in s]
        total = sum(widths)
        if anchor == "r":
            x -= total
        elif anchor == "m":
            x -= total / 2
        for c, w in zip(s, widths):
            cw = font.getlength(c) / SS
            self.d.text(((x + (w - cw) / 2) * SS, y * SS), c, font=font, fill=fill, anchor="ls")
            x += w
        return total

    def vector(self, name, x, y, height, colours=None, alpha=1.0, wipe=None):
        """Paste an SVG logo at 1x (x, y, height). colours maps source fill -> replacement.
        wipe: optional {fill: 0..1} x-fraction of that path to reveal (the lap line)."""
        w, masks = vector_masks(name, int(round(height)))
        for fill, m in masks:
            col = (colours or {}).get(fill, fill)
            if wipe and fill in wipe:
                keep = int(m.width * clamp(wipe[fill]))
                if keep <= 0:
                    continue
                m = m.copy()
                ImageDraw.Draw(m).rectangle([keep, 0, m.width, m.height], fill=0)
            if alpha < 1:
                m = m.point(lambda v, a=alpha: int(v * a))
            self.img.paste(rgb(col), (int(x * SS), int(y * SS)), m)
        return w

    def apply_glow(self):
        """Composite the queued halos into the ground NOW (call before drawing anything else).
        Everything happens at 1/4 res and is upscaled once: the glow is smooth, the resize is the slow part."""
        base = Image.new("RGB", self.halo.size, self.ground)
        for col, k, rad in self.glows:
            m = self.halo.filter(ImageFilter.GaussianBlur(rad)).point(lambda v, k=k: min(255, int(v * k * 2.2)))
            base = Image.composite(Image.new("RGB", self.halo.size, col), base, m)
        self.img = base.resize((W * SS, H * SS), Image.BILINEAR)
        self.d = ImageDraw.Draw(self.img)
        self.glows = []

    def finish(self):
        return self.img.reduce(SS)
