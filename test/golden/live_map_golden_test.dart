import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// The record screen's MAP view (founder 2-Oct), drawn with the fake map
/// factory (the route shape on our canvas, as the real map is a platform
/// view that renders nothing under flutter_test). PNGs come from the CI
/// goldens artifact like the others (see screens_golden_test.dart).
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

void main() {
  for (final h in [800, 640]) {
    testWidgets('record: map view at 360 x $h', (tester) async {
      final fake = FakeRecorderGateway(now: now)..emitRoute = true;
      final services = fakeServices(
        recorder: fake,
        maps: const FakeMapSurfaceFactory(available: true),
        settings: const AppSettings(
          onboardingDone: true,
          liveMapTypes: {'intervals'},
        ),
      );
      await services.recording.start(
        RecordMode.intervals,
        standardPreset(),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      await fake.startReps();
      await pumpTimes(tester, 5);
      for (var i = 0; i < 95; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      await golden(tester, 'record_map_rep_360x$h');
      // Into the recovery: the countdown is the hero over the same strip.
      for (var i = 0; i < 160; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      await golden(tester, 'record_map_recovery_360x$h');
    });
  }

  // Laps: the LAP button keeps its size and place under the map.
  for (final h in [800, 640]) {
    testWidgets('record: laps map view at 360 x $h', (tester) async {
      final fake = FakeRecorderGateway(now: now)..emitRoute = true;
      final services = fakeServices(
        recorder: fake,
        maps: const FakeMapSurfaceFactory(available: true),
        settings: const AppSettings(
          onboardingDone: true,
          liveMapTypes: {'laps'},
        ),
      );
      await services.recording.start(RecordMode.laps, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      for (var i = 0; i < 95; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      await golden(tester, 'record_map_laps_360x$h');
    });
  }

  // Page 1 of a laps run with maps on: no overflow, and on the short phone
  // no MAP button (the dots and the swipe still reach the map).
  for (final h in [800, 640]) {
    testWidgets('record: laps page 1 with maps on at 360 x $h', (tester) async {
      final fake = FakeRecorderGateway(now: now)..emitRoute = true;
      final services = fakeServices(
        recorder: fake,
        maps: const FakeMapSurfaceFactory(available: true),
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(RecordMode.laps, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      for (var i = 0; i < 95; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('page-map-button')),
        h == 640 ? findsNothing : findsOneWidget,
      );
      expect(find.byKey(const ValueKey('page-dots')), findsOneWidget);
      await golden(tester, 'record_laps_map_on_360x$h');
    });
  }

  testWidgets('record: free map view at 360 x 800', (tester) async {
    final fake = FakeRecorderGateway(now: now)..emitRoute = true;
    final services = fakeServices(
      recorder: fake,
      maps: const FakeMapSurfaceFactory(available: true),
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'free'}),
    );
    await services.recording.start(RecordMode.free, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    tester.view.physicalSize = const Size(1080, 800 * 3.0);
    await pumpTimes(tester, 4);
    for (var i = 0; i < 95; i++) {
      fake.advance(const Duration(seconds: 1));
      await tester.pump();
    }
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    await golden(tester, 'record_map_free_360x800');
  });

  // Free and Trail MAP strip (founder 3-Oct): distance, time and average pace
  // at one size.
  for (final mode in [RecordMode.free, RecordMode.trail]) {
    for (final h in [800, 640]) {
      if (mode == RecordMode.free && h == 800) {
        continue; // kept below under its original name
      }
      testWidgets('record: ${mode.name} map view at 360 x $h', (tester) async {
        final fake = FakeRecorderGateway(now: now)..emitRoute = true;
        final services = fakeServices(
          recorder: fake,
          maps: const FakeMapSurfaceFactory(available: true),
          settings: AppSettings(
            onboardingDone: true,
            liveMapTypes: {mode.name},
          ),
        );
        await services.recording.start(mode, null, Units.km);
        await pumpApp(tester, services, pushRoute: Routes.recording);
        tester.view.physicalSize = Size(1080, h * 3.0);
        await pumpTimes(tester, 4);
        for (var i = 0; i < 95; i++) {
          fake.advance(const Duration(seconds: 1));
          await tester.pump();
        }
        await pumpTimes(tester, 5);
        await settleAnimations(tester);
        await golden(tester, 'record_map_${mode.name}_360x$h');
      });
    }
  }

  // Trail page 1 with a map available: the MAP button sits where page 2's
  // NUMBERS button does (founder 14-Oct).
  for (final h in [800, 640]) {
    testWidgets('record: trail numbers page with MAP button at 360 x $h', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now)
        ..emitRoute = true
        ..elevGainM = 124
        ..elevLossM = 87;
      final services = fakeServices(
        recorder: fake,
        maps: const FakeMapSurfaceFactory(available: true),
        settings: const AppSettings(onboardingDone: true),
      );
      await services.recording.start(RecordMode.trail, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      for (var i = 0; i < 95; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('page-map-button')), findsOneWidget);
      await golden(tester, 'record_numbers_trail_map_button_360x$h');
    });
  }

  // Trail MAP view, not retracing: VS START rides in the DISTANCE row and
  // the map keeps all its height.
  for (final h in [800, 640]) {
    testWidgets('record: trail map view height vs start at 360 x $h', (
      tester,
    ) async {
      final fake = FakeRecorderGateway(now: now)
        ..emitRoute = true
        ..elevGainM = 124
        ..elevLossM = 87
        ..heightVsStartM = 42;
      final services = fakeServices(
        recorder: fake,
        maps: const FakeMapSurfaceFactory(available: true),
        settings: const AppSettings(
          onboardingDone: true,
          liveMapTypes: {'trail'},
        ),
      );
      await services.recording.start(RecordMode.trail, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      for (var i = 0; i < 95; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('height-vs-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('back-to-start')), findsNothing);
      await golden(tester, 'record_map_trail_height_360x$h');
    });
  }

  // Trail MAP view while heading back over the old track: BACK TO START and
  // VS START on one strip, the map keeping a usable height.
  for (final h in [800, 640]) {
    testWidgets('record: trail map view retracing at 360 x $h', (tester) async {
      final fake = FakeRecorderGateway(now: now)
        ..emitRoute = true
        ..elevGainM = 124
        ..elevLossM = 87
        ..heightVsStartM = -18
        ..retracing = true
        ..backToStartM = 2400
        ..climbAheadM = 38
        ..descentAheadM = 12;
      final services = fakeServices(
        recorder: fake,
        maps: const FakeMapSurfaceFactory(available: true),
        settings: const AppSettings(
          onboardingDone: true,
          liveMapTypes: {'trail'},
        ),
      );
      await services.recording.start(RecordMode.trail, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      for (var i = 0; i < 95; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 5);
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('back-to-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('height-vs-start')), findsOneWidget);
      await golden(tester, 'record_map_trail_retracing_360x$h');
    });
  }

  testWidgets('record: goal last minute map view, moment cleared, 360 x 800', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now)..emitRoute = true;
    final services = fakeServices(
      recorder: fake,
      maps: const FakeMapSurfaceFactory(available: true),
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'goal'}),
    );
    await services.recording.start(
      RecordMode.intervals,
      engine.SessionSpec.goalTime(1800, '30 min').toPigeon(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    tester.view.physicalSize = const Size(1080, 800 * 3.0);
    await pumpTimes(tester, 4);
    for (var i = 0; i < 1750; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(seconds: 8));
    await pumpTimes(tester, 4);
    await settleAnimations(tester);
    await golden(tester, 'record_map_goal_last_clear_360x800');
  });

  testWidgets('record: goal cool-down map view at 360 x 800', (tester) async {
    final fake = FakeRecorderGateway(now: now)..emitRoute = true;
    final services = fakeServices(
      recorder: fake,
      maps: const FakeMapSurfaceFactory(available: true),
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'goal'}),
    );
    await services.recording.start(
      RecordMode.intervals,
      engine.SessionSpec.goalTime(1800, '30 min').toPigeon(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    tester.view.physicalSize = const Size(1080, 800 * 3.0);
    await pumpTimes(tester, 4);
    for (var i = 0; i < 1870; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    await pumpTimes(tester, 6);
    await settleAnimations(tester);
    await golden(tester, 'record_map_goal_cooldown_360x800');
  });
}
