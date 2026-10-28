import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/coach_choice_row.dart';

import '../helpers.dart';

/// The pre-run choice on the Ready screen (moved off Start, 28-Oct): two big buttons for a Free or distance-goal
/// run, kept between runs, and handed to the recorder in the LiveContext.
void main() {
  late AppServices services;

  Future<FakeRecorderGateway> open(
    WidgetTester tester,
    AppSettings settings,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    services = fakeServices(
      recorder: fake,
      live: LiveContextSource.prepared(const [], now: now),
      settings: settings,
    );
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    await pumpTimes(tester, 6);
    await settleAnimations(tester);
    return fake;
  }

  const free = AppSettings(onboardingDone: true, lastMode: RecordMode.free);
  const chaseKey = CoachChoiceRow.chaseKey;
  const steadyKey = CoachChoiceRow.steadyKey;

  bool selected(WidgetTester tester, Key key) => tester
      .widget<Semantics>(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Semantics))
            .first,
      )
      .properties
      .selected!;

  testWidgets('a Free run asks, chase picked until the runner says otherwise', (
    tester,
  ) async {
    await open(tester, free);
    expect(find.byKey(chaseKey), findsOneWidget);
    expect(find.byKey(steadyKey), findsOneWidget);
    expect(find.text('Chase best'), findsOneWidget);
    expect(find.text('Steady'), findsOneWidget);
    expect(selected(tester, chaseKey), isTrue);
    expect(selected(tester, steadyKey), isFalse);
  });

  testWidgets('one tap picks the other and it is kept', (tester) async {
    await open(tester, free);
    await tapVisible(tester, find.byKey(steadyKey));
    await pumpTimes(tester, 4);
    expect(selected(tester, steadyKey), isTrue);
    expect(selected(tester, chaseKey), isFalse);
    expect(services.settings.settings.coachChoice, engine.CoachChoice.steady);
  });

  testWidgets('a change made on Ready reaches the started run', (tester) async {
    // Saved choice is chase (default); the runner flips it on Ready, then GO.
    final fake = await open(tester, free);
    await tapVisible(tester, find.byKey(steadyKey));
    await pumpTimes(tester, 4);
    await goFromReady(tester);
    await pumpTimes(tester, 6);
    expect(fake.startCalls, hasLength(1));
    expect(fake.startCalls.single.liveContext?.coachChoice, 'steady');
  });

  testWidgets('the picker no longer carries the choice', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    services = fakeServices(recorder: fake, settings: free);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 6);
    expect(find.byKey(chaseKey), findsNothing);
    expect(find.text('HOW DO YOU WANT TO RUN?'), findsNothing);
  });

  testWidgets('the buttons are big: at least 96 px tall and half the width', (
    tester,
  ) async {
    await open(tester, free);
    final chase = tester.getSize(find.byKey(chaseKey));
    final steady = tester.getSize(find.byKey(steadyKey));
    expect(chase.height, greaterThanOrEqualTo(96));
    expect(chase.height, steady.height);
    expect(chase.width, greaterThan(140));
  });

  testWidgets('at 2x text the two cards stay equal and at least 96 tall', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, free);
    final chase = tester.getSize(find.byKey(chaseKey));
    final steady = tester.getSize(find.byKey(steadyKey));
    expect(chase.height, greaterThanOrEqualTo(96));
    expect(chase.height, steady.height);
    // The run-type cards above still overflow at 2x (font-scale pass, #26);
    // only the coach cards are checked here.
    tester.takeException();
  });

  testWidgets('a distance goal asks', (tester) async {
    await open(
      tester,
      const AppSettings(onboardingDone: true, goalRun: true, goalId: 'd10000'),
    );
    expect(find.byKey(chaseKey), findsOneWidget);
  });

  testWidgets('the event is not asked', (tester) async {
    await open(
      tester,
      const AppSettings(
        onboardingDone: true,
        goalRun: true,
        goalId: GoalChoice.eventId,
      ),
    );
    expect(find.byKey(chaseKey), findsNothing);
  });

  testWidgets('a time goal is not asked', (tester) async {
    await open(
      tester,
      const AppSettings(onboardingDone: true, goalRun: true, goalId: 't1800'),
    );
    expect(find.byKey(chaseKey), findsNothing);
  });

  testWidgets('laps and tests are not asked', (tester) async {
    await open(
      tester,
      const AppSettings(onboardingDone: true, lastMode: RecordMode.laps),
    );
    expect(find.byKey(chaseKey), findsNothing);
  });

  testWidgets('START hands the recorder the choice in the live context', (
    tester,
  ) async {
    final fake = await open(
      tester,
      free.copyWith(coachChoice: engine.CoachChoice.steady),
    );
    await goFromReady(tester);
    await pumpTimes(tester, 6);
    final ctx = fake.startCalls.single.liveContext;
    expect(ctx, isNotNull, reason: 'a choice alone is a context');
    expect(ctx!.coachChoice, 'steady');
    expect(ctx.monthFurthestM, isNull);
    expect(ctx.boards, isEmpty);
  });

  testWidgets('a laps run starts with no choice at all', (tester) async {
    final fake = await open(
      tester,
      const AppSettings(onboardingDone: true, lastMode: RecordMode.laps),
    );
    await goFromReady(tester);
    await pumpTimes(tester, 6);
    expect(fake.startCalls.single.liveContext?.coachChoice, isNull);
  });
}
