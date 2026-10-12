import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/lanes.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/mode_chip.dart';

double _rgbDistance(Color a, Color b) {
  final dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  test('weekly story fill is 60+ RGB from every lane and semantic colour', () {
    final lanes = [
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
        t.semNoise,
        t.hrZone,
        t.accentArc,
      ],
      ...HrZones.backgrounds,
      ...HrZones.distributionDark,
      ...HrZones.distributionLight,
    ];
    for (final c in lanes) {
      expect(
        _rgbDistance(AuroraStory.fill, c),
        greaterThanOrEqualTo(60),
        reason: 'too close to $c',
      );
    }
    expect(contrastRatio(Colors.white, AuroraStory.fill), greaterThan(4.5));
  });

  test('Aurora identities retain a label and never replace the HR zones', () {
    expect(AuroraRunType.laps, NightSession.accentArc);
    expect(AuroraRunType.intervals, isNot(HrZones.background(3)));
    expect(HrZones.background(3), const Color(0xFFF5CF1F));
    expect(HrZones.label(3, paired: true), contains('TEMPO'));
  });

  testWidgets('selected type has a neutral border and visible check', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Scaffold(
          body: ModeChip(
            title: 'INTERVALS',
            subtitle: 'Structured reps',
            selected: true,
            typeColor: AuroraRunType.intervals,
            onTap: () {},
          ),
        ),
      ),
    );
    final title = tester.widget<Text>(find.text('INTERVALS'));
    expect(title.style!.color, AuroraRunType.intervals);
    expect(find.byIcon(Icons.check), findsOneWidget);
    final box = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ModeChip),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = box.decoration! as BoxDecoration;
    expect(
      (decoration.border! as Border).top.color,
      NightSessionLight.inkPrimary,
    );
  });
}
