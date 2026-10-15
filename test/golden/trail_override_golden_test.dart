import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/trail_board_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The split / merge controls: the trail board with "Not this trail" and the
/// quiet "Looks off" hint, and the "Same trail as..." picker on a run that
/// was not grouped. PNGs come from CI like every golden.
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

  final old = trailLoopRun(n: 1, start: d1, secPerKm: 420);
  for (final h in [800, 640]) {
    testWidgets('trail board with split controls at 360 x $h', (tester) async {
      // The third run is 9% short: near the length gate, so it reads "Looks off".
      final runs = [
        old,
        trailLoopRun(n: 2, start: d2, secPerKm: 400),
        trailLoopRun(n: 3, start: d3, secPerKm: 405, km: 5.45, loopKm: 6),
      ];
      await pumpApp(
        tester,
        fakeServices(runs: [for (final r in runs) indexed(r)]),
        home: TrailBoardScreen(trailKey: 'trail:${old.id}'),
      );
      phone(tester, h);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      expect(find.text('Not this trail'), findsWidgets);
      await golden(tester, 'trail_override_board_360x$h');
    });

    testWidgets('same trail as picker at 360 x $h', (tester) async {
      // Run in the opposite direction: not grouped, but its start is near.
      final lone = trailLoopRun(n: 4, start: d3, secPerKm: 380, reverse: true);
      final others = [old, trailLoopRun(n: 2, start: d2, secPerKm: 400)];
      await pumpApp(
        tester,
        fakeServices(
          files: [lone],
          runs: [
            for (final r in [...others, lone]) indexed(r),
          ],
        ),
        home: RunDetailScreen(runId: lone.id),
      );
      phone(tester, h);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      final button = find.byKey(const ValueKey('same-trail-as'));
      await tester.scrollUntilVisible(button, 300);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('trail-picker')), findsOneWidget);
      await golden(tester, 'trail_override_picker_360x$h');
    });
  }
}
