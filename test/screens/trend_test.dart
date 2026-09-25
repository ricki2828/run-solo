import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/trend_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Trend per run type (brief §4.9).
void main() {
  final base = DateTime.utc(2026, 8, 1, 6);

  testWidgets('under two 4x4s: "Two 4x4s draw the first line"', (tester) async {
    final r1 = fourByFourFile(n: 1, start: base);
    await pumpApp(tester, fakeServices(files: [r1]), home: const TrendScreen());
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('trend-empty')), findsOneWidget);
    expect(find.text('4X4 · 1 SESSION'), findsOneWidget);
  });

  testWidgets('three 4x4s: hero median, delta, chart, bests', (tester) async {
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
      home: const TrendScreen(),
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('trend-hero')), findsOneWidget);
    expect(find.text('BESTS'), findsOneWidget);
    expect(find.text('BEST REP'), findsOneWidget);
    expect(find.text('LOWEST FADE'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('Free: distance and pace only, no verdict language', (
    tester,
  ) async {
    final files = [
      freeRunFile(n: 1, start: base),
      freeRunFile(n: 2, start: base.add(const Duration(days: 2))),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: const TrendScreen(),
    );
    await pumpTimes(tester, 6);
    await tester.tap(find.text('Free'));
    await pumpTimes(tester, 4);
    expect(find.text('FREE RUN · 2 SESSIONS'), findsOneWidget);
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.textContaining('FASTER'), findsNothing);
    expect(find.textContaining('verdict', findRichText: true), findsOneWidget);
  });

  test('trendPoints: rolling median of the previous 6 eligible runs', () {
    final files = [
      for (var i = 0; i < 8; i++)
        fourByFourFile(
          n: i + 1,
          start: base.add(Duration(days: 3 * i)),
          workSecPerKm: 300 - i,
        ),
    ];
    final services = fakeServices(files: files);
    return services.history.list().then((all) {
      final chrono = all.reversed.toList();
      final pts = trendPoints(chrono);
      expect(pts.length, 8);
      expect(pts.first.medianSecPerKm, isNull);
      expect(pts[1].medianSecPerKm, isNotNull);
      // Point 8's window is runs 2..7 (six of them).
      final window = [for (var i = 1; i < 7; i++) pts[i].paceSecPerKm];
      expect(pts.last.medianSecPerKm, closeTo(median(window), 1e-9));
    });
  });
}
