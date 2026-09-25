#!/usr/bin/env python3
"""Builds the Run Supreme "Lap Line" brand vectors from the bundled Barlow Condensed Bold.

Everything is outlined (no live text) and boolean-cut, so each file is plain filled paths
that work as SVG and as Android VectorDrawable (no masks, no clip paths).

    python3 -m venv /tmp/brandvenv && /tmp/brandvenv/bin/pip install fonttools uharfbuzz skia-pathops
    /tmp/brandvenv/bin/python assets/brand/build_brand.py
"""
from pathlib import Path

import pathops
import uharfbuzz as hb
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = Path(__file__).resolve().parent
FONT = HERE.parent / "fonts" / "BarlowCondensed-Bold.ttf"

BONE, ARC, BG = "#EDEAE3", "#19E6FF", "#0A0B0D"
INK_LIGHT, ARC_LIGHT = "#0F1114", "#0098B2"

# Geometry, in font units (cap height 700, y up). The lap line sits at 40% of cap height.
CAP = 700
CUT_Y = 0.40 * CAP
CUT_T = 0.075 * CAP          # gap cut through the letters
LINE_T = 0.6 * CUT_T         # cyan lap line, centred in the gap
TRACKING = 20                # +2% of the em, brief section 2.2
WORD_DASH_GAP = 0.18 * CAP   # space between the word and its dash
WORD_DASH_LEN = 0.76 * CAP
MARK_TAIL = 0.25 * CAP       # how far the lap line runs past the R
ICON_CUT_T = 0.12 * CAP
ICON_LINE_T = 0.08 * CAP
ICON_TAIL_LEN = 0.2 * CAP
NOTE_CUT_T = 0.15 * CAP      # 24 dp notification icon: twice the cut, or it closes up at 1x

font = TTFont(FONT)
glyphs = font.getGlyphSet()


def rect(x0, y0, x1, y1):
    p = pathops.Path()
    pen = p.getPen()
    pen.moveTo((x0, y0)); pen.lineTo((x1, y0)); pen.lineTo((x1, y1)); pen.lineTo((x0, y1)); pen.closePath()
    return p


def pill(x0, y0, x1, y1, round_left=True):
    """Horizontal bar with a round right end (and optionally a round left end)."""
    r = (y1 - y0) / 2
    k = 0.5523 * r
    cy = (y0 + y1) / 2
    p = pathops.Path()
    pen = p.getPen()
    if round_left:
        pen.moveTo((x0 + r, y0))
    else:
        pen.moveTo((x0, y0))
    pen.lineTo((x1 - r, y0))
    pen.curveTo((x1 - r + k, y0), (x1, cy - k), (x1, cy))
    pen.curveTo((x1, cy + k), (x1 - r + k, y1), (x1 - r, y1))
    if round_left:
        pen.lineTo((x0 + r, y1))
        pen.curveTo((x0 + r - k, y1), (x0, cy + k), (x0, cy))
        pen.curveTo((x0, cy - k), (x0 + r - k, y0), (x0 + r, y0))
    else:
        pen.lineTo((x0, y1))
    pen.closePath()
    return p


def glyph_path(name, dx=0):
    p = pathops.Path()
    glyphs[name].draw(TransformPen(p.getPen(), (1, 0, 0, 1, dx, 0)))
    return p


def union(paths):
    out = pathops.Path()
    for p in paths:
        out = pathops.op(out, p, pathops.PathOp.UNION)
    return out


def diff(a, b):
    return pathops.op(a, b, pathops.PathOp.DIFFERENCE)


def bounds(p):
    return p.bounds  # (xmin, ymin, xmax, ymax)


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
            parts.append(glyph_path(name, x + pos.x_offset))
        x += pos.x_advance + TRACKING
    return union(parts)


def cut(p):
    xmin, _, xmax, _ = bounds(p)
    return diff(p, rect(xmin - 10, CUT_Y - CUT_T / 2, xmax + 10, CUT_Y + CUT_T / 2))


def leg_span(r_path):
    """Left and right edge of the R's leg at the cut height."""
    probe = pathops.op(r_path, rect(-1000, CUT_Y - 1, 2000, CUT_Y + 1), pathops.PathOp.INTERSECTION)
    spans = sorted(bounds(c) for c in probe.contours)
    return spans[-1][0], spans[-1][2]


