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
  bool route = true,
  int seconds = 240,
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
    route: route ? testRoute().toFollowRoute() : null,
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
  // 240 s stays under 1 km, so no KM moment covers the screen (24-Oct
  // review #2: all 11 goldens showed "KM 1" over the cue they test).
  for (var i = 0; i < seconds; i++) {
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

  // Trail without a route: 360 x 640 overflowed by ~39 px on main (GAP row).
  for (final h in [800, 640]) {
    testWidgets('record: trail run, no route, NUMBERS at 360 x $h', (
      tester,
    ) async {
      await run(
        tester,
        height: h,
        map: false,
        mode: RecordMode.trail,
        route: false,
      );
      await golden(tester, 'record_trail_numbers_360x$h');
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
    expect(find.text('OFF ROUTE'), findsOneWidget);
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

  // End of the route: the big TURN AROUND card, above both pages.
  for (final h in [800, 640]) {
    testWidgets('record: end of route, TURN AROUND, NUMBERS at 360 x $h', (
      tester,
    ) async {
      await run(
        tester,
        height: h,
        map: false,
        mode: RecordMode.free,
        progress: RouteProgress(
          toGoM: 8,
          off: false,
          endCue: RouteEndCue.turnAround,
        ),
      );
      await golden(tester, 'record_route_end_numbers_free_360x$h');
    });
  }

  testWidgets('record: end of route, TURN AROUND, MAP at 360 x 640', (
    tester,
  ) async {
    await run(
      tester,
      height: 640,
      map: true,
      mode: RecordMode.free,
      progress: RouteProgress(
        toGoM: 8,
        off: false,
        endCue: RouteEndCue.turnAround,
      ),
    );
    await golden(tester, 'record_route_end_map_free_360x640');
  });

  testWidgets('record: end of a loop, ROUTE DONE, NUMBERS at 360 x 640', (
    tester,
  ) async {
    await run(
      tester,
      height: 640,
      map: false,
      mode: RecordMode.free,
      progress: RouteProgress(toGoM: 8, off: false, endCue: RouteEndCue.done),
    );
    await golden(tester, 'record_route_done_numbers_free_360x640');
  });

  // 24-Oct review #2: a route cue outranks the km moment.
  for (final (name, progress) in [
    (
      'turn around',
      RouteProgress(toGoM: 8, off: false, endCue: RouteEndCue.turnAround),
    ),
    ('off route', RouteProgress(toGoM: 1840, off: true)),
  ]) {
    testWidgets('record: $name across 1 km, no KM moment over it', (
      tester,
    ) async {
      await run(
        tester,
        height: 640,
        map: false,
        mode: RecordMode.free,
        progress: progress,
        seconds: 400,
      );
      expect(find.byKey(const ValueKey('inrun-moment-scrim')), findsNothing);
    });
  }

  testWidgets('record: crossing 1 km with no cue still shows the moment', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now)..emitRoute = true;
    final services = fakeServices(
      recorder: fake,
      maps: const FakeMapSurfaceFactory(available: true),
      settings: AppSettings(onboardingDone: true),
    );
    await services.recording.start(RecordMode.free, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    var seen = false;
    for (var i = 0; i < 400 && !seen; i++) {
      fake.advance(const Duration(seconds: 1));
      await tester.pump();
      seen = find
          .byKey(const ValueKey('inrun-moment-scrim'))
          .evaluate()
          .isNotEmpty;
    }
    expect(seen, isTrue);
  });
}
