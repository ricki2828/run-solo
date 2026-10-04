#!/usr/bin/env python3
"""Generate assets/maps/aurora_topo.json (MapLibre style spec v8) from the app's theme tokens.

Every colour is derived from the token values in lib/theme/tokens.dart (parsed, not copied),
so there is no hand-typed hex in this file. Run:

    python3 tools/topo/build_style.py            # write assets/maps/aurora_topo.json
    python3 tools/topo/build_style.py --check    # fail if the file is stale or contrast < 3:1

Sources use placeholders the app rewrites to the installed pack (see PLACEHOLDERS below).
Schema: Protomaps basemap v4 (layers roads/water/landuse/earth/places), our `contour` layer
(`ele` int metres, zoom ladder 100 m z9-10, 50 m z11-12, 20 m z13+), Terrarium raster-dem.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOKENS = ROOT / "lib/theme/tokens.dart"
OUT = ROOT / "assets/maps/aurora_topo.json"

# The app (TopoMapSurface) replaces these strings in the style JSON before handing it to MapLibre.
PLACEHOLDERS = {
    "basemap": "pmtiles://file://{pack}/basemap.pmtiles",
    "terrain": "pmtiles://file://{pack}/terrain.pmtiles",
    "contours": "pmtiles://file://{pack}/contours.pmtiles",
    "glyphs": "file://{glyphs}/{fontstack}/{range}.pbf",
}

SANS = ["Noto Sans Regular"]
SANS_MEDIUM = ["Noto Sans Medium"]
SANS_ITALIC = ["Noto Sans Italic"]

MIN_ROUTE_CONTRAST = 3.0


# --------------------------------------------------------------------------- colour helpers
def parse_tokens(path: Path = TOKENS) -> dict[str, dict[str, tuple[int, int, int, float]]]:
    """Return {class: {name: (r, g, b, alpha)}} for `static const Color x = Color(0xAARRGGBB)`."""
    out: dict[str, dict[str, tuple[int, int, int, float]]] = {}
    cls = None
    for line in path.read_text().splitlines():
        m = re.match(r"abstract final class (\w+)", line)
        if m:
            cls = m.group(1)
            out[cls] = {}
            continue
        m = re.search(r"static const Color (\w+) = Color\(0x([0-9A-Fa-f]{8})\)", line)
        if m and cls:
            v = int(m.group(2), 16)
            out[cls][m.group(1)] = ((v >> 16) & 255, (v >> 8) & 255, v & 255, ((v >> 24) & 255) / 255)
    return out


Rgb = tuple[float, float, float]


def mix(a: Rgb, b: Rgb, t: float) -> Rgb:
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))  # type: ignore[return-value]


def hexs(c: Rgb) -> str:
    return "#" + "".join(f"{max(0, min(255, round(v))):02X}" for v in c)


def lum(c: Rgb) -> float:
    def ch(v: float) -> float:
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: Rgb, b: Rgb) -> float:
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# --------------------------------------------------------------------------- palette
def palette(tokens: dict) -> dict[str, Rgb]:
    ns = {k: v[:3] for k, v in tokens["NightSession"].items()}
    base, raised, sunken = ns["bgBase"], ns["bgRaised"], ns["bgSunken"]
    ink2, muted = ns["inkSecondary"], ns["inkMuted"]
    green, cyan = ns["semImproving"], ns["accentArc"]

    land = mix(base, raised, 0.35)
    p = {
        "bg": base,
        "land": land,
        "park": mix(land, green, 0.07),
        "wood": mix(land, green, 0.10),
        "scrub": mix(land, green, 0.045),
        "urban": mix(land, raised, 0.7),
        "water": mix(sunken, cyan, 0.08),
        "water_line": mix(sunken, cyan, 0.26),
        "building": mix(land, raised, 0.9),
        "road_minor": mix(base, ink2, 0.10),
        "road_medium": mix(base, ink2, 0.14),
        "road_major": mix(base, ink2, 0.18),
        "road_highway": mix(base, ink2, 0.22),
        # trail layers sit above the roads in brightness but under every run-type colour
        "track": mix(base, ink2, 0.34),
        "path": mix(base, ink2, 0.38),
        "contour": mix(land, muted, 0.40),
        "contour_index": mix(land, muted, 0.62),
        "hill_shadow": sunken,
        "hill_highlight": mix(land, ink2, 0.30),
        "hill_accent": mix(land, sunken, 0.5),
        "label_place": mix(muted, ink2, 0.45),
        "label_minor": muted,
        "label_contour": mix(muted, ink2, 0.35),
        "boundary": mix(base, muted, 0.6),
        "halo": base,
    }
    return p


def run_type_colours(tokens: dict) -> dict[str, Rgb]:
    return {k: v[:3] for k, v in tokens["AuroraRunType"].items()}


# --------------------------------------------------------------------------- style
def w(*stops: tuple[float, float]) -> list:
    """Zoom-interpolated width: w((10, .5), (16, 2))."""
    return ["interpolate", ["linear"], ["zoom"], *[x for s in stops for x in s]]


def build(tokens: dict) -> dict:
    p = {k: hexs(v) for k, v in palette(tokens).items()}
    ele = ["get", "ele"]
    ele_mod = lambda n: ["==", ["%", ele, n], 0]  # noqa: E731
    not_index = ["!=", ["%", ele, 100], 0]
    is_line = ["==", ["geometry-type"], "LineString"]
    is_poly = ["==", ["geometry-type"], "Polygon"]
    kd = ["get", "kind_detail"]
    kind = ["get", "kind"]
    path_kd = ["in", kd, ["literal", ["path", "bridleway", "cycleway"]]]
    name = ["get", "name"]

    layers: list[dict] = [
        {"id": "background", "type": "background", "paint": {"background-color": p["land"]}},
        {
            "id": "landuse-urban",
            "type": "fill",
            "source": "basemap",
            "source-layer": "landuse",
            "filter": ["in", kind, ["literal", ["residential", "commercial", "industrial", "retail", "university", "school", "hospital", "cemetery"]]],
            "minzoom": 10,
            "paint": {"fill-color": p["urban"]},
        },
        {
            "id": "landuse-scrub",
            "type": "fill",
            "source": "basemap",
            "source-layer": "landuse",
            "filter": ["in", kind, ["literal", ["scrub", "grassland", "meadow", "heath", "farmland", "grass"]]],
            "paint": {"fill-color": p["scrub"]},
        },
        {
            "id": "landuse-wood",
            "type": "fill",
            "source": "basemap",
            "source-layer": "landuse",
            "filter": ["in", kind, ["literal", ["forest", "wood"]]],
            "paint": {"fill-color": p["wood"]},
        },
        {
            "id": "landuse-park",
            "type": "fill",
            "source": "basemap",
            "source-layer": "landuse",
            "filter": ["in", kind, ["literal", ["park", "national_park", "nature_reserve", "garden", "golf_course", "pitch", "playground"]]],
            "paint": {"fill-color": p["park"]},
        },
        {
            "id": "hillshade",
            "type": "hillshade",
            "source": "terrain",
            "paint": {
                "hillshade-exaggeration": 0.45,
                "hillshade-shadow-color": p["hill_shadow"],
                "hillshade-highlight-color": p["hill_highlight"],
                "hillshade-accent-color": p["hill_accent"],
                "hillshade-illumination-direction": 315,
            },
        },
        {
            "id": "water-fill",
            "type": "fill",
            "source": "basemap",
            "source-layer": "water",
            "filter": is_poly,
            "paint": {"fill-color": p["water"]},
        },
        {
            "id": "water-line",
            "type": "line",
            "source": "basemap",
            "source-layer": "water",
            "filter": is_line,
            "paint": {
                "line-color": p["water_line"],
                "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.4, 14, ["match", kind, "river", 2.2, "canal", 1.6, 1.0]],
            },
        },
        {
            "id": "buildings",
            "type": "fill",
            "source": "basemap",
            "source-layer": "buildings",
            "minzoom": 14,
            "paint": {"fill-color": p["building"]},
        },
        # --- contours (below roads and trails so paths stay readable) ---
        {
            "id": "contour-50",
            "type": "line",
            "source": "contours",
            "source-layer": "contour",
            "minzoom": 11,
            "maxzoom": 13,
            "filter": ["all", ele_mod(50), not_index],
            "layout": {"line-join": "round"},
            "paint": {"line-color": p["contour"], "line-width": w((11, 0.4), (13, 0.6)), "line-opacity": 0.8},
        },
        {
            "id": "contour-20",
            "type": "line",
            "source": "contours",
            "source-layer": "contour",
            "minzoom": 13,
            "filter": ["all", ele_mod(20), not_index],
            "layout": {"line-join": "round"},
            "paint": {"line-color": p["contour"], "line-width": w((13, 0.5), (16, 0.8)), "line-opacity": 0.8},
        },
        {
            "id": "contour-index",
            "type": "line",
            "source": "contours",
            "source-layer": "contour",
            "minzoom": 9,
            "filter": ele_mod(100),
            "layout": {"line-join": "round"},
            "paint": {"line-color": p["contour_index"], "line-width": w((9, 0.5), (13, 0.9), (16, 1.3))},
        },
        # --- roads ---
        {
            "id": "roads-minor",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 11,
            "filter": ["in", kind, ["literal", ["minor_road", "other"]]],
            "layout": {"line-join": "round", "line-cap": "round"},
            "paint": {"line-color": p["road_minor"], "line-width": w((11, 0.4), (14, 1.2), (17, 4))},
        },
        {
            "id": "roads-medium",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 8,
            "filter": ["==", kind, "medium_road"],
            "layout": {"line-join": "round", "line-cap": "round"},
            "paint": {"line-color": p["road_medium"], "line-width": w((8, 0.4), (14, 1.6), (17, 5))},
        },
        {
            "id": "roads-major",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 6,
            "filter": ["==", kind, "major_road"],
            "layout": {"line-join": "round", "line-cap": "round"},
            "paint": {"line-color": p["road_major"], "line-width": w((6, 0.5), (14, 2.0), (17, 6))},
        },
        {
            "id": "roads-highway",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 4,
            "filter": ["==", kind, "highway"],
            "layout": {"line-join": "round", "line-cap": "round"},
            "paint": {"line-color": p["road_highway"], "line-width": w((4, 0.5), (14, 2.4), (17, 7))},
        },
        # --- trails: dashed, lighter than every road, visible from z12 (tracks) / z13 (paths) ---
        {
            "id": "trail-track",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 12,
            "filter": ["all", ["==", kind, "path"], ["==", kd, "track"]],
            "layout": {"line-join": "round", "line-cap": "butt"},
            "paint": {
                "line-color": p["track"],
                "line-width": w((12, 0.7), (14, 1.4), (17, 3)),
                "line-dasharray": [3, 1.5],
            },
        },
        {
            "id": "trail-path",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 13,
            "filter": ["all", ["==", kind, "path"], ["any", path_kd, ["==", kd, "footway"]]],
            "layout": {"line-join": "round", "line-cap": "butt"},
            "paint": {
                "line-color": p["path"],
                "line-width": w((13, 0.8), (15, 1.5), (17, 2.6)),
                "line-dasharray": [2, 1.5],
            },
        },
        {
            "id": "trail-steps",
            "type": "line",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 15,
            "filter": ["all", ["==", kind, "path"], ["==", kd, "steps"]],
            "paint": {"line-color": p["path"], "line-width": w((15, 1.2), (17, 3)), "line-dasharray": [0.5, 0.8]},
        },
        {
            "id": "boundaries",
            "type": "line",
            "source": "basemap",
            "source-layer": "boundaries",
            "maxzoom": 10,
            "paint": {"line-color": p["boundary"], "line-width": 0.6, "line-dasharray": [4, 2]},
        },
        # --- labels ---
        {
            "id": "label-contour",
            "type": "symbol",
            "source": "contours",
            "source-layer": "contour",
            "minzoom": 12,
            "filter": ele_mod(100),
            "layout": {
                "symbol-placement": "line",
                "text-field": ["concat", ["to-string", ele], " m"],
                "text-font": SANS,
                "text-size": w((12, 9), (16, 11)),
                "symbol-spacing": 320,
                "text-max-angle": 30,
            },
            "paint": {"text-color": p["label_contour"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
        {
            "id": "label-roads",
            "type": "symbol",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 14,
            "filter": ["all", ["has", "name"], ["!=", kind, "path"]],
            "layout": {
                "symbol-placement": "line",
                "text-field": name,
                "text-font": SANS,
                "text-size": w((14, 10), (17, 12)),
                "text-max-angle": 30,
            },
            "paint": {"text-color": p["label_minor"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
        {
            "id": "label-trails",
            "type": "symbol",
            "source": "basemap",
            "source-layer": "roads",
            "minzoom": 15,
            "filter": ["all", ["has", "name"], ["==", kind, "path"]],
            "layout": {
                "symbol-placement": "line",
                "text-field": name,
                "text-font": SANS_ITALIC,
                "text-size": 10,
                "text-max-angle": 30,
            },
            "paint": {"text-color": p["label_minor"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
        {
            "id": "label-neighbourhood",
            "type": "symbol",
            "source": "basemap",
            "source-layer": "places",
            "minzoom": 13,
            "filter": ["in", kind, ["literal", ["neighbourhood", "macrohood"]]],
            "layout": {"text-field": name, "text-font": SANS, "text-size": 10, "text-transform": "uppercase", "text-letter-spacing": 0.08},
            "paint": {"text-color": p["label_minor"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
        {
            "id": "label-locality-small",
            "type": "symbol",
            "source": "basemap",
            "source-layer": "places",
            "minzoom": 11,
            "filter": ["all", ["==", kind, "locality"], ["!", ["in", kd, ["literal", ["city", "town"]]]]],
            "layout": {"text-field": name, "text-font": SANS, "text-size": w((11, 10), (15, 12))},
            "paint": {"text-color": p["label_minor"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
        {
            "id": "label-locality",
            "type": "symbol",
            "source": "basemap",
            "source-layer": "places",
            "filter": ["all", ["==", kind, "locality"], ["in", kd, ["literal", ["city", "town"]]]],
            "layout": {"text-field": name, "text-font": SANS_MEDIUM, "text-size": w((6, 11), (12, 14), (16, 16))},
            "paint": {"text-color": p["label_place"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
        {
            "id": "label-region",
            "type": "symbol",
            "source": "basemap",
            "source-layer": "places",
            "maxzoom": 9,
            "filter": ["in", kind, ["literal", ["region", "country"]]],
            "layout": {"text-field": name, "text-font": SANS_MEDIUM, "text-size": 11, "text-transform": "uppercase", "text-letter-spacing": 0.1},
            "paint": {"text-color": p["label_minor"], "text-halo-color": p["halo"], "text-halo-width": 1.5},
        },
    ]

    return {
        "version": 8,
        "name": "Aurora Topo",
        "metadata": {
            "generator": "tools/topo/build_style.py",
            "note": "Generated from lib/theme/tokens.dart. Do not edit by hand; rerun the generator.",
            "placeholders": ["{pack}", "{glyphs}"],
        },
        "sources": {
            "basemap": {"type": "vector", "url": PLACEHOLDERS["basemap"]},
            "terrain": {"type": "raster-dem", "url": PLACEHOLDERS["terrain"], "encoding": "terrarium", "tileSize": 512},
            "contours": {"type": "vector", "url": PLACEHOLDERS["contours"]},
        },
        "glyphs": PLACEHOLDERS["glyphs"],
        "layers": layers,
    }


# --------------------------------------------------------------------------- contrast gate
def contrast_report(tokens: dict) -> tuple[list[str], float]:
    """Worst-case contrast of each run-type colour against every non-label map colour."""
    pal = palette(tokens)
    land = pal["land"]
    # hillshade highlight is applied at about exaggeration strength, so composite it over land
    pal = dict(pal)
    pal["hill_highlight"] = mix(land, pal["hill_highlight"], 0.45)
    map_keys = [
        "land", "park", "wood", "scrub", "urban", "water", "water_line", "building",
        "road_minor", "road_medium", "road_major", "road_highway",
        "track", "path", "contour", "contour_index", "hill_highlight", "boundary",
    ]
    lines, worst = [], 99.0
    for rt, rgb in run_type_colours(tokens).items():
        scored = [(contrast(rgb, pal[k]), k) for k in map_keys]
        c, k = min(scored)
        worst = min(worst, c)
        lines.append(f"{rt:10s} {hexs(rgb)}  min {c:5.2f}:1 vs {k}")
    return lines, worst


def render(tokens: dict) -> str:
    return json.dumps(build(tokens), indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify the committed style is current and contrast holds")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()

    tokens = parse_tokens()
    report, worst = contrast_report(tokens)
    print("route colour vs map colours (WCAG, need >= %.1f:1)" % MIN_ROUTE_CONTRAST)
    print("\n".join(report))
    if worst < MIN_ROUTE_CONTRAST:
        print(f"FAIL: worst contrast {worst:.2f}:1", file=sys.stderr)
        return 1

    text = render(tokens)
    if args.check:
        if not args.out.exists() or args.out.read_text() != text:
            print(f"FAIL: {args.out} is stale; run tools/topo/build_style.py", file=sys.stderr)
            return 1
        print("style is current")
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
