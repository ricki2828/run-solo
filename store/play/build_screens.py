#!/usr/bin/env python3
"""Builds the Play Store phone screenshots and the progress-direction feature graphic.

Screenshots are the CI golden images (test/golden/goldens) composited onto Aurora frames with a
Barlow Condensed headline. Goldens use a fake map: shots marked MAP_PLACEHOLDER must be replaced
with a real device capture before upload. Re-run whenever the goldens change.

    python3 -m venv /tmp/brandvenv && /tmp/brandvenv/bin/pip install -r assets/brand/requirements.txt
    /tmp/brandvenv/bin/python store/play/build_screens.py

Writes store/play/screens/NN-name.png (1080x1920) and store/play/feature-graphic-progress-1024x500.png.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "assets" / "brand"))
import build_brand as bb  # noqa: E402  (font + Lap Line geometry)

GOLD = REPO / "test" / "golden" / "goldens"
FONT = REPO / "assets" / "fonts" / "BarlowCondensed-Bold.ttf"
OUT = HERE / "screens"

BG, RAISED, BONE, ARC = (10, 11, 13), (20, 22, 25), (237, 234, 227), (25, 230, 255)
MUTED = (165, 169, 177)
W, H = 1080, 1920
TAGLINE = "Track progress. Get better."

# (file, golden, headline, subline, map placeholder)
SHOTS = [
    ("01-progress", "home_progress_up_360x800", "SEE YOUR PROGRESS", "Four scores, and what moved", False),
    ("02-next-session", "start_session_400s_360x800", "PICK YOUR SESSION", "Free, trail, intervals, goals", False),
    ("03-live-numbers", "record_rep_360x800", "BIG LIVE NUMBERS", "Readable at a glance, mid-rep", False),
    ("04-verdict", "verdict_faster", "AN HONEST VERDICT", "Faster, holding or slower", False),
    ("05-trail", "trail_verdict_faster_360x800", "TRAIL VERDICTS", "Same trail, same footing", False),
    ("06-follow-route", "record_route_numbers_trail_360x800", "FOLLOW A ROUTE", "Turn alerts, off-route warnings", False),
    ("07-live-map", "record_route_map_free_360x800", "LIVE MAP ON TAP", "Numbers first, map when you want", True),
    ("08-climbs", "detail_elevation_360x800", "CLIMBS COUNTED", "Grade-adjusted pace, estimate", False),
]

CHECKS = {}  # name -> note, filled while building


def font(size, path=FONT):
    return ImageFont.truetype(str(path), size)


def rounded_top(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height + radius], radius, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im.convert("RGBA"), (0, 0), mask)
    return out


def frame(golden, head, sub):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    for y in range(0, H, 8):  # lane lines, as on the feature graphic
        d.line([(0, y), (W, y)], fill=(16, 17, 19))
    size = 124
    while d.textlength(head, font=font(size)) > W - 144:  # never clip a headline
        size -= 4
    d.text((72, 96 + (124 - size) // 2), head, font=font(size), fill=BONE)
    hw = d.textlength(head, font=font(size))
    ly = 96 + 124 + 38
    d.rounded_rectangle([72, ly, 72 + max(hw, 360), ly + 10], 5, fill=ARC)  # lap line under the headline
    d.text((72, ly + 34), sub, font=font(46, REPO / "assets" / "fonts" / "BarlowCondensed-SemiBold.ttf"), fill=MUTED)
    shot = Image.open(GOLD / f"{golden}.png").convert("RGB")
    sw = 860
    shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
    top = ly + 130
    shot = shot.crop((0, 0, sw, H - top))  # bleeds off the bottom
    border = Image.new("RGB", (sw + 8, shot.height + 8), (52, 56, 62))
    x = (W - sw) // 2
    img.paste(rounded_top(border, 60), (x - 4, top - 4), rounded_top(border, 60))
    img.paste(rounded_top(shot, 56), (x, top), rounded_top(shot, 56))
    return img


def feature_graphic():
    w, h = 1024, 500
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img, "RGBA")
    for y in range(0, h, 8):
        d.line([(0, y), (w, y)], fill=(255, 255, 255, 15))
    line_px = 200
    _, _, wx, _ = bb.bounds(bb.WORD)
    k = 440 / wx
    bb.paint(img, bb.BONE, bb.WORD, (k, 0, 0, -k, 64, line_px + bb.CUT_Y * k))
    ImageDraw.Draw(img).rectangle(
        [64 + wx * k + 24, line_px - bb.LINE_T / 2 * k, w, line_px + bb.LINE_T / 2 * k], fill=bb.ARC)
    # Tagline under the line, two lines so it stays big.
    f = font(76)
    d.text((64, 262), "TRACK PROGRESS.", font=f, fill=BONE)
    d.text((64, 262 + 80), "GET BETTER.", font=f, fill=ARC)
    # Phone crop on the right, bleeding off the bottom.
    shot = Image.open(GOLD / "home_progress_up_360x800.png").convert("RGB")
    sw = 300
    shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
    top = 236
    shot = shot.crop((0, 0, sw, h - top))
    x = 650
    img.paste(Image.new("RGB", (sw + 6, shot.height + 6), (52, 56, 62)), (x - 3, top - 3))
    img.paste(shot, (x, top))
    # keep the lap line in front of the phone edge
    ImageDraw.Draw(img).rectangle([x - 3, line_px - bb.LINE_T / 2 * k, w, line_px + bb.LINE_T / 2 * k], fill=bb.ARC)
    return img


def main():
    OUT.mkdir(exist_ok=True)
    for name, golden, head, sub, placeholder in SHOTS:
        frame(golden, head, sub).save(OUT / f"{name}.png", optimize=True)
        print(f"{name}.png  <- {golden}.png" + ("   REPLACE WITH DEVICE CAPTURE (fake map)" if placeholder else ""))
    feature_graphic().save(HERE / "feature-graphic-progress-1024x500.png", optimize=True)
    print("feature-graphic-progress-1024x500.png")


if __name__ == "__main__":
    main()
