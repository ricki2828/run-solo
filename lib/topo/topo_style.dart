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
import 'dart:math' as math;

import 'package:flutter/painting.dart' show Color;

import '../map/gradient.dart';
import '../map/route_builder.dart';

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
  static const String retraceSource = 'rs-retrace';
  static const String aheadSource = 'rs-ahead';
  static const String marksSource = 'rs-marks';
  static const String meSource = 'rs-me';

  /// `#rrggbb` for a MapLibre colour string.
  static String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// [template] with the pack and glyph paths filled in and the route layers
  /// added on top. The paths are put into the decoded JSON values (so any
  /// character in a path is escaped by `jsonEncode`, never spliced into
  /// text). [routeData] puts GeoJSON straight into the route sources: a
  /// snapshot re-reads the style file, so only data inside the file shows in
  /// it. MapLibre's own attribution button is left without text; the app
  /// draws its credit line.
  static String build(
    String template, {
    required String packDir,
    required String glyphsDir,
    Map<String, Map<String, Object?>> routeData = const {},
    double pixelScale = 1,
  }) {
    final style = (_fill(jsonDecode(template), packDir, glyphsDir) as Map)
        .cast<String, Object?>();
    _swapFonts(style['layers']);
    final sources = (style['sources'] as Map).cast<String, Object?>();
    for (final id in const [
      planSource,
      trackSource,
      retraceSource,
      aheadSource,
      marksSource,
      meSource,
    ]) {
      sources[id] = {
        'type': 'geojson',
        'data': routeData[id] ?? emptyCollection,
      };
    }
    final layers = (style['layers'] as List).cast<Object?>();
    layers.addAll(_routeLayers);
    if (pixelScale != 1) scaleForPixelRatio(layers, pixelScale);
    style['metadata'] = {
      ...((style['metadata'] as Map?)?.cast<String, Object?>() ?? const {}),
      'placeholders': <String>[],
    };
    return jsonEncode(style);
  }

  /// Paint and layout sizes that are in screen pixels.
  static const _pxPaint = [
    'line-width',
    'line-gap-width',
    'line-blur',
    'circle-radius',
    'circle-stroke-width',
    'text-halo-width',
    'text-halo-blur',
  ];
  static const _pxLayout = ['text-size', 'symbol-spacing'];

  /// Makes a style drawn at 1x look the same drawn [k] times denser: the
  /// native snapshotter cannot take a pixel ratio, so a card is shot with
  /// k times the pixels at zoom + log2(k), and every size in pixels, and every
  /// zoom a layer or a size ramp is keyed to, moves with it.
  static void scaleForPixelRatio(List<Object?> layers, double k) {
    final s = math.log(k) / math.ln2;
    for (final l in layers) {
      if (l is! Map) continue;
      for (final key in const ['minzoom', 'maxzoom']) {
        if (l[key] is num) l[key] = (l[key] as num) + s;
      }
      final paint = l['paint'];
      if (paint is Map) {
        for (final n in _pxPaint) {
          if (paint.containsKey(n)) paint[n] = _scale(paint[n], k, s);
        }
      }
      final layout = l['layout'];
      if (layout is Map) {
        for (final n in _pxLayout) {
          if (layout.containsKey(n)) layout[n] = _scale(layout[n], k, s);
        }
      }
    }
  }

  static bool _zoomInput(Object? v) =>
      v is List && v.isNotEmpty && v[0] == 'zoom';

  static Object? _scale(Object? v, double k, double s) {
    if (v is num) return v * k;
    if (v is! List || v.isEmpty) return v;
    if (v[0] == 'interpolate' && v.length >= 5 && _zoomInput(v[2])) {
      return [
        v[0],
        v[1],
        v[2],
        for (var i = 3; i + 1 < v.length; i += 2) ...[
          (v[i] as num) + s,
          _scale(v[i + 1], k, s),
        ],
      ];
    }
    if (v[0] == 'case' && v.length == 4) {
      // ['case', condition, whenTrue, otherwise]: only the sizes scale.
      return [v[0], v[1], _scale(v[2], k, s), _scale(v[3], k, s)];
    }
    if (v[0] == 'step' && v.length >= 3 && _zoomInput(v[1])) {
      return [
        v[0],
        v[1],
        _scale(v[2], k, s),
        for (var i = 3; i + 1 < v.length; i += 2) ...[
          (v[i] as num) + s,
          _scale(v[i + 1], k, s),
        ],
      ];
    }
    return v;
  }

  static Object? _fill(Object? v, String packDir, String glyphsDir) =>
      switch (v) {
        String s =>
          s.replaceAll('{pack}', packDir).replaceAll('{glyphs}', glyphsDir),
        List l => [for (final e in l) _fill(e, packDir, glyphsDir)],
        Map m => {
          for (final e in m.entries) e.key: _fill(e.value, packDir, glyphsDir),
        },
        _ => v,
      };

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
    _line('rs-plan-casing', planSource, ['get', 'k'], 9, wide: 11),
    _line('rs-plan', planSource, ['get', 'c'], 5, wide: 7),
    _line('rs-track-casing', trackSource, ['get', 'k'], 9, wide: 11),
    // A retraced stretch: a Bone band with a dark rim around the track's own
    // colour, so it stands out on any casing and either theme.
    _line('rs-retrace-rim', retraceSource, ['get', 'k'], 17),
    _line('rs-retrace-halo', retraceSource, ['get', 'h'], 13),
    // A dark channel inside the band, so a flat (bone) stretch still reads
    // as a coloured line inside it, not as more band.
    _line('rs-retrace-core', retraceSource, ['get', 'k'], 9),
    _line('rs-track', trackSource, ['get', 'c'], 5, wide: 7),
    // The old track still ahead, coloured by the grade in the runner's
    // direction, over everything beneath it.
    _line('rs-ahead-casing', aheadSource, ['get', 'k'], 11),
    _line('rs-ahead', aheadSource, ['get', 'c'], 7),
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
    double width, {
    double? wide,
  }) => {
    'id': id,
    'type': 'line',
    'source': source,
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {
      'line-color': colour,
      // A steep stretch is drawn wider (feature property `w`), so it does not
      // rest on colour alone.
      'line-width': wide == null
          ? width
          : [
              'case',
              [
                '==',
                ['get', 'w'],
                1,
              ],
              wide,
              width,
            ],
    },
  };

  /// A GeoJSON line for [points] given as (lat, lon) pairs; fewer than two
  /// points is an empty collection. [bold] draws it wide.
  static Map<String, Object?> line(
    Iterable<(double, double)> points, {
    required Color colour,
    required Color casing,
    bool bold = false,
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
          'properties': {
            'c': hex(colour),
            'k': hex(casing),
            // `w` 1 draws the wide variant of the line layers (7 over an 11
            // casing, not 5 over 9): the live route.
            if (bold) 'w': 1,
          },
          'geometry': {'type': 'LineString', 'coordinates': coords},
        },
      ],
    };
  }

  /// The line coloured by gradient class when [points] carry elevation, else
  /// the plain [fallback] line. One feature per run of one class.
  static Map<String, Object?> gradientLine(
    List<GeoPoint> points, {
    required Color fallback,
    required Color casing,
  }) {
    final runs = gradientRuns(points);
    if (runs == null) {
      return line(
        [for (final p in points) (p.lat, p.lon)],
        colour: fallback,
        casing: casing,
      );
    }
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final r in runs)
          {
            'type': 'Feature',
            'properties': {
              'c': hex(GradientColours.of(r.cls)),
              'k': hex(casing),
              'w': r.cls == GradientClass.steep ? 1 : 0,
            },
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final p in r.points) <double>[p.lon, p.lat],
              ],
            },
          },
      ],
    };
  }

  /// The retraced sections as lines: `h` is the Bone band, `k` its rim.
  static Map<String, Object?> retraceLines(
    Iterable<List<GeoPoint>> sections, {
    required Color rim,
    required Color halo,
  }) => {
    'type': 'FeatureCollection',
    'features': [
      for (final sec in sections)
        if (sec.length > 1)
          {
            'type': 'Feature',
            'properties': {'k': hex(rim), 'h': hex(halo)},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final p in sec) <double>[p.lon, p.lat],
              ],
            },
          },
    ],
  };

  /// [points] coloured by gradient in the order given, or nothing when they
  /// carry no elevation.
  static Map<String, Object?> aheadLine(
    List<GeoPoint> points, {
    required Color casing,
  }) => gradientRuns(points) == null
      ? emptyCollection
      : gradientLine(points, fallback: casing, casing: casing);

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
