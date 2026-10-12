import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/home_progress.dart';
import 'package:run_solo/widgets/home_b/home_b.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// Direction B Home against the three fixtures: day 1, week 2, month 3.
void main() {
  LiveContextSource liveWith() {
    final effort = engine.BestEffort(
      distance: engine.BestEffortDistance.k5,
      elapsedMs: 1500000,
      startMs: 0,
      startOffsetM: 0,
      splitsMs: const [],
    );
    final derived = engine.RunBestEfforts(
      efforts: {engine.BestEffortDistance.k5: effort},
      fromStartSplitsMs: const [],
      wholeRunM: 16000,
      wholeRunMs: 4800000,
    );
    return LiveContextSource.prepared([
      engine.LiveCandidate(
        engine.BoardInput(
          runId: 'interval',
          date: testNow.subtract(const Duration(days: 1)),
          mode: engine.RunMode.intervals,
          verdictGrade: true,
          comparisonKey: engine.ComparisonKey.norwegian4x4,
          headlineSecPerKm: 262,
        ),
        engine.RunDerived(bestEfforts: derived),
      ),
      engine.LiveCandidate(
        engine.BoardInput(
          runId: 'long',
          date: testNow.subtract(const Duration(days: 1)),
          mode: engine.RunMode.free,
        ),
        engine.RunDerived(bestEfforts: derived),
      ),
    ], now: now);
  }

  final run = RunSummary(
    id: 'interval',
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

  for (final height in [640, 800]) {
    for (final stage in ['day1', 'week2', 'month3']) {
      testWidgets('Home B $stage 360x$height', (tester) async {
        final full = stage == 'month3';
        await pumpApp(
          tester,
          fakeServices(
            runs: stage == 'day1' ? [] : [run],
            live: full ? liveWith() : null,
            settings: const AppSettings(
              onboardingDone: true,
              profileSex: ProfileSex.male,
              birthYear: 1982,
            ),
          ),
          home: HomeScreen(now: now, snapshot: ProgressSnapshot.sample(stage)),
        );
        tester.view.physicalSize = Size(1080, height * 3);
        await pumpTimes(tester, 8);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('pack-hero')), findsOneWidget);
        final name = 'home_b_${stage}_360x$height';
        expect(
          File('test/golden/goldens/$name.png').existsSync() ||
              autoUpdateGoldenFiles,
          isTrue,
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
        // The lower half: lane blocks, ghost, story, week strip.
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -4000),
        );
        await pumpTimes(tester, 4);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/home_b_${stage}_low_360x$height.png'),
        );
      });
    }
  }

  // Has runs, no age or sex: the hero says what to add, never "find your pack".
  for (final height in [640, 800]) {
    testWidgets('Home B has runs, no profile 360x$height', (tester) async {
      await pumpApp(
        tester,
        fakeServices(
          runs: [run],
          settings: const AppSettings(onboardingDone: true),
        ),
        home: HomeScreen(now: now),
      );
      tester.view.physicalSize = Size(1080, height * 3);
      await pumpTimes(tester, 8);
      expect(tester.takeException(), isNull);
      expect(find.text('ADD YOUR\nAGE BAND'), findsOneWidget);
      expect(find.text('FIND\nYOUR PACK'), findsNothing);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_b_noprofile_360x$height.png'),
      );
    });
  }

  // One lane up, one down, one flat, one not set: the change chips.
  testWidgets('Home B lane change chips', (tester) async {
    engine.IdentityScore score(
      engine.IdentityLane lane,
      double vdot,
      double? prior,
    ) => engine.IdentityScore(
      lane: lane,
      score: 60,
      vdot: vdot,
      priorVdot: prior,
      runId: lane.name,
      date: testNow,
      source: lane == engine.IdentityLane.mid ? '5K' : '4x4',
      boardKey: null,
    );
    final scores = {
      engine.IdentityLane.aerobic: score(engine.IdentityLane.aerobic, 44, 38),
      engine.IdentityLane.speed: score(engine.IdentityLane.speed, 38, 44),
      engine.IdentityLane.mid: score(engine.IdentityLane.mid, 40, 40),
    };
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: HomeLaneBlocks(
            scores: scores,
            profileSex: ProfileSex.male,
            age: 44,
            onOpen: () {},
            onUnlock: (_) {},
          ),
        ),
      ),
    );
    tester.view.physicalSize = const Size(1080, 600);
    await pumpTimes(tester, 4);
    int? change(engine.IdentityLane l) =>
        ScoreNorms.change(scores[l]!, sex: ProfileSex.male, age: 44);
    final up = change(engine.IdentityLane.aerobic)!;
    final down = change(engine.IdentityLane.speed)!;
    expect(up, greaterThan(0));
    expect(down, lessThan(0));
    expect(change(engine.IdentityLane.mid), 0);
    expect(find.text('+$up'), findsOneWidget);
    expect(find.text('$down'), findsOneWidget);
    expect(find.byKey(const ValueKey('lane-change-mid')), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_b_lane_chips_360.png'),
    );
  });
}
