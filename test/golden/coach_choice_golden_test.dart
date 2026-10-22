import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// The pre-run choice on Start (22-Oct): two big buttons, one selected.
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
    testWidgets('start: free run, ${choice.key} picked, 360x640', (
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
      );
      // After pumpApp, which sets its own size.
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      await pumpTimes(tester, 8);
      await settleAnimations(tester);
      await golden(tester, 'start_coach_choice_${choice.key}_360x640');
    });
  }
}
