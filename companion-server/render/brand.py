"""Run Supreme brand tokens for server-rendered media. Single source for cards and motion.

Mirrors the app (assets/fonts, assets/brand). Change a value here, not in a template.
"""
from __future__ import annotations

import base64
import functools
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# A deployed copy has no repo around it: COMPANION_ASSETS_DIR points at its own copy of assets/ (fonts + brand).
ASSETS_DIR = Path(os.environ.get("COMPANION_ASSETS_DIR") or REPO / "assets")
FONT_DIR = ASSETS_DIR / "fonts"
BRAND_SVG_DIR = ASSETS_DIR / "brand" / "svg"

# Ground and text
GROUND = "#FBFBF9"
INK = "#121417"
QUIET = "#6C747E"
HAIRLINE = "#E3E5E0"
BONE = "#EDEAE3"
ARC = "#19E6FF"  # PB cyan, the Lap Line colour

# Score colours (each score owns one colour)
SCORE = {"aerobic": "#3E9B1E", "speed": "#D81B7A", "mid": "#8A5CF0", "long": "#1F8FD6"}
MINT = "#1C8356"        # faster
VERMILLION = "#C8401E"  # slower

# Zone chart ramp Z1..Z5 and the full-bleed floods behind it
ZONE_RAMP = ("#2F6DB5", "#2E9E5B", "#D9A21B", "#E86A1C", "#D6283B")
ZONE_FLOOD_SPEC = ("#1C3F6E", "#17603A", "#7A5A08", "#8A3410", "#7D1222")
# Bone (#EDEAE3) contrast on the spec floods, measured: Z1 8.80, Z2 6.31, Z3 5.31, Z4 6.78, Z5 8.82 (:1).
# Cards promise 7:1, so Z2, Z3 and Z4 are darkened by the smallest step that reaches it:
#   Z2 #17603A -> #155835 (x0.92, 7.05:1), Z3 #7A5A08 -> #634907 (x0.815, 7.03:1), Z4 #8A3410 -> #863210 (x0.97, 7.06:1).
# Z1 and Z5 are unchanged. tests/test_render_cards.py enforces >= 7:1 on every entry.
ZONE_FLOOD = ("#1C3F6E", "#155835", "#634907", "#863210", "#7D1222")

RUN_TYPE_COLOUR = {
    "easy": SCORE["aerobic"], "long": SCORE["long"], "tempo": SCORE["mid"],
    "interval": SCORE["speed"], "race": SCORE["speed"], "cooper": SCORE["speed"], "trail": SCORE["long"],
}

SAIRA = "Saira Extra Condensed"
SCHIBSTED = "Schibsted Grotesk"


def _lum(hex_: str) -> float:
    h = hex_.lstrip("#")
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255
        out.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def contrast(a: str, b: str) -> float:
    hi, lo = sorted((_lum(a), _lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


@functools.lru_cache(maxsize=1)
def font_css() -> str:
    """@font-face rules with the fonts inlined as base64, so a page needs no file access."""
    def face(family: str, file: str, weight: str) -> str:
        data = base64.b64encode((FONT_DIR / file).read_bytes()).decode()
        return (f"@font-face{{font-family:'{family}';font-weight:{weight};font-style:normal;"
                f"src:url(data:font/ttf;base64,{data}) format('truetype');}}")
    return (face(SAIRA, "SairaExtraCondensed-ExtraBold.ttf", "800")
            + face(SAIRA, "SairaExtraCondensed-Medium.ttf", "500")
            + face(SCHIBSTED, "SchibstedGrotesk-Variable.ttf", "400 900"))


@functools.lru_cache(maxsize=None)
def mark_svg(variant: str = "on-light", height: int = 64) -> str:
    """The Lap Line R mark as inline SVG at a given height (variant: on-light, on-dark, mono-black, mono-white)."""
    svg = (BRAND_SVG_DIR / f"mark-{variant}.svg").read_text()
    ratio = 622 / 740
    return svg.replace('width="622" height="740"', f'width="{round(height * ratio)}" height="{height}"', 1)


def flood_for_zone(zone: int) -> str:
    return ZONE_FLOOD[max(1, min(5, zone)) - 1]
