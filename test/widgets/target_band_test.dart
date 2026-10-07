import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/voice_coach_plan.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/target_band.dart';

Widget host(CoachTarget target, double? pace) => MaterialApp(
  theme: runSoloTheme(brightness: Brightness.dark),
  home: Scaffold(
    body: SizedBox(
      width: 300,
      child: TargetBand(
        target: target,
        paceSecPerKm: pace,
        units: Units.km,
        labelColor: Colors.white70,
      ),
    ),
  ),
);

void main() {
  testWidgets('names the target; says "or slower" for a ceiling', (
    tester,
  ) async {
    await tester.pumpWidget(host(const CoachTarget(paceSecPerKm: 290), 292));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('target-label'))).data,
      'TARGET 4:50 /km',
    );
    await tester.pumpWidget(
      host(const CoachTarget(paceSecPerKm: 330, slowerIsFine: true), null),
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('target-label'))).data,
      'TARGET 5:30 /km OR SLOWER',
    );
  });

  testWidgets('the bar draws with and without a live pace', (tester) async {
    await tester.pumpWidget(host(const CoachTarget(paceSecPerKm: 290), null));
    expect(find.byKey(const ValueKey('target-band')), findsOneWidget);
    await tester.pumpWidget(host(const CoachTarget(paceSecPerKm: 290), 270));
    expect(find.byKey(const ValueKey('target-band')), findsOneWidget);
  });
}
