import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/plan_screen.dart';
import 'package:run_solo/state/history_store.dart';

import '../helpers.dart';
import '../screens/load_warning_test.dart' show hotWeek;

void main() {
  for (final height in [640, 800]) {
    for (final state in ['home', 'home_plan', 'plan', 'start']) {
      testWidgets('load warning $state 360x$height', (tester) async {
        final plan = engine.BlockPlanner.build(
          lane: engine.IdentityLane.aerobic,
          perWeek: 3,
          start: testNow,
        );
        final runs = <RunSummary>[
          for (final r in hotWeek())
            if (state == 'home' ||
                state == 'start' ||
                r.start.isBefore(testNow))
              r,
        ];
        await pumpApp(
          tester,
          fakeServices(runs: runs, plan: state == 'home' ? null : plan),
          home: state == 'plan' ? PlanScreen(now: now) : HomeScreen(now: now),
        );
        tester.view.physicalSize = Size(1080, height * 3);
        await pumpTimes(tester, 8);
        expect(tester.takeException(), isNull);
        final name = 'load_warning_${state}_360x$height';
        expect(
          File('test/golden/goldens/$name.png').existsSync() ||
              autoUpdateGoldenFiles,
          isTrue,
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
      });
    }
  }
}
