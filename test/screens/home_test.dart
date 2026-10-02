import 'dart:async';

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
    expect(find.text('SET YOUR SCORES'), findsOneWidget);
    expect(find.text('HOW TO GET BETTER'), findsOneWidget);
    expect(find.text('BEAT 4:22'), findsNothing);
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
    testWidgets('Start presets the recommendation from $mode, no recording', (
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
      // No scores yet: the first 4x4 is what sets AEROBIC.
      expect(services.settings.settings.lastMode, RecordMode.intervals);
      expect(
        services.settings.settings.sessionId,
        engine.SessionSpec.norwegian4x4Id,
      );
      expect(fake.startCalls, isEmpty);
    });
  }

  testWidgets('backing out of setup restores the saved run type', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await tester.tap(find.byType(FilledButton));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.lastMode, RecordMode.intervals);
    Navigator.of(tester.element(find.byType(StartScreen))).pop();
    await pumpTimes(tester, 4);
    expect(services.settings.settings.lastMode, RecordMode.free);
  });

  testWidgets('scores loading: calm hero, Start keeps the last run type', (
    tester,
  ) async {
    final live = _SlowLive();
    final services = fakeServices(
      live: live,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(find.text('Your scores are loading.'), findsOneWidget);
    expect(find.text('Start free run'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await pumpTimes(tester, 4);
    expect(find.byType(StartScreen), findsOneWidget);
    expect(services.settings.settings.lastMode, RecordMode.free);
  });

  testWidgets('scores failed: says so, Start still works', (tester) async {
    final services = fakeServices(
      live: _FailingLive(),
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.laps,
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(find.text("Couldn't load your scores."), findsOneWidget);
    expect(find.text('Start laps run'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await pumpTimes(tester, 4);
    expect(find.byType(StartScreen), findsOneWidget);
  });

  testWidgets('Start from a goal run presets the recommendation', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(onboardingDone: true, goalRun: true),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await tester.tap(find.byType(FilledButton));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.goalRun, isFalse);
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

  testWidgets('map cards draw the route in the run-type colour', (
    tester,
  ) async {
    final services = fakeServices(
      files: [
        freeRunFile(n: 41, start: testNow.subtract(const Duration(days: 1))),
        fourByFourFile(n: 42, start: testNow.subtract(const Duration(days: 2))),
      ],
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 8);
    final recent = find.byType(RecentActivity);
    final runs = tester.widget<RecentActivity>(recent).runs;
    final shapes = tester
        .widgetList<RouteShape>(
          find.descendant(of: recent, matching: find.byType(RouteShape)),
        )
        .toList();
    expect(shapes, hasLength(2));
    for (var i = 0; i < 2; i++) {
      expect(shapes[i].color, runTypeColor(runs[i]));
    }
    expect(shapes[0].color, isNot(shapes[1].color));
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

class _SlowLive extends LiveContextSource {
  _SlowLive() : super.prepared(const []);
  final _never = Completer<void>();
  @override
  Future<void> prepare() => _never.future;
}

class _FailingLive extends LiveContextSource {
  _FailingLive() : super.prepared(const []);
  @override
  Map<engine.IdentityLane, engine.IdentityScore> identityScores() =>
      throw StateError('no scores');
}
