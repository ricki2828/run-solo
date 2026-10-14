import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/grade_band.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';

double _dist(Color a, Color b) {
  final dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('bands at the fixed thresholds', () {
    GradeBand? b(double? p) => GradeBand.of(p);
    expect(b(null), isNull);
    expect(b(0), GradeBand.flat);
    expect(b(1.9), GradeBand.flat);
    expect(b(-1.9), GradeBand.flat);
    expect(b(2), GradeBand.gentle);
    expect(b(4.9), GradeBand.gentle);
    expect(b(5), GradeBand.climb);
    expect(b(7.9), GradeBand.climb);
    expect(b(8), GradeBand.steep);
    expect(b(12), GradeBand.steep);
    expect(b(12.1), GradeBand.verySteep);
    expect(b(-2), GradeBand.down);
    expect(b(-7.9), GradeBand.down);
    expect(b(-8), GradeBand.steepDown);
    expect(b(-20), GradeBand.steepDown);
  });

  test('the words', () {
    expect(
      [for (final g in GradeBand.values) g.word],
      ['Flat', 'Gentle', 'Climb', 'Steep', 'Very steep', 'Down', 'Steep down'],
    );
  });

  test('all seven fills are at least 60 apart from each other', () {
    const all = GradeBand.values;
    for (var i = 0; i < all.length; i++) {
      for (var j = i + 1; j < all.length; j++) {
        expect(
          _dist(all[i].fill, all[j].fill),
          greaterThanOrEqualTo(60),
          reason: '${all[i]} vs ${all[j]}',
        );
      }
    }
  });

  test('fills avoid the zone ramp, semantics and run types, both themes', () {
    final forbidden = <Color>[
      ...HrZones.backgrounds.skip(1),
      ...HrZones.distributionDark.skip(1),
      ...HrZones.distributionLight.skip(1),
      for (final t in [RunSoloTokens.dark, RunSoloTokens.light]) ...[
        t.typeFree,
        t.typeLaps,
        t.typeGoal,
        t.typeIntervals,
        t.typeTests,
        t.typeTrail,
        t.semFaster,
        t.semSlower,
        t.semImproving,
        t.semWarn,
        t.semDanger,
        t.hrZone,
        t.accentArc,
      ],
    ];
    for (final g in GradeBand.values) {
      for (final f in forbidden) {
        expect(
          _dist(g.fill, f),
          greaterThanOrEqualTo(60),
          reason: '${g.name} too close to $f',
        );
      }
    }
  });

  test('the word reads on its chip (4.5:1)', () {
    for (final g in GradeBand.values) {
      expect(
        _contrast(g.ink, g.fill),
        greaterThanOrEqualTo(4.5),
        reason: g.name,
      );
    }
  });
}
