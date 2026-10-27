import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/companion_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../state/companion_test.dart' show FakeCompanionHttp;

/// UI review 24-Oct #26: the screens people open first, at the largest
/// system font Android offers before "Largest" (1.3). An overflow throws and
/// fails the test; the PNG is the eyeball check. PNGs come from the CI
/// goldens artifact like every golden.
void main() {
  Future<void> shot(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull, reason: '$name overflowed at 1.3');
    expect(
      File('test/golden/goldens/$name.png').existsSync() ||
          autoUpdateGoldenFiles,
      isTrue,
      reason:
          'golden $name.png missing: commit it from the CI goldens artifact',
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  void scale13(WidgetTester tester) {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final run = RunSummary(
    id: 'interval',
    mode: RecordMode.intervals,
    start: testNow,
    durationMs: 2400000,
    distanceM: 6000,
    laps: 4,
    row: const IndexRow(
      lapCount: 4,
      eligibleAsPrior: true,
      workPaceSecPerKm: 262,
    ),
  );

  for (final h in [640, 800]) {
    testWidgets('font 1.3: Home at 360 x $h', (tester) async {
      scale13(tester);
      await pumpApp(
        tester,
        fakeServices(
          runs: [run],
          settings: const AppSettings(onboardingDone: true),
        ),
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      await shot(tester, 'font13_home_360x$h');
    });

    testWidgets('font 1.3: Start (intervals) at 360 x $h', (tester) async {
      scale13(tester);
      await pumpApp(
        tester,
        fakeServices(
          settings: const AppSettings(onboardingDone: true, sessionId: '400s'),
        ),
        pushRoute: Routes.start,
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      await shot(tester, 'font13_start_360x$h');
    });

    testWidgets('font 1.3: Settings at 360 x $h', (tester) async {
      scale13(tester);
      await pumpApp(
        tester,
        fakeServices(settings: const AppSettings(onboardingDone: true)),
        home: SettingsScreen(now: now),
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await shot(tester, 'font13_settings_360x$h');
    });

    testWidgets('font 1.3: Companion consent at 360 x $h', (tester) async {
      scale13(tester);
      final ctl = CompanionController(
        store: MemorySecretStore(),
        transfer: FakeTransferGateway(),
        client: CompanionClient(
          baseUrl: 'https://c.test',
          http: FakeCompanionHttp(),
        ),
        pollEvery: Duration.zero,
      );
      await pumpApp(
        tester,
        fakeServices(companion: ctl),
        home: const CompanionScreen(),
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await shot(tester, 'font13_companion_consent_360x$h');
    });
  }
}
