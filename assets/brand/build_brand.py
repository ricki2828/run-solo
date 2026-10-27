#!/usr/bin/env python3
"""Builds the Run Supreme "Track Bend" brand vectors (direction C, Munich lanes).

The mark is five lanes of a 400 m bend seen from above, open to the right
(straight, bend, straight), Z1 outer to Z5 inner in the zone ramp, separated by
white lane gaps. The wordmark is RUN SUPREME in Barlow Condensed Bold with five thin
zone stripes under it. Everything is outlined filled paths (no live text, strokes,
masks or clip paths), so the same path data works in SVG and Android VectorDrawable.

It writes the SVG masters (assets/brand/svg), the Android resources the app ships
(android/app/src/main/res), the iOS app icon (ios/Runner/Assets.xcassets), the Play
Store graphics (store/play) and the Flutter paths (lib/brand).

    python3 -m venv /tmp/brandvenv && /tmp/brandvenv/bin/pip install -r assets/brand/requirements.txt
    /tmp/brandvenv/bin/python assets/brand/build_brand.py [--hero photo.jpg]
"""
import argparse
from pathlib import Path

import pathops
import uharfbuzz as hb
from fontTools.pens.basePen import BasePen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageOps

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RES = REPO / "android" / "app" / "src" / "main" / "res"
STORE = REPO / "store" / "play"
IOS_ICON = REPO / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
FONT = HERE.parent / "fonts" / "BarlowCondensed-Bold.ttf"

# Zone ramp: HrZones.distributionLight / distributionDark (lib/theme/zones.dart).
ZONES_LIGHT = ["#2F6DB5", "#2E9E5B", "#D9A21B", "#E86A1C", "#D6283B"]
ZONES_DARK = ["#4D9BFF", "#2FD07A", "#FFBE2E", "#FF7A2E", "#FF4D5E"]
GROUND = "#FBFBF9"       # NightSessionLight.bgBase: the splash and feature graphic ground
TILE = "#FFFFFF"         # launcher tile
INK_LIGHT = "#121417"    # NightSessionLight.inkPrimary
BONE = "#EDEAE3"
DARK = "#0A0B0D"

CAP = 700
TRACKING = 20                 # +2% of the em, brief section 2.2
STRIPE_H = 0.055 * CAP        # wordmark zone stripes, font units
STRIPE_PITCH = 0.0714 * CAP
STRIPE_OFFSET = 0.137 * CAP   # baseline to the top of the first stripe

# Lane geometry, in mark units (one lane pitch is about 4). Lane k (0 = Z1, outermost)
# has centre radius r0 + pitch * (n - 1 - k) + pitch / 2, stroke pitch - gap, and its
# straights end `stagger` earlier per lane towards the inside (the 400 m stagger).
SPEC_MARK = dict(pitch=4.2, gap=0.9, r0=4.0, straight=28.0, stagger=3.2, zones=(0, 1, 2, 3, 4))
# Launcher and splash icon: seen at 48 px, so a wider gap and a tighter bend.
SPEC_ICON = dict(pitch=4.4, gap=1.5, r0=2.6, straight=15.0, stagger=2.6, zones=(0, 1, 2, 3, 4))
# 24 dp notification icon: three lanes (Z1, Z3, Z5), or five close up.
SPEC_NOTE = dict(pitch=5.2, gap=2.2, r0=2.0, straight=12.0, stagger=3.0, zones=(0, 2, 4))

KAPPA = 0.5522847498

font = TTFont(FONT)
glyphs = font.getGlyphSet()


# ---- path model: ("M", x, y) ("L", x, y) ("Q", x1, y1, x, y) ("C", x1, y1, x2, y2, x, y) ("Z",) ----
def fmt(v, places=2):
    s = f"{v:.{places}f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def pts(cmds):
    for c in cmds:
        a = c[1:]
        for i in range(0, len(a), 2):
            yield a[i], a[i + 1]


def bounds(cmds):
    xs, ys = zip(*pts(cmds))
    return min(xs), min(ys), max(xs), max(ys)


