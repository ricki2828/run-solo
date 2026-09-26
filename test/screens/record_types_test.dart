import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/delta_glyph.dart';
import 'package:run_solo/widgets/lap_button.dart';
import 'package:run_solo/widgets/pace_dial.dart';

import '../helpers.dart';

/// Plan §18.2 three record layouts and §18.1 zone background, against the
/// fake gateway. Default max HR 190: Z3 = 133–151, Z5 ≥ 171.
Future<(FakeRecorderGateway, AppServices)> open(
  WidgetTester tester, {
  required RecordMode mode,
  AppSettings settings = const AppSettings(onboardingDone: true),
  int? hr,
}) async {
  final fake = FakeRecorderGateway(now: now)..scriptedHr = hr;
  final services = fakeServices(recorder: fake, settings: settings);
  await services.recording.start(
    mode,
    mode == RecordMode.intervals ? standardPreset() : null,
    Units.km,
  );
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 4);
  expect(find.byType(RecordingScreen), findsOneWidget);
  // The start tick fires before the screen subscribes; one tick carries HR.
  fake.advance(const Duration(milliseconds: 500));
  await pumpTimes(tester, 3);
  return (fake, services);
}

Color background(WidgetTester tester) => tester
    .widget<AnimatedContainer>(find.byKey(const ValueKey('zone-background')))
    .decoration!
    .let((d) => (d as BoxDecoration).color!);

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

void main() {
  testWidgets('Free run: no LAP button, four numbers, lap presses ignored', (
    tester,
  ) async {
    final (fake, services) = await open(tester, mode: RecordMode.free, hr: 138);
    expect(find.byType(LapButton), findsNothing);
    expect(find.text('FREE RUN'), findsOneWidget);
    expect(find.byKey(const ValueKey('free-run-block')), findsOneWidget);
    expect(find.textContaining('last lap'), findsNothing);
    expect(find.textContaining('LAP '), findsNothing);
    // Founder 25-Sep: current-pace dial against the run's average so far.
    expect(find.byType(PaceDial), findsOneWidget);
    expect(find.textContaining('average'), findsOneWidget);
    // Pause and hold-to-stop remain.
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    await services.recording.lap();
    await fake.lap(LapSource.volumeKey);
    await pumpTimes(tester, 3);
    expect(
      fake.lapsIgnored,
      1,
      reason: 'controller short-circuits, fake ignores',
    );
    expect(services.recording.snapshot.lapIndex, 0);
  });

  testWidgets('Laps run: count-up, LAP button, lap counter and ghost line', (
    tester,
  ) async {
    final (fake, _) = await open(tester, mode: RecordMode.laps);
    expect(find.byType(LapButton), findsOneWidget);
    expect(find.text('LAP 1'), findsOneWidget);
    expect(find.text('first lap'), findsOneWidget);
    fake.advance(const Duration(seconds: 90));
    await pumpTimes(tester, 5);
    await tester.tap(find.byType(LapButton));
    await pumpTimes(tester, 5);
    expect(find.text('LAP 2'), findsOneWidget);
    expect(find.textContaining('last lap'), findsOneWidget);
    // Total time lives in the large vitals row, not the caption.
    expect(find.text('this lap'), findsOneWidget);
    expect(find.byKey(const ValueKey('vitals-total')), findsOneWidget);
    // Holding: "±0 s" and no glyph (a flat dash before 0 read as "−0 s").
    expect(find.text('±0 s', findRichText: true), findsOneWidget);
    expect(find.byType(DeltaGlyph), findsNothing);
    // Faster than the last lap: the arrow, centred on the digits (it floated
    // above them in a baseline Row).
    fake.liveSecPerKm = 270;
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 5);
    expect(find.byType(DeltaGlyph), findsOneWidget);
    expect(find.textContaining('±', findRichText: true), findsNothing);
    final glyph = tester.getCenter(find.byType(DeltaGlyph));
    final delta = tester.getRect(find.byKey(const ValueKey('ghost-delta')));
    expect((glyph.dy - delta.center.dy).abs(), lessThan(4));
  });

  testWidgets('4x4 keeps the countdown and LAP', (tester) async {
    await open(tester, mode: RecordMode.intervals);
    expect(find.text('WARM-UP'), findsOneWidget);
    expect(find.byType(LapButton), findsOneWidget);
  });

  testWidgets(
    'zone background: first HR sets the zone at once, label present',
    (tester) async {
      final (fake, _) = await open(tester, mode: RecordMode.intervals, hr: 140);
      await pumpTimes(tester, 3);
      await tester.pump(const Duration(milliseconds: 700));
      expect(background(tester), HrZones.background(3));
      expect(find.text('ZONE 3 · TEMPO'), findsOneWidget);
      // Jump to Z5: needs 2 bpm past 171 and a 5 s dwell.
      fake.scriptedHr = 178;
      for (var i = 0; i < 12; i++) {
        fake.advance(const Duration(milliseconds: 500));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 700));
      expect(background(tester), HrZones.background(5));
      expect(find.text('ZONE 5 · MAX'), findsOneWidget);
    },
  );

  testWidgets('no strap: black background, no zone label', (tester) async {
    final fake = FakeRecorderGateway(now: now)..hrPaired = false;
    final services = fakeServices(recorder: fake);
    await services.recording.start(RecordMode.laps, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 5);
    await tester.pump(const Duration(milliseconds: 700));
    expect(background(tester), HrZones.background(0));
    expect(find.byKey(const ValueKey('zone-label')), findsNothing);
  });

  testWidgets('(d) reduced motion: zone crossfade is 160 ms', (tester) async {
    await open(
      tester,
      mode: RecordMode.free,
      hr: 140,
      settings: const AppSettings(onboardingDone: true, reducedMotion: true),
    );
    final c = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('zone-background')),
    );
    expect(c.duration, const Duration(milliseconds: 160));
  });

  testWidgets('default zone crossfade is 600 ms', (tester) async {
    await open(tester, mode: RecordMode.free, hr: 140);
    final c = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('zone-background')),
    );
    expect(c.duration, const Duration(milliseconds: 600));
  });

  testWidgets('(f) recreated screen paints the last zone on its first frame', (
    tester,
  ) async {
    final (fake, services) = await open(tester, mode: RecordMode.laps, hr: 160);
    await pumpTimes(tester, 3);
    expect(services.recording.snapshot.zone, 4);
    // Recreate: pop and push the record screen again with no new ticks.
    fake.scriptedHr = null;
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.pop();
    await settleAnimations(tester);
    nav.pushNamed(Routes.recording);
    await tester.pump();
    await tester.pump();
    expect(background(tester), HrZones.background(4));
    expect(find.text('ZONE 4 · HARD'), findsOneWidget);
  });
}
