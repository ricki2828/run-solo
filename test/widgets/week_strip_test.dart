import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/zone_histogram.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/week_strip.dart';

void main() {
  // Thursday; the run is that morning (utc offset 0).
  final now = DateTime(2026, 10, 8, 18);
  final zones = engine.HrZones.percentMax(190);

  RunSummary run({HrHist? hist}) => RunSummary(
    id: 'r1',
    mode: RecordMode.free,
    start: DateTime.utc(2026, 10, 8, 6),
    durationMs: 1800000,
    distanceM: 5000,
    laps: 0,
    utcOffsetMin: 0,
    hrHist: hist,
  );

  test('the run lands on its weekday, split by zone', () {
    // 10 min Z2 (bpm 125), 10 min Z4 (bpm 160); 10 min has no HR.
    final hist = HrHist(125, [600, ...List.filled(34, 0), 600]);
    final days = WeekStrip.daysOf([run(hist: hist)], zones, now);
    expect(days[3][2], 600);
    expect(days[3][4], 600);
    expect(days[3][0], 600);
    expect(days[0].every((s) => s == 0), isTrue);
  });

  testWidgets('a day with a run draws a real bar, the rest a stub', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Scaffold(
          body: WeekStrip(runs: [run()], zones: zones, now: now),
        ),
      ),
    );
    final bar = tester.getSize(find.byKey(const ValueKey('week-bar-3')));
    final stub = tester.getSize(find.byKey(const ValueKey('week-bar-0')));
    // The zone fill itself must have width (a ColoredBox in a Column
    // collapses to zero without stretch).
    final fill = tester.getSize(
      find
          .descendant(
            of: find.byKey(const ValueKey('week-bar-3')),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(fill.width, greaterThan(10));
    expect(bar.width, greaterThan(10));
    expect(bar.height, greaterThan(20));
    expect(stub.height, lessThan(8));
  });
}
