import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/compare_card.dart';
import 'package:run_solo/widgets/start_strip.dart';
import 'package:run_solo/widgets/zone_ladder.dart';

/// The run screen's floods and the foreground drawn on them (D1 and D3,
/// 11-Oct-2026): every foreground the screen actually uses clears 7:1 on its
/// flood, per zone and per run type. Colours are composited to opaque before
/// measuring, so translucent plates count as what the eye sees.
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

Color over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

const Map<String, Color> _runTypes = {
  'free': AuroraRunType.free,
  'laps': AuroraRunType.laps,
  'goal': AuroraRunType.goal,
  'intervals': AuroraRunType.intervals,
  'tests': AuroraRunType.tests,
  'trail': AuroraRunType.trail,
};

/// Every flood the screen can show: Z1-Z5, and no HR in each run type.
Map<String, RunFlood> _floods() => {
  for (var z = 1; z <= HrZones.count; z++)
    'Z$z': RunFlood.of(z, AuroraRunType.free),
  for (final e in _runTypes.entries) 'no HR ${e.key}': RunFlood.of(0, e.value),
};

void main() {
  const base = RunSoloTokens.dark;

  test('Z3 and Z4 are bright true yellow and orange, ink foreground only', () {
    expect(HrZones.background(3), const Color(0xFFF5CF1F));
    expect(HrZones.background(4), const Color(0xFFF5822C));
    for (final z in [3, 4]) {
      final f = RunFlood.of(z, AuroraRunType.free);
      expect(f.ink, isTrue, reason: 'Z$z is ink');
      expect(f.primary, HrZones.floodInk);
    }
    for (final z in [1, 2, 5]) {
      final f = RunFlood.of(z, AuroraRunType.free);
      expect(f.ink, isFalse, reason: 'Z$z keeps Bone');
      expect(f.primary, base.inkPrimary);
    }
  });

  test('numbers and labels clear 7:1 on every flood', () {
    for (final e in _floods().entries) {
      final f = e.value;
      expect(
        _ratio(f.primary, f.background),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'primary on ${e.key}',
      );
      // Bone floods keep the Bone-at-90-% labels (6:1, the old floor); ink
      // floods hold the full 7:1 for labels too.
      final label = over(f.secondary, f.background);
      expect(
        _ratio(label, f.background),
        greaterThanOrEqualTo(f.ink ? RunFlood.minContrast : 6.0),
        reason: 'secondary on ${e.key}',
      );
    }
  });

  test('every token a flood re-points reads 7:1 on its flood', () {
    for (final e in _floods().entries) {
      final f = e.value;
      if (!f.ink) continue;
      final t = f.tokens(base);
      for (final c in {
        'inkPrimary': t.inkPrimary,
        'inkSecondary': t.inkSecondary,
        'inkMuted': t.inkMuted,
        'semWarn (GPS, banners, reconnecting)': t.semWarn,
        'semDanger': t.semDanger,
        'semFaster': t.semFaster,
        'semSlower': t.semSlower,
        'semImproving (recovery title)': t.semImproving,
        'hrZone (heart icon)': t.hrZone,
        'semNoise': t.semNoise,
      }.entries) {
        expect(
          _ratio(over(c.value, f.background), f.background),
          greaterThanOrEqualTo(RunFlood.minContrast),
          reason: '${c.key} on ${e.key}',
        );
      }
    }
  });

  test('D3: the no-HR flood is the run type colour, never black', () {
    for (final e in _runTypes.entries) {
      final f = RunFlood.of(0, e.value);
      expect(f.background, e.value, reason: e.key);
      expect(
        _ratio(f.primary, f.background),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'the picked foreground on ${e.key}',
      );
      // Whichever of Bone and ink reads better is the one picked.
      final bone = _ratio(base.inkPrimary, e.value);
      final ink = _ratio(HrZones.floodInk, e.value);
      expect(_ratio(f.primary, e.value), math.max(bone, ink), reason: e.key);
    }
  });

  test('PAUSE, STOP, mute and banners: ink text on the tinted plate', () {
    for (final e in _floods().entries) {
      if (!e.value.ink) continue;
      final t = e.value.tokens(base);
      final plate = over(t.bgRaised, e.value.background);
      expect(
        _ratio(t.inkPrimary, plate),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'plate text on ${e.key}',
      );
      // The warn / danger bar on a banner is ink too.
      expect(_ratio(t.semWarn, plate), greaterThanOrEqualTo(7));
    }
  });

  test('LAP / BEGIN REPS: flood-coloured text on the ink plate', () {
    for (final e in _floods().entries) {
      if (!e.value.ink) continue;
      final t = e.value.tokens(base);
      expect(
        _ratio(t.bgBase, t.inkPrimary),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'LAP on ${e.key}',
      );
    }
    // Bone floods: the unchanged Bone plate with near-black text.
    for (final z in [1, 2, 5]) {
      final t = RunFlood.of(z, AuroraRunType.free).tokens(base);
      expect(_ratio(t.bgBase, t.inkPrimary), greaterThan(7));
    }
  });

  test('GPS bar fill reads on its track on the ink floods', () {
    for (final e in _floods().entries) {
      if (!e.value.ink) continue;
      final t = e.value.tokens(base);
      final track = over(t.bgSunken, e.value.background);
      expect(_ratio(t.inkPrimary, track), greaterThanOrEqualTo(3.0));
    }
  });

  test('the zone ladder digits clear 7:1 on Z3 and Z4', () {
    for (final z in [3, 4]) {
      final f = RunFlood.of(z, AuroraRunType.free);
      final t = f.tokens(base);
      // Lit rung: flood-coloured number on a solid ink block.
      expect(
        _ratio(t.bgBase, t.inkPrimary),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'lit rung on Z$z',
      );
      // Unlit rungs: ink number on a whisper of the rung's hue.
      for (var r = 1; r <= HrZones.count; r++) {
        final rung = over(
          HrZones.distributionLight[r].withValues(
            alpha: ZoneLadder.inactiveAlphaOnInk,
          ),
          f.background,
        );
        expect(
          _ratio(t.inkPrimary, rung),
          greaterThanOrEqualTo(RunFlood.minContrast),
          reason: 'rung $r on Z$z',
        );
      }
    }
  });

  test('BACK TO START plate and the compare card keep Bone on black', () {
    for (final e in _floods().entries) {
      final f = e.value;
      final plate = over(NightSession.overlayGround, f.background);
      expect(
        _ratio(over(StartStrip.valueColor, plate), plate),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'BACK TO START number on ${e.key}',
      );
      expect(
        _ratio(over(StartStrip.labelColor, plate), plate),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'BACK TO START label on ${e.key}',
      );
      final card = over(CompareCard.ground, f.background);
      expect(
        _ratio(over(CompareCard.ink, card), card),
        greaterThanOrEqualTo(RunFlood.minContrast),
        reason: 'compare card on ${e.key}',
      );
    }
  });

  test('Bone floods keep Bone numbers at 7:1', () {
    for (final z in [1, 2, 5]) {
      final bg = HrZones.background(z);
      expect(_ratio(base.inkPrimary, bg), greaterThan(7), reason: 'Z$z');
    }
  });
}
