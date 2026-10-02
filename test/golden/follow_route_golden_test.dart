import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../route_fixtures.dart';

/// Follow a route, live: the NUMBERS to-go line and the MAP view with the
/// planned line (muted Bone) under the track, at 360 x 640 and 360 x 800,
/// drawn with the fake map factory (the real map is a platform view that
/// renders nothing under flutter_test). PNGs come from the CI goldens
/// artifact like the others (see screens_golden_test.dart).
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens artifact',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

Future<void> run(
  WidgetTester tester, {
  required int height,
  required bool map,
  required RecordMode mode,
  RouteProgress? progress,
}) async {
  final fake = FakeRecorderGateway(now: now)..emitRoute = true;
  final services = fakeServices(
    recorder: fake,
    maps: const FakeMapSurfaceFactory(available: true),
    settings: AppSettings(
      onboardingDone: true,
      liveMapTypes: map ? {mode.name} : const {},
    ),
  );
  await services.recording.start(
    mode,
    null,
    Units.km,
    route: testRoute().toFollowRoute(),
  );
  await pumpApp(tester, services, pushRoute: Routes.recording);
  tester.view.physicalSize = Size(1080, height * 3.0);
  await pumpTimes(tester, 4);
  fake.routeProgress = progress;
  if (mode == RecordMode.trail) {
    fake
      ..elevGainM = 124
      ..elevLossM = 80
      ..gradePct = 3.2;
  }
  for (var i = 0; i < 400; i++) {
    fake.advance(const Duration(seconds: 1));
    if (i % 20 == 0) await tester.pump();
  }
  await pumpTimes(tester, 5);
  await settleAnimations(tester);
}

void main() {
  for (final h in [800, 640]) {
    testWidgets('record: free run following a route, NUMBERS at 360 x $h', (
      tester,
    ) async {
      await run(tester, height: h, map: false, mode: RecordMode.free);
      await golden(tester, 'record_route_numbers_free_360x$h');
    });

    testWidgets('record: trail run, next turn and climb, NUMBERS at 360 x $h', (
      tester,
    ) async {
      await run(
        tester,
        height: h,
        map: false,
        mode: RecordMode.trail,
        progress: RouteProgress(
          toGoM: 1840,
          climbToGoM: 46,
          off: false,
          turnLabel: 'Left turn',
          turnInM: 120,
        ),
      );
      await golden(tester, 'record_route_numbers_trail_360x$h');
    });

    testWidgets('record: free run following a route, MAP at 360 x $h', (
      tester,
    ) async {
      await run(tester, height: h, map: true, mode: RecordMode.free);
      await golden(tester, 'record_route_map_free_360x$h');
    });
  }

  testWidgets('record: off route, NUMBERS at 360 x 640', (tester) async {
    await run(
      tester,
      height: 640,
      map: false,
      mode: RecordMode.free,
      progress: RouteProgress(toGoM: 1840, climbToGoM: 46, off: true),
    );
    await golden(tester, 'record_route_off_numbers_free_360x640');
  });

  testWidgets('record: next turn, MAP at 360 x 640', (tester) async {
    await run(
      tester,
      height: 640,
      map: true,
      mode: RecordMode.free,
      progress: RouteProgress(
        toGoM: 1840,
        climbToGoM: 46,
        off: false,
        turnLabel: 'Keep right',
        turnInM: 80,
      ),
    );
    await golden(tester, 'record_route_turn_map_free_360x640');
  });
}
