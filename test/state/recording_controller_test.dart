import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/recording_controller.dart';

import '../helpers.dart';

void main() {
  late FakeRecorderGateway fake;
  late RecordingController ctl;

  setUp(() {
    fake = FakeRecorderGateway(now: now);
    ctl = RecordingController(fake, now: now);
  });

  tearDown(() async {
    ctl.dispose();
    await fake.dispose();
  });

  Future<void> settle() async {
    // Events cross a broadcast stream; status() is one more microtask.
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('4x4: warm-up → work countdown → auto lap → recovery', () async {
    final r = await ctl.start(
      RecordMode.fourByFour,
      standardPreset(),
      Units.km,
    );
    expect(r.error, isNull);
    await settle();
    expect(ctl.snapshot.phase, Phase.warmup);
    expect(ctl.snapshot.timed, isFalse);

    await ctl.lap();
    await settle();
    expect(ctl.snapshot.phase, Phase.work);
    expect(ctl.snapshot.repIndex, 1, reason: 'RecorderCore rep is 1-based');
    expect(ctl.snapshot.phaseRemainingMs, 240000);
    expect(ctl.lapPulse.value, 1);

    fake.advance(const Duration(seconds: 73));
    await settle();
    expect(ctl.snapshot.phaseRemainingMs, 167000);
    expect(ctl.repCompletePulse.value, 0);

    fake.advance(const Duration(seconds: 167));
    await settle();
    expect(ctl.snapshot.phase, Phase.recovery);
    expect(ctl.snapshot.phaseRemainingMs, 180000);
    expect(ctl.repCompletePulse.value, 1, reason: 'M3 fires once per rep');
    expect(ctl.snapshot.repPaces, hasLength(1));
    expect(
      ctl.snapshot.repPaces.single,
      closeTo(285, 1),
      reason: 'lap distance is the delta of the cumulative LapEvent.distanceM',
    );

    fake.advance(const Duration(seconds: 180));
    await settle();
    expect(ctl.snapshot.phase, Phase.work);
    expect(ctl.snapshot.repIndex, 2);
    expect(ctl.repStartPulse.value, 1);
  });

  test(
    'a pause mid-rep freezes the countdown while elapsed keeps running',
    () async {
      await ctl.start(RecordMode.fourByFour, standardPreset(), Units.km);
      await ctl.lap();
      await settle();
      fake.advance(const Duration(seconds: 60));
      await settle();
      expect(ctl.snapshot.phaseRemainingMs, 180000);

      await ctl.pause();
      await settle();
      fake.advance(const Duration(seconds: 30));
      await settle();
      expect(ctl.snapshot.paused, isTrue);
      expect(ctl.snapshot.elapsedMs, 90000, reason: 'wall time incl. pause');
      expect(ctl.snapshot.phaseRemainingMs, 180000, reason: 'frozen');
      expect(ctl.displayRemainingMs, 180000);

      await ctl.resume();
      await settle();
      fake.advance(const Duration(seconds: 10));
      await settle();
      expect(ctl.snapshot.elapsedMs, 100000);
      expect(ctl.snapshot.phaseRemainingMs, 170000);
    },
  );

  test('recovery follows the last rep before cool-down', () async {
    await ctl.start(
      RecordMode.fourByFour,
      Preset(reps: 3, workSeconds: 240, recoverySeconds: 120),
      Units.km,
    );
    await ctl.lap();
    await settle();
    for (var i = 0; i < 2; i++) {
      fake.advance(const Duration(seconds: 240));
      await settle();
      fake.advance(const Duration(seconds: 120));
      await settle();
    }
    fake.advance(const Duration(seconds: 240));
    await settle();
    expect(ctl.snapshot.phase, Phase.recovery);
    expect(ctl.snapshot.repIndex, 3);
    fake.advance(const Duration(seconds: 120));
    await settle();
    expect(ctl.snapshot.phase, Phase.cooldown);
  });

  test('faults: GPS lost clears pace, strap drop clears HR, never 0', () async {
    await ctl.start(RecordMode.free, null, Units.km);
    fake.advance(const Duration(seconds: 5));
    await settle();
    expect(ctl.snapshot.livePaceSecPerKm, isNotNull);
    expect(ctl.snapshot.hr, isNotNull);
    expect(ctl.snapshot.hrPaired, isTrue);

    fake.gpsLost = true;
    fake.strapDropped = true;
    fake.advance(const Duration(seconds: 1));
    await settle();
    expect(ctl.snapshot.gpsLost, isTrue);
    expect(ctl.snapshot.livePaceSecPerKm, isNull);
    expect(ctl.snapshot.hr, isNull);
    expect(ctl.snapshot.strapDropped, isTrue);

    fake.gpsLost = false;
    fake.strapDropped = false;
    fake.advance(const Duration(seconds: 1));
    await settle();
    expect(ctl.snapshot.gpsLost, isFalse);
    expect(ctl.snapshot.strapDropped, isFalse);
  });

  test('free run: laps count up, volume-key lap honoured', () async {
    await ctl.start(RecordMode.free, null, Units.km);
    fake.advance(const Duration(seconds: 30));
    await fake.lap(LapSource.volumeKey);
    await settle();
    expect(ctl.snapshot.lapIndex, 1);
    expect(ctl.snapshot.phase, Phase.none);
    expect(ctl.lapPulse.value, 1, reason: 'ring confirms every lap source');
  });

  test('preset ignores volume-key laps (plan §6, W8)', () async {
    await ctl.start(RecordMode.fourByFour, standardPreset(), Units.km);
    await fake.lap(LapSource.volumeKey);
    await settle();
    expect(ctl.snapshot.phase, Phase.warmup);
    expect(ctl.lapPulse.value, 0);
  });

  test(
    'elapsed keeps running while paused; stop finalises and returns the id',
    () async {
      final r = await ctl.start(RecordMode.free, null, Units.km);
      fake.advance(const Duration(seconds: 10));
      await ctl.pause();
      fake.advance(const Duration(seconds: 10));
      await settle();
      expect(ctl.snapshot.paused, isTrue);
      expect(
        ctl.snapshot.elapsedMs,
        20000,
        reason: 'elapsed runs through pauses',
      );
      await ctl.resume();
      fake.advance(const Duration(seconds: 5));
      await settle();
      expect(ctl.snapshot.elapsedMs, 25000);
      final id = await ctl.stop();
      expect(id, r.runId);
      expect(fake.finalised.single.durationMs, 25000);
      expect(ctl.snapshot.active, isFalse);
    },
  );

  test('attach() redraws a live run from status() (recreated UI)', () async {
    await fake.start(RecordMode.fourByFour, standardPreset(), Units.km);
    await fake.lap(LapSource.button);
    fake.advance(const Duration(seconds: 100));
    final fresh = RecordingController(fake, now: now);
    await fresh.attach();
    expect(fresh.snapshot.recording, isTrue);
    expect(fresh.snapshot.phase, Phase.work);
    expect(fresh.snapshot.repIndex, 1);
    expect(fresh.snapshot.phaseRemainingMs, 140000);
    expect(fresh.snapshot.preset?.reps, 4);
    fresh.dispose();
  });

  test(
    're-attach rebuilds the rep ghost and mode from status().laps',
    () async {
      await fake.start(RecordMode.fourByFour, standardPreset(), Units.km);
      await fake.lap(LapSource.button);
      fake.advance(const Duration(seconds: 240)); // rep 1 (auto lap)
      fake.advance(const Duration(seconds: 180)); // recovery 1
      fake.advance(const Duration(seconds: 100)); // into rep 2
      final fresh = RecordingController(fake, now: now);
      await fresh.attach();
      expect(fresh.snapshot.mode, RecordMode.fourByFour);
      expect(fresh.snapshot.repPaces, hasLength(1));
      expect(fresh.snapshot.repPaces.single, closeTo(285, 1));
      expect(fresh.snapshot.repIndex, 2);
      // The next lap measures from the last known lap, not from t = 0.
      fake.advance(const Duration(seconds: 140));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(fresh.snapshot.repPaces, hasLength(2));
      expect(fresh.snapshot.repPaces.last, closeTo(285, 1));
      fresh.dispose();
    },
  );

  test('repPacesFromLaps: odd laps end work reps, cool-down laps ignored', () {
    LapSummary lap(int i, int t, int active, double d) => LapSummary(
      index: i,
      tMs: t,
      activeMs: active,
      distanceM: d,
      source: LapSource.auto,
    );
    final laps = [
      lap(0, 60000, 60000, 100), // warm-up
      lap(1, 300000, 240000, 1000), // rep 1: 240 s / 900 m
      lap(2, 480000, 180000, 1300), // recovery 1
      lap(3, 740000, 240000, 2200), // rep 2: 240 s active (20 s pause) / 900 m
      lap(4, 920000, 180000, 2500), // recovery 2 (last, reps = 2)
      lap(5, 980000, 60000, 2700), // cool-down manual lap: ignored
    ];
    final preset = Preset(reps: 2, workSeconds: 240, recoverySeconds: 180);
    final paces = RecordingController.repPacesFromLaps(laps, preset);
    expect(paces, hasLength(2));
    expect(paces.first, closeTo(266.7, 0.1));
    expect(paces.last, closeTo(266.7, 0.1), reason: 'pause not counted');
    expect(RecordingController.repPacesFromLaps(laps, null), isEmpty);
  });

  test('typed start errors pass through untouched', () async {
    fake.startError = StartError.approximateOnly;
    final r = await ctl.start(RecordMode.free, null, Units.km);
    expect(r.error, StartError.approximateOnly);
    expect(ctl.snapshot.active, isFalse);
  });
}
