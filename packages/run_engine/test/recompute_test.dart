import 'package:run_engine/run_engine.dart';
import 'package:run_engine/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Frozen verdicts, overrides and fix-laps on recompute (plan §5, §17 R3).
void main() {
  final run = fixture('preset_4x4_auto_standard').run;

  group('frozen verdict', () {
    test('a frozen verdict is returned as-is, not recomputed', () {
      final first = engine.analyze(run, now: fixedNow);
      expect(first.verdictSource, VerdictSource.computed);
      final sidecar = first.freezeInto(RunSidecar(runId: run.id));
      expect(sidecar.frozenVerdict, isNotNull);

      // Same run, but now with priors that would change the stage: frozen wins.
      final later = engine.analyze(
        run,
        sidecar: sidecar,
        priors: [
          prior(
            '00000000-0000-4000-8000-000000000701',
            DateTime.utc(2026, 1, 1),
            320,
          ),
        ],
        now: fixedNow.add(const Duration(days: 30)),
      );
      expect(later.verdictSource, VerdictSource.frozen);
      expect(later.verdict!.stage, VerdictStage.baseline);
      expect(later.verdict!.computedAt, fixedNow);
      expect(later.verdict!.subline, first.verdict!.subline);
    });

    test('an engine version bump recomputes', () {
      final frozen = engine.analyze(run, now: fixedNow).verdict!;
      final stale = Verdict.fromJson(
        frozen.toJson()..['engine_version'] = engineVersion - 1,
      );
      final a = engine.analyze(
        run,
        sidecar: RunSidecar(runId: run.id, frozenVerdict: stale),
        now: fixedNow,
      );
      expect(a.verdictSource, VerdictSource.computed);
      expect(a.verdict!.engineVersion, engineVersion);
    });

    test('sidecar round trip keeps the frozen verdict reproducible', () {
      final a = engine.analyze(run, now: fixedNow);
      final text = RunSidecarCodec.encode(
        a.freezeInto(RunSidecar(runId: run.id)),
      );
      final restored = engine.analyze(
        run,
        sidecar: RunSidecarCodec.decode(text),
        now: fixedNow.add(const Duration(days: 1)),
      );
      expect(restored.verdictSource, VerdictSource.frozen);
      expect(restored.verdict!.toJson(), a.verdict!.toJson());
    });
  });

  group('override', () {
    test('free override on a 4x4 drops the verdict; survives recompute', () {
      final sidecar = RunSidecar(runId: run.id).withOverride(RunMode.free);
      final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
      expect(a.mode, RunMode.free);
      expect(a.verdict, isNull);
      expect(a.fourByFour, isNull);
      expect(a.freeRun.distanceM, greaterThan(0));
      expect(a.eligibleAsPrior, isFalse);
      // Recompute with priors: still free.
      final again = engine.analyze(
        run,
        sidecar: sidecar,
        priors: [
          prior(
            '00000000-0000-4000-8000-000000000711',
            DateTime.utc(2026, 1, 1),
            300,
          ),
        ],
        now: fixedNow,
      );
      expect(again.verdict, isNull);
    });

    test('4x4 override on a free run detects reps (speed fallback)', () {
      final free = fixture('four_by_four_no_laps_speed_fallback').run
          .copyWith(mode: RunMode.free);
      expect(engine.analyze(free, now: fixedNow).verdict, isNull);
      final a = engine.analyze(
        free,
        sidecar: RunSidecar(runId: free.id).withOverride(RunMode.fourByFour),
        now: fixedNow,
      );
      expect(a.mode, RunMode.fourByFour);
      expect(a.detection!.fromSpeedStream, isTrue);
      expect(a.detection!.consistent, isTrue);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
    });
  });

  group('fix laps', () {
    final trace = Trace(run.samples);

    test('merge joins two laps and renumbers', () {
      final merged = applyLapEdits(run.laps, const [LapEdit.merge(1)], trace);
      expect(merged.length, run.laps.length - 1);
      expect(merged[1].t0Ms, run.laps[1].t0Ms);
      expect(merged[1].t1Ms, run.laps[2].t1Ms);
      expect(merged[1].d1M, run.laps[2].d1M);
      for (var i = 0; i < merged.length; i++) {
        expect(merged[i].index, i);
      }
    });

    test('split divides a lap at a time with interpolated distance', () {
      final lap = run.laps[1];
      final at = lap.t0Ms + 100000;
      final split = applyLapEdits(run.laps, [LapEdit.split(1, at)], trace);
      expect(split.length, run.laps.length + 1);
      expect(split[1].t1Ms, at);
      expect(split[2].t0Ms, at);
      expect(split[1].d1M, split[2].d0M);
      expect(split[1].d1M, closeTo(trace.distAt(at), 0.01));
      expect(split[2].t1Ms, lap.t1Ms);
    });

    test('edits apply in order (split then merge is a no-op)', () {
      final lap = run.laps[1];
      final laps = applyLapEdits(run.laps, [
        LapEdit.split(1, lap.t0Ms + 60000),
        const LapEdit.merge(1),
      ], trace);
      expect(laps.length, run.laps.length);
      expect(laps[1].t0Ms, lap.t0Ms);
      expect(laps[1].t1Ms, lap.t1Ms);
    });

    test('invalid edits are refused', () {
      expect(
        () => applyLapEdits(run.laps, const [LapEdit.merge(99)], trace),
        throwsA(isA<LapEditException>()),
      );
      expect(
        () => applyLapEdits(run.laps, [
          LapEdit.merge(run.laps.length - 1),
        ], trace),
        throwsA(isA<LapEditException>()),
      );
      expect(
        () => applyLapEdits(run.laps, [
          LapEdit.split(1, run.laps[1].t0Ms),
        ], trace),
        throwsA(isA<LapEditException>()),
      );
    });

    test(
      'missed press → inconsistent → split rescues it (verdict recomputed)',
      () {
        final f = fixture('four_by_four_missed_press');
        final broken = engine.analyze(f.run, now: fixedNow);
        expect(broken.lapsInconsistent, isTrue);
        expect(broken.verdict!.headline, VerdictHeadline.noVerdict);
        expect(
          broken.verdict!.subline,
          'Laps do not match a 4x4. Fix laps to get a verdict.',
        );
        expect(
          broken.detection!.inconsistencyDetail,
          'Rep 2 was 7:00, outside the 4x4 window.',
        );

        var sidecar = broken.freezeInto(RunSidecar(runId: f.run.id));
        for (final e in f.expected.rescueEdits) {
          sidecar = sidecar.withLapEdit(e);
        }
        expect(sidecar.frozenVerdict, isNull, reason: 'fix-laps unfreezes');
        final fixed = engine.analyze(f.run, sidecar: sidecar, now: fixedNow);
        expect(fixed.verdictSource, VerdictSource.computed);
        expect(fixed.lapsInconsistent, isFalse);
        expect(fixed.fourByFour!.reps.length, 4);
        expect(fixed.verdict!.headline, VerdictHeadline.baselineSet);
      },
    );

    test('a merge that breaks a good 4x4 is reported with the preset copy', () {
      final a = engine.analyze(
        run,
        sidecar: RunSidecar(runId: run.id).withLapEdit(const LapEdit.merge(3)),
        now: fixedNow,
      );
      expect(a.lapsInconsistent, isTrue);
      expect(
        a.detection!.inconsistencyDetail,
        'Rep 2 was 7:00, the preset expected 4:00. Keep it, merge it, or drop it?',
      );
    });
  });

  group('detector', () {
    test(
      'auto laps and manual laps on the same trace give the same verdict',
      () {
        final auto = engine.analyze(
          fixture('preset_4x4_auto_standard').run,
          now: fixedNow,
        );
        final manual = engine.analyze(
          fixture('preset_4x4_manual_standard').run,
          now: fixedNow,
        );
        expect(manual.verdict!.headline, auto.verdict!.headline);
        expect(manual.verdict!.subline, auto.verdict!.subline);
        expect(
          manual.fourByFour!.avgWorkPaceSecPerKm,
          closeTo(auto.fourByFour!.avgWorkPaceSecPerKm!, 0.01),
        );
      },
    );

    test('the preset window accepts the edited recovery, the by-feel window would not', () {
      // 2:00 recovery is on the by-feel lower bound; 5:00 on the upper. The
      // 3:30 template recovery sits inside both. Check that removing the
      // preset from the 5:00-recovery run still classifies (5:00 is the
      // by-feel max) while a 5:20 recovery only classifies with its preset.
      final base = fixture('preset_6x4_recovery_5_00').run;
      expect(
        engine
            .analyze(base.copyWith(preset: null), now: fixedNow)
            .lapsInconsistent,
        isFalse,
      );

      final long = generator
          .generate(
            SyntheticSpec(
              name: 'r520',
              preset: const Preset(
                reps: 4,
                workSeconds: 240,
                recoverySeconds: 320,
              ),
              segments: SyntheticSpecs.fourByFour(recoveryS: 320),
            ),
          )
          .run;
      expect(engine.analyze(long, now: fixedNow).lapsInconsistent, isFalse);
      expect(
        engine
            .analyze(long.copyWith(preset: null), now: fixedNow)
            .lapsInconsistent,
        isTrue,
      );
    });

    test('preset rep count ±1 is tolerated, ±2 is not', () {
      final five = fixture('preset_5x4_recovery_2_00_missing_final_recovery')
          .run;
      final asFour = five.copyWith(
        preset: const Preset(reps: 4, workSeconds: 240, recoverySeconds: 120),
      );
      expect(engine.analyze(asFour, now: fixedNow).lapsInconsistent, isFalse);
      final asThree = five.copyWith(
        preset: const Preset(reps: 3, workSeconds: 240, recoverySeconds: 120),
      );
      final a = engine.analyze(asThree, now: fixedNow);
      expect(a.lapsInconsistent, isTrue);
      expect(
        a.detection!.inconsistencyDetail,
        'Found 5 reps, the preset expected 3.',
      );
    });

    test('warmup and cooldown laps are labelled, pause laps dropped', () {
      final withPause = run.copyWith(
        laps: [
          ...run.laps.sublist(0, 1),
          Lap(
            index: 1,
            t0Ms: run.laps[1].t0Ms,
            t1Ms: run.laps[1].t0Ms,
            d0M: run.laps[1].d0M,
            d1M: run.laps[1].d0M,
            kind: LapKind.pause,
          ),
          ...run.laps.sublist(1).map((l) => l.copyWith(index: l.index + 1)),
        ],
      );
      final a = engine.analyze(withPause, now: fixedNow);
      expect(a.detection!.warmup.length, 1);
      expect(a.detection!.cooldown.length, 1);
      expect(a.detection!.reps.length, 4);
      expect(a.detection!.laps.every((l) => l.kind != LapKind.pause), isTrue);
    });

    test('work that is not 15% faster than recovery is not a rep', () {
      final flat = generator
          .generate(
            SyntheticSpec(
              name: 'flat',
              preset: Preset.standard,
              segments: SyntheticSpecs.fourByFour(
                workSpeeds: List.filled(4, 1000 / 340),
                recoverySpeed: 1000 / 360,
              ),
            ),
          )
          .run;
      final a = engine.analyze(flat, now: fixedNow);
      expect(a.lapsInconsistent, isTrue);
    });
  });

  group('metrics', () {
    test('HR: max HR precedence and time in zone', () {
      final hr = fixture('four_by_four_manual_clean_hr').run;
      final byAge = engine
          .analyze(hr, profile: const UserProfile(age: 40), now: fixedNow)
          .fourByFour!;
      expect(byAge.maxHrUsed, 180);
      final bySetting = engine
          .analyze(
            hr,
            profile: const UserProfile(age: 40, maxHr: 190),
            now: fixedNow,
          )
          .fourByFour!;
      expect(bySetting.maxHrUsed, 190);
      // No profile at all: the 190 fallback (D3) so zones always resolve;
      // the run's own 30 s peak is reported so the store can fold it into
      // settings, never used as this run's denominator.
      final none = engine.analyze(hr, now: fixedNow).fourByFour!;
      expect(none.maxHrUsed, 190);
      expect(none.timeInZoneSeconds, isNotNull);
      expect(none.observedMaxHrThisRun, closeTo(170, 3));
      // A user-level observed max above 220−age wins over the estimate;
      // this run's own peak never does (one denominator across history).
      final observed = engine
          .analyze(
            hr,
            profile: const UserProfile(age: 60, observedMaxHr: 175),
            now: fixedNow,
          )
          .fourByFour!;
      expect(observed.maxHrUsed, 175);
      final older = engine
          .analyze(hr, profile: const UserProfile(age: 60), now: fixedNow)
          .fourByFour!;
      expect(older.maxHrUsed, 160);
      expect(byAge.timeInZoneSeconds, greaterThan(800));
      expect(byAge.timeInZoneSeconds, lessThanOrEqualTo(byAge.workSeconds));
      expect(byAge.workSeconds, 960);
      expect(
        byAge.reps.every((r) => r.meanHr != null && r.peakHr != null),
        isTrue,
      );
      expect(byAge.reps.first.hrRecoveryDrop, greaterThan(0));
      expect(byAge.metresPerBeat, greaterThan(1));
    });

    test('no HR → HR metrics null, hrLine null', () {
      final a = engine.analyze(
        fixture('four_by_four_manual_clean').run,
        profile: profile,
        now: fixedNow,
      );
      expect(a.fourByFour!.hrPresent, isFalse);
      expect(a.fourByFour!.timeInZoneSeconds, isNull);
      expect(a.verdict!.hrLine, isNull);
    });

    test('free run: distance, moving time, splits, avg HR', () {
      final a = engine.analyze(fixture('easy_free_run').run, now: fixedNow);
      final s = a.freeRun;
      expect(s.distanceM, closeTo(5000, 20));
      expect(s.elapsedSeconds, 1800);
      expect(s.movingSeconds, 1800);
      expect(s.avgPaceSecPerKm, closeTo(360, 2));
      expect(s.splitsSecPerUnit.length, 4);
      expect(s.splitsSecPerUnit[1], closeTo(360, 1));
      expect(s.avgHr, closeTo(142, 3));
    });

    test('pauses reduce moving time', () {
      final a = engine.analyze(fixture('pause_mid_rep3').run, now: fixedNow);
      expect(a.freeRun.movingSeconds, a.freeRun.elapsedSeconds - 30);
    });

    test('rep pace is Δd/Δt over the trimmed window', () {
      final a = engine.analyze(run, now: fixedNow).fourByFour!;
      final r = a.reps.first;
      expect(r.trimmedT0Ms, r.lap.t0Ms + 12000);
      expect(r.trimmedT1Ms, r.lap.t1Ms - 5000);
      expect(
        r.paceSecPerKm,
        closeTo(r.trimmedSeconds / r.distanceM * 1000, 1e-9),
      );
    });
  });
}
