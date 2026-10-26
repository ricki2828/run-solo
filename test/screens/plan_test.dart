import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/plan_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/theme/lanes.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';

RunSummary fourRun(String id, DateTime start) => RunSummary(
  id: id,
  mode: RecordMode.intervals,
  start: start,
  durationMs: 2400000,
  distanceM: 6000,
  laps: 4,
  row: const IndexRow(lapCount: 4, movingMs: 2400000),
);

engine.BlockPlan planAt(DateTime start, {int n = 3}) =>
    engine.BlockPlanner.build(
      lane: engine.IdentityLane.aerobic,
      perWeek: n,
      start: start,
    );

void main() {
  testWidgets('no plan: choose a lane and runs a week, then build', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: PlanScreen(now: now));
    expect(find.text('BUILD YOUR 4 WEEKS'), findsOneWidget);
    // No scores yet: the lane Home would recommend (AEROBIC) is preselected.
    Color? fillOf(String lane) {
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(ValueKey('plan-lane-$lane')),
              matching: find.byType(Container),
            )
            .first,
      );
      return (box.decoration! as BoxDecoration).color;
    }

    final t = Theme.of(tester.element(find.byType(PlanScreen)))
        .extension<RunSoloTokens>()!;
    // Selected = filled in the lane's own colour; the others stay raised.
    expect(fillOf('aerobic'), t.laneFill(engine.IdentityLane.aerobic));
    expect(fillOf('long'), t.bgRaised);
    // Hit boxes for RUNS A WEEK -/+ are at least 48 dp.
    for (final k in ['plan-fewer', 'plan-more']) {
      final size = tester.getSize(find.byKey(ValueKey(k)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.byKey(const ValueKey('plan-lane-long')));
    await tester.pump();
    expect(fillOf('long'), t.laneFill(engine.IdentityLane.long));
    expect(fillOf('aerobic'), t.bgRaised);
    await tester.tap(find.byKey(const ValueKey('plan-more')));
    await tester.tap(find.byKey(const ValueKey('plan-more')));
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan-build')));
    await pumpTimes(tester, 4);
    final plan = services.plans.plan!;
    expect(plan.lane, engine.IdentityLane.long);
    expect(plan.perWeek, 5);
    expect(find.text('LONG BLOCK'), findsOneWidget);
    expect(find.text('WEEK 4'), findsOneWidget);
  });

  testWidgets('runs a week stays between 2 and 6', (tester) async {
    await pumpApp(tester, fakeServices(), home: PlanScreen(now: now));
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const ValueKey('plan-fewer')));
      await tester.pump();
    }
    expect(find.text('2'), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byKey(const ValueKey('plan-more')));
      await tester.pump();
    }
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('lists 4 weeks with done, next and a reason on every row', (
    tester,
  ) async {
    // Monday of this week: weeks run Monday to Sunday.
    final start = DateTime(2026, 9, 21);
    final services = fakeServices(
      plan: planAt(start),
      runs: [fourRun('a', DateTime(2026, 9, 23, 7))],
    );
    await pumpApp(tester, services, home: PlanScreen(now: now));
    expect(find.text('21 Sep to 27 Sep'), findsOneWidget);
    expect(find.text('AEROBIC BLOCK'), findsOneWidget);
    expect(find.textContaining('Week 1 of 4 · 1 of 12 done'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('TEST WEEK'), findsOneWidget);
    expect(find.text('LIGHTER WEEK'), findsNothing);
  });

  testWidgets('a missed session reads as missed, not added on top', (
    tester,
  ) async {
    final start = DateTime(2026, 9, 14);
    final services = fakeServices(
      plan: planAt(start),
      runs: [fourRun('a', DateTime(2026, 9, 14, 7))],
    );
    await pumpApp(tester, services, home: PlanScreen(now: now));
    expect(find.text('MISSED'), findsNWidgets(2));
    expect(find.textContaining('not added on top'), findsNWidgets(2));
  });

  testWidgets('swap a session for another and the plan keeps it', (
    tester,
  ) async {
    final services = fakeServices(plan: planAt(testNow));
    await pumpApp(tester, services, home: PlanScreen(now: now));
    await tester.tap(find.byKey(const ValueKey('plan-row-w1s1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('SWAP'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining('Tempo intervals'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(services.plans.plan!.sessions.first.presetId, 'tempo');
    expect(services.plans.plan!.sessions.first.swapped, isTrue);
    expect(find.textContaining('You swapped this in.'), findsOneWidget);
  });

  testWidgets('the test session has no swap', (tester) async {
    final services = fakeServices(plan: planAt(testNow));
    await pumpApp(tester, services, home: PlanScreen(now: now));
    final test = services.plans.plan!.sessions.firstWhere((s) => s.isTest);
    expect(find.byKey(ValueKey('plan-row-${test.id}')), findsNothing);
  });

  testWidgets('end plan asks first, keeps it on Keep, drops it on End', (
    tester,
  ) async {
    final services = fakeServices(plan: planAt(testNow));
    await pumpApp(tester, services, home: PlanScreen(now: now));
    final end = find.byKey(const ValueKey('plan-end'));
    await tester.scrollUntilVisible(end, 300);
    await tester.tap(end);
    await pumpTimes(tester, 4);
    expect(find.text('Your runs stay. Only the plan goes.'), findsOneWidget);
    await tester.tap(find.text('Keep plan'));
    await pumpTimes(tester, 4);
    expect(services.plans.plan, isNotNull);
    await tester.tap(end);
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('plan-end-confirm')));
    await pumpTimes(tester, 4);
    expect(services.plans.plan, isNull);
    expect(find.text('BUILD YOUR 4 WEEKS'), findsOneWidget);
  });

  testWidgets('a finished block offers the next one', (tester) async {
    final services = fakeServices(plan: planAt(DateTime(2026, 7, 27)));
    await pumpApp(tester, services, home: PlanScreen(now: now));
    expect(find.textContaining('Done: 0 of 12'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan-build-next')));
    await pumpTimes(tester, 4);
    expect(find.text('BUILD YOUR 4 WEEKS'), findsOneWidget);
  });
}
