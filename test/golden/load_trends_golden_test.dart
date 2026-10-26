import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/load_trends.dart';
import 'package:run_solo/screens/trend_screen.dart';

import '../helpers.dart';

/// History > Trends > Load, in every view and early state, at 360 x 640 and
/// 360 x 800. PNGs come from CI like every golden.
engine.WeekLoad _week(
  DateTime monday,
  double load, {
  bool current = false,
  bool noHr = false,
  bool before = false,
}) {
  if (before) return engine.WeekLoad(monday: monday, beforeStart: true);
  return engine.WeekLoad(
    monday: monday,
    load: load,
    km: load / 12,
    minutes: load / 2.2,
    hardMinutes: 30,
    runs: current ? 2 : 4,
    longestKm: 12,
    hrRuns: noHr ? 0 : 3,
    zoneShare: noHr ? const [0, 0, 0, 0, 0] : const [.1, .45, .3, .12, .03],
    noHrShare: noHr ? 1 : 0,
    basisShare: {
      noHr ? engine.LoadBasis.pace : engine.LoadBasis.heartRate: 1.0,
    },
    current: current,
  );
}

/// Eight weeks, the last one (Mon 26 Oct) still being run.
List<engine.WeekLoad> _weeks() {
  final first = DateTime(2026, 9, 7);
  const loads = <double>[300, 330, 340, 350, 356, 350, 420, 180];
  return [
    for (var i = 0; i < 8; i++)
      _week(
        DateTime(first.year, first.month, first.day + 7 * i),
        loads[i],
        current: i == 7,
        noHr: i == 1,
      ),
  ];
}

List<engine.PeriodLoad> _months() {
  const loads = <double>[700, 1100, 1250, 1300, 1500, 1180];
  return [
    for (var i = 0; i < 6; i++)
      engine.PeriodLoad(
        start: DateTime(2026, 5 + i),
        load: loads[i],
        km: loads[i] / 12,
        minutes: loads[i] / 2.2,
        runs: 14,
        current: i == 5,
      ),
  ];
}

engine.YearLoad _year({required bool lastYear}) {
  const loads = <double>[
    0,
    0,
    500,
    900,
    700,
    1100,
    1250,
    1300,
    1500,
    1180,
    0,
    0,
  ];
  final months = [
    for (var m = 0; m < 12; m++)
      engine.PeriodLoad(
        start: DateTime(2026, m + 1),
        load: loads[m],
        km: loads[m] / 12,
        minutes: loads[m] / 2.2,
        runs: loads[m] > 0 ? 14 : 0,
        current: m == 9,
        future: m > 9,
        beforeStart: m < 2,
      ),
  ];
  return engine.YearLoad(
    months: months,
    km: months.fold(0.0, (a, p) => a + p.km),
    runs: months.fold(0, (a, p) => a + p.runs),
    minutes: months.fold(0.0, (a, p) => a + p.minutes),
    lastYearKm: lastYear ? 640 : 0,
    lastYearRuns: lastYear ? 70 : 0,
  );
}

LoadTrendsData _data({List<engine.WeekLoad>? weeks, bool lastYear = false}) =>
    LoadTrendsData(
      weeks: weeks ?? _weeks(),
      months: _months(),
      year: _year(lastYear: lastYear),
      hasRuns: true,
    );

void main() {
  Future<void> shot(WidgetTester tester, String name, int h) async {
    tester.view.physicalSize = Size(1080, h * 3.0);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump(const Duration(milliseconds: 100));
    await settleAnimations(tester);
    expect(tester.takeException(), isNull);
    final file = File('test/golden/goldens/$name.png');
    expect(
      file.existsSync() || autoUpdateGoldenFiles,
      isTrue,
      reason: 'golden $name.png missing: commit it from the CI goldens',
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  final cases = <String, (LoadTrendsData?, String?)>{
    'trends_load_week': (_data(), null),
    // Two full weeks with runs and the part week: still no usual week.
    'trends_load_week_early': (
      _data(
        weeks: [
          for (var i = 0; i < 8; i++)
            i < 5
                ? _week(DateTime(2026, 9, 7 + 7 * i), 0, before: true)
                : _week(
                    DateTime(2026, 9, 7 + 7 * i),
                    i == 7 ? 150 : 300.0 + 20 * i,
                    current: i == 7,
                  ),
        ],
      ),
      null,
    ),
    'trends_load_month': (_data(), 'load-view-month'),
    'trends_load_year': (_data(), 'load-view-year'),
    'trends_load_year_vs_last': (_data(lastYear: true), 'load-view-year'),
    'trends_load_empty': (null, null),
  };

  for (final h in [640, 800]) {
    for (final e in cases.entries) {
      testWidgets('${e.key} 360x$h', (tester) async {
        await pumpApp(
          tester,
          fakeServices(),
          home: TrendScreen(loadData: e.value.$1),
        );
        await tester.pump();
        await tester.pump();
        if (e.value.$2 != null) {
          await tester.tap(find.byKey(ValueKey(e.value.$2!)));
          await tester.pump();
        }
        await shot(tester, '${e.key}_360x$h', h);
      });
    }
  }

  testWidgets('Load is the default chip; the tiles follow the view', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: TrendScreen(loadData: _data(lastYear: true)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('load-bars')), findsOneWidget);
    expect(find.text('180'), findsOneWidget);
    expect(find.text('LOAD SO FAR'), findsOneWidget);
    expect(find.text('USUAL WEEK'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('load-view-month')));
    await tester.pump();
    expect(find.text('TIME'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-month-line')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('load-view-year')));
    await tester.pump();
    expect(find.byKey(const ValueKey('load-year-line')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trends-intervals')));
    await tester.pump();
    expect(find.byKey(const ValueKey('load-bars')), findsNothing);
  });

  testWidgets(
    'the part week is shown but never judged; under 3 weeks says so',
    (tester) async {
      await pumpApp(
        tester,
        fakeServices(),
        home: TrendScreen(
          loadData: _data(
            weeks: [
              for (var i = 0; i < 8; i++)
                i < 5
                    ? _week(DateTime(2026, 9, 7 + 7 * i), 0, before: true)
                    : _week(
                        DateTime(2026, 9, 7 + 7 * i),
                        i == 7 ? 150 : 300.0 + 20 * i,
                        current: i == 7,
                      ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Usual week after 3 weeks.'), findsOneWidget);
      expect(find.text('SO FAR'), findsOneWidget);
      expect(find.byKey(const ValueKey('load-usual-line')), findsNothing);
    },
  );

  testWidgets('an experienced runner mid-week sees the figure, no band, no '
      'first-weeks text', (tester) async {
    await pumpApp(tester, fakeServices(), home: TrendScreen(loadData: _data()));
    await tester.pump();
    await tester.pump();
    // Part week 180 so far against a usual 369: plain numbers only.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('load-tile-1')),
        matching: find.text('369'),
      ),
      findsOneWidget,
    );
    expect(find.text('Usual week after 3 weeks.'), findsNothing);
    expect(find.textContaining('usual week'), findsNothing);
    expect(find.textContaining('takes shape'), findsNothing);
    expect(find.text('SO FAR'), findsOneWidget);
  });

  testWidgets('no runs: the empty state, no tiles', (tester) async {
    await pumpApp(tester, fakeServices(), home: const TrendScreen());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('load-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('load-tile-0')), findsNothing);
  });
}