def bounds_all(layers):
    bs = [bounds(c) for _, c in layers]
    return min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs)


def xf(cmds, s=1.0, e=0.0, f=0.0, sy=None):
    """x' = s x + e, y' = sy y + f (sy defaults to s; pass a negative sy to flip)."""
    sy = s if sy is None else sy
    out = []
    for c in cmds:
        a = list(c[1:])
        for i in range(0, len(a), 2):
            a[i] = s * a[i] + e
            a[i + 1] = sy * a[i + 1] + f
        out.append((c[0], *a))
    return out


def xf_layers(layers, *args, **kw):
    return [(col, xf(c, *args, **kw)) for col, c in layers]


def svg_d(cmds, places=2):
    return "".join(c[0] + " ".join(fmt(v, places) for v in c[1:]) for c in cmds)


def dart_lines(cmds, places=3):
    n = lambda v: fmt(v, places)
    out = []
    for c in cmds:
        a = [n(v) for v in c[1:]]
        if c[0] == "M":
            out.append(f"  ..moveTo({a[0]}, {a[1]})")
        elif c[0] == "L":
            out.append(f"  ..lineTo({a[0]}, {a[1]})")
        elif c[0] == "Q":
            out.append(f"  ..quadraticBezierTo({', '.join(a)})")
        elif c[0] == "C":
            out.append(f"  ..cubicTo({', '.join(a)})")
        else:
            out.append("  ..close()")
    return out


class RecPen(BasePen):
    """Records a glyph or pathops outline as path commands."""

    def __init__(self):
        super().__init__(None)
        self.cmds = []

    def _moveTo(self, p):
        self.cmds.append(("M", *p))

    def _lineTo(self, p):
        self.cmds.append(("L", *p))

    def _curveToOne(self, a, b, c):
        self.cmds.append(("C", *a, *b, *c))

    def _qCurveToOne(self, a, b):
        self.cmds.append(("Q", *a, *b))

    def _closePath(self):
        self.cmds.append(("Z",))

    _endPath = _closePath


def record(path):
    pen = RecPen()
    path.draw(pen)
    return pen.cmds


def to_pathops(cmds):
    p = pathops.Path()
    pen = p.getPen()
    for c in cmds:
        if c[0] == "M":
            pen.moveTo(c[1:3])
        elif c[0] == "L":
            pen.lineTo(c[1:3])
        elif c[0] == "Q":
            pen.qCurveTo(c[1:3], c[3:5])
        elif c[0] == "C":
            pen.curveTo(c[1:3], c[3:5], c[5:7])
        else:
            pen.closePath()
    return p


# ---- the mark ----
def _arc_out(cx, cy, r):
    """Left half of a circle, top to bottom (anticlockwise on screen)."""
    k = KAPPA * r
    return [("C", cx - k, cy - r, cx - r, cy - k, cx - r, cy),
            ("C", cx - r, cy + k, cx - k, cy + r, cx, cy + r)]


def _arc_back(cx, cy, r):
    """Left half of a circle, bottom to top."""
    k = KAPPA * r
    return [("C", cx - k, cy + r, cx - r, cy + k, cx - r, cy),
            ("C", cx - r, cy - k, cx - k, cy - r, cx, cy - r)]


class Mark:
    """Lanes of one spec, in mark units: centre (0, 0) of the bend, y down."""

    def __init__(self, spec):
        self.spec = spec
        self.zones = spec["zones"]
        n = len(self.zones)
        pitch, gap = spec["pitch"], spec["gap"]
        self.stroke = pitch - gap
        self.lanes = []  # (zone, outline, centreline)
        for k, z in enumerate(self.zones):
            rc = spec["r0"] + pitch * (n - 1 - k) + pitch / 2
            ro, ri = rc + self.stroke / 2, rc - self.stroke / 2
            xr = spec["straight"] - k * spec["stagger"]
            outline = ([("M", xr, -ro), ("L", 0, -ro)] + _arc_out(0, 0, ro)
                       + [("L", xr, ro), ("L", xr, ri), ("L", 0, ri)] + _arc_back(0, 0, ri)
                       + [("L", xr, -ri), ("Z",)])
            centre = [("M", xr, -rc), ("L", 0, -rc)] + _arc_out(0, 0, rc) + [("L", xr, rc)]
            self.lanes.append((z, outline, centre))

    def layers(self, colours):
        """Outline layers, colours by zone index (a list of 5) or a single colour."""
        return [(colours if isinstance(colours, str) else colours[z], o) for z, o, _ in self.lanes]

    def bounds(self):
        return bounds_all([(None, o) for _, o, _ in self.lanes])


