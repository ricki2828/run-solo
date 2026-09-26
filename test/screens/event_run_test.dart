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
    final chip = find.byKey(const ValueKey('event-chip'));
    expect(chip, findsOneWidget);
    expect(find.text(name.toUpperCase()), findsOneWidget);
    await tester.tap(chip);
    await pumpTimes(tester, 4);
    expect(services.settings.settings.eventRun, isTrue);
    expect(find.byKey(const ValueKey('event-card')), findsOneWidget);
    expect(find.text('START 5 KM'), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey('event-chip')));
    await pumpTimes(tester, 4);
    await tester.tap(find.text('LAPS'));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.eventRun, isFalse);
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
}
