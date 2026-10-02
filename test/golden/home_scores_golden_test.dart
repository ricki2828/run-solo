import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/live_context.dart';

import '../helpers.dart';

void main() {
  for (final height in [640, 800]) {
    for (final state in ['empty', 'one_run', 'plan_input']) {
      testWidgets('scores Home $state 360x$height', (tester) async {
        final r = RunSummary(
          id: 'last',
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
        await pumpApp(
          tester,
          fakeServices(runs: state == 'one_run' ? [r] : []),
          home: HomeScreen(
            now: now,
            planHeadline: state == 'plan_input'
                ? (name: 'Tempo', subtitle: 'Week 3, session 2 of 3.')
                : null,
          ),
        );
        tester.view.physicalSize = Size(1080, height * 3);
        await pumpTimes(tester, 8);
        expect(tester.takeException(), isNull);
        final name = 'home_scores_${state}_360x$height';
        expect(
          File('test/golden/goldens/$name.png').existsSync() ||
              autoUpdateGoldenFiles,
          isTrue,
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
      });
    }
    // Progress hero states: a 5K in the last window against one from the
    // window before sets MID and AEROBIC; faster is up, slower is down.
    for (final (state, thenMs, nowMs) in [
      ('steady', 1500000, 1500000),
      ('up', 1700000, 1500000),
      ('down', 1500000, 1700000),
    ]) {
      testWidgets('progress hero $state 360x$height', (tester) async {
        engine.LiveCandidate fiveK(String id, int daysAgo, int ms) =>
            engine.LiveCandidate(
              engine.BoardInput(
                runId: id,
                date: testNow.subtract(Duration(days: daysAgo)),
                mode: engine.RunMode.free,
              ),
              engine.RunDerived(
                bestEfforts: engine.RunBestEfforts(
                  efforts: {
                    engine.BestEffortDistance.k5: engine.BestEffort(
                      distance: engine.BestEffortDistance.k5,
                      elapsedMs: ms,
                      startMs: 0,
                      startOffsetM: 0,
                      splitsMs: const [],
                    ),
                  },
                  fromStartSplitsMs: const [],
                ),
              ),
            );
        final live = LiveContextSource.prepared([
          fiveK('then', 50, thenMs),
          fiveK('now', 3, nowMs),
        ], now: now);
        await pumpApp(
          tester,
          fakeServices(
            live: live,
            settings: const AppSettings(
              onboardingDone: true,
              profileSex: ProfileSex.male,
              birthYear: 1982,
            ),
          ),
          home: HomeScreen(now: now),
        );
        tester.view.physicalSize = Size(1080, height * 3);
        await pumpTimes(tester, 8);
        expect(tester.takeException(), isNull);
        final name = 'home_progress_${state}_360x$height';
        expect(
          File('test/golden/goldens/$name.png').existsSync() ||
              autoUpdateGoldenFiles,
          isTrue,
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
      });
    }
    testWidgets('four earned scores 360x$height', (tester) async {
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
      final live = LiveContextSource.prepared([
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
      expect(live.identityScores().length, 4);
      final r = RunSummary(
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
      await pumpApp(
        tester,
        fakeServices(
          runs: [r],
          live: live,
          settings: const AppSettings(
            onboardingDone: true,
            profileSex: ProfileSex.male,
            birthYear: 1982,
          ),
        ),
        home: HomeScreen(now: now),
      );
      tester.view.physicalSize = Size(1080, height * 3);
      await pumpTimes(tester, 8);
      expect(tester.takeException(), isNull);
      final name = 'home_scores_four_360x$height';
      expect(
        File('test/golden/goldens/$name.png').existsSync() ||
            autoUpdateGoldenFiles,
        isTrue,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
