import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/trail_board_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The Trail result states and the trail board at 360 x 800 and 360 x 640.
/// PNGs come from CI like every golden (see screens_golden_test.dart).
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
  final d1 = DateTime.utc(2026, 9, 12, 6);
  final d2 = DateTime.utc(2026, 9, 20, 6);
  final d3 = DateTime.utc(2026, 9, 28, 6);

  RunSummary indexed(engine.RunFile f) {
    final a = const engine.RunEngine().analyze(f, now: now());
    return RunSummary(
      id: f.id,
      mode: RecordMode.trail,
      start: f.start,
      durationMs: f.end.difference(f.start).inMilliseconds,
      distanceM: f.distanceM,
      laps: 0,
      street: 'Kastro',
      row: IndexRow.of(
        f,
        a,
        null,
        sidecar: engine.RunSidecar(runId: f.id, street: 'Kastro'),
      ),
    );
  }

  void phone(WidgetTester tester, int h) {
    tester.view.physicalSize = Size(360 * 3, h * 3.0);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> result(
    WidgetTester tester,
    int h,
    engine.RunFile current,
    List<engine.RunFile> earlier,
    String name,
  ) async {
    await pumpApp(
      tester,
      fakeServices(
        files: [current],
        runs: [
          for (final e in [...earlier, current]) indexed(e),
        ],
        sidecars: {
          current.id: engine.RunSidecar(runId: current.id, street: 'Kastro'),
        },
      ),
      pushRoute: Routes.verdict,
      pushArguments: current.id,
    );
    // After pumpApp, which sets its own phone viewport.
    phone(tester, h);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 200));
    await golden(tester, '${name}_360x$h');
  }

  final old = trailLoopRun(n: 1, start: d1, secPerKm: 420);
  for (final h in [800, 640]) {
    testWidgets('trail verdict: matched faster at 360 x $h', (tester) async {
      final run = trailLoopRun(n: 2, start: d2, secPerKm: 400);
      await result(tester, h, run, [old], 'trail_verdict_faster');
    });

    testWidgets('trail verdict: matched slower at 360 x $h', (tester) async {
      final run = trailLoopRun(n: 3, start: d3, secPerKm: 450);
      await result(tester, h, run, [old], 'trail_verdict_slower');
    });

    testWidgets('trail verdict: no match, true pace at 360 x $h', (
      tester,
    ) async {
      final run = trailLoopRun(n: 4, start: d3, secPerKm: 380, reverse: true);
      await result(tester, h, run, [old], 'trail_verdict_effort');
    });

    testWidgets('trail verdict: baseline at 360 x $h', (tester) async {
      final run = trailLoopRun(n: 5, start: d1, secPerKm: 400);
      await result(tester, h, run, [], 'trail_verdict_baseline');
    });

    testWidgets('trail board at 360 x $h', (tester) async {
      final runs = [
        old,
        trailLoopRun(n: 2, start: d2, secPerKm: 400),
        trailLoopRun(n: 3, start: d3, secPerKm: 410),
      ];
      await pumpApp(
        tester,
        fakeServices(runs: [for (final r in runs) indexed(r)]),
        home: TrailBoardScreen(trailKey: 'trail:${old.id}'),
      );
      phone(tester, h);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      await golden(tester, 'trail_board_360x$h');
    });
  }
}
