import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/surface_choice_row.dart';

import '../helpers.dart';
import '../run_fixtures.dart';
import 'screens_golden_test.dart' show golden;

/// 7-Nov: intervals and the 12-minute test on a treadmill. PNGs come from CI.
void main() {
  Future<void> ready(
    WidgetTester tester, {
    required int incline,
    required String name,
    required double h,
  }) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.cooper,
        countdownSeconds: 0,
        treadmillIncline: incline,
      ),
    );
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    tester.view.physicalSize = Size(1080, h * 3.0);
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    await tester.tap(find.byKey(SurfaceChoiceRow.treadmillKey));
    await pumpTimes(tester, 4);
    await settleAnimations(tester);
    await golden(tester, name);
  }

  testWidgets('Ready: test on a treadmill, 1% at 360 x 640', (tester) async {
    await ready(
      tester,
      incline: 1,
      name: 'ready_treadmill_cooper_360x640',
      h: 640,
    );
  });

  testWidgets('Ready: test on a treadmill, 1% at 360 x 800', (tester) async {
    await ready(
      tester,
      incline: 1,
      name: 'ready_treadmill_cooper_360x800',
      h: 800,
    );
  });

  testWidgets('Ready: flat treadmill shows the hint at 360 x 640', (
    tester,
  ) async {
    await ready(
      tester,
      incline: 0,
      name: 'ready_treadmill_flat_360x640',
      h: 640,
    );
  });

  for (final h in [800, 640]) {
    testWidgets('a rep on a treadmill with two marks at 360 x $h', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(
        RecordMode.intervals,
        engine.SessionSpec.norwegian4x4().toPigeon(),
        Units.km,
        treadmillInclinePct: 1,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('start-reps')));
      await pumpTimes(tester, 4);
      fake.advance(const Duration(minutes: 1));
      await fake.addTreadmillMark(500);
      fake.advance(const Duration(seconds: 55));
      await fake.addTreadmillMark(1000);
      await services.recording.refreshStatus();
      fake.advance(const Duration(seconds: 20));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(seconds: 1));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('treadmill-current-speed')), findsOne);
      await golden(tester, 'record_treadmill_timerep_360x$h');
    });

    testWidgets('the test on a treadmill, mid-test at 360 x $h', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(
        RecordMode.cooper,
        engine.SessionSpec.cooper.toPigeon(),
        Units.km,
        treadmillInclinePct: 1,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      fake.advance(const Duration(minutes: 4));
      await pumpTimes(tester, 3);
      await tester.tap(find.byKey(const ValueKey('start-test')));
      await pumpTimes(tester, 4);
      fake.advance(const Duration(minutes: 2));
      await fake.addTreadmillMark(500);
      fake.advance(const Duration(minutes: 2));
      await fake.addTreadmillMark(1000);
      await services.recording.refreshStatus();
      fake.advance(const Duration(seconds: 30));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(seconds: 1));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('belt-cooper-estimate')), findsOne);
      await golden(tester, 'record_treadmill_cooper_360x$h');
    });

    testWidgets('the test result on a treadmill at 360 x $h', (tester) async {
      final outdoor = cooperTestFile(
        n: 21,
        start: DateTime.utc(2026, 9, 10, 6),
        mps: 3.8,
      );
      final belt1 = cooperBeltFile(
        n: 22,
        start: DateTime.utc(2026, 10, 12, 6),
        distanceM: 2750,
      );
      final belt2 = cooperBeltFile(
        n: 23,
        start: DateTime.utc(2026, 11, 6, 6),
        distanceM: 2900,
        inclinePct: 2,
      );
      await pumpApp(
        tester,
        fakeServices(files: [outdoor, belt1, belt2]),
        pushRoute: Routes.verdict,
        pushArguments: belt2.id,
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('cooper-treadmill-tag')), findsOne);
      await golden(tester, 'cooper_result_treadmill_360x$h');
    });
  }
}
