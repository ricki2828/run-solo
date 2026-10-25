import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/recent_bars_chart.dart';

/// The one bar style (Trends + boards): 0 and 1 attempt are an empty state,
/// two or more draw bars with direction, best and a value list.
void main() {
  final d0 = DateTime.utc(2026, 9, 1);

  Widget host(List<BarPoint> pts, {int maxBars = 8}) => MaterialApp(
    theme: ThemeData(extensions: const [RunSoloTokens.dark]),
    home: Scaffold(
      body: SingleChildScrollView(
        child: RecentBarsChart(
          points: pts,
          lowerIsBetter: true,
          format: (v) => '${v.round()} s',
          direction: 'Faster is taller',
          emptyTitle: 'Two runs draw the first chart.',
          maxBars: maxBars,
        ),
      ),
    ),
  );

  List<BarPoint> pts(int n) => [
    for (var i = 0; i < n; i++)
      BarPoint(
        date: d0.add(Duration(days: i)),
        value: 300.0 - 3 * i,
      ),
  ];

  for (final n in [0, 1]) {
    testWidgets('$n points: empty state, no chart', (tester) async {
      await tester.pumpWidget(host(pts(n)));
      expect(find.byType(ChartEmptyState), findsOneWidget);
      expect(find.text('Two runs draw the first chart.'), findsOneWidget);
      expect(find.textContaining('FASTER IS TALLER'), findsNothing);
    });
  }

  testWidgets('two points: chart, direction and both values listed', (
    tester,
  ) async {
    await tester.pumpWidget(host(pts(2)));
    expect(find.byType(ChartEmptyState), findsNothing);
    expect(find.text('FASTER IS TALLER · LAST 2'), findsOneWidget);
    // Best is the newest (297 s) and carries the PB tag in the list.
    expect(find.text('297 s'), findsOneWidget);
    expect(find.text('300 s'), findsOneWidget);
    expect(find.text('PB'), findsOneWidget);
  });

  testWidgets('many points: capped at maxBars, newest first in the list', (
    tester,
  ) async {
    await tester.pumpWidget(host(pts(12)));
    expect(find.text('FASTER IS TALLER · LAST 8'), findsOneWidget);
    // Oldest shown is index 4 (288 s); index 3 (291 s) is dropped.
    expect(find.text('288 s'), findsOneWidget);
    expect(find.text('291 s'), findsNothing);
    final newest = tester.getTopLeft(find.text('267 s')).dy;
    final older = tester.getTopLeft(find.text('270 s')).dy;
    expect(newest, lessThan(older));
  });

  group('dateLabelSlots', () {
    test('never closer than kLabelGap, keeps newest and oldest', () {
      // 8 bars at 34 dp, labels 28 wide: neighbours are 6 dp apart.
      final keep = dateLabelSlots(
        widths: List.filled(8, 28.0),
        slot: 34,
        pb: 3,
      );
      expect(keep, containsAll([0, 3, 7]));
      for (var a = 0; a < keep.length - 1; a++) {
        final gap = (keep[a + 1] - keep[a]) * 34 - 28;
        expect(gap, greaterThanOrEqualTo(kLabelGap));
      }
    });

    test('short labels all fit', () {
      expect(dateLabelSlots(widths: List.filled(8, 18.0), slot: 34, pb: 0), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
    });
  });

  Widget hostWith(
    List<BarPoint> pts, {
    double minSpan = 0,
    NoiseBand? noise,
  }) => MaterialApp(
    theme: ThemeData(extensions: const [RunSoloTokens.dark]),
    home: Scaffold(
      body: SingleChildScrollView(
        child: RecentBarsChart(
          points: pts,
          lowerIsBetter: true,
          format: (v) => '${v.round()} s',
          direction: 'Faster is taller',
          emptyTitle: 'Two runs draw the first chart.',
          roundTo: 10,
          minSpan: minSpan,
          noise: noise,
        ),
      ),
    ),
  );

  testWidgets('a unique best is the PB', (tester) async {
    await tester.pumpWidget(
      hostWith([
        BarPoint(date: d0, value: 2520),
        BarPoint(date: d0.add(const Duration(days: 1)), value: 2400),
      ]),
    );
    expect(find.text('PB'), findsOneWidget);
  });

  testWidgets('two bars level on the best: no PB for either', (tester) async {
    await tester.pumpWidget(
      hostWith([
        BarPoint(date: d0, value: 2400),
        BarPoint(date: d0.add(const Duration(days: 1)), value: 2400),
        BarPoint(date: d0.add(const Duration(days: 2)), value: 2520),
      ]),
    );
    expect(find.text('PB'), findsNothing);
  });

  testWidgets('a noise band keeps the axis note on the same line', (
    tester,
  ) async {
    final pts = [
      BarPoint(date: d0, value: 2520),
      BarPoint(date: d0.add(const Duration(days: 1)), value: 2400),
    ];
    const band = NoiseBand(
      center: 2460,
      half: 30,
      label: 'Noise',
      detail: '+/- 30 s',
      caption: 'Shaded = GPS noise around your previous median',
    );
    await tester.pumpWidget(hostWith(pts, noise: band));
    expect(find.textContaining('axis from'), findsOneWidget);
    expect(
      find.text('Shaded = GPS noise around your previous median'),
      findsOneWidget,
    );
    expect(find.textContaining('Axis starts at'), findsNothing);
  });

  testWidgets('a minimum span keeps a small gap from reading as big', (
    tester,
  ) async {
    final two = [
      BarPoint(date: d0, value: 2520),
      BarPoint(date: d0.add(const Duration(days: 1)), value: 2400),
    ];
    // A 2:00 gap on a 6 km trail: without a floor the axis starts at 2540.
    await tester.pumpWidget(hostWith(two));
    expect(find.text('Axis starts at 2540 s'), findsOneWidget);
    // With 30 s/km x 6 km = 180 s of span it starts lower, 2550.
    await tester.pumpWidget(hostWith(two, minSpan: 180));
    expect(find.text('Axis starts at 2550 s'), findsOneWidget);
  });

  testWidgets(
    'tapping a bar with no owner-supplied handler shows its readout',
    (tester) async {
      await tester.pumpWidget(host(pts(6)));
      expect(find.byType(CustomPaint), findsWidgets);
      final box = tester.getTopLeft(
        find.descendant(
          of: find.byType(RecentBarsChart),
          matching: find.byType(GestureDetector),
        ),
      );
      // Second slot of the plot: no throw, chart repaints with a selection.
      await tester.tapAt(box + const Offset(60, 100));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
