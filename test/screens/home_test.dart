import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/recent_activity.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// A card title is a rich text: the time-of-day word in ink, the session
/// name in its run-type colour.
Finder cardTitle(String sessionName) => find.descendant(
  of: find.byType(RecentActivity),
  matching: find.byWidgetPredicate(
    (w) =>
        w is RichText &&
        w.text.toPlainText().endsWith(sessionName) &&
        w.text.toPlainText().length > sessionName.length,
  ),
);

void main() {
  testWidgets('new install has one remembered Start and no locked tiles', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: HomeScreen(now: now));
    expect(find.text('SET YOUR LINE'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);
    expect(find.text('NEW RUN'), findsNothing);
    expect(find.text('Start Norwegian 4x4'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  for (final mode in [
    RecordMode.free,
    RecordMode.cooper,
    RecordMode.intervals,
  ]) {
    testWidgets('Start remembers $mode and opens setup before recording', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: AppSettings(onboardingDone: true, lastMode: mode),
      );
      await pumpApp(tester, services, home: HomeScreen(now: now));
      await tester.tap(find.byType(FilledButton));
      await pumpTimes(tester, 4);
      expect(find.byType(StartScreen), findsOneWidget);
      expect(services.settings.settings.lastMode, mode);
      expect(fake.startCalls, isEmpty);
    });
  }

  testWidgets('goal selection survives Home Start', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(onboardingDone: true, goalRun: true),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await tester.tap(find.byType(FilledButton));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.goalRun, isTrue);
    expect(find.byType(StartScreen), findsOneWidget);
  });

  testWidgets('plan input has priority without inventing enrolment', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: HomeScreen(
        now: now,
        planHeadline: (name: 'Tempo', subtitle: 'Week 3, session 2 of 3.'),
      ),
    );
    expect(find.text('TEMPO TODAY'), findsOneWidget);
    expect(find.text('Week 3, session 2 of 3.'), findsOneWidget);
    expect(find.text('Start Tempo'), findsOneWidget);
  });

  testWidgets('recent activity lists the last sessions of any kind', (
    tester,
  ) async {
    final services = fakeServices(
      runs: [
        summary(
          id: 'a',
          start: testNow.subtract(const Duration(days: 3)),
          durationMs: 32 * 60 * 1000,
          distanceM: 6400,
        ),
        summary(
          id: 'b',
          start: testNow.subtract(const Duration(days: 1)),
          fourByFour: false,
        ),
      ],
    );
    await pumpApp(
      tester,
      services,
      home: HomeScreen(now: now, onShowHistory: () {}),
    );

    expect(find.text('RECENT ACTIVITY'), findsOneWidget);
    expect(cardTitle('Norwegian 4x4'), findsOneWidget);
    expect(find.text('LAST RESULT'), findsNothing);
    expect(find.text('5:00/km', findRichText: true), findsOneWidget);
    expect(find.text('32:00'), findsNWidgets(2));
    expect(find.text('6.40'), findsOneWidget);
    expect(find.text('AVG PACE'), findsNWidgets(2));
    expect(find.text('All activity ›'), findsOneWidget);
  });

  testWidgets('12-minute test name keeps Cooper behind info', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        runs: [summary(id: 'cooper', start: testNow, mode: RecordMode.cooper)],
      ),
      home: HomeScreen(now: now),
    );
    expect(cardTitle('12-minute test'), findsOneWidget);
    expect(find.textContaining('Cooper'), findsNothing);
    await tester.ensureVisible(find.byTooltip('12-minute test info'));
    await tester.tap(find.byTooltip('12-minute test info'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('12-minute test: a 12-minute run'),
      findsOneWidget,
    );
  });

  testWidgets('map cards and estimated times stay in vertical order', (
    tester,
  ) async {
    final first = freeRunFile(
      n: 31,
      start: testNow.subtract(const Duration(days: 1)),
    );
    final second = fourByFourFile(
      n: 32,
      start: testNow.subtract(const Duration(days: 2)),
    );
    final effort = engine.BestEffort(
      distance: engine.BestEffortDistance.k5,
      elapsedMs: 1470000,
      startMs: 0,
      startOffsetM: 0,
      splitsMs: const [],
    );
    final candidates = [
      engine.LiveCandidate(
        engine.BoardInput(
          runId: first.id,
          date: first.start,
          mode: engine.RunMode.free,
          efforts: {engine.BestEffortDistance.k5: effort},
        ),
        engine.RunDerived(
          bestEfforts: engine.RunBestEfforts(
            efforts: {engine.BestEffortDistance.k5: effort},
            fromStartSplitsMs: const [],
          ),
        ),
      ),
    ];
    final services = fakeServices(
      files: [first, second],
      live: LiveContextSource.prepared(candidates, now: now),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 8);
    final recent = find.byType(RecentActivity);
    final maps = find.descendant(of: recent, matching: find.byType(RouteShape));
    expect(maps, findsNWidgets(2));
    final table = find.byKey(const ValueKey('recent-estimates-table'));
    expect(table, findsOneWidget);
    final row = find.descendant(of: recent, matching: find.byType(InkWell));
    expect(row, findsWidgets);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('recent activity titles carry the run-type colours', (
    tester,
  ) async {
    final services = fakeServices(
      runs: [
        summary(id: 'interval', start: testNow, mode: RecordMode.intervals),
        summary(
          id: 'free',
          start: testNow.subtract(const Duration(days: 1)),
          mode: RecordMode.free,
        ),
        summary(
          id: 'laps',
          start: testNow.subtract(const Duration(days: 2)),
          mode: RecordMode.laps,
        ),
      ],
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    final expected = {
      'Norwegian 4x4': AuroraRunType.intervals,
      'Free run': AuroraRunType.free,
      'Laps run': AuroraRunType.laps,
    };
    for (final entry in expected.entries) {
      final rich = tester.widget<RichText>(cardTitle(entry.key));
      final colours = <String, Color?>{};
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          colours[span.text!.trim()] = span.style?.color;
        }
        return true;
      });
      // The colour is on the session name only, never the time-of-day word.
      expect(colours[entry.key], entry.value);
      expect(colours.length, 2);
    }
  });

  testWidgets('saved strap stays off Home and Change retains last type', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        strap: SavedStrap(address: 'X', name: 'WHOOP 12'),
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(find.text('Strap: Whoop'), findsNothing);
    await tester.tap(find.text('Change'));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.lastMode, RecordMode.free);
    expect(find.byType(StartScreen), findsOneWidget);
  });

  testWidgets('location not granted: choice opens the checklist first', (
    tester,
  ) async {
    final services = fakeServices(
      permissions: FakePermissionsGateway(
        snapshot: const PermissionSnapshot(fineLocation: false),
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(
      find.text('Location permission needed before you can record.'),
      findsOneWidget,
    );
    await tester.tap(find.byType(FilledButton));
    await pumpTimes(tester, 4);
    expect(find.byType(PermissionsScreen), findsOneWidget);
    expect(find.byType(StartScreen), findsNothing);
  });

  testWidgets('approximate-only location is called out', (tester) async {
    final services = fakeServices(
      permissions: FakePermissionsGateway(
        snapshot: const PermissionSnapshot(
          fineLocation: false,
          coarseOnly: true,
        ),
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(find.textContaining('Location is approximate'), findsOneWidget);
  });
}
