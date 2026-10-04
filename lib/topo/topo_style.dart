/// The Aurora topo style, made ready for MapLibre on this phone.
///
/// `assets/maps/aurora_topo.json` is a template: it names the pack's three
/// PMTiles files and the glyph folder with `{pack}` and `{glyphs}`. MapLibre's
/// native engine fetches tiles and glyphs itself by `file://` path, so
/// nothing can stay inside the APK; [TopoStyle.build] swaps in the real
/// paths and adds the run's route layers (empty GeoJSON sources the surface
/// fills after the style loads). Pure Dart, so it is unit tested.
library;

import 'dart:convert';

import 'package:flutter/painting.dart' show Color;

/// The glyph ranges bundled under `assets/topo/glyphs/NotoSans/`. Latin,
/// Greek, Cyrillic and general punctuation: a range a tile asks for that is
/// missing kills that tile's labels (and made the T0 snapshot fail), so a
/// test keeps this list and the asset folder in step.
const List<String> kTopoGlyphRanges = [
  '0-255',
  '256-511',
  '512-767',
  '768-1023',
  '1024-1279',
  '7680-7935',
  '8192-8447',
  '8448-8703',
];

/// The one font stack the bundled glyphs provide.
const String kTopoFontStack = 'NotoSans';

class TopoStyle {
  const TopoStyle._();

  // Source and layer ids of the route layers.
  static const String planSource = 'rs-plan';
  static const String trackSource = 'rs-track';
  static const String marksSource = 'rs-marks';
  static const String meSource = 'rs-me';

  /// `#rrggbb` for a MapLibre colour string.
  static String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// [template] with the pack and glyph paths filled in and the route layers
  /// added on top. [attribution] (the pack's `map_text`) goes on the base
  /// map source so MapLibre's own attribution control carries it too.
  static String build(
    String template, {
    required String packDir,
    required String glyphsDir,
    String? attribution,
  }) {
    final filled = template
        .replaceAll('{pack}', packDir)
        .replaceAll('{glyphs}', glyphsDir);
    final style = (jsonDecode(filled) as Map).cast<String, Object?>();
    _swapFonts(style['layers']);
    final sources = (style['sources'] as Map).cast<String, Object?>();
    if (attribution != null && sources['basemap'] is Map) {
      (sources['basemap']! as Map)['attribution'] = attribution;
    }
    for (final id in const [planSource, trackSource, marksSource, meSource]) {
      sources[id] = {'type': 'geojson', 'data': emptyCollection};
    }
    final layers = (style['layers'] as List).cast<Object?>();
    layers.addAll(_routeLayers);
    style['metadata'] = {
      ...((style['metadata'] as Map?)?.cast<String, Object?>() ?? const {}),
      'placeholders': <String>[],
    };
    return jsonEncode(style);
  }

  /// Every `text-font` in the style becomes [kTopoFontStack]: the style
  /// names "Noto Sans Regular" / "Italic", the bundled glyph folder is one
  /// stack with no spaces in its path.
  static void _swapFonts(Object? layers) {
    if (layers is! List) return;
    for (final l in layers) {
      if (l is! Map) continue;
      final layout = l['layout'];
      if (layout is Map && layout.containsKey('text-font')) {
        layout['text-font'] = [kTopoFontStack];
      }
    }
  }

  static const Map<String, Object?> emptyCollection = {
    'type': 'FeatureCollection',
    'features': <Object?>[],
  };

  /// Colours come from each feature (`c` fill or line, `k` casing or ring),
  /// so one style serves every run type and theme.
  static final List<Map<String, Object?>> _routeLayers = [
    _line('rs-plan-casing', planSource, ['get', 'k'], 9),
    _line('rs-plan', planSource, ['get', 'c'], 5),
    _line('rs-track-casing', trackSource, ['get', 'k'], 9),
    _line('rs-track', trackSource, ['get', 'c'], 5),
    {
      'id': 'rs-marks',
      'type': 'circle',
      'source': marksSource,
      'paint': {
        'circle-radius': 6,
        'circle-color': ['get', 'c'],
        'circle-stroke-color': ['get', 'k'],
        'circle-stroke-width': 2,
      },
    },
    {
      'id': 'rs-me',
      'type': 'circle',
      'source': meSource,
      'paint': {
        'circle-radius': 8,
        'circle-color': ['get', 'c'],
        'circle-stroke-color': ['get', 'k'],
        'circle-stroke-width': 3,
      },
    },
  ];

  static Map<String, Object?> _line(
    String id,
    String source,
    Object colour,
    double width,
  ) => {
    'id': id,
    'type': 'line',
    'source': source,
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {'line-color': colour, 'line-width': width},
  };

  /// A GeoJSON line for [points] given as (lat, lon) pairs; fewer than two
  /// points is an empty collection.
  static Map<String, Object?> line(
    Iterable<(double, double)> points, {
    required Color colour,
    required Color casing,
  }) {
    final coords = [
      for (final (lat, lon) in points) <double>[lon, lat],
    ];
    if (coords.length < 2) return emptyCollection;
    return {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {'c': hex(colour), 'k': hex(casing)},
          'geometry': {'type': 'LineString', 'coordinates': coords},
        },
      ],
    };
  }

  /// One dot: [fill] inside a [ring].
  static Map<String, Object?> dots(
    Iterable<(double, double, Color, Color)> dots,
  ) => {
    'type': 'FeatureCollection',
    'features': [
      for (final (lat, lon, fill, ring) in dots)
        {
          'type': 'Feature',
          'properties': {'c': hex(fill), 'k': hex(ring)},
          'geometry': {
            'type': 'Point',
            'coordinates': [lon, lat],
          },
        },
    ],
  };
}
