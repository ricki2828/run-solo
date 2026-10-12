import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/progress_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The boards overview (LB3c, mockup frames 1-9), now under BOARDS & RECORDS
/// on the Progress tab. History keeps the run log only.
void main() {
  final base = DateTime.utc(2026, 9, 5, 6);

  testWidgets('empty: the boards explain themselves', (tester) async {
    await pumpApp(tester, fakeServices(), home: const ProgressScreen());
    await pumpTimes(tester, 6);
    await useTallPhoneView(tester);
    expect(find.text('PROGRESS'), findsOneWidget);
    expect(find.text('BOARDS & RECORDS'), findsOneWidget);
    expect(find.text('Nothing to rank yet'), findsOneWidget);
  });

  testWidgets(
    'two parkruns: distance and course cards, a latest-best strip, NEW tags',
    (tester) async {
      final files = [
        eventRunFile(n: 1, start: base, eventName: 'parkrun', mps: 3.2),
        eventRunFile(
          n: 2,
          start: base.add(const Duration(days: 7)),
          eventName: 'parkrun',
          mps: 3.6,
        ),
      ];
      await pumpApp(
        tester,
        fakeServices(files: files),
        home: const ProgressScreen(),
      );
      await pumpTimes(tester, 6);
      // The phone viewport cuts the later sections off; grow it to see all.
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('boards-overview')),
          matching: find.text('DISTANCE'),
        ),
        findsOneWidget,
      );
      expect(find.text('PARKRUN'), findsOneWidget);
      expect(find.text('5K'), findsOneWidget);
      expect(find.byKey(const ValueKey('boards-latest-best')), findsOneWidget);
      // Both boards hold the same two runs, and the newer one is the best.
      expect(find.text('2 runs · last was your best'), findsWidgets);
      expect(find.text('NEW'), findsWidgets);
    },
  );

  testWidgets('a first 12-minute test lands under TESTS', (tester) async {
    await pumpApp(
      tester,
      fakeServices(files: [cooperTestFile(n: 1, start: base)]),
      home: const ProgressScreen(),
    );
    await pumpTimes(tester, 6);
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    expect(find.text('TESTS'), findsOneWidget);
    expect(find.text('12-minute test'), findsOneWidget);
    expect(find.text('VO2 estimate'), findsOneWidget);
    expect(find.text('1 run · the next one races it'), findsWidgets);
  });

  testWidgets('interval boards group under INTERVALS', (tester) async {
    final files = [
      for (var i = 0; i < 3; i++)
        fourByFourFile(
          n: i + 1,
          start: base.add(Duration(days: 4 * i)),
          workSecPerKm: 290 - 8 * i,
        ),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: const ProgressScreen(),
    );
    await pumpTimes(tester, 6);
    await useTallPhoneView(tester);
    expect(find.text('INTERVALS'), findsOneWidget);
  });

  testWidgets('History keeps TRENDS and the run log, boards moved out', (
    tester,
  ) async {
    final files = [
      for (var i = 0; i < 3; i++)
        fourByFourFile(
          n: i + 1,
          start: base.add(Duration(days: 4 * i)),
          workSecPerKm: 290 - 8 * i,
        ),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: const HistoryScreen(),
    );
    await pumpTimes(tester, 6);
    expect(find.text('LEADERBOARD'), findsNothing);
    expect(find.byKey(const ValueKey('history-view-0')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('history-view-2')));
    await pumpTimes(tester, 6);
    expect(find.textContaining('NORWEGIAN 4X4'), findsWidgets);
  });
}
