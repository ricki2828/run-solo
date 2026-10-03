import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/state/history_store.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// History grouped by week at 360 x 640 and 360 x 800: this week, last week,
/// older weeks and an older month, from a FileRunStore (index rows). PNGs
/// come from CI like every golden (see screens_golden_test.dart).
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens artifact',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  // The test clock is Thu 24 Sep 2026.
  final starts = [
    DateTime.utc(2026, 9, 23, 6), // this week
    DateTime.utc(2026, 9, 21, 7),
    DateTime.utc(2026, 9, 19, 6), // last week
    DateTime.utc(2026, 9, 17, 6),
    DateTime.utc(2026, 9, 15, 6),
    DateTime.utc(2026, 9, 9, 6), // 7 to 13 Sep
    DateTime.utc(2026, 9, 1, 6), // 31 Aug to 6 Sep
    DateTime.utc(2026, 8, 25, 6), // 24 to 30 Aug
    DateTime.utc(2026, 8, 20, 6),
    DateTime.utc(2026, 7, 12, 6), // older: July 2026
    DateTime.utc(2026, 7, 4, 6),
  ];

  for (final h in [640, 800]) {
    testWidgets('history: grouped by week at 360 x $h', (tester) async {
      final dir = Directory.systemTemp.createTempSync('runsolo-hwgold-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileRunStore(Directory('${dir.path}/runs'));
      final files = [
        for (var i = 0; i < starts.length; i++)
          i.isEven
              ? withElevation(
                  freeRunFile(
                    n: i + 1,
                    start: starts[i],
                    seconds: 1500 + 240 * i,
                    secPerKm: 340 + 4 * i,
                  ),
                )
              : freeRunFile(
                  n: i + 1,
                  start: starts[i],
                  seconds: 1500 + 240 * i,
                  secPerKm: 340 + 4 * i,
                ),
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
      tester.view.physicalSize = Size(1080, h * 3.0);
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      for (
        var i = 0;
        i < 100 && find.text('THIS WEEK').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await pumpTimes(tester, 4);
      expect(find.text('THIS WEEK'), findsOneWidget);
      await golden(tester, 'history_weeks_360x$h');
      // The tail: older weeks and the month fallback.
      await tester.drag(find.byType(ListView).first, const Offset(0, -5000));
      await pumpTimes(tester, 4);
      expect(find.text('JULY 2026'), findsOneWidget);
      await golden(tester, 'history_weeks_scrolled_360x$h');
    });
  }
}
