import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/widgets/home_scores.dart';

import '../helpers.dart';

Map<engine.IdentityLane, engine.IdentityScore> earnedScores() => {
  for (final lane in engine.IdentityLane.values)
    lane: engine.IdentityScore(
      lane: lane,
      score: 62,
      vdot: 38,
      runId: lane.name,
      date: testNow,
      source: lane == engine.IdentityLane.mid ? '5K' : '4x4',
      boardKey: null,
    ),
};

void main() {
  testWidgets('earned cards route to Progress, with honest different cohorts', (
    tester,
  ) async {
    var opened = false;
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: HomeScores(
          scores: earnedScores(),
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () => opened = true,
        ),
      ),
    );
    expect(find.text('LOCKED'), findsNothing);
    expect(find.text('men 40 to 49'), findsNWidgets(2));
    expect(find.text('men race finishers · all ages'), findsNWidgets(2));
    expect(find.text('percentile'), findsNWidgets(4));
    await tester.tap(find.byKey(const ValueKey('home-score-aerobic')));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('indexed comparable run uses actual work pace, no analysis', (
    tester,
  ) async {
    final r = RunSummary(
      id: 'indexed',
      mode: RecordMode.intervals,
      start: testNow,
      durationMs: 2400000,
      distanceM: 6000,
      laps: 4,
      row: const IndexRow(
        lapCount: 4,
        eligibleAsPrior: true,
        workPaceSecPerKm: 262,
      ),
    );
    expect(r.analysis, isNull);
    await pumpApp(
      tester,
      fakeServices(runs: [r]),
      home: HomeScreen(now: now),
    );
    expect(find.text('BEAT 4:22'), findsOneWidget);
    expect(find.textContaining('work pace, Thu 24 Sep'), findsOneWidget);
  });

  testWidgets('ineligible interval run cannot set a pace target', (
    tester,
  ) async {
    final r = RunSummary(
      id: 'noise',
      mode: RecordMode.intervals,
      start: testNow,
      durationMs: 2400000,
      distanceM: 6000,
      laps: 4,
      row: const IndexRow(
        lapCount: 4,
        eligibleAsPrior: false,
        workPaceSecPerKm: 262,
      ),
    );
    await pumpApp(
      tester,
      fakeServices(runs: [r]),
      home: HomeScreen(now: now),
    );
    expect(find.text('GO AGAIN.'), findsOneWidget);
    expect(find.text('BEAT 4:22'), findsNothing);
  });

  testWidgets(
    'missing profile never substitutes the display score as percentile',
    (tester) async {
      await pumpApp(
        tester,
        fakeServices(),
        home: Scaffold(
          body: HomeScores(
            scores: earnedScores(),
            profileSex: ProfileSex.notSet,
            age: null,
            onOpen: () {},
          ),
        ),
      );
      expect(find.text('--'), findsNWidgets(4));
      expect(find.text('62'), findsNothing);
    },
  );
}
