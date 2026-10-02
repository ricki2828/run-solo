import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
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
    });
  }
}
