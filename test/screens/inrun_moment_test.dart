import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/inrun_moments.dart';
import 'package:run_solo/state/recording_controller.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/inrun_moment.dart';

import '../helpers.dart';

/// 21-Oct UI review, finding 2: the in-run moments. Each trigger fires once,
/// shows for about 1.5 s, and reads in the runner's units.
SessionSpec eventSpec() =>
    engine.SessionSpec.parkrun(kEventNames.parkrun).toPigeon()
      ..warmupSeconds = 0;

Finder moment(InrunMomentKind k) =>
    find.byKey(ValueKey('inrun-moment-${k.name}'));

String text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

Future<FakeRecorderGateway> openRun(
  WidgetTester tester, {
  RecordMode mode = RecordMode.free,
  SessionSpec? spec,
  Units units = Units.km,
  bool reduced = false,
}) async {
  final fake = FakeRecorderGateway(now: now)
    ..scriptedHr = 150
    ..liveSecPerKm = 300;
  final services = fakeServices(
    recorder: fake,
    settings: AppSettings(
      onboardingDone: true,
      units: units,
      reducedMotion: reduced,
    ),
  );
  await services.recording.start(mode, spec, units);
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 6);
  return fake;
}

Future<void> step(WidgetTester tester, FakeRecorderGateway fake, int s) async {
  fake.advance(Duration(seconds: s));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> gone(WidgetTester tester) async {
  await tester.pump(InrunMomentOverlay.shownFor);
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('a km mark: big km number and the time, gone in 1.5 s', (
    tester,
  ) async {
    final fake = await openRun(tester);
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
    await step(tester, fake, 100); // 333 m
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
    await step(tester, fake, 210); // 1.03 km
    expect(moment(InrunMomentKind.distanceMark), findsOneWidget);
    expect(text(tester, 'inrun-moment-label'), 'KM');
    expect(text(tester, 'inrun-moment-headline'), '1');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('inrun-moment-headline')))
          .style!
          .fontSize,
      greaterThanOrEqualTo(64),
    );
    await gone(tester);
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
    // More ticks inside the same km never fire it again.
    await step(tester, fake, 30);
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
    // The next km does.
    await step(tester, fake, 300);
    expect(text(tester, 'inrun-moment-headline'), '2');
    await gone(tester);
  });

  testWidgets('miles: the mark is at 1.609 km and says MI', (tester) async {
    final fake = await openRun(tester, units: Units.mi);
    await step(tester, fake, 310); // 1.03 km: not yet a mile
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
    await step(tester, fake, 200); // 1.70 km
    expect(moment(InrunMomentKind.distanceMark), findsOneWidget);
    expect(text(tester, 'inrun-moment-label'), 'MI');
    expect(text(tester, 'inrun-moment-headline'), '1');
    await gone(tester);
  });

  testWidgets('reduced motion: the moment still shows, with no glow or '
      'scale', (tester) async {
    final fake = await openRun(tester, reduced: true);
    await step(tester, fake, 340);
    expect(moment(InrunMomentKind.distanceMark), findsOneWidget);
    final plate = tester.widget<Container>(
      moment(InrunMomentKind.distanceMark),
    );
    expect((plate.decoration! as BoxDecoration).boxShadow, isNull);
    final scale = tester.widget<Transform>(
      find
          .ancestor(
            of: moment(InrunMomentKind.distanceMark),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(scale.transform.getMaxScaleOnAxis(), 1.0);
    await gone(tester);
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
  });

  testWidgets('a moment takes no taps', (tester) async {
    final fake = await openRun(tester);
    await step(tester, fake, 340);
    expect(
      find.ancestor(
        of: moment(InrunMomentKind.distanceMark),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    await gone(tester);
  });

  testWidgets('event: halfway, last 400 m, then the goal reached', (
    tester,
  ) async {
    final fake = await openRun(
      tester,
      mode: RecordMode.intervals,
      spec: eventSpec(),
    );
    await step(tester, fake, 600); // 2.0 km
    expect(moment(InrunMomentKind.halfway), findsNothing);
    await gone(tester);
    await step(tester, fake, 200); // 2.67 km
    expect(moment(InrunMomentKind.halfway), findsOneWidget);
    expect(text(tester, 'inrun-moment-headline'), 'HALFWAY');
    await gone(tester);
    await step(tester, fake, 600); // 4.67 km, 330 m to go
    expect(moment(InrunMomentKind.lastStretch), findsOneWidget);
    expect(text(tester, 'inrun-moment-headline'), 'LAST 400 M');
    await gone(tester);
    await step(tester, fake, 120); // past 5 km
    fake.emitGoal(
      GoalEvent(
        distanceGoal: true,
        goalValue: 5000,
        timeMs: 1500000,
        distanceM: 5000,
        newBest: false,
        interrupted: false,
        text: 'Goal reached',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(moment(InrunMomentKind.goalReached), findsOneWidget);
    expect(text(tester, 'inrun-moment-headline'), '25:00');
    await gone(tester);
  });

  testWidgets('4x4: rep complete shows the rep pace and the delta vs the '
      'best rep', (tester) async {
    final fake = await openRun(
      tester,
      mode: RecordMode.intervals,
      spec: fourByFourSpec(),
    );
    // Warm-up ends, rep 1 runs 4:00 at 5:00/km, recovery, rep 2 at 4:50.
    await fake.lap(LapSource.button);
    await tester.pump();
    await step(tester, fake, 240);
    await step(tester, fake, 1);
    expect(moment(InrunMomentKind.repDone), findsOneWidget);
    expect(text(tester, 'inrun-moment-label'), 'REP 1 DONE');
    expect(text(tester, 'inrun-moment-headline'), '5:00');
    expect(text(tester, 'inrun-moment-sub'), 'first rep in');
    await gone(tester);
  });

  group('detector', () {
    RecordingSnapshot snap({
      String? runId = 'r1',
      double dist = 0,
      List<double> paces = const [],
      int elapsed = 0,
    }) => RecordingSnapshot(
      state: RecorderState.recording,
      runId: runId,
      mode: RecordMode.intervals,
      spec: fourByFourSpec(),
      phase: Phase.work,
      repIndex: paces.length + 1,
      totalDistanceM: dist,
      repPaces: paces,
      elapsedMs: elapsed,
    );

    test('the first snapshot of a run is a baseline, never a moment', () {
      final d = InrunMomentDetector();
      expect(d.observe(snap(dist: 3500, paces: [300, 290]), Units.km), isNull);
      expect(d.observe(snap(dist: 3600, paces: [300, 290]), Units.km), isNull);
    });

    test('rep done: delta against the best earlier rep', () {
      final d = InrunMomentDetector()..observe(snap(), Units.km);
      var m = d.observe(snap(paces: [290]), Units.km)!;
      expect(m.kind, InrunMomentKind.repDone);
      expect(m.sub, 'first rep in');
      m = d.observe(snap(paces: [290, 284]), Units.km)!;
      expect(m.headline, '4:44');
      expect(m.sub, '6 s faster than your best');
      m = d.observe(snap(paces: [290, 284, 291]), Units.km)!;
      expect(m.sub, '7 s off your best');
      m = d.observe(snap(paces: [290, 284, 291, 284]), Units.km)!;
      expect(m.sub, 'level with your best');
    });

    test('rep delta is in the runner units (per mile)', () {
      final d = InrunMomentDetector()..observe(snap(), Units.mi);
      d.observe(snap(paces: [300]), Units.mi);
      final m = d.observe(snap(paces: [300, 290]), Units.mi)!;
      // 10 s/km is about 16 s/mile.
      expect(m.sub, '16 s faster than your best');
    });

    test('a new run id resets the baselines', () {
      final d = InrunMomentDetector()..observe(snap(), Units.km);
      expect(
        d.observe(snap(dist: 1100), Units.km)?.kind,
        InrunMomentKind.distanceMark,
      );
      expect(d.observe(snap(runId: 'r2', dist: 1100), Units.km), isNull);
      expect(d.observe(snap(runId: 'r2', dist: 2100), Units.km)?.headline, '2');
    });

    test('no run id, no moment', () {
      final d = InrunMomentDetector();
      expect(d.observe(snap(runId: null, dist: 5000), Units.km), isNull);
    });
  });
}
