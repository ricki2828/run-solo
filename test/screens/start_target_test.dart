import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// PD2 on Start (A10.10): the goal card's target line from the prepared
/// candidates; none without something to go on.
void main() {
  engine.LiveCandidate fiveK(String id, int seconds) {
    final e = engine.RunBestEfforts(
      efforts: {
        engine.BestEffortDistance.k5: engine.BestEffort(
          distance: engine.BestEffortDistance.k5,
          elapsedMs: seconds * 1000,
          startMs: 0,
          startOffsetM: 0,
          splitsMs: const [],
        ),
      },
      fromStartSplitsMs: const [],
    );
    return engine.LiveCandidate(
      engine.BoardInput(
        runId: id,
        date: DateTime(2026, 9, 12, 12).toUtc(),
        mode: engine.RunMode.free,
        efforts: e.efforts,
      ),
      engine.RunDerived(bestEfforts: e),
    );
  }

  Future<FakeRecorderGateway> open(WidgetTester tester, String goalId) async {
    final fake = FakeRecorderGateway(now: now);
    await pumpApp(
      tester,
      fakeServices(
        recorder: fake,
        live: LiveContextSource.prepared([fiveK('a', 1470)], now: now),
        settings: AppSettings(
          onboardingDone: true,
          goalRun: true,
          goalId: goalId,
        ),
      ),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 6);
    return fake;
  }

  testWidgets('a 5K goal shows its target under the card', (tester) async {
    await open(tester, 'd5000');
    final line = find.byKey(const ValueKey('start-target'));
    expect(line, findsOneWidget);
    final text = tester
        .widgetList<Text>(
          find.descendant(of: line, matching: find.byType(Text)),
        )
        .first
        .data!;
    expect(text, startsWith('Target '));
    expect(text, contains('24:30'));
  });

  testWidgets('a Half with no 10 km run in 6 weeks has no target line', (
    tester,
  ) async {
    await open(tester, 'd21098');
    expect(find.byKey(const ValueKey('start-target')), findsNothing);
  });

  testWidgets('switching goals re-reads the target', (tester) async {
    await open(tester, 'd21098');
    expect(find.byKey(const ValueKey('start-target')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('goal-d5000')));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('start-target')), findsOneWidget);
  });

  testWidgets('the target START hands the recorder is the one shown '
      '(#84 review P1)', (tester) async {
    debugLiveCompareAtStart = true;
    addTearDown(() => debugLiveCompareAtStart = false);
    final fake = await open(tester, 'd5000');
    expect(find.textContaining('24:30'), findsWidgets);
    fake.emitGpsProbe(GpsProbeEvent(fix: true, accuracyM: 5));
    await pumpTimes(tester, 2);
    await tester.tap(find.text('START GOAL'));
    await pumpTimes(tester, 6);
    final target = fake.startCalls.single.liveContext!.target!;
    expect(target.targetMs, 1470000);
    expect(target.predicted, isTrue);
  });
}
