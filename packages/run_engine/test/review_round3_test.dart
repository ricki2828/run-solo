import 'package:run_engine/run_engine.dart';
import 'package:run_engine/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// PR #2 re-review (5ee444d): P1-5 keep/drop, P2-13 edge false positives,
/// P2-14 distance covered while paused.
void main() {
  group('P1-5 keep / drop resolve a flagged edge phase', () {
    // fixture → (index of the flagged lap in detection.laps, phase)
    const flagged = {
      'preset_rep1_cut_short': 1,
      'preset_last_rep_cut_short': 7,
      'preset_recovery1_cut_short': 2,
      'preset_work_4_31_flagged': 1,
      'preset_work_3_29_flagged': 3,
      'preset_recovery_3_31_flagged': 6,
    };

    for (final entry in flagged.entries) {
      final name = entry.key;
      final index = entry.value;
      final run = fixture(name).run;
      final isRecovery = name.contains('recovery');

      test('$name: keep → verdict with 4 reps, lap marked outsideWindow', () {
        final sidecar = RunSidecar(runId: run.id)
            .withLapEdit(LapEdit.keep(index));
        final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
        expect(a.lapEditsInvalid, isFalse);
        expect(
          a.lapsInconsistent,
          isFalse,
          reason: a.detection!.inconsistencyDetail,
        );
        final m = a.intervals!;
        expect(m.reps.length, 4);
        expect(m.cleanRepCount, 4);
        expect(a.verdict!.headline, VerdictHeadline.baselineSet);
        expect(a.eligibleAsPrior, isTrue);
        if (isRecovery) {
          expect(a.detection!.reps.any((r) => r.recoveryOutsideWindow), isTrue);
        } else {
          expect(m.reps.where((r) => r.outsideWindow).length, 1);
        }
      });

      test(
        '$name: drop → verdict on the remaining reps, dropped one excluded',
        () {
          final sidecar = RunSidecar(runId: run.id)
              .withLapEdit(LapEdit.drop(index));
          final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
          expect(
            a.lapsInconsistent,
            isFalse,
            reason: a.detection!.inconsistencyDetail,
          );
          final m = a.intervals!;
          expect(m.reps.length, 4);
          expect(a.verdict!.headline, VerdictHeadline.baselineSet);
          expect(a.eligibleAsPrior, isTrue);
          if (isRecovery) {
            expect(m.recoveries.where((r) => r.dropped).length, 1);
            expect(m.recoveryPaceSecPerKm, closeTo(370, 0.5));
            expect(m.cleanRepCount, 4);
          } else {
            expect(m.droppedRepCount, 1);
            expect(m.cleanRepCount, 3);
            expect(m.avgWorkPaceSecPerKm, closeTo(284, 0.5));
            // Fade never reads the dropped rep.
            expect(m.fadeSecPerKm, closeTo(0, 0.5));
          }
        },
      );

      test('$name: the edit survives sidecar rebuild and recompute', () {
        final sidecar = RunSidecar(runId: run.id)
            .withLapEdit(LapEdit.keep(index));
        final first = engine.analyze(run, sidecar: sidecar, now: fixedNow);
        final frozen = first.freezeInto(sidecar);
        final restored = RunSidecarCodec.decode(RunSidecarCodec.encode(frozen));
        expect(restored.lapEdits.single, LapEdit.keep(index));
        final again = engine.analyze(
          run,
          sidecar: restored,
          now: fixedNow.add(const Duration(days: 3)),
        );
        expect(again.verdictSource, VerdictSource.frozen);
        expect(again.lapsInconsistent, isFalse);
        // A rebuild without the frozen verdict recomputes to the same answer.
        final recomputed = engine.analyze(
          run,
          sidecar: restored.copyWith(frozenVerdict: null),
          now: fixedNow,
        );
        expect(recomputed.verdictSource, VerdictSource.computed);
        expect(recomputed.verdict!.subline, first.verdict!.subline);
      });
    }

    test('dropping two reps of four leaves too few to compare', () {
      final run = fixture('preset_4x4_auto_standard').run;
      final sidecar = RunSidecar(runId: run.id)
          .withLapEdit(const LapEdit.drop(1))
          .withLapEdit(const LapEdit.drop(3));
      final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
      expect(a.verdict!.headline, VerdictHeadline.noVerdict);
      expect(
        a.verdict!.subline,
        'Rep 1, 2 dropped. Two clean reps are not enough to compare.',
      );
      expect(a.eligibleAsPrior, isFalse);
    });

    test('a kept bail-out rep under half the preset is excluded from fade', () {
      final run = generator
          .generate(
            SyntheticSpec(
              name: 'bail',
              preset: Preset.standard,
              expectLapsConsistent: false,
              segments: [
                ...SyntheticSpecs.fourByFour().sublist(0, 7),
                const Segment.work(
                  100,
                  1000 / 300,
                ), // rep 4 bailed at 1:40, slower
                const Segment.recovery(180, 1000 / 370),
                const Segment.cooldown(300, 1000 / 390),
              ],
            ),
          )
          .run;
      // Under 70% of the preset it is not even phase-like: it reads as
      // cool-down and the run has 3 reps until the runner keeps it.
      expect(engine.analyze(run, now: fixedNow).intervals!.reps.length, 3);
      final a = engine.analyze(
        run,
        sidecar: RunSidecar(runId: run.id).withLapEdit(const LapEdit.keep(7)),
        now: fixedNow,
      );
      expect(
        a.lapsInconsistent,
        isFalse,
        reason: a.detection!.inconsistencyDetail,
      );
      expect(a.intervals!.reps.length, 4);
      expect(a.intervals!.fadeSecPerKm, closeTo(0, 0.5));
      expect(a.intervals!.reps[3].paceSecPerKm, closeTo(300, 1));
    });

    test(
      'keep/drop marks follow their lap through later merges and splits',
      () {
        final run = fixture('preset_4x4_auto_standard').run;
        final trace = Trace(run.samples);
        final base = RepDetector.editableLaps(run.laps);
        final e = applyLapEditsWithMarks(base, [
          const LapEdit.drop(7),
          const LapEdit.merge(1),
          LapEdit.split(0, 30000),
        ], trace);
        // drop lap 7 → merge 1+2 shifts it to 6 → split 0 shifts it to 7.
        expect(e.dropped, {7});
        expect(e.laps[7].t0Ms, base[7].t0Ms);
      },
    );

    test('keep and drop round-trip through the sidecar', () {
      final s = RunSidecar(
        runId: 'r1',
        lapEdits: const [LapEdit.keep(2), LapEdit.drop(5)],
      );
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.lapEdits, s.lapEdits);
      expect(back.lapEdits[0].toJson(), {'op': 'keep', 'index': 2});
    });
  });

  group('P2-13 edge walk false positives', () {
    test('a 2:15 warm-up is not "Recovery 0"', () {
      final f = fixture('warmup_2_15_clean');
      final a = engine.analyze(f.run, now: fixedNow);
      expect(
        a.lapsInconsistent,
        isFalse,
        reason: a.detection!.inconsistencyDetail,
      );
      expect(a.detection!.warmup.single.durationMs, 135000);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
    });

    test('stopping 2:20 into the final recovery is a cool-down', () {
      final f = fixture('final_recovery_truncated_2_20');
      final a = engine.analyze(f.run, now: fixedNow);
      expect(
        a.lapsInconsistent,
        isFalse,
        reason: a.detection!.inconsistencyDetail,
      );
      expect(a.intervals!.reps.length, 4);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(
        a.intervals!.avgWorkPaceSecPerKm,
        closeTo(f.expected.avgWorkPaceSecPerKm!, 0.5),
      );
    });

    test('a truncated recovery in the middle is still flagged', () {
      final a = engine.analyze(
        fixture('preset_recovery1_cut_short').run,
        now: fixedNow,
      );
      expect(a.lapsInconsistent, isTrue);
    });
  });

  group('P2-14 distance covered while paused', () {
    test('walking 24 m during a 20 s pause does not speed the rep up', () {
      final f = fixture('pause_moved_while_paused');
      // The writer kept sampling and accumulating through the pause.
      final inPause = f.run.samples.where(
        (s) => s.tMs > 1400000 && s.tMs < 1420000,
      );
      expect(inPause.length, greaterThan(15));
      expect(inPause.last.distM - inPause.first.distM, greaterThan(15));
      final a = engine.analyze(f.run, now: fixedNow);
      final m = a.intervals!;
      expect(m.reps[2].interrupted, isFalse);
      expect(
        m.reps[2].paceSecPerKm,
        closeTo(284, f.expected.toleranceSecPerKm),
      );
      expect(
        m.avgWorkPaceSecPerKm,
        closeTo(f.expected.avgWorkPaceSecPerKm!, f.expected.toleranceSecPerKm),
      );
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
    });

    test('independent: without the exclusion the rep would read faster', () {
      final f = fixture('pause_moved_while_paused');
      final noPause = f.run.copyWith(pauses: const []);
      final m = engine.analyze(noPause, now: fixedNow).intervals!;
      // 20 s standstill plus 24 m of walking counted as running: slower time,
      // but the exclusion removes both; here nothing is excluded.
      expect((m.reps[2].paceSecPerKm! - 284).abs(), greaterThan(3));
    });

    test('a writer that froze dist through the pause gets the same pace', () {
      final f = fixture('pause_15s_in_rep3');
      final m = engine.analyze(f.run, now: fixedNow).intervals!;
      expect(m.reps[2].paceSecPerKm, closeTo(284, 0.5));
    });
  });

  group('P3 newer-version files and jitter seeds', () {
    test(
      'a newer schema or unknown key is reported as newer, not malformed',
      () {
        final run = fixture('preset_4x4_auto_standard').run;
        expect(
          () => RunFile.fromJson(run.toJson()..['schema'] = 4),
          throwsA(isA<RunFileNewerVersionException>()),
        );
        expect(
          () => RunFile.fromJson(run.toJson()..['cadence'] = []),
          throwsA(isA<RunFileNewerVersionException>()),
        );
        expect(
          () => RunFile.fromJson(run.toJson()..['schema'] = 0),
          throwsA(isA<RunFileFormatException>()),
        );
      },
    );

    test('five seeds at sigma 3 m / 0.98: engine pace equals the recorded distance', () {
      // Jittered haversine inflates the *recorded* distance; that is the
      // recorder's bias, not the engine's. The engine must reproduce
      // Δdist/Δt of the file exactly and stay within 5 s/km of the truth.
      for (final seed in [1, 2, 3, 4, 5]) {
        final s = generator.generate(
          SyntheticSpec(
            name: 'jitter3_$seed',
            seed: seed,
            preset: Preset.standard,
            jitterSigmaM: 3,
            jitterCorrelation: 0.98,
            accuracyM: 12,
            segments: SyntheticSpecs.fourByFour(),
          ),
        );
        final m = engine.analyze(s.run, now: fixedNow).intervals!;
        final t = Trace(s.run.samples);
        for (final r in m.reps) {
          final recorded =
              r.trimmedSeconds /
              (t.distAt(r.trimmedT1Ms) - t.distAt(r.trimmedT0Ms)) *
              1000;
          expect(r.paceSecPerKm, closeTo(recorded, 1e-9), reason: 'seed $seed');
        }
        expect(
          m.avgWorkPaceSecPerKm,
          closeTo(s.expected.avgWorkPaceSecPerKm!, 5),
          reason: 'seed $seed',
        );
      }
    });
  });
}
