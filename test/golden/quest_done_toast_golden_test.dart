import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/quests/quest_store.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/inrun_moment.dart';
import 'package:run_solo/widgets/quest_done_toast.dart';

import '../helpers.dart';

/// "QUEST DONE · SADDLE ×5" on the record screen, on a hard-effort flood.
/// PNGs come from the CI goldens like the others.
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

final quest = engine.QuestDef(
  id: 'q_2026-11_trail_visits_ab12',
  kind: engine.QuestKind.trailVisits,
  month: '2026-11',
  target: 5,
  baseline: 4,
  trailKey: 'trail:x',
  trailName: 'Saddle',
).accept(DateTime.utc(2026, 11, 2, 10));

Future<FakeRecorderGateway> openRun(
  WidgetTester tester, {
  String? doneAtStart,
  int height = 800,
}) async {
  final fake = FakeRecorderGateway(now: now)
    ..emitRoute = true
    ..scriptedHr = 160
    ..liveSecPerKm = 270
    ..questDoneId = doneAtStart;
  final services = fakeServices(
    recorder: fake,
    maps: const FakeMapSurfaceFactory(available: true),
    settings: AppSettings(onboardingDone: true),
    questStore: MemoryQuestStore(QuestState(active: quest)),
  );
  await services.quests.load();
  await services.recording.start(RecordMode.trail, null, Units.km);
  await pumpApp(tester, services, pushRoute: Routes.recording);
  tester.view.physicalSize = Size(1080, height * 3.0);
  await pumpTimes(tester, 4);
  fake.advance(const Duration(seconds: 2000));
  await pumpTimes(tester, 5);
  await settleAnimations(tester);
  return fake;
}

void main() {
  testWidgets('the toast shows once when the quest completes, then goes', (
    tester,
  ) async {
    final fake = await openRun(tester);
    expect(find.byKey(const ValueKey('quest-done-toast')), findsNothing);
    fake.questDoneId = quest.id;
    fake.advance(const Duration(seconds: 5));
    await pumpTimes(tester, 5);
    // 24-Oct review #8: the km moment is still up, and the toast waits for
    // it rather than sitting under its scrim.
    expect(find.byKey(const ValueKey('inrun-moment-scrim')), findsOneWidget);
    expect(find.byKey(const ValueKey('quest-done-toast')), findsNothing);
    await tester.pump(InrunMomentOverlay.shownFor);
    await pumpTimes(tester, 3);
    expect(find.byKey(const ValueKey('inrun-moment-scrim')), findsNothing);
    expect(find.byKey(const ValueKey('quest-done-toast')), findsOneWidget);
    expect(find.text('QUEST DONE · SADDLE ×5'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('quest-done-text')))
          .style!
          .fontSize,
      greaterThanOrEqualTo(36),
    );
    await golden(tester, 'quest_done_toast_hard_360x800');
    await tester.pump(QuestDoneToast.shownFor + const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('quest-done-toast')), findsNothing);
    // More ticks with the same id never show it again.
    fake.advance(const Duration(seconds: 5));
    await pumpTimes(tester, 5);
    expect(find.byKey(const ValueKey('quest-done-toast')), findsNothing);
  });

  testWidgets('a screen opened after the quest was done does not toast it', (
    tester,
  ) async {
    await openRun(tester, doneAtStart: quest.id);
    expect(find.byKey(const ValueKey('quest-done-toast')), findsNothing);
  });
}
