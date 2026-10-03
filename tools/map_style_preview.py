#!/usr/bin/env python3
"""Static before/after preview of the Home card map style.

Not a real Google render: it paints a synthetic street grid, park and water
with the colours read from the style JSON files, then the dimming overlay and
the route (run-type colour, dark casing) as the card draws them. Use it to
judge palette and contrast; the real look needs a device build.

    python3 tools/map_style_preview.py docs/maps/card-style-preview.png
"""
import json
import sys

from PIL import Image, ImageDraw, ImageFont

BG_BASE = (0x0A, 0x0B, 0x0D)
ROUTES = {"free": "#7CDBFF", "goal": "#B48CFF", "intervals": "#FF6EC7"}
W, H, S = 360, 148, 3


def rgb(h):
    return tuple(int(h[i : i + 2], 16) for i in (1, 3, 5))


def style_colours(path):
    out = {}
    for e in json.load(open(path)):
        for st in e.get("stylers", []):
            if "color" in st:
                out[(e.get("featureType", ""), e.get("elementType", ""))] = st["color"]
    return out


def lum(c):
    ch = [v / 255 for v in c]
    ch = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in ch]
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]


def contrast(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def paint(style, overlay, route_hex, labels):
    sc = style_colours(style)
    im = Image.new("RGB", (W * S, H * S), rgb(sc[("landscape", "geometry")]))
    d = ImageDraw.Draw(im)
    s = lambda *v: [x * S for x in v]
    park = rgb(sc[("poi.park", "geometry")])
    water = rgb(sc[("water", "geometry")])
    d.rectangle(s(210, 8, 330, 70), fill=park)
    d.polygon(s(0, 110, 70, 100, 120, 125, 80, 148, 0, 148), fill=water)
    local = rgb(sc[("road.local", "geometry.fill")])
    art = rgb(sc[("road.arterial", "geometry.fill")])
    hwy = rgb(sc[("road.highway", "geometry.fill")])
    for x in range(20, 360, 36):
        d.line(s(x, 0, x + 6, H), fill=local, width=2 * S)
    for y in range(14, 148, 26):
        d.line(s(0, y, W, y + 4), fill=local, width=2 * S)
    d.line(s(0, 60, W, 76), fill=art, width=4 * S)
    d.line(s(150, 0, 190, H), fill=hwy, width=6 * S)
    if labels:
        try:
            f = ImageFont.truetype("DejaVuSans.ttf", 9 * S)
        except OSError:
            f = ImageFont.load_default()
        sub = rgb(sc.get(("administrative.neighborhood", "labels.text.fill"), "#7D838D"))
        pk = rgb(sc.get(("poi.park", "labels.text.fill"), "#6E8577"))
        d.text(s(40, 28), "Albert Park", fill=sub, font=f)
        d.text(s(236, 30), "Memorial Park", fill=pk, font=f)
    base = Image.new("RGB", im.size, BG_BASE)
    im = Image.blend(im, base, overlay)
    d = ImageDraw.Draw(im)
    pts = s(30, 118, 70, 96, 112, 90, 150, 70, 200, 66, 250, 84, 300, 80, 330, 52)
    pts = list(zip(pts[0::2], pts[1::2]))
    d.line(pts, fill=BG_BASE, width=8 * S, joint="curve")
    d.line(pts, fill=rgb(route_hex), width=4 * S, joint="curve")
    return im, hwy


def main(out):
    before = "assets/maps/night_session.json"
    after = "assets/maps/night_session_card.json"
    rows = []
    for name, hexv in ROUTES.items():
        b, hb = paint(before, 0.4, hexv, labels=False)
        a, ha = paint(after, 0.1, hexv, labels=True)
        rows.append((b, a))
        print(
            f"{name}: route vs brightest road  before {contrast(rgb(hexv), hb):.2f}:1"
            f"  after {contrast(rgb(hexv), ha):.2f}:1"
        )
    pad = 12 * S
    img = Image.new(
        "RGB", (2 * W * S + 3 * pad, len(rows) * (H * S + pad) + pad), (0, 0, 0)
    )
    for i, (b, a) in enumerate(rows):
        y = pad + i * (H * S + pad)
        img.paste(b, (pad, y))
        img.paste(a, (2 * pad + W * S, y))
    img = img.resize((img.width // 2, img.height // 2), Image.LANCZOS)
    img.save(out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "docs/maps/card-style-preview.png")
