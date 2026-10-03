import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/screens/run_detail_screen.dart';

import '../helpers.dart';
import '../route_fixtures.dart';
import '../run_fixtures.dart';

/// Run detail of a run that followed a route: the planned line (muted Bone)
/// under the line actually run (the run type's colour), and the summary line.
/// Fake map factory (the real map is a platform view); PNGs come from the CI
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
    testWidgets('run detail: planned vs actual at 360 x $h', (tester) async {
      final run = withFollowedRoute(
        freeRunFile(n: 7, start: DateTime.utc(2026, 9, 24, 6)),
      );
      await pumpApp(
        tester,
        fakeServices(
          files: [run],
          maps: const FakeMapSurfaceFactory(available: true),
        ),
        home: RunDetailScreen(runId: run.id),
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 8);
      await settleAnimations(tester);
      await golden(tester, 'run_detail_followed_route_360x$h');
    });
  }
}
