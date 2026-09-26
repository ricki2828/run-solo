import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/recording_controller.dart';
import 'package:run_solo/widgets/mode_chip.dart';

import '../helpers.dart';

/// K1 / A10.10: the timed 5 km event as a run type of its own, no warm-up.
void main() {
  final name = kEventNames.parkrun;

  /// The event session as the recorder gets it once the engine spec says
  /// "no warm-up" (founder 26-Sep; `warmupSeconds: 0`).
  SessionSpec eventSpec() =>
      engine.SessionSpec.parkrun(name).toPigeon()..warmupSeconds = 0;

  testWidgets('Start: the event is a fourth run type; START hands the event '
      'session to the recorder', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    final chip = find.byKey(const ValueKey('goal-chip'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await pumpTimes(tester, 4);
    expect(services.settings.settings.goalRun, isTrue);
    expect(services.settings.settings.eventRun, isTrue, reason: 'default goal');
    expect(find.byKey(const ValueKey('goal-picker')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('event-gps')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('event-card')), findsOneWidget);
    expect(find.text('START 5 KM'), findsOneWidget);

    // A10.10 / #54: START waits for a pre-start fix at 20 m or better.
    expect(fake.gpsProbeRunning, isTrue);
    FilledButton start() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'START 5 KM'),
    );
    expect(start().onPressed, isNull);
    expect(find.textContaining('Waiting for GPS'), findsOneWidget);
    fake.emitGpsProbe(GpsProbeEvent(fix: true, accuracyM: 35));
    await pumpTimes(tester, 2);
    expect(start().onPressed, isNull, reason: '35 m is not ready');
    fake.emitGpsProbe(
      GpsProbeEvent(fix: true, lat: -37.8, lon: 144.9, accuracyM: 6),
    );
    await pumpTimes(tester, 2);
    expect(find.text('GPS ready · 6 m'), findsOneWidget);
    expect(start().onPressed, isNotNull);
    fake.emitGpsProbe(GpsProbeEvent(fix: false));
    await pumpTimes(tester, 2);
    expect(start().onPressed, isNull, reason: 'the fix went stale');
    fake.emitGpsProbe(GpsProbeEvent(fix: true, accuracyM: 8));
    await pumpTimes(tester, 2);
    await tester.tap(find.text('START 5 KM'));
    await pumpTimes(tester, 6);
    final call = fake.startCalls.single;
    expect(call.mode, RecordMode.intervals);
    expect(call.spec?.templateId, engine.SessionSpec.parkrunId);
    expect(call.spec?.name, name);
    expect(call.spec?.autoStop, isTrue);

    // Another chip clears the event.
    await tester.pageBack();
    await pumpTimes(tester, 4);
  });

  testWidgets('picking LAPS after the event clears it', (tester) async {
    final services = fakeServices();
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('goal-chip')));
    await pumpTimes(tester, 4);
    final fake = services.recorder as FakeRecorderGateway;
    expect(fake.gpsProbeRunning, isTrue);
    await tester.tap(find.text('LAPS'));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.goalRun, isFalse);
    expect(fake.gpsProbeRunning, isFalse, reason: 'probe only for the event');
    expect(services.settings.settings.recordMode, RecordMode.laps);
  });

  testWidgets('record: distance to go is primary, projected finish second; '
      'the last 400 m swap; auto-stop goes to the result', (tester) async {
    final fake = FakeRecorderGateway(now: now)..liveSecPerKm = 240;
    final services = fakeServices(recorder: fake);
    await services.recording.start(RecordMode.intervals, eventSpec(), Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    expect(find.text('${name.toUpperCase()} · 5 KM'), findsOneWidget);
    expect(find.text('5.00 km'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-reps')), findsNothing);

    double size(String key) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(Text),
              )
              .first,
        )
        .style!
        .fontSize!;

    // 240 s/km: 60 s = 250 m, so the projection shows (> 200 m run).
    for (var i = 0; i < 60; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    await pumpTimes(tester, 4);
    expect(find.text('4.75 km'), findsOneWidget);
    expect(find.text('20:00'), findsOneWidget, reason: '240 s/km × 5');
    expect(size('event-to-go'), greaterThan(size('event-finish')));

    // To 4.70 km run: 300 m left, the last stretch.
    for (var i = 0; i < 1068; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('${name.toUpperCase()} · LAST 400 M'), findsOneWidget);
    expect(size('event-finish'), greaterThan(size('event-to-go')));

    // Auto-stop at 5.00 km: the result replaces the record screen.
    for (var i = 0; i < 80; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    await pumpTimes(tester, 8);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.byType(VerdictScreen), findsOneWidget);
    expect(fake.finalised, hasLength(1));
  });

  test('distance to go: km, then metres down to 10 m and 5 m; miles', () {
    expect(eventDistanceToGo(2583, Units.km), '2.58 km');
    expect(eventDistanceToGo(1000, Units.km), '1.00 km');
    expect(eventDistanceToGo(999, Units.km), '990 m');
    expect(eventDistanceToGo(97, Units.km), '95 m');
    expect(eventDistanceToGo(0, Units.km), '0 m');
    expect(eventDistanceToGo(2575, Units.mi), '1.60 mi');
    expect(eventDistanceToGo(150, Units.mi), '150 m');
  });

  test('projected finish needs 200 m and a good fix', () {
    final spec = eventSpec();
    RecordingSnapshot snap({double lap = 0, bool lost = false}) =>
        RecordingSnapshot(
          state: RecorderState.recording,
          mode: RecordMode.intervals,
          spec: spec,
          phase: Phase.work,
          repIndex: 1,
          lapDistanceM: lap,
          gpsLost: lost,
        );
    expect(eventProjectedSeconds(snap(lap: 150), 36000), isNull);
    expect(eventProjectedSeconds(snap(lap: 250), 60000), closeTo(1200, 0.01));
    expect(eventProjectedSeconds(snap(lap: 250, lost: true), 60000), isNull);
  });

  testWidgets('GOAL: the event and 10K under Distance, 30 min under Time; '
      'goals waiting for G1 cannot start', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('goal-chip')));
    await pumpTimes(tester, 4);
    expect(find.text(name), findsWidgets);
    expect(find.text('10K'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('goal-d10000')));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.goalId, 'd10000');
    expect(find.text('Coming with the next build.'), findsOneWidget);
    fake.emitGpsProbe(GpsProbeEvent(fix: true, accuracyM: 5));
    await pumpTimes(tester, 2);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'START GOAL'),
    );
    expect(start.onPressed, isNull, reason: '10K waits for G1 (#63)');
    await tester.tap(find.byKey(const ValueKey('goal-time')));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('goal-t1800')), findsOneWidget);
    expect(find.byKey(const ValueKey('goal-t3600')), findsOneWidget);
    expect(services.settings.settings.goalId, 't1800');
  });

  testWidgets('chips: FREE · LAPS · GOAL · INTERVALS as 2 × 2 at 360 dp; no '
      'chip text under 13 sp', (tester) async {
    await pumpApp(tester, fakeServices(), pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    Offset chip(String title) => tester.getTopLeft(
      find.ancestor(of: find.text(title), matching: find.byType(ModeChip)),
    );
    final free = chip('FREE');
    final laps = chip('LAPS');
    final goal = chip('GOAL');
    final intervals = chip('INTERVALS');
    expect(laps.dy, closeTo(free.dy, 1));
    expect(laps.dx, greaterThan(free.dx));
    expect(goal.dy, greaterThan(free.dy + 40), reason: 'second row');
    expect(intervals.dy, closeTo(goal.dy, 1));
    for (final text in tester.widgetList<Text>(
      find.descendant(of: find.byType(ModeChip), matching: find.byType(Text)),
    )) {
      final size = text.style?.fontSize ?? 14;
      expect(size, greaterThanOrEqualTo(13), reason: text.data);
    }
  });
}
