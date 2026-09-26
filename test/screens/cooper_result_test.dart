import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/cooper_result_screen.dart';
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/widgets/rank_chip.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// C1: the 12-minute test result (A5, A10.5) and its trend.
void main() {
  final d1 = DateTime.utc(2026, 6, 10, 6);
  final d2 = DateTime.utc(2026, 7, 15, 6);
  final d3 = DateTime.utc(2026, 9, 20, 6);

  Future<void> openResult(
    WidgetTester tester,
    List<engine.RunFile> files,
    String id, {
    Map<String, engine.RunSidecar> sidecars = const {},
    bool justFinished = false,
  }) async {
    await pumpApp(
      tester,
      fakeServices(files: files, sidecars: sidecars),
      pushRoute: justFinished ? Routes.verdictJustFinished : Routes.verdict,
      pushArguments: id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CooperResultScreen), findsOneWidget);
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('first test: distance, VO2 estimate with its range, first '
      'on the board, typical curve, the method', (tester) async {
    final r = cooperTestFile(n: 1, start: d3);
    await openResult(tester, [r], r.id);
    expect(text(tester, 'cooper-distance'), '2 880 m');
    expect(find.text('VO2 MAX ESTIMATE'), findsOneWidget);
    expect(text(tester, 'cooper-vo2'), '53');
    expect(find.text('(47 to 59)'), findsOneWidget);
    expect(find.text('ml/kg/min'), findsOneWidget);
    // The big number reads as the labelled estimate (WARN-4).
    expect(find.bySemanticsLabel('VO2 estimate 53 (47 to 59)'), findsOneWidget);
    expect(find.text('First test on your board'), findsOneWidget);
    expect(find.byKey(const ValueKey('pb-chip')), findsNothing);
    expect(find.byKey(const ValueKey('cooper-change')), findsNothing);
    expect(find.byKey(const ValueKey('pace-strip')), findsOneWidget);
    expect(find.text('vs typical curve (research-based)'), findsOneWidget);
    expect(find.text('Estimate. Not a medical measurement.'), findsOneWidget);
    expect(find.textContaining('PEOPLE YOUR AGE'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('cooper-method')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Cooper's 1968 formula"), findsOneWidget);
  });

  testWidgets('third test, a new best: Arc PB chip, change since the last '
      'test, the usual curve', (tester) async {
    final a = cooperTestFile(n: 1, start: d1, mps: 3.8);
    final b = cooperTestFile(n: 2, start: d2, mps: 3.9);
    final c = cooperTestFile(n: 3, start: d3, mps: 4.1);
    await openResult(tester, [a, b, c], c.id, justFinished: true);
    // The test board's chip first (A10.3: its own board leads).
    final chip = tester.widgetList<RankChip>(find.byType(RankChip)).first;
    expect(chip.pb, isTrue);
    expect(chip.label, startsWith('New best test · VO2 est. '));
    expect(
      text(tester, 'cooper-change'),
      startsWith('VO2 est. +'),
      reason: 'against the test before, in July',
    );
    expect(text(tester, 'cooper-change'), endsWith(' since July'));
    expect(find.text('vs your usual'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // M5 plays out
  });

  testWidgets('a slower second test ranks #2 of 2', (tester) async {
    final a = cooperTestFile(n: 1, start: d1, mps: 4.1);
    final b = cooperTestFile(n: 2, start: d2, mps: 3.9);
    await openResult(tester, [a, b], b.id);
    expect(
      find.textContaining('#2 of 2 tests · VO2 est. '),
      findsOneWidget,
      reason: 'the shared board fold (LB3)',
    );
    // The ghost stays the typical curve until test 3 (curveFor switches
    // after two valid tests).
    expect(find.text('vs typical curve (research-based)'), findsOneWidget);
    expect(find.text('vs your usual'), findsNothing);
    expect(
      find.byKey(const ValueKey('cooper-change')),
      findsNothing,
      reason: 'needs two prior tests',
    );
  });

  testWidgets('paused: the distance, why, and no VO2, chip or strip', (
    tester,
  ) async {
    final r = cooperTestFile(n: 1, start: d3, pausedAtS: 400);
    await openResult(tester, [r], r.id);
    expect(find.byKey(const ValueKey('cooper-vo2')), findsNothing);
    expect(
      text(tester, 'cooper-invalid'),
      'Paused during the test, so there is no estimate.',
    );
    expect(find.byType(RankChip), findsNothing);
    expect(find.byKey(const ValueKey('pace-strip')), findsNothing);
  });

  testWidgets('warm hour: the heat line under the raw estimate, ⓘ caveat', (
    tester,
  ) async {
    final r = cooperTestFile(n: 1, start: d3);
    await openResult(
      tester,
      [r],
      r.id,
      sidecars: {
        r.id: engine.RunSidecar(
          runId: r.id,
          weather: const engine.WeatherRecord(
            status: engine.WeatherStatus.ok,
            tempC: 28,
            rh: 60,
            dewPointC: 21,
          ).toJson(),
        ),
      },
    );
    expect(text(tester, 'cooper-vo2'), '53', reason: 'raw stays the headline');
    final heat = text(tester, 'cooper-heat');
    expect(heat, startsWith('Heat-adjusted estimate '));
    expect(engine.carriesEstimateMarker(heat), isTrue);
    expect(find.text(engine.CooperHeat.disclosure), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cooper-heat-info')));
    await tester.pumpAndSettle();
    expect(find.text(engine.CooperHeat.caveat), findsOneWidget);
    expect(find.textContaining('Open-Meteo.com'), findsOneWidget);
  });

  testWidgets('trend: past scores as estimates; empty says take the test', (
    tester,
  ) async {
    final a = cooperTestFile(n: 1, start: d1, mps: 3.8);
    final b = cooperTestFile(n: 2, start: d2, mps: 4.0);
    await pumpApp(
      tester,
      fakeServices(files: [a, b]),
      home: const TrendScreen(),
    );
    await pumpTimes(tester, 6);
    await tester.tap(find.text('Test'));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('cooper-trend-chart')), findsOneWidget);
    expect(find.textContaining('VO2 estimate '), findsNWidgets(2));

    await pumpApp(tester, fakeServices(), home: const TrendScreen());
    await pumpTimes(tester, 6);
    await tester.tap(find.text('Test'));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('cooper-trend-empty')), findsOneWidget);
  });
}
