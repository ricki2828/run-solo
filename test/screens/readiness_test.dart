import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

RunSummary runWithRest(String id, int daysAgo, int? rest) => RunSummary(
  id: id,
  mode: RecordMode.free,
  start: now().subtract(Duration(days: daysAgo)),
  durationMs: 1800000,
  distanceM: 5000,
  laps: 0,
  row: IndexRow(lapCount: 0, restingHrBpm: rest),
);

void main() {
  test(
    'IndexRow keeps the resting HR through JSON and is built from the run',
    () {
      const row = IndexRow(lapCount: 0, restingHrBpm: 57);
      expect(IndexRow.fromJson(row.toJson())!.restingHrBpm, 57);
      expect(
        IndexRow.fromJson(const IndexRow(lapCount: 0).toJson())!.restingHrBpm,
        isNull,
      );
      final run = freeRunFile(n: 1, start: DateTime.utc(2026, 9, 20, 7));
      final standing = run.copyWith(
        samples: [
          for (var s = 0; s < 600; s++)
            engine.Sample(
              tMs: s * 1000,
              speedMps: s < 240 ? 0.2 : 3.5,
              distM: s * 3.0,
              hr: s < 240 ? 56 : 150,
            ),
        ],
      );
      expect(IndexRow.of(standing, null, null).restingHrBpm, 56);
    },
  );

  Future<void> openHome(WidgetTester tester, List<RunSummary> runs) async {
    await pumpApp(
      tester,
      fakeServices(runs: runs),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 8);
  }

  testWidgets('Home: recovered when resting HR is normal', (tester) async {
    await openHome(tester, [
      runWithRest('a', 0, 55),
      runWithRest('b', 2, 54),
      runWithRest('c', 4, 56),
      runWithRest('d', 6, 55),
    ]);
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('readiness-line')),
    );
    expect(text.data, 'Recovered: resting HR normal');
  });

  testWidgets('Home: take it easy when resting HR is up, detail on tap', (
    tester,
  ) async {
    await openHome(tester, [
      runWithRest('a', 0, 62),
      runWithRest('b', 2, 54),
      runWithRest('c', 4, 56),
      runWithRest('d', 6, 55),
    ]);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('readiness-line'))).data,
      'Take it easy: resting HR up 7 bpm',
    );
    // The cards push the line below the fold of the small test screen.
    await tester.ensureVisible(find.byKey(const ValueKey('readiness-info')));
    await tester.tap(find.byKey(const ValueKey('readiness-info')));
    await pumpTimes(tester, 2);
    expect(find.textContaining('Research-based'), findsOneWidget);
  });

  testWidgets('Home: no line without enough strap runs', (tester) async {
    await openHome(tester, [
      runWithRest('a', 0, 62),
      runWithRest('b', 2, 54),
      runWithRest('c', 4, null),
    ]);
    expect(find.byKey(const ValueKey('readiness-line')), findsNothing);
  });
}
