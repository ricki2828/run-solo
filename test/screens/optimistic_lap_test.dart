import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/recording_controller.dart';
import 'package:run_solo/widgets/lap_button.dart';

import '../helpers.dart';

/// #26 review P1: native holds a manual lap's LapEvent for up to 1 s (its
/// distance is interpolated at the press). The screen shows the lap at the
/// press from the LapPendingEvent; the LapEvent only fills in the pace.
Future<(FakeRecorderGateway, AppServices)> open(
  WidgetTester tester,
  RecordMode mode,
) async {
  final fake = FakeRecorderGateway(now: now)..deferManualLaps = true;
  final services = fakeServices(recorder: fake);
  await services.recording.start(
    mode,
    mode == RecordMode.intervals ? standardPreset() : null,
    Units.km,
  );
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 4);
  fake.advance(const Duration(milliseconds: 500));
  await pumpTimes(tester, 3);
  return (fake, services);
}

void main() {
  testWidgets('Laps run: the press shows LAP 2 at once, the LapEvent fills '
      'in the pace without a second ring', (tester) async {
    final (fake, services) = await open(tester, RecordMode.laps);
    final ctl = services.recording;
    fake.advance(const Duration(seconds: 90));
    await pumpTimes(tester, 3);
    final pulses = ctl.lapPulse.value;

    await tester.tap(find.byType(LapButton));
    await pumpTimes(tester, 3);
    // Before any tick: the new lap is on screen, its pace is not yet.
    expect(find.text('LAP 2'), findsOneWidget);
    expect(ctl.lapPulse.value, pulses + 1);
    expect(ctl.snapshot.repPaces, isEmpty);
    expect(ctl.displayLapElapsedMs, lessThan(1000));
    expect(find.textContaining('last lap'), findsNothing);

    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    expect(find.text('LAP 2'), findsOneWidget);
    expect(ctl.snapshot.repPaces, hasLength(1));
    expect(find.textContaining('last lap'), findsOneWidget);
    expect(ctl.lapPulse.value, pulses + 1, reason: 'no second ring reset');
  });

  testWidgets('4x4: START 4x4 and a rep ended by LAP show the next phase at '
      'the press; the rep keeps its pace', (tester) async {
    final (fake, services) = await open(tester, RecordMode.intervals);
    final ctl = services.recording;
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 3);

    await ctl.startReps();
    await pumpTimes(tester, 3);
    expect(find.textContaining('REP 1 OF 4'), findsOneWidget);
    expect(ctl.displayRemainingMs, greaterThan(239 * 1000));
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    expect(find.textContaining('REP 1 OF 4'), findsOneWidget);

    fake.advance(const Duration(seconds: 60));
    await pumpTimes(tester, 3);
    final completes = ctl.repCompletePulse.value;
    await ctl.lap();
    await pumpTimes(tester, 3);
    expect(find.textContaining('RECOVERY 1 OF 3'), findsOneWidget);
    expect(ctl.repCompletePulse.value, completes + 1);
    expect(ctl.snapshot.repPaces, isEmpty);

    // LapEvent arrives while the screen already says Recovery: the pace
    // still belongs to rep 1 (attributed by the lap, not arrival order).
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    expect(ctl.snapshot.repPaces, hasLength(1));
    expect(ctl.repCompletePulse.value, completes + 1);
    expect(find.textContaining('RECOVERY 1 OF 3'), findsOneWidget);
  });

  testWidgets('a LapEvent that never lands is reconciled from status()', (
    tester,
  ) async {
    final (fake, services) = await open(tester, RecordMode.laps);
    final ctl = services.recording;
    fake.advance(const Duration(seconds: 90));
    await pumpTimes(tester, 3);
    fake.dropNextDeferredLap = true;

    await tester.tap(find.byType(LapButton));
    await pumpTimes(tester, 3);
    expect(find.text('LAP 2'), findsOneWidget);
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    expect(ctl.snapshot.repPaces, isEmpty);

    await tester.pump(RecordingController.lapReconcileAfter);
    await pumpTimes(tester, 3);
    expect(ctl.snapshot.repPaces, hasLength(1), reason: 'from status().laps');
    expect(find.text('LAP 2'), findsOneWidget);
  });

  // #40 review (rebase on #28): the optimistic phase must drop native's
  // step fields, or the new title shows with the previous step's caption
  // and metres-to-go until the next tick.
  testWidgets('8x400: START REPS and a LAP-ended rep show the new step at '
      'once, never the old step\'s metres', (tester) async {
    final fake = FakeRecorderGateway(now: now)..deferManualLaps = true;
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.intervals,
      presetSpec('400s'),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 3);
    final ctl = services.recording;

    await ctl.startReps();
    await pumpTimes(tester, 3);
    var s = ctl.snapshot;
    expect(s.phase, Phase.work);
    expect(s.currentStep!.kind, StepKind.work);
    expect(s.currentStep!.repIndex, 1);
    expect(s.metresToGo, 400);

    // Into rep 1: native now sends the step's index and metres left.
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 3);
    s = ctl.snapshot;
    expect(s.stepIndex, isNotNull);
    expect(s.metresToGo, lessThan(400));

    // LAP ends rep 1 early: before any tick, the 200 m recovery is the
    // step, not rep 1 with its metres left.
    await ctl.lap();
    await pumpTimes(tester, 3);
    s = ctl.snapshot;
    expect(s.phase, Phase.recovery);
    expect(s.stepIndex, isNull);
    expect(s.stepRemainingM, isNull);
    expect(s.currentStep!.kind, StepKind.recovery);
    expect(s.currentStep!.repIndex, 1);
    expect(s.metresToGo, 200, reason: 'the 200 m recovery, from its start');
    // The held LapEvent lands on the next tick (no reconcile timer left).
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 3);
    expect(ctl.snapshot.repPaces, hasLength(1));
  });
}
