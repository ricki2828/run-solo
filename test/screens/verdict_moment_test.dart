import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/moment_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/progress/seen_moments_store.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The result screen's post-run moment hook, through the real progress
/// engine and the shared seen-moments store.
void main() {
  // Ended about 45 minutes before the fixed test clock: a fresh run.
  final fresh = testNow.subtract(const Duration(minutes: 90));
  final old = DateTime.utc(2026, 9, 10, 6);

  Future<void> open(
    WidgetTester tester,
    engine.RunFile run,
    SeenMomentsStore seen, {
    bool justFinished = true,
  }) async {
    await pumpApp(
      tester,
      fakeServices(
        files: [run],
        seenMoments: seen,
        settings: const AppSettings(onboardingDone: true),
      ),
      pushRoute: justFinished ? Routes.verdictJustFinished : Routes.verdict,
      pushArguments: run.id,
    );
    await pumpTimes(tester, 6);
    expect(find.byType(VerdictScreen), findsOneWidget);
    // Past the 900 ms beat, and the moment's own entrance.
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 1600));
  }

  testWidgets('several pending: one shown, all marked seen, none return', (
    tester,
  ) async {
    final seen = MemorySeenMomentsStore();
    final run = fourByFourFile(n: 1, start: fresh);
    final runs = await tester.runAsync(
      () => fakeServices(files: [run]).history.list(),
    );
    final pending = buildProgressSnapshot(
      runs!,
      now: testNow,
      sex: ProfileSex.notSet,
      birthYear: null,
    ).pending.where((m) => m.kind != MomentKind.story).map((m) => m.id);
    expect(
      pending.length,
      greaterThan(2),
      reason: 'a first run stacks moments',
    );

    await open(tester, run, seen);
    expect(find.byType(MomentScreen), findsOneWidget);
    expect(await seen.load(), pending.toSet());

    // A later run: none of the first run's moments come back.
    await tester.tap(find.byKey(const ValueKey('moment-nice')));
    await settleAnimations(tester);
    await tester.pumpWidget(const SizedBox());
    final next = fourByFourFile(
      n: 2,
      start: fresh.add(const Duration(minutes: 50)),
    );
    final before = await seen.load();
    await open(tester, next, seen);
    final big = find.byKey(const ValueKey('moment-big'));
    final after = await seen.load();
    // Whatever this run adds is new; nothing already seen is shown again.
    expect(after.containsAll(before), isTrue);
    if (big.evaluate().isEmpty) expect(after, before);
  });

  test('pickMoment: PB over level-up over first over story', () {
    Moment m(String id, MomentKind k) =>
        Moment(id: id, kind: k, eyebrow: '', big: '', detail: '');
    final first = m('first:a', MomentKind.first);
    final level = m('level:3', MomentKind.levelUp);
    final pb = m('pb:5k:x', MomentKind.pb);
    final story = m('story:1', MomentKind.story);
    expect(pickMoment([story, first, level, pb]), pb);
    expect(pickMoment([story, first, level]), level);
    expect(pickMoment([story, first]), first);
    expect(pickMoment([story]), story);
  });

  testWidgets('not just finished: no moment, nothing marked seen', (
    tester,
  ) async {
    final seen = MemorySeenMomentsStore();
    await open(
      tester,
      fourByFourFile(n: 1, start: fresh),
      seen,
      justFinished: false,
    );
    expect(find.byType(MomentScreen), findsNothing);
    expect(await seen.load(), isEmpty);
  });

  testWidgets('run ended long ago: no moment, nothing marked seen', (
    tester,
  ) async {
    final seen = MemorySeenMomentsStore();
    await open(tester, fourByFourFile(n: 1, start: old), seen);
    expect(find.byType(MomentScreen), findsNothing);
    expect(await seen.load(), isEmpty);
  });
}
