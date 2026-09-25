import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/delta_glyph.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// History rows carry the verdict arrow (brief §4.8) and the three-type
/// filter (plan §18.2); tap opens the verdict or the detail.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  final d2 = DateTime.utc(2026, 9, 14, 6);
  final d3 = DateTime.utc(2026, 9, 15, 6);
  final d4 = DateTime.utc(2026, 9, 16, 6);

  Future<void> openHistory(WidgetTester tester, services) async {
    await pumpApp(tester, services, home: const HistoryScreen());
    await pumpTimes(tester, 6);
  }

  testWidgets(
    'arrows: baseline dot, faster ▲ in Arc; laps and free show none',
    (tester) async {
      final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
      final r2 = fourByFourFile(n: 2, start: d2, workSecPerKm: 260);
      final laps = lapsRunFile(n: 3, start: d3);
      final free = freeRunFile(n: 4, start: d4);
      await openHistory(tester, fakeServices(files: [r1, r2, laps, free]));
      final g1 = tester.widget<Text>(
        find.byKey(ValueKey('verdict-glyph-${r1.id}')),
      );
      expect(g1.data, '·');
      final g2 = tester.widget<DeltaGlyph>(
        find.byKey(ValueKey('verdict-glyph-${r2.id}')),
      );
      expect(g2.direction, DeltaDirection.up);
      expect(g2.color, RunSoloTokens.dark.semFaster);
      expect(find.byKey(ValueKey('verdict-glyph-${laps.id}')), findsNothing);
      expect(find.byKey(ValueKey('verdict-glyph-${free.id}')), findsNothing);
      expect(find.text('LAPS'), findsWidgets);
      expect(find.text('FREE'), findsWidgets);
    },
  );

  testWidgets('filters: All, 4x4, Laps, Free', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final laps = lapsRunFile(n: 3, start: d3);
    final free = freeRunFile(n: 4, start: d4);
    await openHistory(tester, fakeServices(files: [r1, laps, free]));
    expect(find.byType(HistoryRow), findsNWidgets(3));
    await tester.tap(find.text('Laps'));
    await pumpTimes(tester, 2);
    expect(find.byType(HistoryRow), findsOneWidget);
    await tester.tap(find.text('Free'));
    await pumpTimes(tester, 2);
    expect(find.byType(HistoryRow), findsOneWidget);
    await tester.tap(find.text('4x4'));
    await pumpTimes(tester, 2);
    expect(find.byType(HistoryRow), findsOneWidget);
    await tester.tap(find.text('All'));
    await pumpTimes(tester, 2);
    expect(find.byType(HistoryRow), findsNWidgets(3));
  });

  testWidgets('tap a 4x4 → verdict; tap a free run → detail', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final free = freeRunFile(n: 4, start: d4);
    await openHistory(tester, fakeServices(files: [r1, free]));
    await tester.tap(find.byType(HistoryRow).last);
    await settleAnimations(tester);
    expect(find.byType(VerdictScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(VerdictScreen))).pop();
    await settleAnimations(tester);
    await tester.tap(find.byType(HistoryRow).first);
    await settleAnimations(tester);
    expect(find.byType(RunDetailScreen), findsOneWidget);
  });

  testWidgets('missing file row is shown, not tappable', (tester) async {
    await openHistory(
      tester,
      fakeServices(
        runs: [
          RunSummary(
            id: 'gone',
            mode: RecordMode.fourByFour,
            start: d1,
            durationMs: 1800000,
            distanceM: 6000,
            laps: 8,
            missing: true,
          ),
        ],
      ),
    );
    expect(find.text('File missing'), findsOneWidget);
    await tester.tap(find.byType(HistoryRow));
    await settleAnimations(tester);
    expect(find.byType(VerdictScreen), findsNothing);
  });
}
