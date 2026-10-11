import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/recent_bars_chart.dart';

double _dist(Color a, Color b) {
  final dr = (a.r - b.r) * 255;
  final dg = (a.g - b.g) * 255;
  final db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  for (final (name, t) in [
    ('light', RunSoloTokens.light),
    ('dark', RunSoloTokens.dark),
  ]) {
    test('PB bar is 60+ RGB from every run-type bar colour ($name)', () {
      final types = {
        'free': t.typeFree,
        'laps': t.typeLaps,
        'intervals': t.typeIntervals,
        'tests': t.typeTests,
        'goal': t.typeGoal,
        'trail': t.typeTrail,
      };
      for (final e in types.entries) {
        expect(
          _dist(t.pbBarColour, e.value),
          greaterThanOrEqualTo(60),
          reason: 'PB vs ${e.key} ($name)',
        );
      }
    });
  }
}
