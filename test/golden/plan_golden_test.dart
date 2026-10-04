import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/plan_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../helpers.dart';

void main() {
  for (final height in [640, 800]) {
    for (final state in ['create', 'plan']) {
      testWidgets('plan screen $state 360x$height', (tester) async {
        final start = testNow.subtract(const Duration(days: 8));
        await pumpApp(
          tester,
          fakeServices(
            plan: state == 'plan'
                ? engine.BlockPlanner.build(
                    lane: engine.IdentityLane.aerobic,
                    perWeek: 3,
                    start: start,
                  )
                : null,
            runs: state == 'plan'
                ? [
                    RunSummary(
                      id: 'a',
                      mode: RecordMode.intervals,
                      start: start.add(const Duration(hours: 7)),
                      durationMs: 2400000,
                      distanceM: 6000,
                      laps: 4,
                      row: const IndexRow(lapCount: 4, movingMs: 2400000),
                    ),
                  ]
                : const [],
          ),
          home: PlanScreen(now: now),
        );
        tester.view.physicalSize = Size(1080, height * 3);
        await pumpTimes(tester, 8);
        expect(tester.takeException(), isNull);
        final name = 'plan_${state}_360x$height';
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
