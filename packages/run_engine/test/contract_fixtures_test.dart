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

  /// Schema-2 fixtures live at the top level; the schema-1 set is frozen
  /// under `contract/schema1/` (§18.7). A name is looked up in both so the
  /// tests below survive the writer's move.
  File fileOf(String name) {
    for (final candidate in [
      File('${dir.path}/$name.json'),
      File('${dir.path}/schema1/$name.json'),
    ]) {
      if (candidate.existsSync()) return candidate;
    }
    fail('contract fixture $name missing from $dir and $dir/schema1');
  }

  RunFile load(String name) =>
      RunFileCodec.decode(fileOf(name).readAsStringSync());

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
      final inSchema1Dir = f.path.contains('/schema1/');
      expect(
        run.readSchema,
        inSchema1Dir ? 1 : anyOf(1, 2),
        reason: 'frozen schema-1 copies stay schema 1: ${f.path}',
      );
    }
  });

  test('a frozen schema-1 fixture, once present, is byte-identical to the '
      'copy that shipped with Phase 1', () {
    // The four Phase-1 files are frozen read-only under schema1/ by the
    // writer's PR; until then they sit at the top level. Either way the
    // schema-1 `free` file must read as laps (§18.7 B1).
    final run = load('free_run_pause_manual_laps');
    expect(run.readSchema, 1);
    expect(run.mode, RunMode.laps);
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
