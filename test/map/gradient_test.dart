import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/gradient.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/map/snapshot_cache.dart';
import 'package:run_solo/theme/tokens.dart';
import 'package:run_solo/topo/topo_style.dart';

/// Points 10 m apart heading north, at the given elevations.
List<GeoPoint> _climb(List<double?> ele) => [
  for (var i = 0; i < ele.length; i++)
    GeoPoint(1.0 + i * 10 / 111320, 103.0, ele[i]),
];

double _dist(Color a, Color b) {
  final dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  test('a short blip near a route end is not steep', () {
    // 10 points (90 m): the window is cut short at both ends.
    final ele = <double?>[100, 100, 100, 103, 100, 100, 100, 100, 100, 100];
    final runs = gradientRuns(_climb(ele))!;
    expect(runs.any((r) => r.cls == GradientClass.steep), isFalse);
    // And a real climb at the start of a long route still shows.
    final real = <double?>[for (var i = 0; i < 40; i++) 100.0 + i];
    expect(
      gradientRuns(_climb(real))!.any((r) => r.cls == GradientClass.steep),
      isTrue,
    );
  });

  test('card fingerprint changes when elevation appears', () {
    RouteGeometry g(List<GeoPoint> pts) => RouteGeometry(
      points: pts,
      markers: const [],
      bounds: RouteBuilder.boundsOf(pts),
    );
    final bare = [for (var i = 0; i < 5; i++) GeoPoint(1 + i * 1e-4, 103)];
    final withEle = [
      for (var i = 0; i < 5; i++) GeoPoint(1 + i * 1e-4, 103, 10.0 + i),
    ];
    expect(routeFingerprint(g(bare)), isNot(routeFingerprint(g(withEle))));
  });

  test('steep stretches are drawn wider, and scaled with the pixel ratio', () {
    final layers = <Object?>[
      <String, Object?>{
        'id': 'rs-track',
        'type': 'line',
        'paint': <String, Object?>{
          'line-width': [
            'case',
            [
              '==',
              ['get', 'w'],
              1,
            ],
            7,
            5,
          ],
        },
      },
    ];
    TopoStyle.scaleForPixelRatio(layers, 2);
    final w = (((layers.first! as Map)['paint']! as Map)['line-width']) as List;
    expect(w, [
      'case',
      [
        '==',
        ['get', 'w'],
        1,
      ],
      14,
      10,
    ]);
  });

  test('classOfGrade thresholds', () {
    expect(classOfGrade(0.0), GradientClass.flat);
    expect(classOfGrade(0.029), GradientClass.flat);
    expect(classOfGrade(0.03), GradientClass.up);
    expect(classOfGrade(0.08), GradientClass.up);
    expect(classOfGrade(0.081), GradientClass.steep);
    expect(classOfGrade(-0.05), GradientClass.down);
  });

  test('no elevation, no gradient line', () {
    expect(gradientRuns(_climb([null, null, null])), isNull);
    expect(gradientRuns(const [GeoPoint(1, 1)]), isNull);
  });

  test('flat then steep climb gives a flat run then a steep run', () {
    // 30 points (290 m): 15 flat, then +1 m per 10 m (10 %).
    final ele = <double?>[
      for (var i = 0; i < 15; i++) 100,
      for (var i = 1; i <= 15; i++) 100 + i.toDouble(),
    ];
    final runs = gradientRuns(_climb(ele))!;
    expect(runs.first.cls, GradientClass.flat);
    expect(runs.last.cls, GradientClass.steep);
    // Runs share their end point, so the line has no gaps.
    for (var i = 1; i < runs.length; i++) {
      expect(runs[i].points.first, runs[i - 1].points.last);
    }
  });

  test('a 3 m blip inside the window does not stripe the line', () {
    final ele = <double?>[for (var i = 0; i < 40; i++) 100];
    ele[20] = 103;
    final runs = gradientRuns(_climb(ele))!;
    // A 3 m spike over a 50 m window is about 6 % at worst, never steep.
    expect(runs.any((r) => r.cls == GradientClass.steep), isFalse);
  });

  test('descent is down', () {
    final ele = <double?>[for (var i = 0; i < 30; i++) 200 - i.toDouble()];
    final runs = gradientRuns(_climb(ele))!;
    expect(runs.any((r) => r.cls == GradientClass.down), isTrue);
    expect(
      runs.every(
        (r) => r.cls == GradientClass.down || r.cls == GradientClass.flat,
      ),
      isTrue,
    );
  });

  test('gradient colours avoid the zone ramp and semantic colours', () {
    const forbidden = [
      AuroraRunType.free,
      AuroraRunType.laps,
      AuroraRunType.goal,
      AuroraRunType.intervals,
      AuroraRunType.tests,
      AuroraRunType.trail,
      Color(0xFF2F6DB5),
      Color(0xFF2E9E5B),
      Color(0xFFD9A21B),
      Color(0xFFE86A1C),
      Color(0xFFD6283B),
      Color(0xFF1C8356),
      Color(0xFFC8401E),
      Color(0xFF19E6FF),
      // Light-theme score colours: speed magenta, aerobic lime, mid violet,
      // long ice.
      Color(0xFFD81B7A),
      Color(0xFF3E9B1E),
      Color(0xFF8A5CF0),
      Color(0xFF1F8FD6),
      // Dark-theme semantics, from the tokens.
      NightSession.semSlower,
      NightSession.semImproving,
      NightSession.accentArc,
      NightSession.semWarn,
      NightSession.semDanger,
      NightSession.pulseRose,
    ];
    for (final c in GradientClass.values) {
      for (final f in forbidden) {
        expect(
          _dist(GradientColours.of(c), f),
          greaterThan(90),
          reason: '$c too close to $f',
        );
      }
    }
  });

  test('TopoStyle.gradientLine falls back to one plain feature', () {
    final plain = TopoStyle.gradientLine(
      _climb([null, null, null]),
      fallback: const Color(0xFFFFFFFF),
      casing: const Color(0xFF000000),
    );
    expect((plain['features'] as List).length, 1);
    final g = TopoStyle.gradientLine(
      _climb([for (var i = 0; i < 30; i++) 100.0 + i]),
      fallback: const Color(0xFFFFFFFF),
      casing: const Color(0xFF000000),
    );
    final colours = [
      for (final f in g['features'] as List)
        ((f as Map)['properties'] as Map)['c'],
    ];
    expect(colours, contains(TopoStyle.hex(GradientColours.steep)));
  });
}
