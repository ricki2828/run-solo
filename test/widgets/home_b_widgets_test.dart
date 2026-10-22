import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/home_progress.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/home_b/home_b.dart';

import '../helpers.dart';

Widget _scaffold(Widget child) =>
    Scaffold(body: SingleChildScrollView(child: child));

Map<engine.IdentityLane, engine.IdentityScore> _scores({double? prior}) => {
  for (final lane in engine.IdentityLane.values)
    lane: engine.IdentityScore(
      lane: lane,
      score: 62,
      vdot: 38,
      priorVdot: prior,
      runId: lane.name,
      date: testNow,
      source: lane == engine.IdentityLane.mid ? '5K' : '4x4',
      boardKey: null,
    ),
};

void main() {
  final story = WeeklyStory(
    weekStart: testNow,
    km: 10,
    runs: 3,
    headline: 'Steady week.',
    dailyKm: const [0, 5, 0, 5, 0, 0, 0],
    dailyLane: const [null, null, null, null, null, null, null],
  );

  testWidgets('StoryButton shows km, or miles from the units setting', (
    tester,
  ) async {
    var taps = 0;
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(StoryButton(story: story, onTap: () => taps++)),
    );
    expect(find.text('10.0 KM, 3 RUNS'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-story')));
    expect(taps, 1);
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(StoryButton(story: story, units: Units.mi, onTap: () {})),
    );
    expect(find.text('6.2 MI, 3 RUNS'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('home-story'))).label,
      contains('6.2 mi'),
    );
  });

  testWidgets('HomeLaneBlocks: change chips, unlock taps, open tap', (
    tester,
  ) async {
    var opened = 0;
    final unlocked = <AppSettings>[];
    final scores = _scores(prior: 30);
    scores.remove(engine.IdentityLane.long);
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(
        HomeLaneBlocks(
          scores: scores,
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () => opened++,
          onUnlock: (apply) => unlocked.add(apply(const AppSettings())),
        ),
      ),
    );
    final change = ScoreNorms.change(
      scores[engine.IdentityLane.aerobic]!,
      sex: ProfileSex.male,
      age: 44,
    )!;
    expect(change, isNot(0));
    expect(find.text(change > 0 ? '+$change' : '$change'), findsWidgets);
    expect(find.byKey(const ValueKey('lane-change-aerobic')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-score-aerobic')));
    expect(opened, 1);
    await tester.tap(find.byKey(const ValueKey('home-unlock-long')));
    expect(unlocked, hasLength(1));
  });

  testWidgets('HomeLaneBlocks: no change chip without a prior score', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(
        HomeLaneBlocks(
          scores: _scores(),
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () {},
          onUnlock: (_) {},
        ),
      ),
    );
    expect(find.byKey(const ValueKey('lane-change-aerobic')), findsNothing);
  });

  testWidgets('StreakCard: states and a different tint lane', (tester) async {
    Widget card(WeeklyStreak s, {engine.IdentityLane? lane}) => _scaffold(
      StreakCard(
        streak: s,
        firstsDone: 3,
        firstsTotal: 15,
        lane: lane ?? engine.IdentityLane.aerobic,
      ),
    );
    await pumpApp(
      tester,
      fakeServices(),
      home: card(
        const WeeklyStreak(
          weeks: 0,
          thisWeekDone: false,
          freezesReady: 0,
          recent: [],
        ),
      ),
    );
    expect(find.text('START YOUR STREAK'), findsOneWidget);
    expect(
      find.bySemanticsLabel('START YOUR STREAK, No freeze ready'),
      findsOneWidget,
    );
    await pumpApp(
      tester,
      fakeServices(),
      home: card(
        const WeeklyStreak(
          weeks: 5,
          thisWeekDone: true,
          freezesReady: 2,
          recent: [
            engine.StreakWeek.ran,
            engine.StreakWeek.ran,
            engine.StreakWeek.frozen,
            engine.StreakWeek.ran,
            engine.StreakWeek.ran,
            engine.StreakWeek.ran,
            engine.StreakWeek.ran,
            engine.StreakWeek.ran,
          ],
        ),
        lane: engine.IdentityLane.speed,
      ),
    );
    expect(find.text('5 WEEK STREAK'), findsOneWidget);
    expect(
      find.bySemanticsLabel('5 WEEK STREAK, 2 freezes ready'),
      findsOneWidget,
    );
  });

  testWidgets('GhostCard: faster, slower and steady lines use both labels', (
    tester,
  ) async {
    Widget ghost(Duration now, Duration then) => _scaffold(
      GhostCard(
        ghost: GhostCompare(
          label: '5K',
          now: now,
          then: then,
          thenLabel: kGhostThenLabel,
        ),
      ),
    );
    await pumpApp(
      tester,
      fakeServices(),
      home: ghost(const Duration(minutes: 25), const Duration(minutes: 26)),
    );
    expect(
      find.text('60 seconds faster than the 4 weeks before.'),
      findsOneWidget,
    );
    expect(find.text(kGhostNowLabel), findsWidgets);
    await pumpApp(
      tester,
      fakeServices(),
      home: ghost(const Duration(minutes: 26), const Duration(minutes: 25)),
    );
    expect(
      find.text('60 seconds slower than the 4 weeks before.'),
      findsOneWidget,
    );
    await pumpApp(
      tester,
      fakeServices(),
      home: ghost(const Duration(minutes: 25), const Duration(minutes: 25)),
    );
    expect(find.textContaining('Steady.'), findsOneWidget);
  });

  testWidgets('PackHero: no run, profile needed, and axis labels', (
    tester,
  ) async {
    var added = 0;
    CalibratedLevel level() => ProgressSnapshot.empty.level;
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(PackHero(level: level(), runCount: 0)),
    );
    expect(find.text('FIND\nYOUR PACK'), findsOneWidget);
    expect(find.byKey(const ValueKey('pack-hero-add-profile')), findsNothing);
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(
        PackHero(
          level: level(),
          runCount: 2,
          needsProfile: true,
          onAddProfile: () => added++,
          slowerLabel: 'Behind',
          fasterLabel: 'Ahead',
        ),
      ),
    );
    expect(find.text('ADD YOUR\nAGE BAND'), findsOneWidget);
    expect(find.text('Behind'), findsOneWidget);
    expect(find.text('Ahead'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pack-hero-add-profile')));
    expect(added, 1);
  });

  testWidgets('PackHero: profile set but no pack yet says almost there', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: _scaffold(
        PackHero(level: ProgressSnapshot.empty.level, runCount: 1),
      ),
    );
    expect(find.text('ALMOST\nIN THE PACK'), findsOneWidget);
    expect(find.byKey(const ValueKey('pack-hero-add-profile')), findsNothing);
  });

  testWidgets('PackHero: no norms for the sex, button only for birth year', (
    tester,
  ) async {
    Widget hero({required bool needsBirthYear}) => _scaffold(
      PackHero(
        level: ProgressSnapshot.empty.level,
        runCount: 2,
        needsProfile: true,
        noNorms: true,
        needsBirthYear: needsBirthYear,
        onAddProfile: () {},
      ),
    );
    await pumpApp(tester, fakeServices(), home: hero(needsBirthYear: false));
    expect(find.text('NO PACK FOR\nTHIS PROFILE'), findsOneWidget);
    expect(
      find.text(
        "Pack comparisons use published men's and women's norms, so there's "
        'no pack for this profile.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pack-hero-add-profile')), findsNothing);
    await pumpApp(tester, fakeServices(), home: hero(needsBirthYear: true));
    expect(find.text('Add your birth year'), findsOneWidget);
  });
}
