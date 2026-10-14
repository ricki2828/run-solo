#!/usr/bin/env python3
"""Generate the Home card map styles (assets/maps/card/*.json): a printed-trail-map look.

The live and detail maps keep assets/maps/aurora_topo.json (dark, navigation style). Home card
snapshots use these instead: pale paper ground, soft hillshade, thin lane-tinted contours, soft
blue water, almost no labels. The run's lane colour is not known at build time, so three sentinel
colours stand in for it and lib/topo/topo_style.dart swaps them per card:

    LANE       the lane colour itself
    LANE_LINE  a light grey with a little lane in it (contours, trails)
    LANE_WASH  the lane colour, used at low opacity as a wash over the ground

    python3 tools/topo/build_card_style.py            # write assets/maps/card/*.json
    python3 tools/topo/build_card_style.py --check    # fail if a file is stale
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import build_style as bs

ROOT = bs.ROOT
OUT_DIR = ROOT / "assets/maps/card"

LANE = "#fe01fe"
LANE_LINE = "#fe02fe"
LANE_WASH = "#fe03fe"

# variant -> (hillshade exaggeration, minor contours, index weight, wash opacity). Picked from the
# 14-Oct review of paper+contours (a), hillshade-heavy (b) and lane wash (c): c's wash with b's relief.
VARIANTS = {
    "light": dict(hill=0.5, minor=0.4, index=1.0, wash=0.10),
    "dark": dict(hill=0.26, minor=0.55, index=1.0, wash=0.0),
}
FILES = {
    "light": "aurora_card_light.json",
    "dark": "aurora_card_dark.json",
}


def palette(tokens: dict, dark: bool) -> dict[str, str]:
    h = bs.hexs
    if dark:
        ns = {k: v[:3] for k, v in tokens["NightSession"].items()}
        paper = bs.mix(ns["bgBase"], ns["bgRaised"], 0.45)
        return {
            "paper": h(paper),
            "wood": h(bs.mix(paper, (60, 90, 70), 0.14)),
            "park": h(bs.mix(paper, (60, 90, 70), 0.08)),
            "urban": h(bs.mix(paper, (120, 120, 125), 0.08)),
            "water": h(bs.mix(paper, (40, 90, 110), 0.40)),
            "water_line": h(bs.mix(paper, (70, 130, 150), 0.55)),
            "road_minor": h(bs.mix(paper, (150, 150, 150), 0.10)),
            "road_major": h(bs.mix(paper, (150, 150, 150), 0.20)),
            "path": h(bs.mix(paper, (170, 165, 150), 0.40)),
            "hill_shadow": "#000000",
            "hill_highlight": h(bs.mix(paper, (200, 205, 210), 0.45)),
            "hill_accent": "#000000",
            "label": h(bs.mix(paper, (200, 200, 195), 0.55)),
            "halo": h(paper),
        }
    lt = {k: v[:3] for k, v in tokens["NightSessionLight"].items()}
    paper = bs.mix(lt["bgSunken"], (246, 240, 224), 0.55)
    return {
        "paper": h(paper),
        "wood": h(bs.mix(paper, (170, 200, 150), 0.18)),
        "park": h(bs.mix(paper, (170, 205, 160), 0.12)),
        "urban": h(bs.mix(paper, (200, 195, 185), 0.35)),
        "water": h((196, 222, 236)),
        "water_line": h((150, 196, 220)),
        "road_minor": h(bs.mix(paper, (255, 255, 255), 0.75)),
        "road_major": h(bs.mix(paper, (255, 255, 255), 0.95)),
        "path": h((176, 160, 138)),
        "hill_shadow": h((96, 100, 112)),
        "hill_highlight": h((255, 253, 246)),
        "hill_accent": h((120, 110, 100)),
        "label": h((120, 122, 118)),
        "halo": h(paper),
    }


def build(tokens: dict, variant: str) -> dict:
    dark = variant == "dark"
    v = VARIANTS[variant]
    p = palette(tokens, dark)
    ele = ["get", "ele"]
    ele_mod = lambda n: ["==", ["%", ele, n], 0]  # noqa: E731
    not_index = ["!=", ["%", ele, 100], 0]
    kind, kd = ["get", "kind"], ["get", "kind_detail"]
    w = bs.w
    index_w = v["index"]
    minor_op = v["minor"] * (0.8 if dark else 1.0)

    layers: list[dict] = [
        {"id": "background", "type": "background", "paint": {"background-color": p["paper"]}},
    ]
    for lid, kinds, col in (
        ("landuse-urban", ["residential", "commercial", "industrial", "retail", "university", "school", "hospital", "cemetery"], "urban"),
        ("landuse-wood", ["forest", "wood"], "wood"),
        ("landuse-park", ["park", "national_park", "nature_reserve", "garden", "golf_course", "pitch", "playground", "scrub", "grassland", "meadow", "heath", "farmland", "grass"], "park"),
    ):
        layers.append({
            "id": lid, "type": "fill", "source": "basemap", "source-layer": "landuse",
            "filter": ["in", kind, ["literal", kinds]], "paint": {"fill-color": p[col]},
        })
    layers.append({
        "id": "hillshade", "type": "hillshade", "source": "terrain",
        "paint": {
            "hillshade-exaggeration": v["hill"],
            "hillshade-shadow-color": p["hill_shadow"],
            "hillshade-highlight-color": p["hill_highlight"],
            "hillshade-accent-color": p["hill_accent"],
            "hillshade-illumination-direction": 315,
        },
    })
    if v["wash"] > 0:
        layers.append({"id": "lane-wash", "type": "background", "paint": {"background-color": LANE_WASH, "background-opacity": v["wash"]}})
    layers += [
        {"id": "water-fill", "type": "fill", "source": "basemap", "source-layer": "water",
         "filter": ["==", ["geometry-type"], "Polygon"], "paint": {"fill-color": p["water"]}},
        {"id": "water-line", "type": "line", "source": "basemap", "source-layer": "water",
         "filter": ["==", ["geometry-type"], "LineString"],
         "paint": {"line-color": p["water_line"],
                   "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.4, 14, ["match", kind, "river", 1.8, "canal", 1.2, 0.8]]}},
    ]
    if minor_op > 0:
        layers += [
            {"id": "contour-50", "type": "line", "source": "contours", "source-layer": "contour", "minzoom": 11, "maxzoom": 13,
             "filter": ["all", ele_mod(50), not_index], "layout": {"line-join": "round"},
             "paint": {"line-color": LANE_LINE, "line-width": w((11, 0.35), (13, 0.5)), "line-opacity": minor_op}},
            {"id": "contour-20", "type": "line", "source": "contours", "source-layer": "contour", "minzoom": 13,
             "filter": ["all", ele_mod(20), not_index], "layout": {"line-join": "round"},
             "paint": {"line-color": LANE_LINE, "line-width": w((13, 0.4), (16, 0.7)), "line-opacity": minor_op}},
        ]
    layers += [
        {"id": "contour-index", "type": "line", "source": "contours", "source-layer": "contour", "minzoom": 9,
         "filter": ele_mod(100), "layout": {"line-join": "round"},
         "paint": {"line-color": LANE_LINE,
                   "line-width": w((9, 0.5 * index_w), (13, 0.9 * index_w), (16, 1.3 * index_w)),
                   "line-opacity": 0.95}},
        {"id": "roads-minor", "type": "line", "source": "basemap", "source-layer": "roads", "minzoom": 12,
         "filter": ["in", kind, ["literal", ["minor_road", "other"]]], "layout": {"line-join": "round", "line-cap": "round"},
         "paint": {"line-color": p["road_minor"], "line-width": w((12, 0.5), (14, 1.4), (17, 4))}},
        {"id": "roads-major", "type": "line", "source": "basemap", "source-layer": "roads", "minzoom": 8,
         "filter": ["in", kind, ["literal", ["medium_road", "major_road", "highway"]]], "layout": {"line-join": "round", "line-cap": "round"},
         "paint": {"line-color": p["road_major"], "line-width": w((8, 0.5), (14, 2.2), (17, 6))}},
        {"id": "trail-path", "type": "line", "source": "basemap", "source-layer": "roads", "minzoom": 12,
         "filter": ["all", ["==", kind, "path"], ["!=", kd, "steps"]], "layout": {"line-join": "round", "line-cap": "butt"},
         "paint": {"line-color": p["path"], "line-width": w((12, 0.7), (15, 1.2), (17, 2)), "line-dasharray": [2, 1.5], "line-opacity": 0.85}},
        {"id": "label-locality", "type": "symbol", "source": "basemap", "source-layer": "places", "minzoom": 10,
         "filter": ["all", ["==", kind, "locality"], ["in", kd, ["literal", ["city", "town", "village"]]]],
         "layout": {"text-field": ["get", "name"], "text-font": bs.SANS_MEDIUM, "text-size": w((10, 10), (14, 12)),
                    "text-transform": "uppercase", "text-letter-spacing": 0.1},
         "paint": {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.5}},
    ]
    return {
        "version": 8,
        "name": f"Aurora Card {variant}",
        "metadata": {
            "generator": "tools/topo/build_card_style.py",
            "note": "Generated. Sentinel colours stand in for the run lane; see the script header.",
            "card": True,
            "placeholders": ["{pack}", "{glyphs}"],
        },
        "sources": {
            "basemap": {"type": "vector", "url": bs.PLACEHOLDERS["basemap"]},
            "terrain": {"type": "raster-dem", "url": bs.PLACEHOLDERS["terrain"], "encoding": "terrarium", "tileSize": 512},
            "contours": {"type": "vector", "url": bs.PLACEHOLDERS["contours"]},
        },
        "glyphs": bs.PLACEHOLDERS["glyphs"],
        "layers": layers,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    tokens = bs.parse_tokens()
    bad = 0
    for variant, fname in FILES.items():
        text = json.dumps(build(tokens, variant), indent=2, ensure_ascii=False) + "\n"
        path = OUT_DIR / fname
        if args.check:
            if not path.exists() or path.read_text() != text:
                print(f"FAIL: {path} is stale; run tools/topo/build_card_style.py", file=sys.stderr)
                bad = 1
        else:
            OUT_DIR.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            print(f"wrote {path}")
    if args.check and not bad:
        print("card styles are current")
    return bad


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    sys.exit(main())
