import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/target_pace.dart';
import 'package:run_solo/state/zone_histogram.dart';
import 'package:run_solo/widgets/pace_nudge_line.dart';

import '../helpers.dart';

/// The nudge on Home: shown only on evidence, applied only on a tap, and
/// honest when the save fails.
final engine.TargetPaces testPaces = engine.TargetPaces.fromVdot(40)!;
double get easyTarget => testPaces[engine.PaceIntensity.easy]!.trueSecPerKm;

/// Four easy runs over three weeks, each [secQuicker] under the target.
List<RunSummary> easyRuns({double secQuicker = 15}) => [
  for (final (i, back) in [2, 9, 15, 22].indexed)
    RunSummary(
      id: 'e$i',
      mode: RecordMode.free,
      start: DateTime(testNow.year, testNow.month, testNow.day - back, 12),
      durationMs: 40 * 60 * 1000,
      distanceM: 7000,
      laps: 1,
      row: IndexRow(lapCount: 1, truePaceSecPerKm: easyTarget - secQuicker),
      hrHist: HrHist(110, [2000, for (var i = 0; i < 39; i++) 0, 400]),
    ),
];

Widget host(List<RunSummary> runs) => Scaffold(
  body: Padding(
    padding: const EdgeInsets.all(16),
    child: PaceNudgeLine(runs: runs, now: testNow, pacesOverride: testPaces),
  ),
);

void main() {
  testWidgets('shows the nudge and changes nothing until Yes', (tester) async {
    final services = fakeServices(runs: easyRuns());
    await pumpApp(tester, services, home: host(easyRuns()));
    await pumpTimes(tester, 3);
    expect(find.byKey(const ValueKey('pace-nudge-text')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('pace-nudge-text'))).data,
      contains('easy pace looks quicker now'),
    );
    expect(services.targetPaces.adopted, isEmpty);

    await tester.tap(find.byKey(const ValueKey('pace-nudge-yes')));
    await pumpTimes(tester, 3);
    expect(services.targetPaces.adopted[engine.PaceIntensity.easy], isNotNull);
    expect(find.textContaining('Easy pace is now'), findsOneWidget);
  });

  testWidgets('Keep leaves the target and the line goes away', (tester) async {
    final services = fakeServices(runs: easyRuns());
    await pumpApp(tester, services, home: host(easyRuns()));
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('pace-nudge-keep')));
    await pumpTimes(tester, 3);
    expect(services.targetPaces.adopted, isEmpty);
    expect(find.byKey(const ValueKey('pace-nudge')), findsNothing);
  });

  testWidgets('no evidence, no line', (tester) async {
    final services = fakeServices(runs: easyRuns(secQuicker: 0));
    await pumpApp(tester, services, home: host(easyRuns(secQuicker: 0)));
    await pumpTimes(tester, 3);
    expect(find.byKey(const ValueKey('pace-nudge')), findsNothing);
  });

  testWidgets('a failed save says so and the pace stays', (tester) async {
    final services = fakeServices(
      runs: easyRuns(),
      targetPaces: TargetPaceController(_FailingStore()),
    );
    await pumpApp(tester, services, home: host(easyRuns()));
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('pace-nudge-yes')));
    await pumpTimes(tester, 3);
    expect(services.targetPaces.adopted, isEmpty);
    expect(find.textContaining('Could not save that'), findsOneWidget);
  });
}

class _FailingStore implements TargetPaceStore {
  @override
  Future<TargetPaceState> load() async => TargetPaceState.empty;

  @override
  Future<void> save(TargetPaceState state) async =>
      throw StateError('disk full');
}
