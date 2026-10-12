import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/moment_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/progress/seen_moments_store.dart';
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

  testWidgets('a pending moment shows once; reopening moves on', (
    tester,
  ) async {
    final seen = MemorySeenMomentsStore();
    final run = fourByFourFile(n: 1, start: fresh);
    await open(tester, run, seen);
    expect(find.byType(MomentScreen), findsOneWidget);
    final firstSeen = await seen.load();
    expect(firstSeen, hasLength(1));
    final firstBig = tester
        .widget<Text>(find.byKey(const ValueKey('moment-big')))
        .data;

    // Close it, then open the same result screen again.
    await tester.tap(find.byKey(const ValueKey('moment-nice')));
    await settleAnimations(tester);
    expect(find.byType(MomentScreen), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, run, seen);
    final again = find.byKey(const ValueKey('moment-big'));
    if (again.evaluate().isNotEmpty) {
      // The next unseen moment, never the one already shown.
      expect(tester.widget<Text>(again).data, isNot(firstBig));
      expect(await seen.load(), hasLength(2));
    }
  });

  testWidgets('everything already seen: no moment', (tester) async {
    final seen = MemorySeenMomentsStore();
    final run = fourByFourFile(n: 1, start: fresh);
    await open(tester, run, seen);
    await tester.tap(find.byKey(const ValueKey('moment-nice')));
    await settleAnimations(tester);
    // Drain any further pending moments the same way.
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(const SizedBox());
      await open(tester, run, seen);
      if (find.byType(MomentScreen).evaluate().isEmpty) break;
      await tester.tap(find.byKey(const ValueKey('moment-nice')));
      await settleAnimations(tester);
    }
    expect(find.byType(MomentScreen), findsNothing);
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
