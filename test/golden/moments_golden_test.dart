import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/moment_screen.dart';
import 'package:run_solo/screens/weekly_story_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';

import '../helpers.dart';

/// The full-screen moments and the weekly story at 360 x 800. PNGs come from
/// CI like every golden (see screens_golden_test.dart).
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
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3.0);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> shot(WidgetTester tester, Widget home, String name) async {
    await pumpApp(tester, fakeServices(), home: home);
    phone(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // The entrance is 1.4 s at most; settle past it.
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 200));
    await golden(tester, name);
  }

  testWidgets('moment: first 5K', (tester) async {
    await shot(
      tester,
      const MomentScreen(
        moment: Moment(
          id: 'first-5k',
          kind: MomentKind.first,
          eyebrow: 'Your first',
          big: '5K',
          detail: '28:12 on Sunday, run 5. Small first, 4 of 15.',
        ),
      ),
      'moment_first_5k',
    );
  });

  testWidgets('moment: level up', (tester) async {
    await shot(
      tester,
      const MomentScreen(
        moment: Moment(
          id: 'level-14',
          kind: MomentKind.levelUp,
          eyebrow: 'Level up',
          big: 'Level 14',
          detail: 'Up from 12 a month ago. Age grade 58%.',
          lane: engine.IdentityLane.aerobic,
        ),
      ),
      'moment_level_up',
    );
  });

  testWidgets('moment: personal best', (tester) async {
    await shot(
      tester,
      const MomentScreen(
        moment: Moment(
          id: 'pb-5k',
          kind: MomentKind.pb,
          eyebrow: 'New 5K best',
          big: '26:41',
          detail: '1:14 faster than September.',
          lane: engine.IdentityLane.speed,
        ),
      ),
      'moment_pb',
    );
  });

  testWidgets('weekly story', (tester) async {
    await shot(
      tester,
      WeeklyStoryScreen(story: ProgressSnapshot.sample('month3').story),
      'weekly_story',
    );
  });
}
