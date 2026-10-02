import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/settings.dart';
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
    expect(find.text('Men 40 to 49, lab norms'), findsNWidgets(2));
    expect(
      find.text('Men, recreational race finishers, all ages'),
      findsNWidgets(2),
    );
    expect(find.text('percentile'), findsNWidgets(4));
    await tester.tap(find.byKey(const ValueKey('home-score-aerobic')));
    expect(opened, isTrue);
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
      expect(find.text('--'), findsNWidgets(4));
      expect(find.text('Add your sex to compare'), findsNWidgets(4));
      expect(find.text('62'), findsNothing);
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
}