# ---- shapes (font units) ----
R = glyph_path("R")
_, _, r_xmax, _ = bounds(R)


def make_mark(cut_t, line_t, tail):
    """R with the lap-line cut. Returns (cut R, colour lap line, monochrome tail)."""
    r_cut = diff(R, rect(0, CUT_Y - cut_t / 2, 1000, CUT_Y + cut_t / 2))
    leg_l, _ = leg_span(R)
    y0, y1 = CUT_Y - line_t / 2, CUT_Y + line_t / 2
    # Colour: the lap line enters at the leg and leaves to the right, through the cut.
    line = pill(leg_l, y0, r_xmax + tail, y1, round_left=False)
    # Monochrome: only the part that has left the letter, so the cut stays readable in one colour.
    mono = pill(r_xmax + 0.06 * CAP, y0, r_xmax + tail, y1)
    return r_cut, line, mono


R_CUT, MARK_LINE, MONO_TAIL = make_mark(CUT_T, LINE_T, MARK_TAIL)
# Launcher and splash icons are seen at 48 px: a heavier cut and line, a shorter tail.
ICON_R, ICON_LINE, ICON_TAIL = make_mark(ICON_CUT_T, ICON_LINE_T, ICON_TAIL_LEN)
line_y0, line_y1 = CUT_Y - LINE_T / 2, CUT_Y + LINE_T / 2

WORD = cut(shape_text("RUN SUPREME"))
_, _, w_xmax, _ = bounds(WORD)
WORD_DASH = pill(w_xmax + WORD_DASH_GAP, line_y0, w_xmax + WORD_DASH_GAP + WORD_DASH_LEN, line_y1)


# ---- output helpers ----
def to_d(p, a, b, c, d, e, f):
    pen = SVGPathPen(None, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
    p.draw(TransformPen(pen, (a, b, c, d, e, f)))
    return pen.getCommands()


def points(p):
    for _, pts in p.segments:
        yield from pts


def fit_circle(parts, canvas, radius):
    """Scale + offset (font units, y up) so every point sits within `radius` of the canvas centre."""
    allp = union(parts)
    xmin, ymin, xmax, ymax = bounds(allp)
    cx, cy = (xmin + xmax) / 2, (ymin + ymax) / 2
    far = max(((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 for x, y in points(allp))
    s = radius / far
    c = canvas / 2
    return (s, 0, 0, -s, c - s * cx, c + s * cy)


def fit_box(parts, canvas, pad):
    allp = union(parts)
    xmin, ymin, xmax, ymax = bounds(allp)
    s = (canvas - 2 * pad) / max(xmax - xmin, ymax - ymin)
    return (s, 0, 0, -s, canvas / 2 - s * (xmin + xmax) / 2, canvas / 2 + s * (ymin + ymax) / 2)


def box_xform(parts, pad):
    allp = union(parts)
    xmin, ymin, xmax, ymax = bounds(allp)
    w, h = xmax - xmin + 2 * pad, ymax - ymin + 2 * pad
    return (1, 0, 0, -1, pad - xmin, pad + ymax), w, h


def svg(w, h, layers, bg=None, extra=""):
    body = "".join(f'<path fill="{col}" d="{d}"/>' for col, d in layers)
    back = f'<rect width="{w:g}" height="{h:g}" fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" '
            f'width="{w:g}" height="{h:g}">{back}{body}{extra}</svg>\n')


def vector(size_dp, viewport, layers):
    paths = "\n".join(f'    <path\n        android:fillColor="{col}"\n        android:pathData="{d}" />'
                      for col, d in layers)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<!-- Generated by assets/brand/build_brand.py. Do not edit by hand. -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{size_dp}dp"\n    android:height="{size_dp}dp"\n'
            f'    android:viewportWidth="{viewport}"\n    android:viewportHeight="{viewport}">\n'
            f'{paths}\n</vector>\n')


def write(rel, text):
    out = HERE / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)


