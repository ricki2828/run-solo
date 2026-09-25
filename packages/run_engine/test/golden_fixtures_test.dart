import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:run_engine/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Every synthetic fixture is analysed and checked against its analytic
/// expectation (plan §5 W5: expected paces are computed from the segments,
/// never pinned from the engine's output).
void main() {
  final fixtures = loadFixtures();

  test('the fixture set covers every spec', () {
    expect(
      fixtures.map((f) => f.name).toSet(),
      SyntheticSpecs.all.map((s) => s.name).toSet(),
    );
    expect(fixtures.length, greaterThanOrEqualTo(18));
  });

  test('fixtures on disk match what the generator emits (no drift)', () {
    for (final f in fixtures) {
      final regenerated = generator.generate(spec(f.name));
      expect(
        RunFileCodec.encode(f.run),
        RunFileCodec.encode(regenerated.run),
        reason: '${f.name}: regenerate with `dart run tool/gen_fixtures.dart`',
      );
      expect(
        jsonEncode(f.expected.toJson()),
        jsonEncode(regenerated.expected.toJson()),
        reason: '${f.name}: expectation drifted, regenerate the fixtures',
      );
    }
  });

  for (final f in fixtures) {
    group(f.name, () {
      final analysis = engine.analyze(f.run, profile: profile, now: fixedNow);
      final e = f.expected;

      test('gates', () {
        expect(analysis.indoor, e.indoor);
        expect(analysis.noisy, e.noisy);
      });

      switch (f.run.mode) {
        case RunMode.free:
        case RunMode.cooper:
          test('free run has a summary and no verdict', () {
            expect(analysis.verdict, isNull);
            expect(analysis.intervals, isNull);
            expect(analysis.laps, isNull);
            expect(analysis.freeRun.distanceM, greaterThan(0));
            expect(analysis.freeRun.avgPaceSecPerKm, isNotNull);
          });
          return;
        case RunMode.laps:
          test('laps run has a lap table and no verdict', () {
            expect(analysis.verdict, isNull);
            expect(analysis.intervals, isNull);
            expect(
              analysis.laps!.laps.length,
              e.repCount * 2 + 2,
              reason: 'warmup + work/recovery pairs + cooldown',
            );
            expect(analysis.freeRun.distanceM, greaterThan(0));
          });
          return;
        case RunMode.intervals:
          break;
      }

      final m = analysis.intervals!;
      final d = analysis.detection!;

      test('laps consistent = ${e.lapsConsistent}', () {
        expect(d.consistent, e.lapsConsistent, reason: d.inconsistencyDetail);
      });

      test('headline with no priors is ${e.headlineRun1}', () {
        expect(analysis.verdict!.headline.name, e.headlineRun1);
        expect(analysis.verdict!.engineVersion, engineVersion);
        expect(analysis.verdict!.floorSecPerKm, 10);
        expect(analysis.verdict!.bandSecPerKm, 10);
      });

      if (e.lapsConsistent) {
        test('rep count and interrupted reps', () {
          expect(m.reps.length, e.repCount);
          expect(
            m.reps.where((r) => r.interrupted).map((r) => r.number).toList(),
            e.interruptedReps,
          );
        });

        if (!e.indoor && !e.noisy) {
          test('per-rep paces within ${e.toleranceSecPerKm} s/km', () {
            for (var i = 0; i < e.repCount; i++) {
              final r = m.reps[i];
              if (r.interrupted) continue;
              expect(
                r.paceSecPerKm,
                closeTo(e.repPacesSecPerKm[i], e.toleranceSecPerKm),
                reason: 'rep ${i + 1}',
              );
            }
          });

          test('avg work pace, recovery pace, fade, spread', () {
            if (e.interruptedReps.isEmpty) {
              expect(
                m.avgWorkPaceSecPerKm,
                closeTo(e.avgWorkPaceSecPerKm!, e.toleranceSecPerKm),
              );
              expect(
                m.fadeSecPerKm,
                closeTo(e.fadeSecPerKm!, e.toleranceSecPerKm),
              );
              expect(
                m.repSpreadSecPerKm,
                closeTo(e.spreadSecPerKm!, e.toleranceSecPerKm),
              );
            }
            expect(
              m.recoveryPaceSecPerKm,
              closeTo(e.recoveryPaceSecPerKm!, e.recoveryToleranceSecPerKm),
            );
          });
        }
      }

      if (e.lapsConsistent) {
        test('independent: rep count equals the work segments in the spec', () {
          final works = spec(f.name).segments
              .where((s) => s.phase == SegmentPhase.work)
              .length;
          expect(m.reps.length, works);
          // Reps are contiguous: every recovery starts where its work ends.
          for (final r in d.reps) {
            if (r.recovery != null) expect(r.recovery!.t0Ms, r.work.t1Ms);
          }
        });
      }

      if (e.expectedMeanWorkHr != null) {
        test('HR truth: mean/peak HR, zone time at max 180, m/beat', () {
          final withMax = engine
              .analyze(
                f.run,
                profile: const UserProfile(maxHr: 180),
                now: fixedNow,
              )
              .intervals!;
          for (final r in withMax.reps) {
            expect(r.meanHr, closeTo(e.expectedMeanWorkHr!, 0.01));
            expect(r.peakHr, e.expectedMeanWorkHr!.round());
          }
          expect(withMax.meanWorkHr, closeTo(e.expectedMeanWorkHr!, 0.01));
          expect(
            withMax.timeInZoneSeconds,
            closeTo(e.expectedZoneSecondsAtMax180!, 0.01),
          );
          expect(
            withMax.metresPerBeat,
            closeTo(e.expectedMetresPerBeat!, 0.001),
          );
          expect(
            withMax.meanWorkHrFraction,
            closeTo(e.expectedMeanWorkHr! / 180, 1e-9),
          );
        });
      }

      if (e.rescueEdits.isNotEmpty) {
        test('fix-laps rescue edits restore the 4x4', () {
          var sidecar = RunSidecar(runId: f.run.id);
          for (final edit in e.rescueEdits) {
            sidecar = sidecar.withLapEdit(edit);
          }
          final fixed = engine.analyze(
            f.run,
            sidecar: sidecar,
            profile: profile,
            now: fixedNow,
          );
          expect(fixed.detection!.consistent, isTrue);
          expect(fixed.intervals!.reps.length, e.repCount);
          expect(
            fixed.intervals!.avgWorkPaceSecPerKm,
            closeTo(e.avgWorkPaceSecPerKm!, e.toleranceSecPerKm),
          );
          expect(fixed.verdict!.headline, VerdictHeadline.baselineSet);
        });
      }
    });
  }
}
