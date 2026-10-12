import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/moment_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/seen_moments.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

const _moment = Moment(
  id: 'first-5k',
  kind: MomentKind.first,
  eyebrow: 'Your first',
  big: '5K',
  detail: '28:12.',
);

/// The result screen's post-run moment hook, with the snapshot injected so
/// the engine stub does not decide the outcome.
void main() {
  // Ended 90 minutes before the fixed test clock: a fresh run.
  final fresh = testNow.subtract(const Duration(minutes: 90));
  final old = DateTime.utc(2026, 9, 10, 6);
  var builds = 0;

  /// Honours the seen set like the real engine: a seen moment is not pending.
  void inject(List<Moment> moments) {
    VerdictScreen.snapshotBuilder =
        (
          runs, {
          required now,
          required sex,
          required birthYear,
          seenMoments = const {},
        }) {
          builds++;
          return ProgressSnapshot(
            runCount: runs.length,
            level: ProgressSnapshot.empty.level,
            streak: ProgressSnapshot.empty.streak,
            firsts: ProgressSnapshot.empty.firsts,
            pending: [
              for (final m in moments)
                if (!seenMoments.contains(m.id)) m,
            ],
          );
        };
  }

  setUp(() {
    builds = 0;
    // No application directory: SeenMoments stays in memory, and the test
    // never waits on real file IO inside fake async.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => throw PlatformException(code: 'none'),
        );
    SeenMoments.instance.clearForTest();
  });

  tearDown(() {
    VerdictScreen.snapshotBuilder = buildProgressSnapshot;
    SeenMoments.instance.clearForTest();
  });

  Future<void> open(
    WidgetTester tester,
    engine.RunFile run, {
    bool justFinished = true,
  }) async {
    await pumpApp(
      tester,
      fakeServices(
        files: [run],
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

  testWidgets('empty snapshot: no moment', (tester) async {
    inject(const []);
    await open(tester, fourByFourFile(n: 1, start: fresh));
    expect(builds, 1);
    expect(find.byType(MomentScreen), findsNothing);
  });

  testWidgets('not just finished: no moment, nothing computed', (tester) async {
    inject(const [_moment]);
    await open(tester, fourByFourFile(n: 1, start: fresh), justFinished: false);
    expect(builds, 0);
    expect(find.byType(MomentScreen), findsNothing);
  });

  testWidgets('run ended long ago: no moment, nothing computed', (
    tester,
  ) async {
    inject(const [_moment]);
    await open(tester, fourByFourFile(n: 1, start: old));
    expect(builds, 0);
    expect(find.byType(MomentScreen), findsNothing);
  });

  testWidgets('pending moment shows once; reopening does not re-show it', (
    tester,
  ) async {
    inject(const [_moment]);
    final run = fourByFourFile(n: 1, start: fresh);
    await open(tester, run);
    expect(find.byType(MomentScreen), findsOneWidget);
    expect(find.text('5K'), findsOneWidget);
    expect(await SeenMoments.instance.load(), contains('first-5k'));

    // Close it, then open the same result screen again.
    await tester.tap(find.byKey(const ValueKey('moment-nice')));
    await settleAnimations(tester);
    expect(find.byType(MomentScreen), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, run);
    expect(builds, 2);
    expect(find.byType(MomentScreen), findsNothing);
  });
}
