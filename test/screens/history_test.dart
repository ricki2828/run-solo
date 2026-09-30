import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/platform/gateway.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

void main() {
  testWidgets('empty: Lap Line R, baseline line, START', (tester) async {
    final services = fakeServices();
    var started = false;
    await pumpApp(
      tester,
      services,
      home: HistoryScreen(onStart: () => started = true),
    );
    await pumpTimes(tester);
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester);
    expect(find.text('Your first 4x4 sets the baseline.'), findsOneWidget);
    await tester.tap(find.text('START'));
    expect(started, isTrue);
  });

  testWidgets(
    'a test row: 12:00, the test distance, the prime score (27-Sep)',
    (tester) async {
      // Warm-up 5:00 + 12:00 test + 2:00 cool-down = a 19:00, 3.89 km file;
      // the row shows the test's own window (his 12:31 / 2.78 km report).
      final r = cooperTestFile(n: 1, start: DateTime(2026, 9, 22, 7));
      await pumpApp(
        tester,
        fakeServices(files: [r]),
        home: const HistoryScreen(),
      );
      await pumpTimes(tester);
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      await pumpTimes(tester);
      expect(find.text('12:00'), findsOneWidget);
      expect(find.text('19:00'), findsNothing);
      expect(find.textContaining('2.88'), findsOneWidget);
      expect(find.textContaining('3.89'), findsNothing);
      // The score replaces the '--' pace (raw here: no weather on the run).
      expect(find.text('53'), findsOneWidget);
    },
  );

  testWidgets('newest first, grouped by month, filter chips', (tester) async {
    final services = fakeServices(
      runs: [
        summary(
          id: 'aug',
          start: DateTime(2026, 8, 30, 7),
          durationMs: 30 * 60 * 1000,
          distanceM: 6000,
        ),
        summary(
          id: 'sep-free',
          start: DateTime(2026, 9, 20, 7),
          fourByFour: false,
          durationMs: 25 * 60 * 1000,
          distanceM: 5000,
          laps: 1,
        ),
        summary(
          id: 'sep-4x4',
          start: DateTime(2026, 9, 22, 7),
          durationMs: 32 * 60 * 1000,
          distanceM: 6400,
        ),
      ],
    );
    await pumpApp(tester, services, home: const HistoryScreen());
    await pumpTimes(tester);
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester);

    expect(find.text('SEPTEMBER 2026'), findsOneWidget);
    expect(find.text('AUGUST 2026'), findsOneWidget);
    expect(find.byType(HistoryRow), findsNWidgets(3));

    final rows = tester
        .widgetList<HistoryRow>(find.byType(HistoryRow))
        .map((r) => r.run.id)
        .toList();
    expect(rows, ['sep-4x4', 'sep-free', 'aug']);
    expect(find.text('5:00/km'), findsNWidgets(3));
    expect(find.text('8 laps · 6.40 km'), findsOneWidget);
    expect(find.text('32:00'), findsOneWidget);

    await tester.tap(find.text('Free'));
    await pumpTimes(tester);
    expect(find.byType(HistoryRow), findsOneWidget);
    expect(find.text('AUGUST 2026'), findsNothing);

    await tester.tap(find.text('Intervals'));
    await pumpTimes(tester);
    expect(find.byType(HistoryRow), findsNWidgets(2));
  });

  testWidgets('miles when units are mi; missing file is flagged', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(onboardingDone: true, units: Units.mi),
      runs: [
        RunSummary(
          id: 'gone',
          mode: RecordMode.intervals,
          start: DateTime(2026, 9, 1, 7),
          durationMs: 32 * 60 * 1000,
          distanceM: 6400,
          laps: 8,
          missing: true,
        ),
      ],
    );
    await pumpApp(tester, services, home: const HistoryScreen());
    await pumpTimes(tester);
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester);
    expect(find.text('File missing'), findsOneWidget);
    expect(find.text('8:03/mi'), findsOneWidget);
  });
}
