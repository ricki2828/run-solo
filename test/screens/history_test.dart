import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
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

  testWidgets('newest first, grouped by week, filter chips', (tester) async {
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

    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('LAST WEEK'), findsOneWidget);
    expect(find.text('24 TO 30 AUG'), findsOneWidget);
    expect(find.text('SEPTEMBER 2026'), findsNothing);
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
    expect(find.text('24 TO 30 AUG'), findsNothing);
    expect(find.text('THIS WEEK'), findsOneWidget);
    // This week has no Free run now: anchored, not dropped.
    expect(find.text('No runs yet this week'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('history-totals-LAST WEEK')),
      findsOneWidget,
    );
    expect(find.text('1 run · 5.0 km · 0:25'), findsOneWidget);

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

  testWidgets('totals follow the filter; units follow the setting', (
    tester,
  ) async {
    final runs = [
      summary(
        id: 'a',
        start: DateTime(2026, 9, 22, 7),
        durationMs: 30 * 60 * 1000,
        distanceM: 10000,
      ),
      summary(
        id: 'b',
        start: DateTime(2026, 9, 23, 7),
        fourByFour: false,
        durationMs: 40 * 60 * 1000,
        distanceM: 8000,
        laps: 1,
      ),
    ];
    await pumpApp(
      tester,
      fakeServices(
        runs: runs,
        settings: const AppSettings(onboardingDone: true, units: Units.mi),
      ),
      home: const HistoryScreen(),
    );
    await pumpTimes(tester);
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester);
    expect(find.text('2 runs · 11.2 mi · 1:10'), findsOneWidget);
    await tester.tap(find.text('Free'));
    await pumpTimes(tester);
    expect(find.text('1 run · 5.0 mi · 0:40'), findsOneWidget);
    expect(find.text('2 runs · 11.2 mi · 1:10'), findsNothing);
  });

  testWidgets('File store: weeks, month fallback, totals from index rows', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('runsolo-hweek-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileRunStore(Directory('${dir.path}/runs'));
    final files = [
      withElevation(
        freeRunFile(n: 1, start: DateTime.utc(2026, 9, 22, 12), seconds: 1800),
      ),
      freeRunFile(n: 2, start: DateTime.utc(2026, 9, 16, 12), seconds: 1800),
      freeRunFile(n: 3, start: DateTime.utc(2026, 8, 5, 12), seconds: 1800),
      freeRunFile(n: 4, start: DateTime.utc(2026, 2, 5, 12), seconds: 1800),
    ];
    await tester.runAsync(() async {
      await store.importBundles([
        for (final f in files) engine.RunBundle(run: f),
      ]);
      await store.list();
      await store.derivedIdle;
    });
    await pumpApp(
      tester,
      fakeServices(history: store),
      home: const HistoryScreen(),
    );
    for (var i = 0; i < 60 && find.text('THIS WEEK').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('LAST WEEK'), findsOneWidget);
    expect(find.text('3 TO 9 AUG'), findsOneWidget);
    expect(find.text('FEBRUARY 2026'), findsOneWidget);
    // This week's run carries the fused elevation: its climb is in the line.
    final thisWeek = tester.widget<Text>(
      find.byKey(const ValueKey('history-totals-THIS WEEK')),
    );
    expect(
      thisWeek.data,
      matches(RegExp(r'^1 run · [\d.]+ km · 0:\d\d · \+\d+ m$')),
    );
    final lastWeek = tester.widget<Text>(
      find.byKey(const ValueKey('history-totals-LAST WEEK')),
    );
    expect(lastWeek.data, isNot(contains('+')));
  });
}