MARK = Mark(SPEC_MARK)
ICON = Mark(SPEC_ICON)
NOTE = Mark(SPEC_NOTE)


# ---- the wordmark ----
def shape_text(text):
    blob = hb.Blob.from_file_path(str(FONT))
    hbfont = hb.Font(hb.Face(blob))
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hbfont, buf, {"kern": True, "liga": False})
    order = font.getGlyphOrder()
    x, parts = 0, []
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        name = order[info.codepoint]
        if name != "space":
            g = pathops.Path()
            glyphs[name].draw(TransformPen(g.getPen(), (1, 0, 0, 1, x + pos.x_offset, 0)))
            parts.append(g)
        x += pos.x_advance + TRACKING
    out = pathops.Path()
    for p in parts:
        out = pathops.op(out, p, pathops.PathOp.UNION)
    return out


WORD = shape_text("RUN SUPREME")
W_X0, _, W_X1, _ = WORD.bounds
WORD_TEXT = record(WORD)  # font units, y up
# Wordmark in design units, y down, baseline at y = 0.
WORD_TEXT_DOWN = xf(WORD_TEXT, 1, 0, 0, sy=-1)


def stripe_cmds(i):
    y0 = STRIPE_OFFSET + i * STRIPE_PITCH
    return [("M", W_X0, y0), ("L", W_X1, y0), ("L", W_X1, y0 + STRIPE_H), ("L", W_X0, y0 + STRIPE_H), ("Z",)]


def wordmark_layers(ink, zones):
    return [(ink, WORD_TEXT_DOWN)] + [(zones if isinstance(zones, str) else zones[i], stripe_cmds(i)) for i in range(5)]


# ---- output helpers ----
def box(layers, pad, scale=1.0):
    """Layers translated so the art starts at (pad, pad); returns (layers, w, h)."""
    x0, y0, x1, y1 = bounds_all(layers)
    out = xf_layers(layers, scale, pad - x0 * scale, pad - y0 * scale)
    return out, (x1 - x0) * scale + 2 * pad, (y1 - y0) * scale + 2 * pad


def fit_circle(layers, canvas, radius):
    """Scale + offset so every point sits within `radius` of the canvas centre."""
    x0, y0, x1, y1 = bounds_all(layers)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    far = max(((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 for _, c in layers for x, y in pts(c))
    s = radius / far
    return s, canvas / 2 - s * cx, canvas / 2 - s * cy


def fit_box(layers, canvas, pad):
    x0, y0, x1, y1 = bounds_all(layers)
    s = (canvas - 2 * pad) / max(x1 - x0, y1 - y0)
    return s, canvas / 2 - s * (x0 + x1) / 2, canvas / 2 - s * (y0 + y1) / 2


def svg(w, h, layers, bg=None, extra=""):
    body = "".join(f'<path fill="{col}" d="{svg_d(c)}"/>' for col, c in layers)
    back = f'<rect width="{w:g}" height="{h:g}" fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" '
            f'width="{w:g}" height="{h:g}">{back}{body}{extra}</svg>\n')


def vector(size_dp, viewport, layers):
    paths = "\n".join(f'    <path\n        android:fillColor="{col}"\n        android:pathData="{svg_d(c)}" />'
                      for col, c in layers)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Generated by assets/brand/build_brand.py. Do not edit by hand. -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{size_dp}dp"\n    android:height="{size_dp}dp"\n'
            f'    android:viewportWidth="{viewport}"\n    android:viewportHeight="{viewport}">\n'
            f'{paths}\n</vector>\n')