def main():
    # Mark and wordmark, cropped to their bounds with a small pad (font units).
    for name, main_path, accent_path, mono_accent in (
        ("mark", R_CUT, MARK_LINE, MONO_TAIL),
        ("wordmark", WORD, WORD_DASH, WORD_DASH),
    ):
        t, w, h = box_xform([main_path, accent_path], pad=20)
        d_main, d_acc, d_mono = (to_d(p, *t) for p in (main_path, accent_path, mono_accent))
        write(f"svg/{name}-on-dark.svg", svg(w, h, [(BONE, d_main), (ARC, d_acc)]))
        write(f"svg/{name}-on-light.svg", svg(w, h, [(INK_LIGHT, d_main), (ARC_LIGHT, d_acc)]))
        write(f"svg/{name}-mono-black.svg", svg(w, h, [("#000000", d_main), ("#000000", d_mono)]))
        write(f"svg/{name}-mono-white.svg", svg(w, h, [("#FFFFFF", d_main), ("#FFFFFF", d_mono)]))

    # Adaptive launcher icon: 108 dp canvas, mark inside the 66 dp safe zone (radius 33, 1 dp margin).
    t = fit_circle([ICON_R, ICON_LINE], 108, 32)
    fg = [(BONE, to_d(ICON_R, *t)), (ARC, to_d(ICON_LINE, *t))]
    # Same transform as the colour layer, so the themed icon sits exactly where the colour one does.
    mono = [("#FFFFFFFF", to_d(ICON_R, *t)), ("#FFFFFFFF", to_d(ICON_TAIL, *t))]
    bg_rect = "M0 0H108V108H0Z"
    write("android/drawable/ic_launcher_foreground.xml", vector(108, 108, fg))
    write("android/drawable/ic_launcher_monochrome.xml", vector(108, 108, mono))
    write("android/drawable/ic_launcher_background.xml", vector(108, 108, [(BG, bg_rect)]))
    write("android/mipmap-anydpi-v26/ic_launcher.xml",
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <background android:drawable="@drawable/ic_launcher_background" />\n'
          '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
          '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
          '</adaptive-icon>\n')
    write("svg/icon/ic_launcher_foreground.svg", svg(108, 108, fg))
    write("svg/icon/ic_launcher_monochrome.svg", svg(108, 108, [("#FFFFFF", d) for _, d in mono]))
    write("svg/icon/ic_launcher_background.svg", svg(108, 108, [], bg=BG))
    write("svg/icon/ic_launcher_full.svg", svg(108, 108, fg, bg=BG))
    guides = ('<rect x=".5" y=".5" width="107" height="107" fill="none" stroke="#5F646D" stroke-width=".5" stroke-dasharray="2 2"/>'
              '<circle cx="54" cy="54" r="36" fill="none" stroke="#A5A9B1" stroke-width=".5" stroke-dasharray="1 2"/>'
              '<circle cx="54" cy="54" r="33" fill="none" stroke="#19E6FF" stroke-width=".5" stroke-dasharray="3 2"/>')
    write("svg/icon/ic_launcher_safe-zone-guide.svg", svg(108, 108, fg, bg=BG, extra=guides))

    # Android 12 splash icon (no icon background): 288 dp canvas, keep inside the 192 dp circle.
    ts = fit_circle([ICON_R, ICON_LINE], 288, 84)
    splash = [(BONE, to_d(ICON_R, *ts)), (ARC, to_d(ICON_LINE, *ts))]
    write("android/drawable/splash_icon.xml", vector(288, 288, splash))
    write("svg/icon/splash_icon.svg", svg(288, 288, splash))

    # Notification small icon: 24 dp, white on transparent, 1 dp padding, heavier cut for legibility.
    heavy = diff(R, rect(0, CUT_Y - NOTE_CUT_T / 2, 1000, CUT_Y + NOTE_CUT_T / 2))
    tail = pill(r_xmax + 0.08 * CAP, CUT_Y - 0.055 * CAP, r_xmax + 0.36 * CAP, CUT_Y + 0.055 * CAP)
    tn = fit_box([heavy, tail], 24, 1)
    note = [("#FFFFFFFF", to_d(heavy, *tn)), ("#FFFFFFFF", to_d(tail, *tn))]
    write("android/drawable/ic_stat_runsupreme.xml", vector(24, 24, note))
    write("svg/icon/ic_stat_runsupreme.svg", svg(24, 24, [("#FFFFFF", d) for _, d in note]))
    print("brand assets written to", HERE)


if __name__ == "__main__":
    main()
