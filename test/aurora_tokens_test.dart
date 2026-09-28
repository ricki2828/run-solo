import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/mode_chip.dart';

void main() {
  test('Aurora identities retain a label and never replace the HR zones', () {
    expect(AuroraRunType.laps, NightSession.accentArc);
    expect(AuroraRunType.intervals, isNot(HrZones.background(3)));
    expect(HrZones.background(3), const Color(0xFF403208));
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
    expect((decoration.border! as Border).top.color, NightSession.inkPrimary);
  });
}