def dart_path(name, doc, cmds):
    body = "\n".join(dart_lines(cmds))
    return f"/// {doc}\nPath {name}() => Path()\n{body};\n"


def dart_paths():
    """lib/brand/track_bend_paths.dart for the Track Bend intro and in-app marks: the
    lane centrelines (stroke them with `laneStroke`, butt caps) and the wordmark outline."""
    x0, y0, x1, y1 = MARK.bounds()
    centres = [xf(c, 1, -x0, -y0) for _, _, c in MARK.lanes]
    n = lambda v: fmt(v, 3)
    wb_x0, wb_x1 = W_X0, W_X1
    consts = {
        "markWidth": x1 - x0,
        "markHeight": y1 - y0,
        "laneStroke": MARK.stroke,
        "cap": CAP,
        "wordLeft": wb_x0,
        "wordRight": wb_x1,
        "wordTop": 0,
        "wordBottom": CAP,
        "stripeTop": CAP + STRIPE_OFFSET,
        "stripeHeight": STRIPE_H,
        "stripePitch": STRIPE_PITCH,
    }
    head = ("// Generated by assets/brand/build_brand.py. Do not edit by hand.\n"
            "// Track Bend: five lane centrelines of a 400 m bend (Z1 outer .. Z5 inner),\n"
            "// in mark units, y down, origin at the mark's top left. Stroke each with\n"
            "// `laneStroke`, butt caps. The wordmark is in font units, y down, baseline at\n"
            "// y = cap; the five zone stripes sit under it from `stripeTop`.\n\n"
            "import 'dart:ui';\n\n"
            "abstract final class TrackBendGeometry {\n"
            + "".join(f"  static const double {k} = {n(v)};\n" for k, v in consts.items())
            + "  static const int laneCount = 5;\n}\n\n")
    lanes = "".join(dart_path(f"trackBendLane{i + 1}", f"Lane Z{i + 1} centreline, drawn from the top straight round the bend.", c) + "\n"
                    for i, c in enumerate(centres))
    word = xf(WORD_TEXT, 1, 0, CAP, sy=-1)
    return head + lanes + dart_path("trackBendWordmark", "RUN SUPREME, outlined (no stripes).", word)


def write(rel, text, root=HERE):
    out = root / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)


# ---- raster (Play Store graphics) ----
class _Flatten(BasePen):
    """Flattens a path into polygons, one per contour, for Pillow."""

    def __init__(self, xform, steps=24):
        super().__init__(None)
        self.a, self.b, self.c, self.d, self.e, self.f = xform
        self.steps, self.polys, self.cur = steps, [], []

    def _pt(self, p):
        x, y = p
        return (self.a * x + self.c * y + self.e, self.b * x + self.d * y + self.f)

    def _moveTo(self, p):
        self.cur = [self._pt(p)]

    def _lineTo(self, p):
        self.cur.append(self._pt(p))

    def _curveToOne(self, p1, p2, p3):
        p0 = self._getCurrentPoint()
        for i in range(1, self.steps + 1):
            s = i / self.steps
            u = 1 - s
            self.cur.append(self._pt((
                u ** 3 * p0[0] + 3 * u * u * s * p1[0] + 3 * u * s * s * p2[0] + s ** 3 * p3[0],
                u ** 3 * p0[1] + 3 * u * u * s * p1[1] + 3 * u * s * s * p2[1] + s ** 3 * p3[1])))

    def _qCurveToOne(self, p1, p2):
        p0 = self._getCurrentPoint()
        for i in range(1, self.steps + 1):
            s = i / self.steps
            u = 1 - s
            self.cur.append(self._pt((u * u * p0[0] + 2 * u * s * p1[0] + s * s * p2[0],
                                      u * u * p0[1] + 2 * u * s * p1[1] + s * s * p2[1])))

    def _closePath(self):
        if len(self.cur) > 2:
            self.polys.append(self.cur)
        self.cur = []

    _endPath = _closePath


