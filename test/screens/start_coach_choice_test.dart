import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/coach_choice_row.dart';

import '../helpers.dart';

/// The pre-run choice on Start: two big buttons for a Free or distance-goal
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
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 6);
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
    expect(find.text('Chase your best'), findsOneWidget);
    expect(find.text('Steady run'), findsOneWidget);
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
    await readyAndGo(tester);
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
    await readyAndGo(tester);
    await pumpTimes(tester, 6);
    expect(fake.startCalls.single.liveContext?.coachChoice, isNull);
  });
}
