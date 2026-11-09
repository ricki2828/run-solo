import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/surface_choice_row.dart';

import '../helpers.dart';

/// 8-Nov (Ricki's treadmill run, WHOOP): the strap stayed amber on Ready and
/// needed a manual reconnect, because #336 tied "the strap is wanted" to the
/// GPS probe and a treadmill run has no probe. The strap is its own want, on
/// for every run type while Start/Ready is up, with no GPS for an indoor one.
void main() {
  Future<FakeRecorderGateway> ready(
    WidgetTester tester,
    AppSettings settings,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake, settings: settings);
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    return fake;
  }

  AppSettings base(RecordMode mode, {bool goal = false}) => AppSettings(
    onboardingDone: true,
    lastMode: mode,
    goalRun: goal,
    goalId: 'd5000',
    countdownSeconds: 0,
  );

  testWidgets('a free treadmill run wants the strap and starts no GPS', (
    tester,
  ) async {
    final fake = await ready(tester, base(RecordMode.treadmill));
    expect(fake.strapHuntRunning, isTrue);
    expect(fake.gpsProbeRunning, isFalse);
  });

  for (final (name, mode, goal) in [
    ('the 12-minute test', RecordMode.cooper, false),
    ('intervals', RecordMode.intervals, false),
    ('a goal run', RecordMode.intervals, true),
  ]) {
    testWidgets('$name on a treadmill keeps the strap with GPS off', (
      tester,
    ) async {
      final fake = await ready(tester, base(mode, goal: goal));
      // Outdoors first: both are wanted.
      expect(fake.strapHuntRunning, isTrue);
      expect(fake.gpsProbeRunning, isTrue);
      await tester.tap(find.byKey(SurfaceChoiceRow.treadmillKey));
      await pumpTimes(tester, 4);
      // The belt stops the probe and never lets the strap go.
      expect(fake.gpsProbeRunning, isFalse);
      expect(fake.strapHuntRunning, isTrue);
    });
  }

  testWidgets('leaving Ready lets the strap go', (tester) async {
    final fake = await ready(tester, base(RecordMode.treadmill));
    expect(fake.strapHuntRunning, isTrue);
    await tester.tap(find.byKey(const ValueKey('ready-back')));
    await pumpTimes(tester, 6);
    await settleAnimations(tester);
    expect(fake.strapHuntRunning, isFalse);
  });
}
