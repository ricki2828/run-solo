import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/state/settings.dart';

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
    expect(find.text('NORWEGIAN 4X4 · 1 SESSION'), findsOneWidget);
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
