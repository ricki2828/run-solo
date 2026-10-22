import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/theme/lanes.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _ratio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The everyday light theme (brand build, 7-Oct-2026): body text 4.5:1,
/// large text and run-type names 3:1, on the ground and the raised surface.
void main() {
  const t = RunSoloTokens.light;
  final grounds = {'ground': t.bgBase, 'raised': t.bgRaised};

  test('light ground and ink match the brand spec', () {
    expect(t.bgBase, const Color(0xFFFBFBF9));
    expect(t.bgRaised, const Color(0xFFFFFFFF));
    expect(t.lineHair, const Color(0xFFE3E5E0));
    expect(t.inkPrimary, const Color(0xFF121417));
    expect(t.inkSecondary, const Color(0xFF4A5058));
  });

  test('body text and semantic colours are >= 4.5:1 on both surfaces', () {
    final text = {
      'ink': t.inkPrimary,
      'secondary': t.inkSecondary,
      'quiet': t.inkMuted,
      'mint': t.semImproving,
      'vermillion': t.semSlower,
      'faster': t.semFaster,
      'arc': t.accentArc,
      'warn': t.semWarn,
      'danger': t.semDanger,
      'noise': t.semNoise,
      'heart': t.hrZone,
    };
    for (final g in grounds.entries) {
      for (final c in text.entries) {
        expect(
          _ratio(c.value, g.value),
          greaterThanOrEqualTo(4.5),
          reason: '${c.key} on ${g.key}',
        );
      }
    }
  });

  test('run-type names are >= 3:1 on both surfaces', () {
    final types = {
      'free': t.typeFree,
      'laps': t.typeLaps,
      'goal': t.typeGoal,
      'intervals': t.typeIntervals,
      'tests': t.typeTests,
      'trail': t.typeTrail,
    };
    for (final g in grounds.entries) {
      for (final c in types.entries) {
        expect(
          _ratio(c.value, g.value),
          greaterThanOrEqualTo(3.0),
          reason: '${c.key} on ${g.key}',
        );
      }
    }
  });

  test(
    'score colours: text >= 4.5:1, big fills >= 3:1, hues stay distinct',
    () {
      for (final lane in engine.IdentityLane.values) {
        for (final g in grounds.entries) {
          expect(
            _ratio(t.laneText(lane), g.value),
            greaterThanOrEqualTo(4.5),
            reason: '${lane.name} text on ${g.key}',
          );
          expect(
            _ratio(t.laneFill(lane), g.value),
            greaterThanOrEqualTo(3.0),
            reason: '${lane.name} fill on ${g.key}',
          );
        }
      }
      expect(
        {for (final l in engine.IdentityLane.values) t.laneFill(l)}.length,
        engine.IdentityLane.values.length,
      );
      // Text keeps the fill's hue: it only gets darker.
      for (final l in engine.IdentityLane.values) {
        final f = HSLColor.fromColor(t.laneFill(l));
        final x = HSLColor.fromColor(t.laneText(l));
        expect((f.hue - x.hue).abs(), lessThan(3), reason: l.name);
        expect(x.lightness, lessThanOrEqualTo(f.lightness));
      }
    },
  );

  test('run-type text (history label, activity name) is >= 4.5:1', () {
    for (final c in [
      t.typeFree,
      t.typeLaps,
      t.typeGoal,
      t.typeIntervals,
      t.typeTests,
      t.typeTrail,
    ]) {
      for (final g in grounds.entries) {
        expect(_ratio(t.textOn(c), g.value), greaterThanOrEqualTo(4.5));
      }
    }
  });

  test('primary button: white on ink is >= 4.5:1', () {
    final scheme = runSoloTheme().colorScheme;
    expect(scheme.primary, t.inkPrimary);
    expect(_ratio(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(4.5));
  });

  test('zone fills are the brand ramp; zone text clears 3:1', () {
    expect(
      [for (var z = 1; z <= 5; z++) HrZones.distribution(z, Brightness.light)],
      const [
        Color(0xFF2F6DB5),
        Color(0xFF2E9E5B),
        Color(0xFFD9A21B),
        Color(0xFFE86A1C),
        Color(0xFFD6283B),
      ],
    );
    for (var z = 1; z <= HrZones.count; z++) {
      for (final g in grounds.entries) {
        expect(
          _ratio(HrZones.text(z, Brightness.light), g.value),
          greaterThanOrEqualTo(4.5),
          reason: 'Z$z on ${g.key}',
        );
      }
    }
  });

  test('the recording theme stays dark', () {
    final dark = runSoloTheme(brightness: Brightness.dark);
    expect(dark.scaffoldBackgroundColor, RunSoloTokens.dark.bgBase);
    expect(runSoloTheme().scaffoldBackgroundColor, t.bgBase);
  });
}
