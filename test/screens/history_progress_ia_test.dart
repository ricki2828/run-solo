import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/screens/progress_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

class _EarnedLive extends LiveContextSource {
  _EarnedLive({this.vdot = 38}) : super.prepared(const []);
  final double vdot;

  @override
  Map<engine.IdentityLane, engine.IdentityScore> identityScores() => {
    for (final lane in engine.IdentityLane.values)
      lane: engine.IdentityScore(
        lane: lane,
        score: 62,
        vdot: vdot,
        runId: lane.name,
        date: testNow,
        source: lane == engine.IdentityLane.mid ? '5K' : '4x4',
        boardKey: null,
      ),
  };
}

void main() {
  testWidgets(
    'History opens leaderboard and retains chronological and trends',
    (tester) async {
      await pumpApp(
        tester,
        fakeServices(
          files: [fourByFourFile(n: 1, start: DateTime.utc(2026, 9, 20))],
        ),
        home: const HistoryScreen(),
      );
      await pumpTimes(tester, 6);
      expect(find.byKey(const ValueKey('boards-overview')), findsOneWidget);
      expect(find.byType(HistoryRow), findsNothing);
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      await pumpTimes(tester, 2);
      expect(find.byType(HistoryRow), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-view-2')));
      await pumpTimes(tester, 2);
      expect(find.text('TRENDS'), findsOneWidget);
    },
  );

  testWidgets('Progress explains locked lanes without making up percentiles', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: const ProgressScreen());
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('score-analysis')), findsOneWidget);
    for (final lane in ['aerobic', 'speed', 'mid', 'long']) {
      expect(find.byKey(ValueKey('analysis-$lane')), findsOneWidget);
    }
    expect(find.text('HOW YOU COMPARE'), findsOneWidget);
    expect(find.textContaining('rough comparison'), findsOneWidget);
  });

  testWidgets('Progress: a missing sex says what to add and opens Settings', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(live: _EarnedLive()),
      home: const ProgressScreen(),
    );
    await pumpTimes(tester, 6);
    final prompt = find.text(
      'Add your sex in Settings to see how you compare.',
    );
    expect(prompt, findsWidgets);
    expect(find.text("CAN'T COMPARE YET"), findsWidgets);
    expect(find.textContaining('NO PERCENTILE'), findsNothing);
    await tester.ensureVisible(prompt.first);
    await tester.tap(prompt.first);
    await pumpTimes(tester, 4);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Progress: a known profile names its comparison group', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          birthYear: 1986,
          profileSex: ProfileSex.male,
        ),
        live: _EarnedLive(),
      ),
      home: const ProgressScreen(),
    );
    await pumpTimes(tester, 6);
    expect(find.textContaining('tested on a lab treadmill'), findsWidgets);
    expect(find.textContaining('Estimate, compared with US men'), findsWidgets);
    expect(find.textContaining('VDOT'), findsNothing);
  });

  for (final (vdot, number, line) in [
    (
      56.0,
      '95',
      'Above the published table, so this is an estimate from the shape of the data.',
    ),
    (
      17.0,
      '4',
      'Below the published table, so this is an estimate from the shape of the data.',
    ),
  ]) {
    testWidgets('Progress: vdot $vdot is a flagged $number percentile', (
      tester,
    ) async {
      await pumpApp(
        tester,
        fakeServices(
          settings: const AppSettings(
            onboardingDone: true,
            birthYear: 1982,
            profileSex: ProfileSex.male,
          ),
          live: _EarnedLive(vdot: vdot),
        ),
        home: const ProgressScreen(),
      );
      await pumpTimes(tester, 6);
      final card = find.byKey(const ValueKey('analysis-aerobic'));
      expect(
        find.descendant(of: card, matching: find.text('$number percentile')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text(line)),
        findsOneWidget,
      );
      expect(find.textContaining('table stops'), findsNothing);
    });
  }
}
