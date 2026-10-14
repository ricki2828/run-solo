import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/platform_api.g.dart' show TrailProgress;
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/odometer_distance.dart';
import 'package:run_solo/widgets/trail_ghost.dart';

import '../helpers.dart';

/// The known-trail readouts on the run screen: ahead of best, behind, TURN
/// AROUND and Off the trail. PNGs come from the CI goldens like the others.
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

TrailProgress trail({
  int? best,
  int? last,
  bool lastIsBest = true,
  bool off = false,
  bool turn = false,
}) => TrailProgress(
  trailId: 't1',
  name: 'Ridge loop',
  alongM: 2400,
  toGoM: 2600,
  off: off,
  aheadBestMs: best,
  aheadLastMs: last,
  lastIsBest: lastIsBest,
  bestDateMs: 0,
  lastDateMs: 0,
  turnCue: turn,
);

Future<FakeRecorderGateway> openRun(
  WidgetTester tester, {
  required TrailProgress? progress,
  required int hr,
  bool mapPage = false,
  int height = 800,
}) async {
  final fake = FakeRecorderGateway(now: now)
    ..emitRoute = true
    ..scriptedHr = hr
    ..liveSecPerKm = 270
    ..elevGainM = 124
    ..elevLossM = 87
    ..gradePct = 6
    ..trailProgress = progress;
  final services = fakeServices(
    recorder: fake,
    maps: const FakeMapSurfaceFactory(available: true),
    settings: AppSettings(
      onboardingDone: true,
      liveMapTypes: mapPage ? {RecordMode.trail.name} : const {},
    ),
  );
  await services.recording.start(RecordMode.trail, null, Units.km);
  await pumpApp(tester, services, pushRoute: Routes.recording);
  tester.view.physicalSize = Size(1080, height * 3.0);
  await pumpTimes(tester, 4);
  fake.advance(const Duration(seconds: 2000));
  await pumpTimes(tester, 5);
  await settleAnimations(tester);
  await tester.pump(const Duration(milliseconds: 700));
  return fake;
}

void main() {
  tearDown(() => kOdometerDistance = false);

  test('gap wording', () {
    expect(trailGapLine(12000, 'best'), '12 s ahead of best');
    expect(trailGapLine(-8400, 'last'), '8 s behind last');
    expect(trailGapLine(65000, 'best'), '1:05 ahead of best');
    expect(trailGapLine(300, 'best'), 'Level with best');
  });

  testWidgets('no trail matched: no readout, no gap', (tester) async {
    await openRun(tester, progress: null, hr: 124);
    expect(find.byKey(const ValueKey('trail-ghost')), findsNothing);
    expect(find.byKey(const ValueKey('trail-turn-card')), findsNothing);
  });

  testWidgets('matched ahead of best: mint, page 1', (tester) async {
    await openRun(tester, progress: trail(best: 12000), hr: 124);
    expect(find.text('12 s ahead of best'), findsOneWidget);
    expect(find.byKey(const ValueKey('trail-ghost-last')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('trail-ghost-best')))
          .style!
          .fontSize,
      greaterThanOrEqualTo(36),
    );
    await golden(tester, 'trail_ghost_ahead_z2_360x800');
  });

  testWidgets('behind best, and behind last when last was not the best', (
    tester,
  ) async {
    await openRun(
      tester,
      progress: trail(best: -8000, last: 5000, lastIsBest: false),
      hr: 140,
    );
    expect(find.text('8 s behind best'), findsOneWidget);
    expect(find.text('5 s ahead of last'), findsOneWidget);
    await golden(tester, 'trail_ghost_behind_z3_360x800');
  });

  testWidgets('TURN AROUND card', (tester) async {
    await openRun(tester, progress: trail(best: 4000, turn: true), hr: 124);
    expect(find.text('TURN AROUND'), findsOneWidget);
    await golden(tester, 'trail_ghost_turn_z2_360x800');
  });

  testWidgets('off the trail', (tester) async {
    await openRun(tester, progress: trail(off: true), hr: 124);
    expect(find.text('Off the trail'), findsOneWidget);
    await golden(tester, 'trail_ghost_off_z2_360x800');
  });

  testWidgets('page 2: the best gap sits above climb and grade', (
    tester,
  ) async {
    await openRun(
      tester,
      progress: trail(best: 12000, last: -3000, lastIsBest: false),
      hr: 124,
      mapPage: true,
    );
    expect(find.text('12 s ahead of best'), findsOneWidget);
    expect(find.text('3 s behind last'), findsNothing);
    final ghost = tester.getTopLeft(find.byKey(const ValueKey('trail-ghost')));
    final row = tester.getTopLeft(find.byKey(const ValueKey('elevation-row')));
    expect(ghost.dy, lessThan(row.dy));
    await golden(tester, 'trail_ghost_page2_z2_360x800');
  });

  testWidgets('short phone 360 x 640 still fits the numbers', (tester) async {
    await openRun(tester, progress: trail(best: 12000), hr: 140, height: 640);
    expect(find.text('12 s ahead of best'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden(tester, 'trail_ghost_ahead_z3_360x640');
  });
}
