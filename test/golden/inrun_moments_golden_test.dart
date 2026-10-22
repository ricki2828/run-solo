import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/inrun_moments.dart';

import '../helpers.dart' show fourByFourSpec;
import '../screens/inrun_moment_test.dart'
    show eventSpec, gone, moment, openRun, step;

/// One golden per in-run moment (21-Oct UI review, finding 2), caught at the
/// peak of its 1.5 s: km, mile, rep done, halfway, last 400 m, goal reached.
/// PNGs come from the CI goldens release (see the brief).
Future<void> shot(WidgetTester tester, String name) async {
  tester.view.physicalSize = const Size(1080, 800 * 3.0);
  await tester.pump(const Duration(milliseconds: 400)); // scale-in done
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens release',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// The moment's glow is a software-rendered blur: a handful of edge pixels
/// differ between CI runs (4-40 px of 2.6 M). Anything under 0.05% passes.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  static const double tolerance = 0.0005;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    return result.passed || result.diffPercent <= tolerance;
  }
}

void main() {
  setUpAll(() {
    goldenFileComparator = _TolerantComparator(
      Uri.parse('test/golden/inrun_moments_golden_test.dart'),
    );
  });

  testWidgets('moment: km', (tester) async {
    final fake = await openRun(tester);
    await step(tester, fake, 340);
    expect(moment(InrunMomentKind.distanceMark), findsOneWidget);
    await shot(tester, 'inrun_moment_km_360x800');
    await gone(tester);
  });

  testWidgets('moment: mile', (tester) async {
    final fake = await openRun(tester, units: Units.mi);
    await step(tester, fake, 520);
    expect(moment(InrunMomentKind.distanceMark), findsOneWidget);
    await shot(tester, 'inrun_moment_mile_360x800');
    await gone(tester);
  });

  testWidgets('moment: rep done', (tester) async {
    final fake = await openRun(
      tester,
      mode: RecordMode.intervals,
      spec: fourByFourSpec(),
    );
    await fake.lap(LapSource.button);
    await tester.pump();
    await step(tester, fake, 240);
    await step(tester, fake, 1);
    expect(moment(InrunMomentKind.repDone), findsOneWidget);
    await shot(tester, 'inrun_moment_rep_360x800');
    await gone(tester);
  });

  testWidgets('moment: halfway, last 400 m, goal reached', (tester) async {
    final fake = await openRun(
      tester,
      mode: RecordMode.intervals,
      spec: eventSpec(),
    );
    await step(tester, fake, 800);
    expect(moment(InrunMomentKind.halfway), findsOneWidget);
    await shot(tester, 'inrun_moment_halfway_360x800');
    await gone(tester);
    await step(tester, fake, 600);
    expect(moment(InrunMomentKind.lastStretch), findsOneWidget);
    await shot(tester, 'inrun_moment_last400_360x800');
    await gone(tester);
    // Emitted inside the last 400 m: the fake ends the whole run at 5 km,
    // which would navigate away before the shot.
    fake.emitGoal(
      GoalEvent(
        distanceGoal: true,
        goalValue: 5000,
        timeMs: 1500000,
        distanceM: 5000,
        newBest: false,
        interrupted: false,
        text: 'Goal reached',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(moment(InrunMomentKind.goalReached), findsOneWidget);
    await shot(tester, 'inrun_moment_goal_360x800');
    await gone(tester);
  });
}
