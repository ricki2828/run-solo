import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/platform/gateway.dart' show RecordMode;
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
    expect(find.textContaining(RegExp(r'\d:\d\d to \d')), findsNWidgets(2));
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
}
