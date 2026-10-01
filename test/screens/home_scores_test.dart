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
  homeCoherenceTests();
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
    expect(find.text('Men 40 to 49, lab norms'), findsNWidgets(2));
    expect(
      find.text('Men, recreational race finishers, all ages'),
      findsNWidgets(2),
    );
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
    expect(find.text('SET YOUR LINE'), findsOneWidget);
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
      expect(find.text('Add your sex to compare'), findsNWidgets(4));
      expect(find.text('62'), findsNothing);
    },
  );
}

RunSummary _run(
  String id,
  RecordMode mode,
  int daysAgo, {
  double distanceM = 5000,
  int durationMs = 1500000,
  int laps = 5,
  IndexRow? row,
  engine.SessionSpec? spec,
}) => RunSummary(
  id: id,
  mode: mode,
  start: testNow.subtract(Duration(days: daysAgo)),
  durationMs: durationMs,
  distanceM: distanceM,
  laps: laps,
  row: row ?? IndexRow(lapCount: laps),
  spec: spec,
);

void homeCoherenceTests() {
  Future<void> pump(
    WidgetTester tester, {
    List<RunSummary> runs = const [],
    AppSettings settings = const AppSettings(onboardingDone: true),
    ({String name, String subtitle})? plan,
  }) async {
    await pumpApp(
      tester,
      fakeServices(runs: runs, settings: settings),
      home: HomeScreen(now: now, planHeadline: plan),
    );
  }

  testWidgets('plan active: headline and Start use the plan session', (
    tester,
  ) async {
    await pump(
      tester,
      plan: (name: 'Tempo', subtitle: 'Week 3, session 2 of 3.'),
      runs: [
        _run(
          'x',
          RecordMode.intervals,
          1,
          row: const IndexRow(
            lapCount: 4,
            eligibleAsPrior: true,
            workPaceSecPerKm: 262,
          ),
        ),
      ],
    );
    expect(find.text('TEMPO TODAY'), findsOneWidget);
    expect(find.text('Start Tempo'), findsOneWidget);
    expect(find.textContaining('BEAT'), findsNothing);
  });

  testWidgets('last 4x4: BEAT work pace, line and Start share the name', (
    tester,
  ) async {
    await pump(
      tester,
      runs: [
        _run(
          'new',
          RecordMode.intervals,
          1,
          row: const IndexRow(
            lapCount: 4,
            eligibleAsPrior: true,
            workPaceSecPerKm: 262,
          ),
        ),
        _run(
          'old',
          RecordMode.intervals,
          8,
          row: const IndexRow(
            lapCount: 4,
            eligibleAsPrior: true,
            workPaceSecPerKm: 268,
          ),
        ),
      ],
    );
    expect(find.text('BEAT 4:22'), findsOneWidget);
    expect(
      find.textContaining('Your last Norwegian 4x4 work pace'),
      findsOneWidget,
    );
    expect(
      find.textContaining('6 s faster than the run before'),
      findsOneWidget,
    );
    expect(find.text('Start Norwegian 4x4'), findsOneWidget);
    expect(find.text('LAST RESULT'), findsNothing);
  });

  testWidgets('last free: BEAT average pace of the last free run', (
    tester,
  ) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
      runs: [
        _run('free', RecordMode.free, 2),
        _run(
          'int',
          RecordMode.intervals,
          1,
          row: const IndexRow(
            lapCount: 4,
            eligibleAsPrior: true,
            workPaceSecPerKm: 262,
          ),
        ),
      ],
    );
    expect(find.text('BEAT 5:00'), findsOneWidget);
    expect(find.textContaining('Your last free run, 5.00 km'), findsOneWidget);
    expect(find.text('Start free run'), findsOneWidget);
  });

  testWidgets('last laps without a median lap: shows last distance', (
    tester,
  ) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.laps,
      ),
      runs: [_run('laps', RecordMode.laps, 2, durationMs: 1500000, laps: 5)],
    );
    expect(find.text('BEAT 5.00 km'), findsOneWidget);
    expect(find.textContaining('Lap times come'), findsNothing);
    expect(find.textContaining('Your last laps run'), findsOneWidget);
    expect(find.text('Start laps run'), findsOneWidget);
  });

  testWidgets('paused free run: BEAT uses moving pace', (tester) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
      runs: [
        _run(
          'free',
          RecordMode.free,
          1,
          distanceM: 5000,
          durationMs: 1800000,
          row: const IndexRow(lapCount: 1, movingMs: 1500000),
        ),
      ],
    );
    expect(find.text('BEAT 5:00'), findsOneWidget);
    expect(find.text('BEAT 6:00'), findsNothing);
  });

  testWidgets('laps with a median lap: BEAT is that lap time', (tester) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.laps,
      ),
      runs: [
        _run(
          'laps',
          RecordMode.laps,
          1,
          distanceM: 5000,
          laps: 10,
          row: const IndexRow(lapCount: 10, medianLapSec: 92),
        ),
        _run(
          'older',
          RecordMode.laps,
          8,
          distanceM: 5000,
          laps: 10,
          row: const IndexRow(lapCount: 10, medianLapSec: 95),
        ),
      ],
    );
    expect(find.text('BEAT 1:32'), findsOneWidget);
    expect(
      find.textContaining('3 s faster than the run before'),
      findsOneWidget,
    );
  });

  testWidgets('laps delta skips runs with a different lap distance', (
    tester,
  ) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.laps,
      ),
      runs: [
        _run(
          'laps',
          RecordMode.laps,
          1,
          distanceM: 5000,
          laps: 10,
          row: const IndexRow(lapCount: 10, medianLapSec: 92),
        ),
        _run(
          'long',
          RecordMode.laps,
          8,
          distanceM: 8000,
          laps: 10,
          row: const IndexRow(lapCount: 10, medianLapSec: 140),
        ),
      ],
    );
    expect(find.text('BEAT 1:32'), findsOneWidget);
    expect(find.textContaining('than the run before'), findsNothing);
  });

  testWidgets('fartlek gets a BEAT from fartlek runs only', (tester) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        sessionId: engine.SessionSpec.fartlekId,
      ),
      runs: [
        _run('lap', RecordMode.laps, 1, distanceM: 3000),
        _run(
          'fart',
          RecordMode.laps,
          3,
          distanceM: 6000,
          spec: engine.SessionSpec.fartlek,
        ),
      ],
    );
    expect(find.text('BEAT 6.00 km'), findsOneWidget);
    expect(find.text('SET YOUR LINE'), findsNothing);
  });

  testWidgets('free delta only compares runs within 15% distance', (
    tester,
  ) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
      runs: [
        _run('a', RecordMode.free, 1, distanceM: 5000, durationMs: 1500000),
        _run('b', RecordMode.free, 3, distanceM: 10000, durationMs: 3300000),
      ],
    );
    expect(find.text('BEAT 5:00'), findsOneWidget);
    expect(find.textContaining('than the run before'), findsNothing);
  });

  testWidgets('goal matches by distance, not label text', (tester) async {
    goalRun10k(int days, int ms) => _run(
      'g$days',
      RecordMode.intervals,
      days,
      distanceM: 10000,
      durationMs: ms,
      spec: engine.SessionSpec.goalDistance(10000, 'Ten kilometres'),
      row: IndexRow(
        lapCount: 1,
        goal: engine.GoalResult(
          kind: engine.GoalKind.distance,
          target: 10000,
          name: 'Ten kilometres',
          reached: true,
          goalMs: ms,
          stoppedAtM: 10000,
        ),
      ),
    );
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        goalRun: true,
        goalId: 'd10000',
      ),
      runs: [goalRun10k(2, 3000000)],
    );
    expect(find.text('BEAT 50:00'), findsOneWidget);
    expect(find.text('Start 10K'), findsOneWidget);
  });

  testWidgets('ineligible last 4x4 says why under SET YOUR LINE', (
    tester,
  ) async {
    await pump(
      tester,
      runs: [
        _run(
          'noise',
          RecordMode.intervals,
          1,
          row: const IndexRow(lapCount: 4, workPaceSecPerKm: 262),
        ),
      ],
    );
    expect(find.text('SET YOUR LINE'), findsOneWidget);
    expect(find.textContaining('no clean reps to beat'), findsOneWidget);
  });

  testWidgets('none yet for the session: SET YOUR LINE with its name', (
    tester,
  ) async {
    await pump(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
      runs: [
        _run(
          'int',
          RecordMode.intervals,
          1,
          row: const IndexRow(
            lapCount: 4,
            eligibleAsPrior: true,
            workPaceSecPerKm: 262,
          ),
        ),
      ],
    );
    expect(find.text('SET YOUR LINE'), findsOneWidget);
    expect(
      find.text('Your first free run is the one to beat.'),
      findsOneWidget,
    );
    expect(find.text('Start free run'), findsOneWidget);
  });

  testWidgets('scores: 2x2, no horizontal scroll, labelled dots', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: HomeScores(
          scores: {
            for (final l in [
              engine.IdentityLane.aerobic,
              engine.IdentityLane.speed,
              engine.IdentityLane.mid,
            ])
              l: earnedScores()[l]!,
          },
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () {},
        ),
      ),
    );
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.text('LONG'), findsOneWidget);
    expect(find.text('AEROBIC'), findsNWidgets(2));
  });
}
