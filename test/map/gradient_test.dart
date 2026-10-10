import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/gradient.dart';
import 'package:run_solo/map/route_builder.dart';
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
    expect(runs.single.cls, GradientClass.down);
  });

  test('gradient colours avoid the zone ramp and semantic colours', () {
    const forbidden = [
      Color(0xFF2F6DB5),
      Color(0xFF2E9E5B),
      Color(0xFFD9A21B),
      Color(0xFFE86A1C),
      Color(0xFFD6283B),
      Color(0xFF1C8356),
      Color(0xFFC8401E),
      Color(0xFF19E6FF),
    ];
    for (final c in GradientClass.values) {
      for (final f in forbidden) {
        expect(
          _dist(GradientColours.of(c), f),
          greaterThan(60),
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
    final props = ((g['features'] as List).first as Map)['properties'] as Map;
    expect(props['c'], TopoStyle.hex(GradientColours.steep));
  });
}
