import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// K1 / A10.10: the event's course at Start, from the probe's position.
void main() {
  final day0 = DateTime.utc(2026, 8, 1, 22);
  engine.RunFile event(int n, {double shift = 0}) => eventRunFile(
    n: n,
    start: day0.add(Duration(days: 7 * n)),
    eventName: kEventNames.parkrun,
    latShiftDeg: shift,
  );

  testWidgets('the nearest known course within 150 m shows; farther is '
      'somewhere new; tap to change', (tester) async {
    final a = event(1);
    final b = event(2, shift: 0.01); // ~1.1 km north: a second course
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      files: [a, b],
      courseNames: {engine.ParkrunCourses.newCourseId(a): 'Albert Park'},
      settings: const AppSettings(onboardingDone: true, goalRun: true),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 6);
    final row = find.byKey(const ValueKey('start-course'));
    expect(row, findsOneWidget);
    expect(find.text('Course: found once GPS is ready'), findsOneWidget);

    final start = engine.ParkrunCourses.startOf(a)!;
    // ~100 m from course 1's start (0.0009° lat).
    fake.emitGpsProbe(
      GpsProbeEvent(
        fix: true,
        accuracyM: 5,
        lat: start.lat + 0.0009,
        lon: start.lon,
      ),
    );
    await pumpTimes(tester, 2);
    expect(find.text('Course: Albert Park'), findsOneWidget);

    // ~220 m away: no course that close.
    fake.emitGpsProbe(
      GpsProbeEvent(
        fix: true,
        accuracyM: 5,
        lat: start.lat + 0.002,
        lon: start.lon,
      ),
    );
    await pumpTimes(tester, 2);
    expect(find.text('Course: somewhere new'), findsOneWidget);

    // The runner picks course 2; the probe no longer moves it.
    await tester.tap(row);
    await pumpTimes(tester, 2);
    await tester.pump(const Duration(milliseconds: 600));
    final second = engine.ParkrunCourses.newCourseId(b);
    await tester.tap(find.byKey(ValueKey('start-course-$second')));
    await pumpTimes(tester, 2);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Course: Course 2'), findsOneWidget);
    fake.emitGpsProbe(
      GpsProbeEvent(
        fix: true,
        accuracyM: 5,
        lat: start.lat + 0.0009,
        lon: start.lon,
      ),
    );
    await pumpTimes(tester, 2);
    expect(find.text('Course: Course 2'), findsOneWidget);
  });

  testWidgets('no course row before any course is known', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(onboardingDone: true, goalRun: true),
      ),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('start-course')), findsNothing);
  });

  testWidgets('the known course gives the event its course PB target; the '
      'swap is what START races (#76 + #84)', (tester) async {
    debugLiveCompareAtStart = true;
    addTearDown(() => debugLiveCompareAtStart = false);
    final a = event(1);
    final course = engine.ParkrunCourses.newCourseId(a);
    // A fresh course PB (official 24:12) and a GPS 5K of 25:00.
    final efforts = engine.RunBestEfforts(
      efforts: {
        engine.BestEffortDistance.k5: engine.BestEffort(
          distance: engine.BestEffortDistance.k5,
          elapsedMs: 1500000,
          startMs: 0,
          startOffsetM: 0,
          splitsMs: const [],
        ),
      },
      fromStartSplitsMs: const [],
    );
    final pb = engine.LiveCandidate(
      engine.BoardInput(
        runId: 'pb',
        date: DateTime(2026, 9, 19, 8).toUtc(),
        mode: engine.RunMode.intervals,
        comparisonKey: engine.ComparisonKey.parkrunOf(courseId: course),
        efforts: efforts.efforts,
        officialTimeMs: 1452000,
      ),
      engine.RunDerived(bestEfforts: efforts),
    );
    final fake = FakeRecorderGateway(now: now);
    await pumpApp(
      tester,
      fakeServices(
        recorder: fake,
        files: [a],
        live: LiveContextSource.prepared([pb], now: now),
        settings: const AppSettings(onboardingDone: true, goalRun: true),
      ),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 6);
    Finder line(String text) => find.descendant(
      of: find.byKey(const ValueKey('start-target')),
      matching: find.text(text),
    );
    // No fix yet: no course, so the prediction only.
    expect(line('Target 25:00 (predicted)'), findsOneWidget);
    expect(find.text('Use predicted ›'), findsNothing);

    final start = engine.ParkrunCourses.startOf(a)!;
    fake.emitGpsProbe(
      GpsProbeEvent(fix: true, accuracyM: 5, lat: start.lat, lon: start.lon),
    );
    await pumpTimes(tester, 2);
    expect(line('Target 24:12 (your PB)'), findsOneWidget);
    await tester.tap(find.text('Use predicted ›'));
    await pumpTimes(tester, 2);
    expect(line('Target 25:00 (predicted)'), findsOneWidget);

    await tester.tap(find.text('START 5 KM'));
    await pumpTimes(tester, 6);
    final target = fake.startCalls.single.liveContext!.target!;
    expect(target.targetMs, 1500000, reason: 'the shown (swapped) target');
    expect(target.predicted, isTrue);
  });
}
