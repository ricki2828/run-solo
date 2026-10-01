import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/recent_bars_chart.dart';

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
    expect(find.byKey(const ValueKey('trend-chart')), findsNothing);
    expect(find.text('NORWEGIAN 4X4 · 1 SESSION'), findsOneWidget);
  });

  testWidgets('no runs: designed empty state, no chart', (tester) async {
    await pumpApp(tester, fakeServices(), home: const TrendScreen());
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('trend-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('trend-chart')), findsNothing);
  });

  testWidgets('many 4x4s: bars capped at 8, direction stated', (tester) async {
    final files = [
      for (var i = 0; i < 10; i++)
        fourByFourFile(
          n: i + 1,
          start: base.add(Duration(days: 3 * i)),
          workSecPerKm: 300 - 2 * i,
        ),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: const TrendScreen(),
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('trend-chart')), findsOneWidget);
    expect(find.text('FASTER IS TALLER · LAST 8'), findsOneWidget);
    expect(find.text('PB'), findsOneWidget);
    // The noise floor stays on the chart, with its plain-words caption.
    expect(
      find.text('Shaded = GPS noise around your previous median'),
      findsOneWidget,
    );
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
    // The chart says which way is better; there is still no verdict.
    expect(find.textContaining('FASTER IS TALLER'), findsOneWidget);
    expect(find.textContaining('verdict', findRichText: true), findsOneWidget);
  });

  group('Laps and Free charts', () {
    Future<void> open(
      WidgetTester tester,
      List<engine.RunFile> files,
      String tab,
    ) async {
      await pumpApp(
        tester,
        fakeServices(files: files),
        home: const TrendScreen(),
      );
      await pumpTimes(tester, 6);
      await tester.tap(find.text(tab));
      await pumpTimes(tester, 4);
    }

    final chart = find.byKey(const ValueKey('distance-trend-chart'));

    testWidgets('Free 0 runs: no chart', (tester) async {
      await open(tester, [], 'Free');
      expect(find.byType(ChartEmptyState), findsNothing);
      expect(find.textContaining('FASTER IS TALLER'), findsNothing);
    });

    testWidgets('Free 1 run: empty state, names the band', (tester) async {
      await open(tester, [freeRunFile(n: 1, start: base)], 'Free');
      expect(
        find.text('Two comparable runs draw the first chart.'),
        findsOneWidget,
      );
      expect(find.textContaining('runs of 4 to 6 km only'), findsOneWidget);
      expect(find.textContaining('FASTER IS TALLER'), findsNothing);
    });

    testWidgets('Free many: chart, band caption, PB', (tester) async {
      await open(tester, [
        for (var i = 0; i < 4; i++)
          freeRunFile(
            n: i + 1,
            start: base.add(Duration(days: 2 * i)),
            seconds: 1800 - 60 * i,
          ),
      ], 'Free');
      expect(chart, findsOneWidget);
      expect(find.text('FASTER IS TALLER · LAST 4'), findsOneWidget);
      expect(find.text('PB'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('distance-trend-caption')),
        findsOneWidget,
      );
    });

    // Index-row summaries (History reads rows, not analysis).
    RunSummary row(
      int i,
      RecordMode m, {
      required double distM,
      required int durationMs,
      int? movingMs,
      int laps = 0,
      double? medianLap,
    }) => RunSummary(
      id: 'r$i',
      mode: m,
      start: base.add(Duration(days: 2 * i)),
      durationMs: durationMs,
      distanceM: distM,
      laps: laps,
      row: IndexRow(
        lapCount: laps,
        movingMs: movingMs,
        medianLapSec: medianLap,
      ),
    );

    Future<void> openRuns(
      WidgetTester tester,
      List<RunSummary> runs,
      String tab,
    ) async {
      await pumpApp(
        tester,
        fakeServices(runs: runs),
        home: const TrendScreen(),
      );
      await pumpTimes(tester, 6);
      await tester.tap(find.text(tab));
      await pumpTimes(tester, 4);
    }

    testWidgets('Free draws moving pace, not wall-clock pace', (tester) async {
      // 5 km, 40 min on the clock but 25 min moving: 5:00/km, not 8:00.
      await openRuns(tester, [
        for (var i = 0; i < 3; i++)
          row(
            i,
            RecordMode.free,
            distM: 5000,
            durationMs: 2400000,
            movingMs: 1500000 - i * 30000,
          ),
      ], 'Free');
      expect(chart, findsOneWidget);
      expect(find.text('5:00'), findsOneWidget);
      expect(find.textContaining('pause'), findsNothing);
      // The tiles agree with the chart: nothing reads 8:00 anywhere.
      expect(find.text('8:00'), findsNothing);
    });

    testWidgets('Laps 0 and 1 comparable: no chart', (tester) async {
      await openRuns(tester, [
        row(
          0,
          RecordMode.laps,
          distM: 1600,
          durationMs: 600000,
          laps: 4,
          medianLap: 90,
        ),
        // No median: left out.
        row(1, RecordMode.laps, distM: 1600, durationMs: 600000, laps: 4),
      ], 'Laps');
      expect(find.textContaining('FASTER IS TALLER'), findsNothing);
      expect(
        find.text('Two comparable runs draw the first chart.'),
        findsOneWidget,
      );
    });

    testWidgets('Laps many: median lap chart, caption names lap distance', (
      tester,
    ) async {
      await openRuns(tester, [
        for (var i = 0; i < 4; i++)
          row(
            i,
            RecordMode.laps,
            distM: 1600,
            durationMs: 700000,
            laps: 4,
            medianLap: 95.0 - 3 * i,
          ),
      ], 'Laps');
      expect(chart, findsOneWidget);
      expect(find.text('FASTER IS TALLER · LAST 4'), findsOneWidget);
      expect(find.text('Median lap, laps of about 400 m'), findsOneWidget);
      expect(find.text('1:26'), findsWidgets);
    });

    test('comparableRuns: Laps keeps ±10% lap distance, drops null median', () {
      RunSummary lap(double distM, int laps, double? med) => RunSummary(
        id: 'l$distM$laps',
        mode: RecordMode.laps,
        start: base,
        durationMs: 600000,
        distanceM: distM,
        laps: laps,
        row: IndexRow(lapCount: laps, medianLapSec: med),
      );
      final all = [
        lap(1600, 4, 90), // 400 m laps
        lap(3200, 4, 160), // 800 m laps: not comparable
        lap(1680, 4, 92), // 420 m: within 10%
        lap(1600, 4, null), // no median: out
        lap(1600, 4, 88),
      ];
      final c = comparableRuns(all, RecordMode.laps, Units.km)!;
      expect([for (final (_, v) in c.points) v], [90, 92, 88]);
      expect(c.caption, 'Median lap, laps of about 400 m');
    });

    test('comparableRuns: Free band in the user unit, other bands dropped', () {
      RunSummary run(double distM) => RunSummary(
        id: 'r$distM',
        mode: RecordMode.free,
        start: base,
        durationMs: (distM * 0.35).round() * 1000,
        distanceM: distM,
        laps: 0,
      );
      final all = [run(2000), run(4200), run(5800)];
      final km = comparableRuns(all, RecordMode.free, Units.km)!;
      // 5.8 km rounds to 6: 5 to 7 km, so only the latest.
      expect(km.points.length, 1);
      expect(km.caption, 'Average pace, runs of 5 to 7 km only');
      final mi = comparableRuns([run(5800)], RecordMode.free, Units.mi)!;
      // 5.8 km = 3.6 mi, rounds to 3.5: 2.5 to 4.5 mi.
      expect(mi.caption, 'Average pace, runs of 2.5 to 4.5 mi only');
    });
  });

  testWidgets('noise band is centred on the previous median', (tester) async {
    final files = [
      for (var i = 0; i < 4; i++)
        fourByFourFile(
          n: i + 1,
          start: base.add(Duration(days: 3 * i)),
          workSecPerKm: 300 - 10 * i,
        ),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: const TrendScreen(),
    );
    await pumpTimes(tester, 6);
    final chart = tester.widget<RecentBarsChart>(
      find.byKey(const ValueKey('trend-chart')),
    );
    final all = await fakeServices(files: files).history.list();
    final pts = trendPoints(all.reversed.toList());
    final previous = median([
      for (final p in pts.sublist(0, 3)) p.paceSecPerKm,
    ]);
    expect(chart.noise!.center, closeTo(previous, 1e-9));
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

  group('W2 heat-adjusted series', () {
    final files = [
      for (var i = 0; i < 3; i++)
        fourByFourFile(
          n: i + 1,
          start: base.add(Duration(days: 4 * i)),
          workSecPerKm: 290,
        ),
    ];
    engine.RunSidecar hot(engine.RunFile f) => engine.RunSidecar(
      runId: f.id,
      weather: engine.WeatherRecord(
        status: engine.WeatherStatus.ok,
        fetchedAt: base,
        latR: -33.9,
        lonR: 151.2,
        tempC: 28,
        rh: 65,
        dewPointC: 21,
        adj: engine.HeatModel.of(tempC: 28, dewPointC: 21).fraction,
      ).toJson(),
    );
    // Only the newest run has weather.
    final sidecars = {files.last.id: hot(files.last)};

    test('off: raw leads, the adjusted twin is the ghost', () async {
      final all = await fakeServices(
        files: files,
        sidecars: sidecars,
      ).history.list();
      final pts = trendPoints(all.reversed.toList());
      final raw = all.first.workPaceSecPerKm!;
      final f = all.first.heatFraction!;
      expect(pts.last.paceSecPerKm, raw);
      expect(pts.last.ghostSecPerKm, closeTo(raw * (1 - f), 1e-9));
      expect(pts.first.ghostSecPerKm, isNull);
    });

    test('on: the adjusted series leads, raw is the ghost; a run without '
        'weather stays raw with no ghost', () async {
      final all = await fakeServices(
        files: files,
        sidecars: sidecars,
      ).history.list();
      final pts = trendPoints(all.reversed.toList(), heatAdjusted: true);
      final raw = all.first.workPaceSecPerKm!;
      final f = all.first.heatFraction!;
      expect(pts.last.paceSecPerKm, closeTo(raw * (1 - f), 1e-9));
      expect(pts.last.ghostSecPerKm, raw);
      expect(pts.first.paceSecPerKm, all.last.workPaceSecPerKm);
      expect(pts.first.ghostSecPerKm, isNull);
    });

    testWidgets('no weather anywhere: no legend (chart unchanged)', (
      tester,
    ) async {
      await pumpApp(
        tester,
        fakeServices(
          files: files,
          settings: const AppSettings(
            onboardingDone: true,
            compareHeatAdjusted: true,
          ),
        ),
        home: const TrendScreen(),
      );
      await pumpTimes(tester, 6);
      expect(find.byKey(const ValueKey('trend-legend')), findsNothing);
      expect(find.textContaining('HEAT-ADJUSTED'), findsNothing);
    });

    testWidgets('on, with weather: hero says heat-adjusted, legend leads '
        'with HEAT-ADJ', (tester) async {
      await pumpApp(
        tester,
        fakeServices(
          files: files,
          sidecars: sidecars,
          settings: const AppSettings(
            onboardingDone: true,
            compareHeatAdjusted: true,
          ),
        ),
        home: const TrendScreen(),
      );
      await pumpTimes(tester, 6);
      expect(find.byKey(const ValueKey('trend-legend')), findsOneWidget);
      expect(find.textContaining('HEAT-ADJUSTED'), findsOneWidget);
      final labels = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('trend-legend')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .toList();
      expect(labels, ['HEAT-ADJ', 'RAW']);
    });
  });
}
