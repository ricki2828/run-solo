import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/time_in_zone.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// "Time in zone, in colour" on run detail, dark (the real screen) and light
/// (the widget on the light theme; the app itself is dark only). PNGs come
/// from the CI goldens artifact like the others (see screens_golden_test.dart).
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
    testWidgets('run detail: time in zone, dark, 360 x $h', (tester) async {
      tester.view.physicalSize = Size(360 * 3, h * 3.0);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Z1 to Z4 in turn, no reading for the last 18 %.
      final base = freeRunFile(
        n: 81,
        start: DateTime.utc(2026, 10, 2, 6),
        seconds: 2400,
      );
      final run = base.copyWith(
        samples: [
          for (final s in base.samples)
            s.copyWith(
              hr: switch (s.tMs ~/ 1000) {
                < 240 => 100,
                < 960 => 125,
                < 1700 => 145,
                < 1960 => 165,
                _ => null,
              },
            ),
        ],
      );
      await pumpApp(
        tester,
        fakeServices(files: [run]),
        home: RunDetailScreen(runId: run.id),
      );
      await pumpTimes(tester, 6);
      await scrollTo(tester, find.text('TIME IN ZONE'));
      await settleAnimations(tester);
      await golden(tester, 'time_in_zone_dark_360x$h');
    });

    testWidgets('time in zone, light, 360 x $h', (tester) async {
      await loadRunSoloFonts();
      tester.view.physicalSize = Size(360 * 3, h * 3.0);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: runSoloTheme(brightness: Brightness.light),
          home: const Scaffold(
            body: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(Space.screenGutter),
                child: TimeInZone(
                  seconds: [480, 240, 720, 760, 260, 0],
                  maxHrLine: 'Max HR 190, entered',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await golden(tester, 'time_in_zone_light_360x$h');
    });
  }
}
