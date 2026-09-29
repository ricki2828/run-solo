import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/progress_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

void main() {
  testWidgets(
    'History opens leaderboard and retains chronological and trends',
    (tester) async {
      await pumpApp(
        tester,
        fakeServices(
          files: [fourByFourFile(n: 1, start: DateTime.utc(2026, 9, 20))],
        ),
        home: const HistoryScreen(),
      );
      await pumpTimes(tester, 6);
      expect(find.byKey(const ValueKey('boards-overview')), findsOneWidget);
      expect(find.byType(HistoryRow), findsNothing);
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      await pumpTimes(tester, 2);
      expect(find.byType(HistoryRow), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-view-2')));
      await pumpTimes(tester, 2);
      expect(find.text('TRENDS'), findsOneWidget);
    },
  );

  testWidgets('Progress explains locked lanes without making up percentiles', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: const ProgressScreen());
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('score-analysis')), findsOneWidget);
    for (final lane in ['aerobic', 'speed', 'mid', 'long']) {
      expect(find.byKey(ValueKey('analysis-$lane')), findsOneWidget);
    }
    expect(find.textContaining('not an age percentile'), findsOneWidget);
    expect(find.textContaining('different measures'), findsOneWidget);
  });
}
