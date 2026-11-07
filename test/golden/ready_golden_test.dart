import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// Start flow goldens (10-Oct): the Ready screen, the countdown, the picker's
/// READY UP button and Home's session button. Rendered on CI; a missing PNG
/// fails, the fix is to commit it from the `goldens-pr-<N>` release.
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

Future<void> openReady(
  WidgetTester tester,
  AppServices services, {
  bool phone640 = true,
}) async {
  await pumpApp(
    tester,
    services,
    pushRoute: Routes.start,
    pushArguments: const StartArgs(readyFirst: true),
  );
  // After pumpApp, which sets its own size: the 640 dp phone the ready_*
  // goldens are named for. The countdown shots keep pumpApp's taller size.
  if (phone640) {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
  }
  await pumpTimes(tester, 4);
  await settleAnimations(tester);
  await pumpTimes(tester, 2);
}

void main() {
  testWidgets('ready: free run, GPS searching, no strap', (tester) async {
    await openReady(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.free,
        ),
      ),
    );
    await golden(tester, 'ready_gps_searching_360x640');
  });

  testWidgets('ready: GPS good and a strap connected', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        strap: SavedStrap(address: 'X', name: 'Polar H10'),
      ),
      ble: FakeBleGateway()
        ..connected = true
        ..lastHr = 61,
    );
    await openReady(tester, services);
    (services.recorder as FakeRecorderGateway).emitGpsProbe(
      GpsProbeEvent(fix: true, lat: -41.3, lon: 174.8, accuracyM: 6),
    );
    await pumpTimes(tester, 3);
    await golden(tester, 'ready_gps_good_strap_360x640');
  });

  testWidgets('ready: intervals preset', (tester) async {
    await openReady(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.intervals,
        ),
      ),
    );
    await golden(tester, 'ready_intervals_360x640');
  });

  testWidgets('ready: free run with a last run', (tester) async {
    await openReady(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.free,
        ),
        runs: [
          summary(
            id: 'f1',
            start: testNow.subtract(const Duration(days: 3)),
            fourByFour: false,
            durationMs: 37 * 60 * 1000,
            distanceM: 7200,
          ),
        ],
      ),
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'ready_free_last_run_360x640');
  });

  testWidgets('countdown at 3', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.intervals,
      ),
    );
    await openReady(tester, services, phone640: false);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(); // starts the numeral's animation
    await tester.pump(const Duration(milliseconds: 500));
    await golden(tester, 'countdown_3_360x640');
    // Leave the screen tidy: cancel so no timer is pending.
    await tester.tap(find.byKey(const ValueKey('countdown')));
    await pumpTimes(tester, 2);
  });

  testWidgets('countdown at GO', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.intervals,
      ),
    );
    await openReady(tester, services, phone640: false);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(seconds: 3));
    // GO's numeral has finished animating in; the 450 ms hold has not ended.
    await tester.pump(const Duration(milliseconds: 400));
    await golden(tester, 'countdown_go_360x640');
    await tester.pump(const Duration(seconds: 1));
    await pumpTimes(tester, 4);
  });

  testWidgets('picker: READY UP button', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.intervals,
        ),
      ),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'start_ready_up_360x640');
  });

  testWidgets('home: session button leads to Ready', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.intervals,
        ),
      ),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'home_cta_ready_360x640');
  });
}
