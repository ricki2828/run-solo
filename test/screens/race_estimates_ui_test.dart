import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/progress_screen.dart';
import 'package:run_solo/state/live_context.dart';

import '../helpers.dart';

/// Race times and VO2 on Progress, and the Home line that opens it.
void main() {
  engine.LiveCandidate candidate(
    String id, {
    Map<engine.BestEffortDistance, engine.BestEffort> efforts = const {},
    double? wholeM,
    int? wholeMs,
  }) {
    final e = engine.RunBestEfforts(
      efforts: efforts,
      fromStartSplitsMs: const [],
      wholeRunM: wholeM,
      wholeRunMs: wholeMs,
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

  final fiveK = candidate(
    'a',
    efforts: {
      engine.BestEffortDistance.k5: engine.BestEffort(
        distance: engine.BestEffortDistance.k5,
        elapsedMs: 1470 * 1000,
        startMs: 0,
        startOffsetM: 0,
        splitsMs: const [],
      ),
    },
  );
  final long = candidate('l', wholeM: 12000, wholeMs: 3600 * 1000);

  Future<void> openProgress(
    WidgetTester tester,
    List<engine.LiveCandidate> runs,
  ) async {
    await pumpApp(
      tester,
      fakeServices(live: LiveContextSource.prepared(runs, now: now)),
      home: const ProgressScreen(),
    );
    await pumpTimes(tester, 6);
  }

  testWidgets('Progress: 5K, 10K, VO2, and why there is no half', (
    tester,
  ) async {
    await openProgress(tester, [fiveK]);
    expect(find.byKey(const ValueKey('race-estimates')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('race-time-5K'))).data,
      '24:30',
    );
    expect(find.byKey(const ValueKey('race-time-10K')), findsOneWidget);
    expect(find.byKey(const ValueKey('race-range-10K')), findsOneWidget);
    expect(find.byKey(const ValueKey('race-time-Half')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('race-why-Half'))).data,
      engine.RaceEstimates.longWhyNot,
    );
    expect(find.byKey(const ValueKey('race-vo2')), findsOneWidget);
  });

  testWidgets('Progress: a long run gives half and marathon', (tester) async {
    await openProgress(tester, [fiveK, long]);
    expect(find.byKey(const ValueKey('race-time-Half')), findsOneWidget);
    expect(find.byKey(const ValueKey('race-time-Marathon')), findsOneWidget);
    expect(find.byKey(const ValueKey('race-why-Half')), findsNothing);
  });

  testWidgets('the method is behind "How this works"', (tester) async {
    await openProgress(tester, [fiveK]);
    expect(find.textContaining('Riegel'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('race-how')));
    await tester.tap(find.byKey(const ValueKey('race-how')));
    await pumpTimes(tester, 2);
    expect(find.textContaining('Riegel'), findsOneWidget);
    expect(find.textContaining('Research-based'), findsOneWidget);
  });

  testWidgets('Home line shows half, marathon and VO2 and opens Progress', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(
        runs: [
          summary(
            id: 'r1',
            start: DateTime(2026, 9, 12, 12),
            fourByFour: false,
          ),
        ],
        live: LiveContextSource.prepared([fiveK, long], now: now),
      ),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 8);
    final line = find.byKey(const ValueKey('home-race-line'));
    await tester.ensureVisible(line);
    final text = tester.widget<Text>(
      find.descendant(of: line, matching: find.byType(Text)),
    );
    expect(text.data, matches(RegExp(r'^Half .+ · Marathon .+ · VO2 \d+ ›$')));
    await tester.tap(line);
    await pumpTimes(tester, 4);
    expect(find.byType(ProgressScreen), findsOneWidget);
  });
}