SS = 4  # supersampling factor


def paint(img, colour, path, xform):
    """Fills `path` onto `img`. Contours never overlap, so XOR = nonzero."""
    w, h = img.size
    mask = Image.new("1", (w * SS, h * SS), 0)
    pen = _Flatten(tuple(v * SS for v in xform))
    path.draw(pen)
    for poly in pen.polys:
        m = Image.new("1", mask.size, 0)
        ImageDraw.Draw(m).polygon(poly, fill=1)
        mask = ImageChops.logical_xor(mask, m)
    alpha = mask.convert("L").resize((w, h), Image.LANCZOS)
    img.paste(Image.new("RGBA", (w, h), colour), (0, 0), alpha)


def paint_layers(img, layers, s, dx, dy):
    """Paints y-down layers placed with scale `s` and offset (dx, dy)."""
    for col, c in layers:
        paint(img, col, to_pathops(c), (s, 0, 0, s, dx, dy))


def icon_layers(colours=ZONES_LIGHT):
    return ICON.layers(colours)


def tile_icon(size, crop=80):
    """The launcher artwork on the white tile, cropped to the central `crop` dp of the 108 dp canvas."""
    s, ex, ey = fit_circle(icon_layers(), 108, 32)
    k = size / crop
    off = -(108 - crop) / 2 * k
    img = Image.new("RGBA", (size, size), TILE)
    paint_layers(img, icon_layers(), s * k, ex * k + off, ey * k + off)
    return img


def play_icon():
    return tile_icon(512)


def ios_icon():
    """1024 x 1024, RGB with no alpha: App Store upload rejects an icon with transparency."""
    return tile_icon(1024).convert("RGB")


