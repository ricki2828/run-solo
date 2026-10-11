import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/plan_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

RunSummary freeRun(String id, int daysAgo, {int min = 40, double km = 6.5}) =>
    RunSummary(
      id: id,
      mode: RecordMode.free,
      start: DateTime(testNow.year, testNow.month, testNow.day - daysAgo, 7),
      durationMs: min * 60000,
      distanceM: km * 1000,
      laps: 0,
      row: IndexRow(lapCount: 0, movingMs: min * 60000),
    );

/// Three steady weeks, then a hot one: 7 runs of 60 minutes in 7 days.
List<RunSummary> hotWeek() => [
  for (final d in [27, 25, 23, 20, 18, 16, 13, 11, 9]) freeRun('s$d', d),
  for (final d in [6, 5, 4, 3, 2, 1, 0]) freeRun('h$d', d, min: 60, km: 10),
];

List<RunSummary> usualWeek() => [
  for (final d in [27, 25, 23, 20, 18, 16, 13, 11, 9, 6, 4, 2])
    freeRun('s$d', d),
];

const message = 'An easy run today is the safer choice.';

void main() {
  testWidgets('a hot week warns on Home in plain words', (tester) async {
    await pumpApp(
      tester,
      fakeServices(runs: hotWeek()),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsOneWidget);
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('load-message')),
    );
    expect(
      text.data,
      matches(
        RegExp(
          r'^This week is (\d+% more than usual|about [\d.]+ times your usual|about double your usual)\. ',
        ),
      ),
    );
    expect(text.data, endsWith(message));
    expect(text.data, isNot(contains('—')));
  });

  testWidgets(
    'while warned, Start is the easy run and the hard one is a link',
    (tester) async {
      await pumpApp(
        tester,
        fakeServices(runs: hotWeek()),
        home: HomeScreen(now: now),
      );
      await pumpTimes(tester, 6);
      expect(find.text('Easy run ›'), findsOneWidget);
      expect(find.text('Norwegian 4x4 ›'), findsNothing);
      final anyway = find.byKey(const ValueKey('home-do-anyway'));
      expect(anyway, findsOneWidget);
      expect(tester.getSize(anyway).height, greaterThanOrEqualTo(48));
      expect(find.textContaining('anyway'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('load-dismiss')));
      await pumpTimes(tester, 6);
      expect(find.text('Norwegian 4x4 ›'), findsOneWidget);
      expect(find.text('Easy run ›'), findsNothing);
      expect(anyway, findsNothing);
    },
  );

  testWidgets('a usual week shows nothing', (tester) async {
    await pumpApp(
      tester,
      fakeServices(runs: usualWeek()),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsNothing);
  });

  testWidgets('a new runner with little history is not warned', (tester) async {
    await pumpApp(
      tester,
      fakeServices(runs: [freeRun('a', 1, min: 90), freeRun('b', 0, min: 90)]),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsNothing);
  });

  testWidgets('the warning never blocks Start', (tester) async {
    final services = fakeServices(runs: hotWeek());
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsOneWidget);
    final start = find.byType(FilledButton);
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
  });

  testWidgets('Why? states the rules, labelled research-based', (tester) async {
    await pumpApp(
      tester,
      fakeServices(runs: hotWeek()),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 6);
    await tester.tap(find.byKey(const ValueKey('load-why')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('more than 30% above'), findsOneWidget);
    expect(find.textContaining('more than 25% above'), findsOneWidget);
    expect(find.textContaining('research'), findsOneWidget);
  });

  testWidgets('dismiss hides it for the rest of the week', (tester) async {
    final services = fakeServices(runs: hotWeek());
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 6);
    await tester.tap(find.byKey(const ValueKey('load-dismiss')));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('load-warning')), findsNothing);
    expect(services.settings.settings.loadDismissedWeek, '2026-09-21');
    // Same week, a later day: still hidden.
    DateTime laterThisWeek() => testNow.add(const Duration(days: 2));
    await pumpApp(tester, services, home: HomeScreen(now: laterThisWeek));
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsNothing);
  });

  testWidgets('a dismissal from an earlier week does not hide this one', (
    tester,
  ) async {
    final services = fakeServices(
      runs: hotWeek(),
      settings: const AppSettings(
        onboardingDone: true,
        loadDismissedWeek: '2026-09-14',
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsOneWidget);
  });

  testWidgets('Start shows a one-line warning above START, still enabled', (
    tester,
  ) async {
    final services = fakeServices(runs: hotWeek());
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsOneWidget);
    expect(find.text('Load is up this week · Why?'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('load-warning'))).height,
      greaterThanOrEqualTo(48),
    );
    final start = find.widgetWithText(FilledButton, 'READY UP ›');
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
  });

  testWidgets('a plan eases its next session when the week runs hot', (
    tester,
  ) async {
    final plan = engine.BlockPlanner.build(
      lane: engine.IdentityLane.aerobic,
      perWeek: 3,
      start: testNow,
    );
    final services = fakeServices(
      runs: hotWeek().where((r) => r.start.isBefore(testNow)).toList(),
      plan: plan,
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 6);
    expect(find.text('Easy run ›'), findsOneWidget);
    expect(find.textContaining(', so this one is easy.'), findsOneWidget);
  });

  testWidgets('dismissing the warning stops the plan easing this week', (
    tester,
  ) async {
    final plan = engine.BlockPlanner.build(
      lane: engine.IdentityLane.aerobic,
      perWeek: 3,
      start: testNow,
    );
    final services = fakeServices(
      runs: hotWeek().where((r) => r.start.isBefore(testNow)).toList(),
      plan: plan,
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 6);
    expect(find.text('Easy run ›'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('load-dismiss')));
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('load-warning')), findsNothing);
    expect(find.text('Easy run ›'), findsNothing);
    expect(find.textContaining(', so this one is easy.'), findsNothing);
    expect(find.text('Norwegian 4x4 ›'), findsOneWidget);
  });

  testWidgets('Why? and Dismiss are at least 48 dp', (tester) async {
    await pumpApp(
      tester,
      fakeServices(runs: hotWeek()),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 6);
    for (final k in ['load-why', 'load-dismiss']) {
      final size = tester.getSize(find.byKey(ValueKey(k)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('Plan screen shows the eased session with its reason', (
    tester,
  ) async {
    final plan = engine.BlockPlanner.build(
      lane: engine.IdentityLane.aerobic,
      perWeek: 3,
      start: testNow,
    );
    final services = fakeServices(
      runs: hotWeek().where((r) => r.start.isBefore(testNow)).toList(),
      plan: plan,
    );
    await pumpApp(tester, services, home: PlanScreen(now: now));
    await pumpTimes(tester, 6);
    expect(
      find.textContaining(', so this one is easy.'),
      findsNWidgets(2), // a ratio this high eases two sessions
    );
  });

  test('dismissal is per Monday', () {
    const s = AppSettings(loadDismissedWeek: '2026-09-21');
    expect(
      s.loadDismissedWeek == engine.LoadGuard.weekKey(DateTime(2026, 9, 27)),
      isTrue,
    );
    expect(
      s.loadDismissedWeek == engine.LoadGuard.weekKey(DateTime(2026, 9, 28)),
      isFalse,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.loadDismissedWeek, '2026-09-21');
  });
}
