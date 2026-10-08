#!/usr/bin/env python3
"""Builds the Play Store phone screenshots and the feature graphic in the light everyday look.

Screenshots are the CI golden images (test/golden/goldens) composited onto a light frame with a
Saira Extra Condensed headline, a Schibsted Grotesk subline and a lap line in a score colour.
Goldens use a fake map, so no map-bearing golden is used; add device captures of the live map or
the Topo map by hand if wanted. Re-run whenever the goldens change.

    python3 -m venv /tmp/brandvenv && /tmp/brandvenv/bin/pip install -r assets/brand/requirements.txt
    /tmp/brandvenv/bin/python store/play/build_screens.py

Writes store/play/screens/NN-name.png (1080x1920) and store/play/feature-graphic-1024x500.png.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "assets" / "brand"))
import build_brand as bb  # noqa: E402  (Lap Line R geometry)

GOLD = REPO / "test" / "golden" / "goldens"
FONTS = REPO / "assets" / "fonts"
HEAD_FONT = FONTS / "SairaExtraCondensed-ExtraBold.ttf"
BODY_FONT = FONTS / "SchibstedGrotesk-Variable.ttf"
OUT = HERE / "screens"

# Light everyday palette (lib/theme/tokens.dart) and the score colours as the app shows them.
BG, INK, INK2, HAIR = (251, 251, 249), (18, 20, 23), (74, 80, 88), (227, 229, 224)
AEROBIC, SPEED, MID, LONG = (47, 161, 0), (255, 49, 175), (162, 112, 255), (0, 149, 206)
ARC_LIGHT = "#0098B2"
W, H = 1080, 1920

# (file, golden, headline, subline, line colour)
SHOTS = [
    ("01-progress", "home_progress_up_360x800", "TRACK PROGRESS.", "See how you rank for your age (estimate)", AEROBIC),
    ("02-run-ladder", "record_rep_z4_target_360x800", "SEE YOUR ZONE LIVE", "Big numbers, a zone ladder, voice coaching", SPEED),
    ("03-verdict", "verdict_faster", "AN HONEST VERDICT", "Faster, holding or slower, and why", MID),
    ("04-plan", "plan_plan_360x800", "A 4-WEEK PLAN", "Built around your scores, week by week", LONG),
    ("05-zone-charts", "detail_chart_4x4_360x640", "WHERE THE EFFORT WENT", "Reps, splits and time in zone, by colour", AEROBIC),
    ("06-offline-maps", "offline_maps_list", "TOPO MAPS, NO SIGNAL", "Download a region, run with no data", SPEED),
    ("07-start", "start_session_400s_360x800", "PICK YOUR SESSION", "Free, trail, intervals, laps, goals, tests", MID),
    ("08-history", "history_weeks_360x800", "SEE EVERY RUN", "By week, with pace and zone colours", LONG),
]


def head_font(size):
    return ImageFont.truetype(str(HEAD_FONT), size)


def body_font(size, weight=500):
    f = ImageFont.truetype(str(BODY_FONT), size)
    f.set_variation_by_axes([weight])
    return f


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height + radius], radius, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im.convert("RGBA"), (0, 0), mask)
    return out


def frame(golden, head, sub, colour):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    size = 150
    while d.textlength(head, font=head_font(size)) > W - 144:  # never clip a headline
        size -= 4
    d.text((72, 84), head, font=head_font(size), fill=INK)
    hw = d.textlength(head, font=head_font(size))
    ly = 84 + size + 30
    d.rounded_rectangle([72, ly, 72 + max(hw, 360), ly + 12], 6, fill=colour)  # lap line in a score colour
    sub_size = 44
    while d.textlength(sub, font=body_font(sub_size)) > W - 144:
        sub_size -= 2
    d.text((72, ly + 36), sub, font=body_font(sub_size), fill=INK2)
    shot = Image.open(GOLD / f"{golden}.png").convert("RGB")
    sw = 860
    shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
    top = ly + 150
    shot = shot.crop((0, 0, sw, H - top))  # bleeds off the bottom
    x = (W - sw) // 2
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x, top + 14, x + sw, H + 80], 56, fill=(18, 20, 23, 46))
    img.paste(shadow.filter(ImageFilter.GaussianBlur(22)), (0, 0), shadow.filter(ImageFilter.GaussianBlur(22)))
    border = Image.new("RGB", (sw + 6, shot.height + 6), (205, 208, 202))
    img.paste(rounded(border, 58), (x - 3, top - 3), rounded(border, 58))
    img.paste(rounded(shot, 56), (x, top), rounded(shot, 56))
    return img


def feature_graphic():
    w, h = 1024, 500
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    # Four score colours as a lane strip along the top edge.
    seg = w // 4
    for i, c in enumerate((AEROBIC, SPEED, MID, LONG)):
        d.rectangle([i * seg, 0, (i + 1) * seg, 12], fill=c)
    # Lap Line R, left, with its lap line running out to the tagline column.
    kr = 330 / bb.CAP
    rx, base = 64, 410
    bb.paint(img, INK, bb.R_CUT, (kr, 0, 0, -kr, rx, base))
    _, _, rxmax, _ = bb.bounds(bb.R_CUT)
    cy = base - bb.CUT_Y * kr
    # lap line in the Lap Line cyan, as on the icon
    t = bb.LINE_T * kr
    leg_l, _ = bb.leg_span(bb.R)
    d.rounded_rectangle([rx + leg_l * kr, cy - t / 2, rx + (rxmax + bb.MARK_TAIL) * kr, cy + t / 2], t / 2, fill=ARC_LIGHT)
    # Tagline, two lines, Saira.
    f = head_font(100)
    tx = 410
    d.text((tx, 110), "TRACK PROGRESS.", font=f, fill=INK)
    d.text((tx, 110 + 112), "GET BETTER.", font=f, fill=AEROBIC)
    d.text((tx, 110 + 112 * 2 + 20), "Run scores, honest verdicts, trail runs.", font=body_font(28), fill=INK2)
    d.text((tx, 46), "RUN SUPREME", font=head_font(40), fill=INK2)
    return img


def main():
    OUT.mkdir(exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()  # file names changed with the refresh; do not leave stale shots behind
    for name, golden, head, sub, colour in SHOTS:
        frame(golden, head, sub, colour).save(OUT / f"{name}.png", optimize=True)
        print(f"{name}.png  <- {golden}.png")
    feature_graphic().save(HERE / "feature-graphic-1024x500.png", optimize=True)
    print("feature-graphic-1024x500.png")


if __name__ == "__main__":
    main()
