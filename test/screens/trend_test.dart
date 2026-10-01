import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
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

    testWidgets('Laps 0 and 1 run: no chart', (tester) async {
      await open(tester, [lapsRunFile(n: 1, start: base)], 'Laps');
      expect(find.textContaining('FASTER IS TALLER'), findsNothing);
      expect(
        find.text('Two comparable runs draw the first chart.'),
        findsOneWidget,
      );
    });

    testWidgets('Laps many: chart names the lap distance', (tester) async {
      await open(tester, [
        for (var i = 0; i < 3; i++)
          lapsRunFile(
            n: i + 1,
            start: base.add(Duration(days: 2 * i)),
          ),
      ], 'Laps');
      expect(chart, findsOneWidget);
      expect(
        find.textContaining('Average lap pace, laps of about'),
        findsOneWidget,
      );
    });

    test('comparableRuns: fewer than 3 laps excluded, mi bands in miles', () {
      RunSummary run(RecordMode m, int laps, double distM) => RunSummary(
        id: 'r$laps$distM',
        mode: m,
        start: base,
        durationMs: (distM * 0.35).round() * 1000,
        distanceM: distM,
        laps: laps,
      );
      expect(
        comparableRuns(
          [run(RecordMode.laps, 2, 800)],
          RecordMode.laps,
          Units.km,
        ),
        isNull,
      );
      final mixed = [
        run(RecordMode.laps, 2, 800),
        run(RecordMode.laps, 4, 1600),
      ];
      expect(comparableRuns(mixed, RecordMode.laps, Units.km)!.runs.length, 1);
      final mi = comparableRuns(
        [run(RecordMode.free, 0, 5800)],
        RecordMode.free,
        Units.mi,
      )!;
      // 5.8 km = 3.6 mi, rounds to 3.5: 2.5 to 4.5 mi.
      expect(mi.caption, 'Average pace, runs of 2.5 to 4.5 mi only');
    });

    test(
      'comparableRuns drops runs with another lap distance / band',
      () async {
        final all = await fakeServices(
          files: [
            lapsRunFile(n: 1, start: base),
            freeRunFile(n: 2, start: base.add(const Duration(days: 1))),
            lapsRunFile(n: 3, start: base.add(const Duration(days: 2))),
          ],
        ).history.list();
        final chrono = all.reversed.toList();
        final laps = [
          for (final r in chrono)
            if (r.mode == RecordMode.laps) r,
        ];
        expect(comparableRuns(laps, RecordMode.laps, Units.km)!.runs.length, 2);
        // A run with twice the lap distance is not comparable.
        final odd = RunSummary(
          id: 'x',
          mode: RecordMode.laps,
          start: base.add(const Duration(days: 9)),
          durationMs: laps.last.durationMs,
          distanceM: laps.last.distanceM * 2,
          laps: laps.last.laps,
        );
        final c = comparableRuns([...laps, odd], RecordMode.laps, Units.km)!;
        expect(c.runs, [odd]);
      },
    );
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
