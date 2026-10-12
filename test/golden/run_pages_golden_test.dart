import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/odometer_distance.dart';

import '../helpers.dart';

/// The record screen's two pages (Ricki 11-Oct): page 1 the run numbers,
/// page 2 the map and every route readout. Zone 3 is the bright yellow flood
/// with ink numbers (the sun case), zone 2 a dark Bone-on-green flood.
/// The odometer distance is a decision for Ricki: off in the app, drawn here
/// only. PNGs come from the CI goldens like the others.
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

Future<void> openRun(
  WidgetTester tester, {
  required int hr,
  required bool mapPage,
  RecordMode mode = RecordMode.trail,
  int height = 800,
}) async {
  final fake = FakeRecorderGateway(now: now)
    ..emitRoute = true
    ..scriptedHr = hr
    ..liveSecPerKm = 270
    ..elevGainM = 124
    ..elevLossM = 87
    ..gradePct = 3
    ..heightVsStartM = -18
    ..retracing = true
    ..backToStartM = 2400
    ..climbAheadM = 38
    ..descentAheadM = 12;
  final services = fakeServices(
    recorder: fake,
    maps: const FakeMapSurfaceFactory(available: true),
    settings: AppSettings(
      onboardingDone: true,
      liveMapTypes: mapPage ? {mode.name} : const {},
    ),
  );
  await services.recording.start(mode, null, Units.km);
  await pumpApp(tester, services, pushRoute: Routes.recording);
  tester.view.physicalSize = Size(1080, height * 3.0);
  await pumpTimes(tester, 4);
  // About 7.4 km at 4:30/km: a two-digit distance for the odometer.
  fake.advance(const Duration(seconds: 2000));
  await pumpTimes(tester, 5);
  await settleAnimations(tester);
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  tearDown(() => kOdometerDistance = false);

  const zones = {'z3': 140, 'z2': 124, 'z4': 162};

  for (final z in ['z3', 'z2']) {
    testWidgets('run page 1: numbers, zone ${z.substring(1)}', (tester) async {
      kOdometerDistance = false; // plain-digit variant
      await openRun(tester, hr: zones[z]!, mapPage: false);
      expect(find.byKey(const ValueKey('page-dots')), findsOneWidget);
      expect(find.byKey(const ValueKey('free-distance')), findsOneWidget);
      expect(find.textContaining('TRUE'), findsNothing);
      expect(find.byKey(const ValueKey('elevation-row')), findsNothing);
      await golden(tester, 'run_page1_${z}_360x800');
    });

    testWidgets('run page 2: map and route readouts, zone ${z.substring(1)}', (
      tester,
    ) async {
      await openRun(tester, hr: zones[z]!, mapPage: true);
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('free-distance')), findsNothing);
      await golden(tester, 'run_page2_${z}_360x800');
    });
  }

  testWidgets('run page 1 at 360 x 640, zone 3', (tester) async {
    kOdometerDistance = false; // plain-digit variant
    await openRun(tester, hr: zones['z3']!, mapPage: false, height: 640);
    await golden(tester, 'run_page1_z3_360x640');
  });

  // Odometer distance: the default since Ricki's 12-Oct "odo yes".
  for (final z in ['z3', 'z2', 'z4']) {
    testWidgets('run page 1 with odometer distance, zone ${z.substring(1)}', (
      tester,
    ) async {
      kOdometerDistance = true;
      await openRun(tester, hr: zones[z]!, mapPage: false);
      expect(find.byKey(const ValueKey('odo-cell-0')), findsWidgets);
      await golden(tester, 'run_page1_odometer_${z}_360x800');
    });
  }

  testWidgets('the flag drives the odometer', (tester) async {
    kOdometerDistance = true;
    await openRun(tester, hr: zones['z3']!, mapPage: false);
    expect(find.byKey(const ValueKey('odo-cell-0')), findsWidgets);
  });
}
