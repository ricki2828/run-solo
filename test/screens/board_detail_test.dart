import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/board_detail_screen.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The board detail (LB3d, mockup frames 2-8): hero, trend, podium,
/// recent-runs chart, the ALL table, and the A11.4 PB moment with its
/// "PB seen" state.
void main() {
  final july = DateTime.utc(2026, 7, 15, 6);

  /// Five parkruns a week apart, each quicker, the newest yesterday (so
  /// its best is inside the overview's 14-day NEW window): a 5K board
  /// with a trend (4+ entries in 90 days) and a course board.
  List<engine.RunFile> fiveParkruns() => [
    for (var i = 0; i < 5; i++)
      eventRunFile(
        n: i + 1,
        start: DateTime.utc(2026, 8, 26, 6).add(Duration(days: 7 * i)),
        eventName: 'parkrun',
        mps: 3.0 + 0.1 * i,
      ),
  ];

  Future<void> pumpDetail(
    WidgetTester tester,
    List<engine.RunFile> files, {
    Map<String, engine.RunSidecar> sidecars = const {},
  }) async {
    await pumpApp(
      tester,
      fakeServices(files: files, sidecars: sidecars),
      home: const BoardDetailScreen(boardKey: 'be:5000'),
    );
    await pumpTimes(tester, 6);
    // The detail is one long scroll: grow the viewport to see it all.
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    // Let the PB-moment replay finish and mark the board seen.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
  }

  testWidgets('5K: hero, provenance, trend, podium and the ALL table', (
    tester,
  ) async {
    await pumpDetail(tester, fiveParkruns());
    expect(find.text('5K · 5 RUNS'), findsOneWidget);
    expect(find.byKey(const ValueKey('board-hero')), findsOneWidget);
    expect(find.textContaining('Your best · '), findsOneWidget);
    // The best effort's own window offsets (A11.6).
    expect(find.textContaining('From'), findsOneWidget);
    expect(find.textContaining('of a'), findsOneWidget);
    // Improving times: the trend reads quicker, in words.
    expect(find.textContaining('quicker a month'), findsOneWidget);
    // The ALL table carries the gaps.
    expect(find.textContaining('+'), findsWidgets);
    // The table: header, rank, gap, date and the no-weather tag (the
    // fixtures carry no weather, so nothing is estimated).
    expect(find.text('ALL'), findsOneWidget);
    expect(find.text('TIME'), findsOneWidget);
    expect(find.text('GAP'), findsOneWidget);
    expect(find.textContaining('HEAT-ADJ'), findsOneWidget);
    expect(find.text('no weather'), findsWidgets);
  });

  testWidgets('the PB moment plays once, then the board is seen', (
    tester,
  ) async {
    final services = fakeServices(files: fiveParkruns());
    await pumpApp(tester, services, home: const HistoryScreen());
    await pumpTimes(tester, 6);
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    // A fresh best the runner has not opened carries NEW.
    expect(find.text('NEW'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('board-card-be:5000')));
    await pumpTimes(tester, 8);
    expect(find.byKey(const ValueKey('board-detail')), findsOneWidget);
    // The quiet replay: the gain line shows for this visit only.
    expect(find.byKey(const ValueKey('board-gain')), findsOneWidget);
    expect(find.textContaining('quicker than your old best'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(services.settings.settings.pbSeen['be:5000'], isNotNull);
    // Back on the overview the board's NEW tag has cleared (A11.4); the
    // other boards keep theirs until they are opened.
    await tester.tap(find.byKey(const ValueKey('board-detail-back')));
    await pumpTimes(tester, 6);
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('board-card-be:5000')),
        matching: find.text('NEW'),
      ),
      findsNothing,
    );
    // A second visit opens straight at the end state: no gain line.
    await tester.tap(find.byKey(const ValueKey('board-card-be:5000')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('board-gain')), findsNothing);
  });

  testWidgets('one run: the first on the board, nothing to compare', (
    tester,
  ) async {
    await pumpDetail(tester, [
      freeRunFile(n: 1, start: july, seconds: 40 * 60),
    ]);
    expect(find.textContaining('Your first 5K on the board'), findsOneWidget);
    expect(find.text('The next 5K races this one'), findsOneWidget);
    // One run is not a chart: a designed empty state instead.
    expect(find.byKey(const ValueKey('board-chart-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('board-chart')), findsNothing);
  });

  testWidgets('the 12-minute test board reads in VO2', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        files: [
          cooperTestFile(n: 1, start: july, mps: 3.8),
          cooperTestFile(
            n: 2,
            start: july.add(const Duration(days: 21)),
            mps: 4.0,
          ),
        ],
      ),
      home: const BoardDetailScreen(boardKey: 'cooper'),
    );
    await pumpTimes(tester, 6);
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('12-MIN TEST · 2 TESTS'), findsOneWidget);
    expect(find.text('VO2 est.'), findsWidgets);
    expect(find.textContaining('Your best estimate · '), findsOneWidget);
    expect(find.textContaining('in 12 minutes'), findsOneWidget);
    expect(find.text('VO2 est.'), findsWidgets);
    expect(find.textContaining('HEAT-ADJ EST.'), findsOneWidget);
  });

  testWidgets('an interval board reads in pace, counted in sessions', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(
        files: [
          for (var i = 0; i < 2; i++)
            fourByFourFile(
              n: i + 1,
              start: july.add(Duration(days: 10 * i)),
              workSecPerKm: 300 - 10 * i,
            ),
        ],
      ),
      home: const BoardDetailScreen(
        boardKey: engine.ComparisonKey.norwegian4x4,
      ),
    );
    await pumpTimes(tester, 6);
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('NORWEGIAN 4X4 · 2 SESSIONS'), findsOneWidget);
    expect(find.text('PACE'), findsOneWidget);
    expect(find.text('Not enough sessions yet for a trend'), findsOneWidget);
  });

  testWidgets('a row opens its run; the legend toggles the heat layer', (
    tester,
  ) async {
    final files = fiveParkruns();
    await pumpDetail(tester, files);
    await tester.tap(find.byKey(const ValueKey('board-legend')));
    await tester.pump();
    // The heat layer lists its two marks while it shows.
    expect(find.text('heat-adjusted estimate'), findsOneWidget);
    expect(find.text('no weather'), findsWidgets);
    await tester.tap(find.byKey(ValueKey('board-row-${files.last.id}')));
    await pumpTimes(tester, 8);
    expect(find.byType(RunDetailScreen), findsOneWidget);
  });

  testWidgets('a course board with an official time says so', (tester) async {
    final files = fiveParkruns();
    final best = files.last;
    // Close to the run's GPS 5K, or the engine reads it as a typo (K1).
    final sidecar = engine.RunSidecar(runId: best.id)
        .withParkrun(const engine.ParkrunInfo(officialTimeSeconds: 1465));
    final services = fakeServices(files: files, sidecars: {best.id: sidecar});
    final boards = await services.history.boards();
    final courseKey = boards.byKey.keys.firstWhere(
      (k) => k.startsWith('parkrun:'),
    );
    await pumpApp(
      tester,
      services,
      home: BoardDetailScreen(boardKey: courseKey),
    );
    await pumpTimes(tester, 6);
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Official time'), findsOneWidget);
    expect(find.text('official'), findsWidgets);
  });
}
