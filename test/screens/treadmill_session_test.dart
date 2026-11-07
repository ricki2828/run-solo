import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/gps_bar.dart';
import 'package:run_solo/widgets/surface_choice_row.dart';

import '../helpers.dart';

/// 7-Nov: intervals and the 12-minute test on a treadmill (PR A: time reps).
void main() {
  Future<FakeRecorderGateway> openReady(
    WidgetTester tester, {
    required RecordMode mode,
    String sessionId = engine.SessionSpec.norwegian4x4Id,
    int incline = 1,
  }) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: AppSettings(
        onboardingDone: true,
        lastMode: mode,
        sessionId: sessionId,
        countdownSeconds: 0,
        treadmillIncline: incline,
      ),
    );
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    return fake;
  }

  testWidgets('Ready for the test offers the surface, outdoors by default', (
    tester,
  ) async {
    final fake = await openReady(tester, mode: RecordMode.cooper);
    expect(find.byKey(SurfaceChoiceRow.treadmillKey), findsOneWidget);
    expect(find.byKey(SurfaceChoiceRow.inclineKey(1)), findsNothing);
    expect(find.byKey(const ValueKey('ready-gps')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpTimes(tester, 8);
    expect(fake.startCalls.single.mode, RecordMode.cooper);
    expect(fake.startCalls.single.treadmillInclinePct, isNull);
    await fake.discard();
  });

  testWidgets('On a treadmill: no GPS chip, incline chips, 1% remembered', (
    tester,
  ) async {
    final fake = await openReady(tester, mode: RecordMode.cooper);
    await tester.tap(find.byKey(SurfaceChoiceRow.treadmillKey));
    await pumpTimes(tester, 3);
    expect(find.byKey(const ValueKey('ready-gps')), findsNothing);
    expect(find.byKey(const ValueKey('ready-gps-warning')), findsNothing);
    for (final pct in AppSettings.treadmillInclineChoices) {
      expect(find.byKey(SurfaceChoiceRow.inclineKey(pct)), findsOneWidget);
    }
    expect(find.byKey(SurfaceChoiceRow.hintKey), findsNothing);
    await tester.tap(find.byKey(SurfaceChoiceRow.inclineKey(2)));
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpTimes(tester, 8);
    final call = fake.startCalls.single;
    expect(call.mode, RecordMode.cooper);
    expect(call.spec!.templateId, engine.SessionSpec.cooperId);
    expect(call.treadmillInclinePct, 2.0);
    expect(call.liveContext, isNull, reason: 'no GPS compare on a belt');
    expect((await fake.status()).treadmillInclinePct, 2.0);
    expect(fake.gpsProbeRunning, isFalse);
    await fake.discard();
  });

  testWidgets('0% shows the one-line hint', (tester) async {
    await openReady(tester, mode: RecordMode.cooper, incline: 0);
    await tester.tap(find.byKey(SurfaceChoiceRow.treadmillKey));
    await pumpTimes(tester, 3);
    expect(find.text('Set 1% to match outdoor effort.'), findsOneWidget);
    await tester.tap(find.byKey(SurfaceChoiceRow.inclineKey(1)));
    await pumpTimes(tester, 3);
    expect(find.byKey(SurfaceChoiceRow.hintKey), findsNothing);
  });

  testWidgets('time-rep intervals can go on a treadmill', (tester) async {
    final fake = await openReady(tester, mode: RecordMode.intervals);
    await tester.tap(find.byKey(SurfaceChoiceRow.treadmillKey));
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpTimes(tester, 8);
    expect(fake.startCalls.single.mode, RecordMode.intervals);
    expect(fake.startCalls.single.treadmillInclinePct, 1.0);
    await fake.discard();
  });

  testWidgets('distance reps do not offer the treadmill yet', (tester) async {
    await openReady(tester, mode: RecordMode.intervals, sessionId: '400s');
    expect(find.byKey(SurfaceChoiceRow.treadmillKey), findsNothing);
  });

  testWidgets('the run screen of a rep session on a belt: strip, no GPS', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(onboardingDone: true),
    );
    await services.recording.start(
      RecordMode.intervals,
      engine.SessionSpec.norwegian4x4().toPigeon(),
      Units.km,
      treadmillInclinePct: 1,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('start-reps')));
    await pumpTimes(tester, 4);
    fake.advance(const Duration(minutes: 1, seconds: 10));
    await pumpTimes(tester, 4);
    expect(services.recording.snapshot.indoor, isTrue);
    expect(services.recording.snapshot.gpsLost, isFalse);
    expect(find.byType(GpsBar), findsNothing);
    expect(find.byKey(const ValueKey('treadmill-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('treadmill-hint')), findsOneWidget);
    // A mark gives the speeds and UNDO.
    await fake.addTreadmillMark(500);
    await services.recording.refreshStatus();
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('treadmill-current-speed')), findsOne);
    expect(find.byKey(const ValueKey('treadmill-undo')), findsOne);
    await fake.discard();
  });

  testWidgets('the test on a belt asks for its distance and keeps the tag', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(onboardingDone: true),
    );
    await services.recording.start(
      RecordMode.cooper,
      engine.SessionSpec.cooper.toPigeon(),
      Units.km,
      treadmillInclinePct: 1,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    fake.advance(const Duration(minutes: 3));
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('start-test')));
    await pumpTimes(tester, 4);
    fake.advance(const Duration(minutes: 12, seconds: 5));
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('stop')));
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('finish-save')));
    await pumpTimes(tester, 4);
    expect(find.text('Test distance'), findsOneWidget);
    // The test needs a distance: no SKIP.
    expect(find.byKey(const ValueKey('treadmill-distance-skip')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('treadmill-distance')),
      '2.8',
    );
    await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
    await pumpTimes(tester, 6);
    expect(fake.finalised.single.mode, RecordMode.cooper);
    expect(fake.finalised.single.distanceM, 2800);
  });
}
