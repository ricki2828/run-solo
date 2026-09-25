import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/value_stepper.dart';

import '../helpers.dart';

Finder stepperButton(String label, IconData icon) => find.descendant(
  of: find.widgetWithText(ValueStepper, label.toUpperCase()),
  matching: find.byIcon(icon),
);

void main() {
  testWidgets('preset editor: reps 3–6, work locked, recovery 15 s steps', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);

    expect(find.text('Fixed at 4:00 in this version.'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    await tester.tap(stepperButton('Reps', Icons.add));
    await pumpTimes(tester);
    await tester.tap(stepperButton('Reps', Icons.add));
    await pumpTimes(tester);
    expect(find.text('6'), findsOneWidget);
    await tester.tap(stepperButton('Reps', Icons.add));
    await pumpTimes(tester);
    expect(find.text('6'), findsOneWidget, reason: 'clamped at 6');
    expect(services.settings.settings.reps, PresetRules.maxReps);

    await tester.tap(stepperButton('Recovery', Icons.remove));
    await pumpTimes(tester);
    expect(find.text('2:45'), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      await tester.tap(stepperButton('Recovery', Icons.remove));
      await pumpTimes(tester);
    }
    expect(find.text('2:00'), findsOneWidget, reason: 'floor 2:00');
    expect(services.settings.settings.recoverySeconds, 120);
  });

  testWidgets('START 4x4 hands the preset to the recorder', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        reps: 5,
        recoverySeconds: 150,
        cues: false,
      ),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);

    await tester.tap(find.text('START 4x4'));
    await pumpTimes(tester, 6);

    final status = await fake.status();
    expect(status.state, RecorderState.recording);
    expect(status.preset?.reps, 5);
    expect(status.preset?.recoverySeconds, 150);
    expect(status.preset?.workSeconds, 240);
    expect(fake.cuesEnabled, isFalse);
    expect(find.byType(RecordingScreen), findsOneWidget);
  });

  testWidgets('free run mode starts without a preset', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    expect(find.byType(ValueStepper), findsNothing);
    await tester.tap(find.text('START FREE RUN'));
    await pumpTimes(tester, 6);
    expect((await fake.status()).preset, isNull);
    expect(find.text('FREE RUN'), findsOneWidget);
  });

  testWidgets('approximateOnly start error routes to the checklist', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(
      now: now,
      startError: StartError.approximateOnly,
    );
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await tester.tap(find.text('START 4x4'));
    await pumpTimes(tester, 6);
    expect(find.byType(PermissionsScreen), findsOneWidget);
    expect(find.byType(RecordingScreen), findsNothing);
  });

  testWidgets('lowStorage start error is shown inline', (tester) async {
    final fake = FakeRecorderGateway(
      now: now,
      startError: StartError.lowStorage,
    );
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await tester.tap(find.text('START 4x4'));
    await pumpTimes(tester, 6);
    expect(find.textContaining('Not enough storage'), findsOneWidget);
  });
}
