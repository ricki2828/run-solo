import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/home_score_spark.dart';
import 'package:run_solo/widgets/home_scores.dart';

import '../helpers.dart';

Map<engine.IdentityLane, engine.IdentityScore> earnedScores() => {
  for (final lane in engine.IdentityLane.values)
    lane: engine.IdentityScore(
      lane: lane,
      score: 62,
      vdot: 38,
      runId: lane.name,
      date: testNow,
      source: lane == engine.IdentityLane.mid ? '5K' : '4x4',
      boardKey: null,
    ),
};

void main() {
  testWidgets('earned cards route to Progress, with honest different cohorts', (
    tester,
  ) async {
    var opened = false;
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: HomeScores(
          scores: earnedScores(),
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () => opened = true,
        ),
      ),
    );
    expect(find.text('LOCKED'), findsNothing);
    // The norms are named once under the grid, not on every card.
    expect(find.text('Men 40 to 49, lab norms'), findsNothing);
    expect(find.byKey(const ValueKey('home-score-norms')), findsOneWidget);
    expect(
      find.text(
        'Compared with men 40-49 (lab norms) and recreational race finishers '
        '(men, all ages).',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('percentile'), findsNWidgets(4));
    await tester.tap(find.byKey(const ValueKey('home-score-aerobic')));
    expect(opened, isTrue);
    final spoken = tester
        .getSemantics(find.byKey(const ValueKey('home-score-aerobic')))
        .label;
    expect(spoken, matches(RegExp(r'\d+(st|nd|rd|th) percentile')));
    expect(spoken, isNot(contains('about')));
    expect(spoken, isNot(contains('estimate')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing profile never substitutes the display score as percentile',
    (tester) async {
      await pumpApp(
        tester,
        fakeServices(),
        home: Scaffold(
          body: HomeScores(
            scores: earnedScores(),
            profileSex: ProfileSex.notSet,
            age: null,
            onOpen: () {},
          ),
        ),
      );
      expect(find.textContaining('--', findRichText: true), findsNWidgets(4));
      expect(find.text('Add your sex to compare'), findsNWidgets(4));
      expect(find.textContaining('62', findRichText: true), findsNothing);
    },
  );

  testWidgets('scores: 2x2, no horizontal scroll, labelled dots', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: HomeScores(
          scores: {
            for (final l in [
              engine.IdentityLane.aerobic,
              engine.IdentityLane.speed,
              engine.IdentityLane.mid,
            ])
              l: earnedScores()[l]!,
          },
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () {},
        ),
      ),
    );
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.text('LONG'), findsOneWidget);
    expect(find.text('AEROBIC'), findsNWidgets(2));
  });

  testWidgets('a sparkline shows only with two points, in the score colour', (
    tester,
  ) async {
    engine.IdentityScore score(engine.IdentityLane l, double? prior) =>
        engine.IdentityScore(
          lane: l,
          score: 62,
          vdot: 40,
          priorVdot: prior,
          priorSource: prior == null ? null : '4x4',
          runId: l.name,
          date: testNow,
          source: '4x4',
          boardKey: null,
        );
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: HomeScores(
          scores: {
            engine.IdentityLane.aerobic: score(engine.IdentityLane.aerobic, 34),
            engine.IdentityLane.speed: score(engine.IdentityLane.speed, 46),
            engine.IdentityLane.mid: score(engine.IdentityLane.mid, null),
          },
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () {},
        ),
      ),
    );
    final t = Theme.of(tester.element(find.byType(HomeScores)))
        .extension<RunSoloTokens>()!;
    HomeScoreSparkPainter painter(String lane) =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(ValueKey('home-spark-$lane')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as HomeScoreSparkPainter;
    // Each sparkline is its own score's colour, rising or not.
    expect(painter('aerobic').color, t.typeTests);
    expect(painter('speed').color, t.typeIntervals);
    expect(find.byKey(const ValueKey('home-spark-mid')), findsNothing);
  });

  testWidgets('empty state rows are 48 dp, tappable, and preselect Start', (
    tester,
  ) async {
    final picked = <engine.IdentityLane, AppSettings>{};
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: HomeScores(
          scores: const {},
          profileSex: ProfileSex.male,
          age: 44,
          onOpen: () {},
          onUnlock: (apply) {
            final s = apply(const AppSettings());
            picked[engine.IdentityLane.values.firstWhere(
                  (l) => !picked.containsKey(l),
                )] =
                s;
          },
        ),
      ),
    );
    for (final lane in engine.IdentityLane.values) {
      final row = find.byKey(ValueKey('home-unlock-${lane.name}'));
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      await tester.tap(row);
    }
    final a = picked[engine.IdentityLane.aerobic]!;
    expect(a.lastMode, RecordMode.cooper);
    expect(a.goalRun, isFalse);
    final sp = picked[engine.IdentityLane.speed]!;
    expect(sp.lastMode, RecordMode.intervals);
    expect(sp.sessionId, engine.SessionCatalogue.fourHundreds.id);
    final m = picked[engine.IdentityLane.mid]!;
    expect(m.goalRun, isTrue);
    expect(m.goalId, 'd5000');
    final l = picked[engine.IdentityLane.long]!;
    expect(l.lastMode, RecordMode.free);
    expect(l.goalRun, isFalse);
  });
}
