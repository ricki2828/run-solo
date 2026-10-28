import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// The pre-run choice on Ready (22-Oct): two big buttons, one selected.
/// Rendered on CI; a missing PNG fails, the fix is to commit it from the
/// `goldens-pr-<N>` release.
Future<void> golden(WidgetTester tester, String name) async {
  expect(
    File('test/golden/goldens/$name.png').existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens release',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  for (final choice in engine.CoachChoice.values) {
    testWidgets('ready: free run, ${choice.key} picked, 360x640', (
      tester,
    ) async {
      await pumpApp(
        tester,
        fakeServices(
          settings: AppSettings(
            onboardingDone: true,
            lastMode: RecordMode.free,
            coachChoice: choice,
          ),
        ),
        pushRoute: Routes.start,
        pushArguments: const StartArgs(readyFirst: true),
      );
      // After pumpApp, which sets its own size.
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      await pumpTimes(tester, 8);
      await settleAnimations(tester);
      await golden(tester, 'ready_coach_choice_${choice.key}_360x640');
    });
  }

  testWidgets('ready: free run, choice at font scale 1.3, 360x640', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.free,
        ),
      ),
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    await pumpTimes(tester, 8);
    await settleAnimations(tester);
    await golden(tester, 'ready_coach_choice_scale13_360x640');
  });
}