def feature_graphic(hero=None):
    """1024 x 500 on the light ground: wordmark with its stripes left, the large mark right."""
    w, h = 1024, 500
    img = Image.new("RGB", (w, h), GROUND)
    if hero:
        photo = ImageOps.fit(Image.open(hero).convert("RGB"), (w, h), Image.LANCZOS)
        photo = ImageEnhance.Color(photo).enhance(0.25)
        img = Image.blend(img, photo, 0.12)
    img = img.convert("RGBA")
    # Wordmark: 470 px wide.
    wl = wordmark_layers(INK_LIGHT, ZONES_LIGHT)
    wx0, wy0, wx1, wy1 = bounds_all(wl)
    k = 470 / (wx1 - wx0)
    paint_layers(img, wl, k, 64 - wx0 * k, (h - (wy1 - wy0) * k) / 2 - wy0 * k)
    # Mark: 320 px tall, right.
    ml = MARK.layers(ZONES_LIGHT)
    mx0, my0, mx1, my1 = bounds_all(ml)
    km = 320 / (my1 - my0)
    paint_layers(img, ml, km, 940 - (mx1 - mx0) * km - mx0 * km, (h - 320) / 2 - my0 * km)
    return img.convert("RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hero", help="licensed hero photo for the feature graphic (see store/art/LICENSES.md)")
    args = ap.parse_args()

    # Mark and wordmark masters, with a small pad.
    variants = {
        "on-dark": (ZONES_DARK, BONE),
        "on-light": (ZONES_LIGHT, INK_LIGHT),
        "mono-black": ("#000000", "#000000"),
        "mono-white": ("#FFFFFF", "#FFFFFF"),
    }
    for suffix, (zones, ink) in variants.items():
        layers, w, h = box(MARK.layers(zones), pad=3, scale=10)
        write(f"svg/mark-{suffix}.svg", svg(w, h, layers))
        layers, w, h = box(wordmark_layers(ink, zones), pad=20)
        write(f"svg/wordmark-{suffix}.svg", svg(w, h, layers))

    # Adaptive launcher icon: 108 dp canvas, mark inside the 66 dp safe zone (radius 33, 1 dp margin).
    il = icon_layers()
    s, ex, ey = fit_circle(il, 108, 32)
    fg = xf_layers(il, s, ex, ey)
    # Same transform as the colour layer, so the themed icon sits exactly where the colour one does.
    mono = [("#FFFFFFFF", c) for _, c in fg]
    write("drawable/ic_launcher_foreground.xml", vector(108, 108, fg), RES)
    write("drawable/ic_launcher_monochrome.xml", vector(108, 108, mono), RES)
    write("drawable/ic_launcher_background.xml", vector(108, 108, [(TILE, [("M", 0, 0), ("L", 108, 0), ("L", 108, 108), ("L", 0, 108), ("Z",)])]), RES)
    write("mipmap-anydpi-v26/ic_launcher.xml",
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <background android:drawable="@drawable/ic_launcher_background" />\n'
          '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
          '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
          '</adaptive-icon>\n', RES)
    write("svg/icon/ic_launcher_foreground.svg", svg(108, 108, fg))
    write("svg/icon/ic_launcher_monochrome.svg", svg(108, 108, [("#FFFFFF", c) for _, c in fg]))
    write("svg/icon/ic_launcher_background.svg", svg(108, 108, [], bg=TILE))
    write("svg/icon/ic_launcher_full.svg", svg(108, 108, fg, bg=TILE))
    guides = ('<rect x=".5" y=".5" width="107" height="107" fill="none" stroke="#9AA0A8" stroke-width=".5" stroke-dasharray="2 2"/>'
              '<circle cx="54" cy="54" r="36" fill="none" stroke="#5F646D" stroke-width=".5" stroke-dasharray="1 2"/>'
              '<circle cx="54" cy="54" r="33" fill="none" stroke="#C41230" stroke-width=".5" stroke-dasharray="3 2"/>')
    write("svg/icon/ic_launcher_safe-zone-guide.svg", svg(108, 108, fg, bg=TILE, extra=guides))

    # Android 12 splash icon (no icon background): 288 dp canvas, keep inside the 192 dp circle.
    ss, sx, sy = fit_circle(il, 288, 84)
    splash = xf_layers(il, ss, sx, sy)
    write("drawable/splash_icon.xml", vector(288, 288, splash), RES)
    write("svg/icon/splash_icon.svg", svg(288, 288, splash))

    # Notification small icon: 24 dp, white on transparent, 2 dp padding (system icon grid), three lanes.
    nl = NOTE.layers("#FFFFFFFF")
    ns, nx, ny = fit_box(nl, 24, 2)
    note = xf_layers(nl, ns, nx, ny)
    write("drawable/ic_stat_runsupreme.xml", vector(24, 24, note), RES)
    write("svg/icon/ic_stat_runsupreme.svg", svg(24, 24, [("#FFFFFF", c) for _, c in note]))

    STORE.mkdir(parents=True, exist_ok=True)
    play_icon().convert("RGB").save(STORE / "icon-512.png", optimize=True)
    feature_graphic(args.hero).save(STORE / "feature-graphic-wordmark-1024x500.png", optimize=True)
    # iOS: one 1024 px universal icon; Xcode 14+ derives every other size from it.
    IOS_ICON.mkdir(parents=True, exist_ok=True)
    ios_icon().save(IOS_ICON / "Icon-App-1024x1024@1x.png", optimize=True)
    write("Contents.json",
          '{\n'
          '  "images" : [\n'
          '    {\n'
          '      "filename" : "Icon-App-1024x1024@1x.png",\n'
          '      "idiom" : "universal",\n'
          '      "platform" : "ios",\n'
          '      "size" : "1024x1024"\n'
          '    }\n'
          '  ],\n'
          '  "info" : {\n'
          '    "author" : "xcode",\n'
          '    "version" : 1\n'
          '  }\n'
          '}\n', IOS_ICON)
    # Flutter paths for the Track Bend intro and in-app marks.
    write("brand/track_bend_paths.dart", dart_paths(), REPO / "lib")
    print("brand assets written to", HERE, RES, IOS_ICON, STORE, REPO / "lib" / "brand")


if __name__ == "__main__":
    main()
