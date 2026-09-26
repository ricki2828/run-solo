import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/widgets/lap_button.dart';

import '../helpers.dart';

/// C1b (design addendum A5): the 12-minute test from Start to cool-down.
void main() {
  Future<(FakeRecorderGateway, AppServices)> recordTest(
    WidgetTester tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.cooper,
      engine.SessionSpec.cooper.toPigeon(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    return (fake, services);
  }

  testWidgets('Start: TESTS eyebrow, the chip opens the health note, and '
      'only its button starts the test', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    expect(find.text('TESTS'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('test-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-sheet')), findsOneWidget);
    expect(
      find.text(
        'Healthy and used to hard running? If unsure, check with a doctor.',
      ),
      findsOneWidget,
    );
    expect(find.text('Estimate. Not a medical measurement.'), findsOneWidget);
    expect(fake.startCalls, isEmpty, reason: 'the chip alone never starts');

    await tester.tap(find.byKey(const ValueKey('test-go')));
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 400));
    expect(fake.startCalls.single.mode, RecordMode.cooper);
    expect(
      fake.startCalls.single.spec!.templateId,
      engine.SessionSpec.cooperId,
    );
    expect(services.settings.settings.lastMode, RecordMode.cooper);
    expect(find.byType(RecordingScreen), findsOneWidget);
  });

  testWidgets('warm-up, START TEST, 12:00 with no LAP, then cool-down', (
    tester,
  ) async {
    final (fake, services) = await recordTest(tester);
    final ctl = services.recording;
    expect(find.text('WARM-UP'), findsOneWidget);
    expect(find.text('warm up, then tap START TEST'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-test')), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is LapButton && w.label == 'LAP'),
      findsNothing,
    );
    fake.advance(const Duration(minutes: 5));
    await pumpTimes(tester, 3);

    await tester.tap(find.byKey(const ValueKey('start-test')));
    await pumpTimes(tester, 4);
    expect(find.text('12-MINUTE TEST'), findsOneWidget);
    expect(find.text('left in the test'), findsOneWidget);
    expect(find.text('12:00'), findsOneWidget);
    expect(find.byType(LapButton), findsNothing, reason: 'no LAP for 12 min');
    expect(find.text('Pausing ends the test'), findsOneWidget);
    // A press from anywhere else is ignored too.
    await fake.lap(LapSource.notification);
    expect(fake.lapsIgnored, 1);

    fake.advance(const Duration(minutes: 6));
    await pumpTimes(tester, 3);
    expect(find.text('6:00'), findsOneWidget);
    final completes = ctl.repCompletePulse.value;
    fake.advance(const Duration(minutes: 6, seconds: 1));
    await pumpTimes(tester, 3);
    expect(find.text('COOL-DOWN'), findsOneWidget);
    expect(find.text('Cool down, then stop'), findsOneWidget);
    expect(ctl.repCompletePulse.value, completes + 1, reason: 'M3 at 0:00');
    expect(find.text('Pausing ends the test'), findsNothing);
  });

  testWidgets('no GPS in the warm-up: START TEST waits for a fix', (
    tester,
  ) async {
    final (fake, services) = await recordTest(tester);
    fake.gpsLost = true;
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    expect(find.byKey(const ValueKey('start-test')), findsNothing);
    expect(
      find.text('The test needs GPS. Wait for a fix to start it.'),
      findsOneWidget,
    );
    await services.recording.startReps();
    expect(services.recording.snapshot.phase, Phase.warmup);
  });

  testWidgets('pausing the test says there will be no estimate', (
    tester,
  ) async {
    final (fake, services) = await recordTest(tester);
    await tester.tap(find.byKey(const ValueKey('start-test')));
    await pumpTimes(tester, 4);
    await services.recording.pause();
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('paused-note')), findsOneWidget);
    expect(fake.lapsIgnored, 0);
  });
}
