import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/live_context.dart';

import '../helpers.dart';
import 'screens_golden_test.dart' show golden;

/// 27-Oct: an 8 km goal run names what it is aiming for, in one fixed row
/// ("TARGET 41:17 · ON PACE FOR 49:20"), from the first km to the last 400 m,
/// and the cool-down card keeps the target beside the result. The run is
/// held at 6:10/km against a target from a 24:58 5K, as in his run, so the
/// two figures are far apart. PNGs come from the CI goldens artifact.
void main() {
  LiveContextSource history() {
    final efforts = engine.RunBestEfforts(
      efforts: {
        engine.BestEffortDistance.k5: engine.BestEffort(
          distance: engine.BestEffortDistance.k5,
          elapsedMs: 1498000,
          startMs: 0,
          startOffsetM: 0,
          splitsMs: const [],
        ),
      },
      fromStartSplitsMs: const [],
    );
    return LiveContextSource.prepared([
      engine.LiveCandidate(
        engine.BoardInput(
          runId: 'a',
          date: DateTime(2026, 9, 12, 12).toUtc(),
          mode: engine.RunMode.free,
          efforts: efforts.efforts,
        ),
        engine.RunDerived(bestEfforts: efforts),
      ),
    ], now: now);
  }

  /// Start's number as the controller keeps it with the run (the screen's
  /// ease-off check reads it).
  final started = LiveContext(
    boards: const [],
    coachingMuted: false,
    builtAtMs: 0,
    engineVersion: 1,
    target: LiveTarget(
      distanceM: 8000,
      targetMs: 2477000,
      predicted: true,
      source: '5K on 12 Sep',
    ),
  );

  Future<FakeRecorderGateway> open(
    WidgetTester tester,
    int h, {
    LiveContext? context,
  }) async {
    final fake = FakeRecorderGateway(now: now)
      ..liveSecPerKm = 370
      ..scriptedHr = 150;
    final services = fakeServices(recorder: fake, live: history());
    await services.recording.start(
      RecordMode.intervals,
      engine.SessionSpec.goalDistance(8000, '8 km').toPigeon(),
      Units.km,
      liveContext: context,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    tester.view.physicalSize = Size(1080, h * 3.0);
    await pumpTimes(tester, 4);
    return fake;
  }

  Future<void> at(WidgetTester tester, FakeRecorderGateway fake, int s) async {
    for (var i = 0; i < s; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    await pumpTimes(tester, 6);
    // Past the moment banner's hold, so no scrim sits over the figures.
    await tester.pump(const Duration(seconds: 8));
    await pumpTimes(tester, 4);
    await settleAnimations(tester);
  }

  for (final h in [800, 640]) {
    testWidgets('goal target row: 1 km, 400 m to go, cool-down at 360 x $h', (
      tester,
    ) async {
      final fake = await open(tester, h);
      await at(tester, fake, 375);
      expect(find.byKey(const ValueKey('goal-target-row')), findsOneWidget);
      expect(find.text('TARGET'), findsOneWidget);
      expect(find.text('ON PACE FOR'), findsOneWidget);
      Text figure(String key) => tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(figure('goal-target').data, '41:17');
      Offset where(String key) => tester.getTopLeft(find.byKey(ValueKey(key)));
      final early = {
        for (final k in ['event-to-go', 'goal-target', 'event-finish'])
          k: where(k),
      };
      await golden(tester, 'record_goal_target_1km_360x$h');

      // 400 m to go: 7600 m at 6:10/km is 2812 s.
      await at(tester, fake, 2812 - 375);
      for (final e in early.entries) {
        expect(where(e.key), e.value, reason: '${e.key} moved in the finish');
      }
      await golden(tester, 'record_goal_target_last400_360x$h');

      // Past the line: the cool-down keeps the target beside the result.
      await at(tester, fake, 200);
      expect(find.byKey(const ValueKey('goal-target-result')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('goal-target-result')))
            .data,
        'TARGET 41:17 · 8:03 OVER',
      );
      await golden(tester, 'record_goal_target_cooldown_360x$h');
    });
  }

  testWidgets('after an ease off the screen names no target and no gap', (
    tester,
  ) async {
    final fake = await open(tester, 800, context: started);
    await at(tester, fake, 375);
    expect(find.byKey(const ValueKey('goal-target-row')), findsOneWidget);

    fake.emitPromptResolved(
      PromptResolvedEvent(id: 1, choice: 'ease', source: 'tap', eased: true),
    );
    await at(tester, fake, 5);
    expect(find.byKey(const ValueKey('goal-target-row')), findsNothing);
    expect(find.text('TARGET'), findsNothing);
    // The run's own projected finish stays.
    expect(find.byKey(const ValueKey('event-finish')), findsOneWidget);
    await golden(tester, 'record_goal_eased_1km_360x800');

    // Past the line: the result, with no target line or gap under it.
    await at(tester, fake, 2812 - 380 + 200);
    expect(find.byKey(const ValueKey('goal-target-result')), findsNothing);
    expect(find.byKey(const ValueKey('goal-result')), findsOneWidget);
    await golden(tester, 'record_goal_eased_cooldown_360x800');
  });
}
