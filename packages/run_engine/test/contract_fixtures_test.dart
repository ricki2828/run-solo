import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Kotlin → Dart contract: real `RunFile.fromReplay` output from the
/// core-jvm pipeline (copied verbatim from
/// `android/core-jvm/src/test/fixtures/contract/`). Pins the writer's
/// formatting (`Instant.toString()` without millis, integral doubles as
/// ints, full-precision doubles, no-fix ticks as `[t,null×5,dist,hr]`).
void main() {
  final dir = Directory('test/fixtures/contract');
  RunFile load(String name) =>
      RunFileCodec.decode(File('${dir.path}/$name.json').readAsStringSync());

  test('all four contract fixtures decode and re-encode stably', () {
    for (final f in dir.listSync().whereType<File>()) {
      final text = f.readAsStringSync();
      expect(text, contains('T00:00:00Z"'), reason: 'Instant.toString()');
      expect(text, contains('"d0":0,'), reason: 'integral double as int');
      final run = RunFileCodec.decode(text);
      final canonical = RunFileCodec.encode(run);
      expect(RunFileCodec.encode(RunFileCodec.decode(canonical)), canonical);
      expect(run.start, DateTime.utc(2025, 9, 24));
    }
  });

  test(
    '4x4 preset with RecorderCore auto-laps and HR gets a baseline verdict',
    () {
      final run = load('four_by_four_preset_auto_hr');
      expect(run.preset, Preset.standard);
      expect(run.laps.length, 10);
      expect(run.laps.where((l) => l.kind == LapKind.auto).length, 8);
      expect(run.laps.first.kind, LapKind.manual);
      final a = engine.analyze(
        run,
        profile: const UserProfile(maxHr: 185),
        now: fixedNow,
      );
      expect(
        a.lapsInconsistent,
        isFalse,
        reason: a.detection!.inconsistencyDetail,
      );
      final m = a.fourByFour!;
      expect(m.reps.length, 4);
      expect(m.allRepsClean, isTrue);
      // 4.2 m/s = 238.1 s/km work, 2.0 m/s = 500 s/km recovery.
      for (final r in m.reps) {
        expect(r.paceSecPerKm, closeTo(1000 / 4.2, 0.5));
        expect(r.meanHr, inInclusiveRange(165, 169));
      }
      expect(m.recoveryPaceSecPerKm, closeTo(500, 1));
      expect(
        m.timeInZoneSeconds,
        closeTo(960, 1),
        reason: '165-169 is 89-91% of 185',
      );
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(
        a.verdict!.subline,
        '3:58/km work pace. Reps within 0 s of each other. Recovery 8:21. Next 4x4 gets a verdict.',
      );
      expect(a.verdict!.hrLine, 'Time in zone 16:00 of 16:00.');
      expect(a.eligibleAsPrior, isTrue);
    },
  );

  test('treadmill: no-fix ticks carry HR; indoor, HR only', () {
    final run = load('treadmill_no_fix_hr');
    expect(run.samples.length, 600);
    expect(
      run.samples.every((s) => !s.hasFix && s.accM == null && s.hr != null),
      isTrue,
    );
    expect(run.distanceM, 0);
    final free = engine.analyze(
      run,
      profile: const UserProfile(maxHr: 180),
      now: fixedNow,
    );
    expect(free.indoor, isTrue);
    expect(free.verdict, isNull);
    expect(free.freeRun.avgHr, closeTo(135, 2));
    expect(free.freeRun.avgPaceSecPerKm, isNull);
    // Overridden to 4x4 it is INDOOR RUN, never a pace verdict.
    final indoor = engine.analyze(
      run,
      sidecar: RunSidecar(runId: run.id).withOverride(RunMode.fourByFour),
      profile: const UserProfile(maxHr: 180),
      now: fixedNow,
    );
    expect(indoor.verdict!.headline, VerdictHeadline.indoorRun);
    expect(indoor.eligibleAsPrior, isFalse);
  });

  test('GPS dropout: no-fix ticks with repeated dist, fixes resume without a spike', () {
    final run = load('gps_dropout_hr');
    final noFix = run.samples.where((s) => !s.hasFix).toList();
    expect(noFix.length, 46);
    expect(noFix.map((s) => s.distM).toSet().length, 1, reason: 'dist repeats');
    expect(noFix.every((s) => s.hr == 150), isTrue);
    final t = Trace(run.samples);
    expect(t.fixShare(), closeTo(315 / 361, 0.01));
    // Quality counts the no-fix ticks as bad samples but the run is not noisy.
    final a = engine.analyze(run, now: fixedNow);
    expect(a.indoor, isFalse);
    expect(a.noisy, isFalse);
    expect(a.gpsQuality, closeTo(315 / 361, 0.01));
    expect(a.freeRun.distanceM, closeTo(1078.8, 0.1));
    // The 45 s hole is a sample gap for any rep it sits in: forced to 4x4
    // the speed fallback finds no pattern (constant 3 m/s), no throw.
    final forced = engine.analyze(
      run,
      sidecar: RunSidecar(runId: run.id).withOverride(RunMode.fourByFour),
      now: fixedNow,
    );
    expect(forced.verdict!.headline, VerdictHeadline.noVerdict);
  });

  test('free run with a pause and manual laps: moving time and splits', () {
    final run = load('free_run_pause_manual_laps');
    expect(run.pauses, [const Span(270000, 290000)]);
    expect(run.laps.map((l) => l.kind).toSet(), {LapKind.manual});
    expect(run.hasHr, isFalse);
    final a = engine.analyze(run, now: fixedNow);
    expect(a.verdict, isNull);
    expect(a.freeRun.elapsedSeconds, 540);
    expect(a.freeRun.movingSeconds, 520);
    expect(a.freeRun.distanceM, closeTo(1558.2, 0.1));
    expect(a.freeRun.avgPaceSecPerKm, closeTo(520 / 1.5582, 0.5));
    expect(a.freeRun.splitsSecPerUnit.length, 1);
    expect(a.freeRun.avgHr, isNull);
  });
}
