import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/platform/gateway.dart' show LiveTarget, RecordMode;
import 'package:run_solo/platform/session_codec.dart';

import '../helpers.dart';

/// PD2: the Home ESTIMATED TIMES card (design A10.4) from the index's
/// derived data, and the Start target built into the live context.
void main() {
  engine.LiveCandidate fiveK(String id, int seconds, {DateTime? date}) {
    final e = engine.RunBestEfforts(
      efforts: {
        engine.BestEffortDistance.k5: engine.BestEffort(
          distance: engine.BestEffortDistance.k5,
          elapsedMs: seconds * 1000,
          startMs: 0,
          startOffsetM: 0,
          splitsMs: const [],
        ),
      },
      fromStartSplitsMs: const [],
    );
    return engine.LiveCandidate(
      engine.BoardInput(
        runId: id,
        date: (date ?? DateTime(2026, 9, 12, 12)).toUtc(),
        mode: engine.RunMode.free,
        efforts: e.efforts,
      ),
      engine.RunDerived(bestEfforts: e),
    );
  }

  testWidgets('rows, source line, band on tap', (tester) async {
    final semantics = tester.ensureSemantics();
    final services = fakeServices(
      live: LiveContextSource.prepared([fiveK('a', 1470)], now: now),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    expect(find.text('ESTIMATED TIMES'), findsOneWidget);
    expect(find.text('24:30'), findsOneWidget);
    expect(find.text('5K'), findsWidgets);
    expect(find.text('10K'), findsWidgets);
    expect(find.text('From your 5K on Sat 12 Sep'), findsOneWidget);
    expect(find.bySemanticsLabel('Estimated 5K 24:30'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d:\d\d to \d')), findsNothing);
    await tester.tap(find.text('ESTIMATED TIMES'));
    await pumpTimes(tester, 4);
    // The 5K from a 5K has no band (it would read "24:30 to 24:30").
    expect(find.textContaining(RegExp(r'\d:\d\d to \d')), findsOneWidget);
    expect(find.text('24:30 to 24:30'), findsNothing);
    await tester.tap(find.text('ESTIMATED TIMES'));
    await pumpTimes(tester, 4);
    expect(find.textContaining(RegExp(r'\d:\d\d to \d')), findsNothing);
    semantics.dispose();
  });

  testWidgets('no qualifying run: the empty line, no number', (tester) async {
    final services = fakeServices(
      live: LiveContextSource.prepared(const [], now: now),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    expect(
      find.text('Run 3 km or more to see your estimated times.'),
      findsOneWidget,
    );
  });

  testWidgets('no source (tests, before any prepare): no card', (tester) async {
    await pumpApp(tester, fakeServices(), home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    expect(find.text('ESTIMATED TIMES'), findsNothing);
  });

  test('the Start context carries the event target (PD2), even with no '
      'board yet', () async {
    final source = LiveContextSource.prepared([fiveK('a', 1470)], now: now);
    final ctx = await source.build(
      mode: RecordMode.intervals,
      spec: engine.SessionSpec.parkrun('parkrun').toPigeon(),
    );
    expect(ctx, isNotNull);
    expect(ctx!.boards, isEmpty);
    expect(ctx.target!.distanceM, 5000);
    expect(ctx.target!.targetMs, 1470000);
    expect(ctx.target!.predicted, isTrue);
    expect(
      source.targetFor(engine.SessionSpec.parkrun('parkrun').toPigeon())!.line,
      'Target 24:30 (predicted)',
    );
  });
  test('the Start target tapped to its other choice is the one raced '
      '(A10.10)', () async {
    // A fresh course PB (official 24:12) leads; the prediction from the
    // GPS 5K (25:00) is the other choice.
    final pb = engine.LiveCandidate(
      engine.BoardInput(
        runId: 'pb',
        date: DateTime(2026, 9, 19, 8).toUtc(),
        mode: engine.RunMode.intervals,
        comparisonKey: 'parkrun:albert',
        efforts: fiveK('x', 1500).input.efforts,
        officialTimeMs: 1452000,
      ),
      fiveK('x', 1500).derived,
    );
    final source = LiveContextSource.prepared([pb], now: now);
    final spec = engine.SessionSpec.parkrun('parkrun').toPigeon();
    Future<LiveTarget?> raced({bool alt = false}) async => (await source.build(
      mode: RecordMode.intervals,
      spec: spec,
      courseKey: 'parkrun:albert',
      preferAlternative: alt,
    ))!.target;
    final shown = await raced();
    expect(shown!.targetMs, 1452000);
    expect(shown.predicted, isFalse);
    final other = await raced(alt: true);
    expect(other!.targetMs, 1500000);
    expect(other.predicted, isTrue);
    // No other choice (no course PB): the flag changes nothing.
    final alone = LiveContextSource.prepared([fiveK('a', 1470)], now: now);
    final ctx = await alone.build(
      mode: RecordMode.intervals,
      spec: spec,
      preferAlternative: true,
    );
    expect(ctx!.target!.targetMs, 1470000);
  });
}
