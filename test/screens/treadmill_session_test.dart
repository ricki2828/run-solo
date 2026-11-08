import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/recording_screen.dart' show eventFinishText;
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

  testWidgets('distance reps offer the treadmill, the event does not', (
    tester,
  ) async {
    await openReady(tester, mode: RecordMode.intervals, sessionId: '400s');
    expect(find.byKey(SurfaceChoiceRow.treadmillKey), findsOneWidget);
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

  group('distance reps on a belt', () {
    Future<(FakeRecorderGateway, AppServices)> inRep(
      WidgetTester tester,
    ) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(
        RecordMode.intervals,
        engine.SessionCatalogue.fourHundreds.defaults.toPigeon(),
        Units.km,
        treadmillInclinePct: 1,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('start-reps')));
      await pumpTimes(tester, 4);
      return (fake, services);
    }

    testWidgets('REP DONE takes a double-tap, shows the rep time up', (
      tester,
    ) async {
      final (fake, services) = await inRep(tester);
      fake.advance(const Duration(seconds: 50));
      await pumpTimes(tester, 4);
      expect(find.byKey(const ValueKey('rep-done-block')), findsOneWidget);
      expect(find.byKey(const ValueKey('treadmill-strip')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('rep-done-prompt'))).data,
        contains('rep: tap when the treadmill shows it'),
      );
      final size = tester.getSize(find.byKey(const ValueKey('rep-done')));
      expect(size.height, greaterThanOrEqualTo(72));
      // The clock counts the rep up, not metres down.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('timer'))).data,
        matches(RegExp(r'^\d+:\d\d$')),
      );
      // One tap does nothing.
      await tester.tap(find.byKey(const ValueKey('rep-done')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(services.recording.snapshot.phase, Phase.work);
      // A double-tap ends the rep; recovery starts.
      await tester.tap(find.byKey(const ValueKey('rep-done')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('rep-done')));
      await pumpTimes(tester, 4);
      await services.recording.refreshStatus();
      await pumpTimes(tester, 2);
      expect(services.recording.snapshot.phase, Phase.recovery);
      expect(services.recording.snapshot.beltReps.single.distanceM, 400);
      expect(find.byKey(const ValueKey('last-belt-rep-speed')), findsOne);
      expect(find.byKey(const ValueKey('undo-rep-done')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await fake.discard();
    });

    testWidgets('UNDO REP DONE puts the rep back, its clock unbroken', (
      tester,
    ) async {
      final (fake, services) = await inRep(tester);
      fake.advance(const Duration(seconds: 30));
      await pumpTimes(tester, 3);
      await services.recording.repDone();
      await services.recording.refreshStatus();
      await pumpTimes(tester, 3);
      expect(services.recording.snapshot.phase, Phase.recovery);
      await tester.tap(find.byKey(const ValueKey('undo-rep-done')));
      await pumpTimes(tester, 4);
      expect(fake.undoRepDoneCalls, 1);
      expect(services.recording.snapshot.phase, Phase.work);
      expect(services.recording.snapshot.repIndex, 1);
      expect(services.recording.snapshot.beltReps, isEmpty);
      expect(find.byKey(const ValueKey('undo-rep-done')), findsNothing);
      expect(find.byKey(const ValueKey('rep-done')), findsOneWidget);
    });

    testWidgets('UNDO goes away after its window', (tester) async {
      final (fake, services) = await inRep(tester);
      fake.advance(const Duration(seconds: 30));
      await services.recording.repDone();
      await services.recording.refreshStatus();
      expect(services.recording.repUndoAvailable, isTrue);
      fake.advance(const Duration(seconds: 20));
      await pumpTimes(tester, 3);
      expect(services.recording.repUndoAvailable, isFalse);
    });

    testWidgets('a time rep has no REP DONE', (tester) async {
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
      expect(services.recording.canRepDone, isFalse);
      expect(find.byKey(const ValueKey('rep-done')), findsNothing);
    });
  });

  group('live projection on a belt', () {
    Future<(FakeRecorderGateway, AppServices)> inTest(
      WidgetTester tester,
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
      fake.advance(const Duration(minutes: 4));
      await pumpTimes(tester, 3);
      // Warm-up: no strip, a reminder to reset the treadmill.
      expect(find.byKey(const ValueKey('treadmill-test-reset')), findsOne);
      expect(find.byKey(const ValueKey('treadmill-strip')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('start-test')));
      await pumpTimes(tester, 4);
      return (fake, services);
    }

    testWidgets('nothing before the first mark, then the outdoor '
        'projection on every mark and UNDO', (tester) async {
      final (fake, services) = await inTest(tester);
      expect(find.byKey(const ValueKey('treadmill-strip')), findsOneWidget);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      expect(find.byKey(const ValueKey('belt-cooper-estimate')), findsNothing);
      await fake.addTreadmillMark(750);
      await services.recording.refreshStatus();
      await pumpTimes(tester, 3);
      final e1 = services.recording.snapshot.beltCooperEstimate;
      expect(e1, isNotNull);
      expect(
        e1!.distanceM,
        closeTo(
          engine.CooperProjection.project(
            engine.CooperCurve.defaultCurve,
            elapsedSeconds: 180,
            distanceM: 750,
          )!.distanceM,
          1,
        ),
      );
      expect(find.byKey(const ValueKey('belt-cooper-distance')), findsOne);
      expect(find.byKey(const ValueKey('belt-cooper-vo2')), findsOne);
      fake.advance(const Duration(minutes: 2));
      await fake.addTreadmillMark(1250);
      await services.recording.refreshStatus();
      final e2 = services.recording.snapshot.beltCooperEstimate!;
      expect(e2.distanceM, isNot(closeTo(e1.distanceM, 1)));
      // UNDO goes back to the first mark's projection.
      await tester.tap(find.byKey(const ValueKey('treadmill-undo')));
      await pumpTimes(tester, 4);
      expect(
        services.recording.snapshot.beltCooperEstimate!.distanceM,
        closeTo(e1.distanceM, 1),
      );
      await fake.discard();
    });
  });

  group('goal runs on a belt', () {
    Future<FakeRecorderGateway> goalReady(
      WidgetTester tester, {
      String goalId = 'd5000',
    }) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.intervals,
          goalRun: true,
          goalId: goalId,
          countdownSeconds: 0,
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

    testWidgets('a distance goal offers the belt and starts with no GPS', (
      tester,
    ) async {
      final fake = await goalReady(tester);
      await tester.tap(find.byKey(SurfaceChoiceRow.treadmillKey));
      await pumpTimes(tester, 3);
      // A goal outdoors waits for a good fix; on a belt START is open.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('ready-start')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('ready-start')));
      await tester.pump(const Duration(milliseconds: 500));
      await pumpTimes(tester, 8);
      final call = fake.startCalls.single;
      expect(call.mode, RecordMode.intervals);
      expect(call.spec!.templateId, engine.SessionSpec.goalId);
      expect(call.treadmillInclinePct, 1.0);
      expect(call.liveContext, isNull);
      await fake.discard();
    });

    testWidgets('a time goal and the event stay outdoors', (tester) async {
      await goalReady(tester, goalId: 't1800');
      expect(find.byKey(SurfaceChoiceRow.treadmillKey), findsNothing);
      await goalReady(tester, goalId: 'parkrun');
      expect(find.byKey(SurfaceChoiceRow.treadmillKey), findsNothing);
    });

    testWidgets('the finish estimate follows the markers, UNDO included', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(
        RecordMode.intervals,
        engine.SessionSpec.goalDistance(5000, '5K').toPigeon(),
        Units.km,
        treadmillInclinePct: 1,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      // No marker yet: nothing projected, the whole goal to go.
      fake.advance(const Duration(seconds: 60));
      await pumpTimes(tester, 3);
      expect(find.text('--'), findsWidgets);
      expect(services.recording.snapshot.metresToGo, 5000);
      // 500 m at 2:30: 25:00 for 5K, 4.50 km to go.
      fake.advance(const Duration(seconds: 90));
      await fake.addTreadmillMark(500);
      await services.recording.refreshStatus();
      await pumpTimes(tester, 3);
      expect(services.recording.snapshot.metresToGo, 4500);
      expect(
        eventFinishText(
          services.recording.snapshot,
          services.recording,
          Units.km,
        ),
        '25:00',
      );
      // 1 km at 4:50: 24:10.
      fake.advance(const Duration(seconds: 140));
      await fake.addTreadmillMark(1000);
      await services.recording.refreshStatus();
      await pumpTimes(tester, 3);
      expect(
        eventFinishText(
          services.recording.snapshot,
          services.recording,
          Units.km,
        ),
        '24:10',
      );
      // Between markers it does not move.
      fake.advance(const Duration(seconds: 30));
      await pumpTimes(tester, 3);
      expect(
        eventFinishText(
          services.recording.snapshot,
          services.recording,
          Units.km,
        ),
        '24:10',
      );
      // UNDO goes back to the first marker's estimate.
      await tester.tap(find.byKey(const ValueKey('treadmill-undo')));
      await pumpTimes(tester, 4);
      expect(
        eventFinishText(
          services.recording.snapshot,
          services.recording,
          Units.km,
        ),
        '25:00',
      );
      expect(find.byKey(const ValueKey('event-to-go')), findsOneWidget);
      await fake.discard();
    });

    testWidgets('GOAL DONE ends the goal and UNDO takes it back', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(
        RecordMode.intervals,
        engine.SessionSpec.goalDistance(5000, '5K').toPigeon(),
        Units.km,
        treadmillInclinePct: 1,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      fake.advance(const Duration(minutes: 25));
      await pumpTimes(tester, 3);
      final target = find.byKey(const ValueKey('goal-done-target'));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(72));
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 600));
      expect(services.recording.snapshot.phase, Phase.work, reason: 'one tap');
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await pumpTimes(tester, 4);
      await services.recording.refreshStatus();
      await pumpTimes(tester, 3);
      expect(services.recording.snapshot.phase, Phase.cooldown);
      expect(find.byKey(const ValueKey('goal-done')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('undo-rep-done')));
      await pumpTimes(tester, 4);
      expect(services.recording.snapshot.phase, Phase.work);
      await tester.pump(const Duration(seconds: 1));
      await fake.discard();
    });
  });
}
