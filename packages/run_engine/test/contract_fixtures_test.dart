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

  /// `contract/schema1/` is the frozen Phase-1 writer output (read-only,
  /// still `schema: 1`, `mode: free`); `contract/<name>.json` is regenerated
  /// by the Phase-2 Kotlin writer (§18.7). Both trees are `diff -r`'d
  /// against core-jvm in CI.
  File fileOf(String name, {int schema = 1}) {
    final f = File(
      schema == 1 ? '${dir.path}/schema1/$name.json' : '${dir.path}/$name.json',
    );
    if (!f.existsSync()) fail('contract fixture missing: ${f.path}');
    return f;
  }

  RunFile load(String name, {int schema = 1}) =>
      RunFileCodec.decode(fileOf(name, schema: schema).readAsStringSync());

  List<File> allFixtures() => [
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.json')) f,
  ];

  test('every contract fixture decodes and re-encodes stably', () {
    final files = allFixtures();
    expect(files, isNotEmpty, reason: 'an empty dir must fail, never pass');
    for (final f in files) {
      final text = f.readAsStringSync();
      expect(text, contains('T00:00:00Z"'), reason: 'Instant.toString()');
      expect(text, contains('"d0":0,'), reason: 'integral double as int');
      final run = RunFileCodec.decode(text);
      final canonical = RunFileCodec.encode(run);
      expect(RunFileCodec.encode(RunFileCodec.decode(canonical)), canonical);
      expect(run.start, DateTime.utc(2025, 9, 24));
      final expectedSchema = f.path.contains('/schema1/') ? 1 : 2;
      expect(run.readSchema, expectedSchema, reason: f.path);
      expect(text, contains('"schema":$expectedSchema,'), reason: f.path);
    }
    expect(files.length, greaterThanOrEqualTo(9), reason: '4 frozen + 5 new');
  });

  test('the frozen schema-1 free file reads as laps (§18.7 B1)', () {
    final run = load('free_run_pause_manual_laps');
    expect(run.readSchema, 1);
    expect(run.mode, RunMode.laps);
  });

  group('schema-2 writer output', () {
    test('4x4 preset: identical verdict to the frozen schema-1 recording', () {
      final v1 = load('four_by_four_preset_auto_hr');
      final v2 = load('four_by_four_preset_auto_hr', schema: 2);
      expect(v2.readSchema, 2);
      expect(v2.mode, RunMode.fourByFour);
      expect(v2.preset, Preset.standard);
      // No recovery after the last rep: 9 laps, stopped 60 s into cool-down
      // (27:00); the work reps match the frozen 10-lap schema-1 recording.
      expect(v2.laps.length, 9);
      expect(v2.samples.length, 1620);
      final a1 = engine.analyze(
        v1,
        profile: const UserProfile(maxHr: 185),
        now: fixedNow,
      );
      final a2 = engine.analyze(
        v2,
        profile: const UserProfile(maxHr: 185),
        now: fixedNow,
      );
      expect(a2.verdict!.headline, VerdictHeadline.baselineSet);
      expect(a2.verdict!.subline, a1.verdict!.subline);
      expect(a2.verdict!.hrLine, a1.verdict!.hrLine);
      expect(
        a2.fourByFour!.avgWorkPaceSecPerKm,
        closeTo(a1.fourByFour!.avgWorkPaceSecPerKm!, 1e-6),
      );
    });

    test(
      'treadmill recorded as laps: indoor, lap rows with no pace, HR band',
      () {
        final run = load('treadmill_no_fix_hr', schema: 2);
        expect(run.mode, RunMode.laps);
        expect(run.laps.length, 2);
        final a = engine.analyze(
          run,
          profile: const UserProfile(maxHr: 180),
          now: fixedNow,
        );
        expect(a.indoor, isTrue);
        expect(a.verdict, isNull);
        final l = a.laps!;
        expect(l.laps.length, 2);
        expect(l.laps.every((r) => r.paceSecPerKm == null), isTrue);
        expect(l.laps.every((r) => !r.scored), isTrue, reason: 'no distance');
        expect(l.fastestLapNumber, isNull);
        expect(l.spreadSecPerKm, isNull);
        expect(l.laps.every((r) => r.movingSeconds == 300), isTrue);
        expect(l.avgHr, closeTo(135, 2));
        expect(l.maxHrUsed, 180);
        expect(l.timeInBandSeconds, isNotNull);
      },
    );

    test('gps dropout recorded as free: summary only, same distance as v1', () {
      final v1 = load('gps_dropout_hr');
      final v2 = load('gps_dropout_hr', schema: 2);
      expect(v1.mode, RunMode.laps, reason: 'v1 free → laps');
      expect(v2.mode, RunMode.free);
      expect(v2.laps.length, 1, reason: 'one segment [0, end]');
      final a = engine.analyze(v2, now: fixedNow);
      expect(a.laps, isNull);
      expect(a.verdict, isNull);
      expect(a.freeRun.distanceM, closeTo(1075.8, 0.5));
      expect(a.gpsQuality, closeTo(314 / 360, 0.01));
    });

    test(
      'laps run with a pause: same lap table as the frozen v1 recording',
      () {
        final v1 = load('free_run_pause_manual_laps');
        final v2 = load('laps_run_pause_manual_laps', schema: 2);
        expect(v2.mode, RunMode.laps);
        expect(v2.pauses, [const Span(270000, 290000)]);
        expect(v2.laps.length, 3);
        final a1 = engine.analyze(v1, now: fixedNow).laps!;
        final a2 = engine.analyze(v2, now: fixedNow).laps!;
        expect(a2.laps.length, 3);
        expect(a2.laps[1].movingSeconds, 160);
        for (var i = 0; i < 3; i++) {
          expect(a2.laps[i].distanceM, closeTo(a1.laps[i].distanceM, 0.01));
          expect(
            a2.laps[i].paceSecPerKm,
            closeTo(a1.laps[i].paceSecPerKm!, 0.01),
          );
        }
        expect(a2.fastestLapNumber, a1.fastestLapNumber);
        expect(a2.spreadSecPerKm, closeTo(a1.spreadSecPerKm!, 0.01));
      },
    );

    test(
      'free run with no laps: one segment, pause excluded, no lap table',
      () {
        final run = load('free_run_no_laps', schema: 2);
        expect(run.mode, RunMode.free);
        expect(run.preset, isNull);
        expect(run.laps.length, 1, reason: 'lap() calls ignored: one segment');
        expect(run.laps.single.t0Ms, 0);
        expect(run.laps.single.t1Ms, 480000);
        expect(run.pauses, [const Span(240000, 255000)]);
        expect(run.hasHr, isTrue);
        final a = engine.analyze(run, now: fixedNow);
        expect(a.mode, RunMode.free);
        expect(a.laps, isNull);
        expect(a.verdict, isNull);
        expect(a.freeRun.elapsedSeconds, 480);
        expect(a.freeRun.movingSeconds, 465);
        expect(a.freeRun.distanceM, closeTo(1387, 1));
        expect(a.freeRun.avgHr, isNotNull);
        expect(a.freeRun.splitsSecPerUnit.length, 1);
        // Overridden to Laps it is one row; the segment is the whole run.
        final asLaps = engine.analyze(
          run,
          sidecar: RunSidecar(runId: run.id).withOverride(RunMode.laps),
          now: fixedNow,
        );
        expect(asLaps.laps!.laps.length, 1);
        expect(asLaps.laps!.laps.single.movingSeconds, 465);
        expect(asLaps.laps!.spreadSecPerKm, isNull);
      },
    );
  });

  test(
    '4x4 preset with RecorderCore auto-laps and HR gets a baseline verdict',
    () {
      final run = load('four_by_four_preset_auto_hr');
      expect(run.preset, Preset.standard);
      expect(run.laps.length, 10);
      expect(run.samples.length, 1800);
      expect(
        run.samples.first.tMs,
        1000,
        reason: 'recording starts at second 1',
      );
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
        closeTo(
          956,
          0.5,
        ), // each rep's first tick carries the previous phase HR
        reason: '165-169 is 89-91% of 185',
      );
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(
        a.verdict!.subline,
        '3:58/km work pace. Reps within 0 s of each other. Recovery 8:21. Next 4x4 gets a verdict.',
      );
      expect(a.verdict!.hrLine, 'Time in zone 15:56 of 16:00.');
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
    expect(t.fixShare(), closeTo(314 / 360, 0.01));
    // Quality counts the no-fix ticks as bad samples but the run is not noisy.
    final a = engine.analyze(run, now: fixedNow);
    expect(a.indoor, isFalse);
    expect(a.noisy, isFalse);
    expect(a.gpsQuality, closeTo(314 / 360, 0.01));
    expect(
      a.freeRun.distanceM,
      closeTo(1075.8, 0.5),
      reason: 'anchored on the second fix',
    );
    // The 45 s hole is a sample gap for any rep it sits in: forced to 4x4
    // the speed fallback finds no pattern (constant 3 m/s), no throw.
    final forced = engine.analyze(
      run,
      sidecar: RunSidecar(runId: run.id).withOverride(RunMode.fourByFour),
      now: fixedNow,
    );
    expect(forced.verdict!.headline, VerdictHeadline.noVerdict);
  });

  test('v1 free run with a pause and manual laps: reads as Laps, gets the '
      'lap table with the pause taken out of lap 2', () {
    final run = load('free_run_pause_manual_laps');
    expect(run.pauses, [const Span(270000, 290000)]);
    expect(run.laps.map((l) => l.kind).toSet(), {LapKind.manual});
    expect(run.hasHr, isFalse);
    final a = engine.analyze(run, now: fixedNow);
    expect(a.verdict, isNull);
    expect(a.mode, RunMode.laps);
    final l = a.laps!;
    expect(l.laps.length, 3);
    expect(l.laps.every((r) => r.scored), isTrue);
    // Lap 2 (180–360 s) holds the 20 s pause with dist frozen: 160 s moving
    // over the recorded lap distance.
    final lap2 = l.laps[1];
    expect(lap2.movingSeconds, 160);
    expect(lap2.distanceM, closeTo(run.laps[1].distanceM, 0.01));
    expect(
      lap2.paceSecPerKm,
      closeTo(160 / run.laps[1].distanceM * 1000, 0.01),
    );
    expect(l.laps[0].movingSeconds, 180);
    expect(l.hrPresent, isFalse);
    expect(l.timeInBandSeconds, isNull);
    expect(l.avgHr, isNull);
    expect(l.fastestLapNumber, isNotNull);
    expect(l.spreadSecPerKm, isNotNull);
    expect(a.freeRun.elapsedSeconds, 540);
    expect(a.freeRun.movingSeconds, 520);
    expect(a.freeRun.distanceM, closeTo(1552.3, 0.5));
    expect(a.freeRun.avgPaceSecPerKm, closeTo(520 / 1.5523, 0.5));
    // Dist is frozen through the pause (P2-14 on the Kotlin side); the
    // samples are still there with a fix.
    final paused = run.samples
        .where((s) => s.tMs >= 270000 && s.tMs <= 290000)
        .toList();
    expect(paused.every((s) => s.hasFix), isTrue);
    expect(paused.map((s) => s.distM).toSet().length, 1);
    expect(a.freeRun.splitsSecPerUnit.length, 1);
    expect(a.freeRun.avgHr, isNull);
  });
}
