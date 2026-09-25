import 'package:run_engine/run_engine.dart';
import 'package:run_engine/testing.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'helpers.dart';

/// Regression tests for the PR #2 review findings (P1-1..3, P2s, P3s).
void main() {
  group('P1-1 edge phases are flagged, not relabelled', () {
    const cases = {
      'preset_rep1_cut_short': 'Rep 1 was 3:20, the preset expected 4:00. Keep it, merge it, or drop it?',
      'preset_last_rep_cut_short': 'Rep 4 was 3:20, the preset expected 4:00. Keep it, merge it, or drop it?',
      'preset_recovery1_cut_short': 'Recovery 1 was 2:20, the preset expected 3:00. Keep it, merge it, or drop it?',
      'preset_work_4_31_flagged': 'Rep 1 was 4:31, the preset expected 4:00. Keep it, merge it, or drop it?',
      'preset_work_3_29_flagged': 'Rep 2 was 3:29, the preset expected 4:00. Keep it, merge it, or drop it?',
      'preset_recovery_3_31_flagged': 'Recovery 3 was 3:31, the preset expected 3:00. Keep it, merge it, or drop it?',
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final a = engine.analyze(fixture(entry.key).run, now: fixedNow);
        expect(a.lapsInconsistent, isTrue);
        expect(a.detection!.inconsistencyDetail, entry.value);
        expect(a.verdict!.headline, VerdictHeadline.noVerdict);
        expect(a.eligibleAsPrior, isFalse);
      });
    }

    test(
      'independent: the odd lap is outside the block and the run is refused',
      () {
        for (final name in cases.keys) {
          final a = engine.analyze(fixture(name).run, now: fixedNow);
          final d = a.detection!;
          final block = <Lap>[
            for (final r in d.reps) r.work,
            for (final r in d.reps)
              if (r.recovery != null) r.recovery!,
          ];
          final outside = [...d.warmup, ...d.cooldown];
          // The spec's odd phase (200 s, 140 s, 271 s, 209 s or 211 s) is the
          // one lap whose length matches none of the standard phases.
          const standard = {480000, 240000, 180000, 300000};
          final odd = d.laps.where((l) => !standard.contains(l.durationMs));
          expect(odd.length, 1, reason: name);
          expect(outside, contains(odd.single), reason: name);
          expect(block.length + outside.length, d.laps.length, reason: name);
        }
      },
    );

    test('edges inside the tolerance are accepted', () {
      for (final name in [
        'preset_work_4_30_accepted',
        'preset_work_3_30_accepted',
        'preset_recovery_edges_accepted',
      ]) {
        final a = engine.analyze(fixture(name).run, now: fixedNow);
        expect(
          a.lapsInconsistent,
          isFalse,
          reason: '$name: ${a.detection!.inconsistencyDetail}',
        );
        expect(a.fourByFour!.reps.length, 4, reason: name);
      }
    });

    test('a slow long warm-up or cool-down is still not a phase', () {
      final a = engine.analyze(
        fixture('preset_4x4_auto_standard').run,
        now: fixedNow,
      );
      expect(a.detection!.warmup.length, 1);
      expect(a.detection!.cooldown.length, 1);
      expect(a.lapsInconsistent, isFalse);
    });

    test('a by-feel run flags a cut edge with the by-feel copy', () {
      final run = fixture('preset_rep1_cut_short').run.copyWith(session: null);
      final a = engine.analyze(run, now: fixedNow);
      expect(a.lapsInconsistent, isTrue);
      expect(
        a.detection!.inconsistencyDetail,
        'Rep 1 was 3:20, outside the 4x4 window.',
      );
    });
  });

  group('P1-2 short pauses inside a rep', () {
    for (final name in ['pause_8s_in_rep3', 'pause_15s_in_rep3']) {
      test('$name: pace excludes the standstill, no "GPS dropped"', () {
        final f = fixture(name);
        final a = engine.analyze(f.run, now: fixedNow);
        final m = a.fourByFour!;
        expect(m.reps.every((r) => !r.interrupted), isTrue);
        expect(m.reps[2].pausedMs, f.run.pauses.single.durationMs);
        expect(m.reps[2].paceSecPerKm, closeTo(284, 0.5));
        expect(m.repSpreadSecPerKm, closeTo(0, 0.5));
        expect(
          m.avgWorkPaceSecPerKm,
          closeTo(f.expected.avgWorkPaceSecPerKm!, 0.5),
        );
        expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      });
    }

    test('independent: the paused rep covers less ground in less time', () {
      final f = fixture('pause_15s_in_rep3');
      final m = engine.analyze(f.run, now: fixedNow).fourByFour!;
      expect(m.reps[2].distanceM, lessThan(m.reps[0].distanceM - 40));
      expect(
        m.reps[2].trimmedSeconds,
        closeTo(m.reps[0].trimmedSeconds - 15, 0.01),
      );
    });

    test('a 30 s pause is "Paused", never "GPS dropped"', () {
      final a = engine.analyze(fixture('pause_mid_rep3').run, now: fixedNow);
      expect(a.fourByFour!.reps[2].interruptReason, InterruptReason.paused);
      expect(
        a.verdict!.subline,
        'Paused in rep 3. Three clean reps are not enough to compare.',
      );
    });

    test('a 15 s GPS dropout (no pause span) still reads as GPS dropped', () {
      final run = generator
          .generate(
            SyntheticSpec(
              name: 'drop15',
              preset: Preset.standard,
              dropouts: const [Span(1400000, 1415000)],
              segments: SyntheticSpecs.fourByFour(),
            ),
          )
          .run;
      final a = engine.analyze(run, now: fixedNow);
      expect(a.fourByFour!.reps[2].interruptReason, InterruptReason.gpsDropped);
    });
  });

  group('P1-3 fix-laps on a speed-fallback run', () {
    final run = fixture('four_by_four_no_laps_speed_fallback').run;

    test('edits apply to the derived laps and never throw', () {
      final base = engine.analyze(run, now: fixedNow);
      expect(base.detection!.fromSpeedStream, isTrue);
      final derived = base.detection!.laps;
      // Merge rep 2's work into its recovery: indices are positions in
      // detection.laps.
      final merged = engine.analyze(
        run,
        sidecar: RunSidecar(runId: run.id).withLapEdit(const LapEdit.merge(3)),
        now: fixedNow,
      );
      expect(merged.lapEditsInvalid, isFalse);
      expect(merged.detection!.laps.length, derived.length - 1);
      expect(merged.lapsInconsistent, isTrue);
      // Split it back: the 4x4 returns.
      final split = engine.analyze(
        run,
        sidecar: RunSidecar(runId: run.id)
            .withLapEdit(const LapEdit.merge(3))
            .withLapEdit(LapEdit.split(3, derived[3].t1Ms)),
        now: fixedNow,
      );
      expect(split.lapEditsInvalid, isFalse);
      expect(split.lapsInconsistent, isFalse);
      expect(split.verdict!.headline, VerdictHeadline.baselineSet);
    });

    test(
      'an edit that no longer applies is ignored and flagged, never thrown',
      () {
        final a = engine.analyze(
          run,
          sidecar: RunSidecar(runId: run.id)
              .withLapEdit(const LapEdit.merge(99)),
          now: fixedNow,
        );
        expect(a.lapEditsInvalid, isTrue);
        expect(a.verdict, isNotNull);
        expect(a.lapsInconsistent, isFalse);
        final recorded = fixture('preset_4x4_auto_standard').run;
        final b = engine.analyze(
          recorded,
          sidecar: RunSidecar(runId: recorded.id)
              .withLapEdit(const LapEdit.split(0, -5)),
          now: fixedNow,
        );
        expect(b.lapEditsInvalid, isTrue);
        expect(b.verdict!.headline, VerdictHeadline.baselineSet);
      },
    );
  });

  group('P2-1 lap-edit coordinates', () {
    test(
      'edits index detection.laps (pause laps dropped), not RunFile.laps',
      () {
        final run = fixture('preset_4x4_auto_standard').run;
        final withPause = run.copyWith(
          laps: [
            run.laps[0],
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
        final edit = RunSidecar(runId: run.id)
            .withLapEdit(const LapEdit.merge(1));
        final plain = engine.analyze(run, sidecar: edit, now: fixedNow);
        final paused = engine.analyze(withPause, sidecar: edit, now: fixedNow);
        expect(
          paused.detection!.laps.map((l) => (l.t0Ms, l.t1Ms)),
          plain.detection!.laps.map((l) => (l.t0Ms, l.t1Ms)),
        );
        for (var i = 0; i < paused.detection!.laps.length; i++) {
          expect(paused.detection!.laps[i].index, i);
        }
      },
    );
  });

  group('P2-2 HR line follows m/beat vs the baseline', () {
    final d1 = DateTime.utc(2026, 9, 1);
    final d2 = DateTime.utc(2026, 9, 5);
    final d3 = DateTime.utc(2026, 9, 9);
    final run = runWithPaces([282, 283, 285, 287], hr: true, start: d3);
    final own = engine
        .analyze(run, profile: profile, now: fixedNow)
        .fourByFour!;
    final pct = (own.meanWorkHrFraction! * 100).round();

    test('pace better and m/beat better → "Faster at the same HR"', () {
      final wasFraction = own.meanWorkHrFraction! - 0.05;
      final priors = [
        prior(
          '00000000-0000-4000-8000-000000000801',
          d1,
          298,
          hrFraction: wasFraction,
          mpb: own.metresPerBeat! * 0.9,
        ),
        prior(
          '00000000-0000-4000-8000-000000000802',
          d2,
          298,
          hrFraction: wasFraction,
          mpb: own.metresPerBeat! * 0.95,
        ),
      ];
      final v = engine
          .analyze(run, priors: priors, profile: profile, now: fixedNow)
          .verdict!;
      expect(v.headline, VerdictHeadline.faster);
      expect(
        v.hrLine,
        'Faster at the same HR: $pct% max HR, was ${(wasFraction * 100).round()}%.',
      );
    });

    test('pace better and m/beat better at the same % → "Same effort"', () {
      final priors = [
        prior(
          '00000000-0000-4000-8000-000000000821',
          d1,
          298,
          hrFraction: own.meanWorkHrFraction!,
          mpb: own.metresPerBeat! * 0.9,
        ),
        prior(
          '00000000-0000-4000-8000-000000000822',
          d2,
          298,
          hrFraction: own.meanWorkHrFraction!,
          mpb: own.metresPerBeat! * 0.9,
        ),
      ];
      final v = engine
          .analyze(run, priors: priors, profile: profile, now: fixedNow)
          .verdict!;
      expect(v.hrLine, 'Same effort: $pct% max HR both runs.');
    });

    test('pace better but m/beat worse → "it cost more"', () {
      final priors = [
        prior(
          '00000000-0000-4000-8000-000000000811',
          d1,
          298,
          hrFraction: own.meanWorkHrFraction!,
          mpb: own.metresPerBeat! * 1.1,
        ),
        prior(
          '00000000-0000-4000-8000-000000000812',
          d2,
          298,
          hrFraction: own.meanWorkHrFraction!,
          mpb: own.metresPerBeat! * 1.2,
        ),
      ];
      final v = engine
          .analyze(run, priors: priors, profile: profile, now: fixedNow)
          .verdict!;
      expect(v.hrLine, 'Faster, but it cost more: $pct% max HR, was $pct%.');
    });
  });

  group('P2-4/P2-5 sidecar history and stale frozen verdicts', () {
    final run = fixture('preset_4x4_auto_standard').run;

    test('unfreezing keeps the old verdict in history; rebuild sees it', () {
      final first = engine.analyze(run, now: fixedNow);
      var sidecar = first.freezeInto(RunSidecar(runId: run.id));
      sidecar = sidecar.withLapEdit(const LapEdit.merge(3));
      expect(sidecar.frozenVerdict, isNull);
      expect(sidecar.verdictHistory.single.subline, first.verdict!.subline);
      final second = engine.analyze(run, sidecar: sidecar, now: fixedNow);
      sidecar = second.freezeInto(sidecar);
      expect(sidecar.verdictHistory.length, 1);
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(sidecar));
      expect(back.verdictHistory.single.headline, VerdictHeadline.baselineSet);
      expect(back.frozenVerdict!.headline, VerdictHeadline.noVerdict);
    });

    test('an engine bump moves the replaced verdict into history', () {
      final v = engine.analyze(run, now: fixedNow).verdict!;
      final stale = Verdict.fromJson(
        v.toJson()
          ..['engine_version'] = engineVersion - 1
          ..['subline'] = 'Words the last engine wrote.',
      );
      final sidecar = RunSidecar(runId: run.id, frozenVerdict: stale);
      final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
      final frozen = a.freezeInto(sidecar);
      expect(frozen.verdictHistory.single.engineVersion, engineVersion - 1);
      expect(frozen.frozenVerdict!.engineVersion, engineVersion);
    });

    test('an engine bump with the same headline and text adds no history '
        '(Phase 3 eng-review INFO)', () {
      final v = engine.analyze(run, now: fixedNow).verdict!;
      final stale = Verdict.fromJson(
        v.toJson()..['engine_version'] = engineVersion - 1,
      );
      final sidecar = RunSidecar(runId: run.id, frozenVerdict: stale);
      final a = engine.analyze(run, sidecar: sidecar, now: fixedNow);
      final frozen = a.freezeInto(sidecar);
      expect(frozen.verdictHistory, isEmpty);
      expect(frozen.frozenVerdict!.engineVersion, engineVersion);
    });

    test('a frozen verdict whose inputs no longer match is recomputed', () {
      final v = engine.analyze(run, now: fixedNow).verdict!;
      // A DB restore that merged a lap edit in without unfreezing.
      final tampered = RunSidecar(
        runId: run.id,
        lapEdits: const [LapEdit.merge(3)],
        frozenVerdict: v,
      );
      final a = engine.analyze(run, sidecar: tampered, now: fixedNow);
      expect(a.verdictSource, VerdictSource.computed);
      expect(a.verdict!.headline, VerdictHeadline.noVerdict);
      final overridden = RunSidecar(
        runId: run.id,
        runTypeOverride: RunMode.free,
        frozenVerdict: v,
      );
      expect(
        engine.analyze(run, sidecar: overridden, now: fixedNow).verdict,
        isNull,
      );
    });
  });

  group('P2-6/P2-7 strict run files', () {
    final run = fixture('preset_4x4_auto_standard').run;

    test('unknown keys are rejected rather than dropped', () {
      expect(
        () => RunFile.fromJson(run.toJson()..['weather'] = 'wet'),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('naive timestamps are rejected; offsets are honoured', () {
      expect(
        () => RunFile.fromJson(run.toJson()..['start'] = '2026-09-24T06:00:00'),
        throwsA(isA<RunFileFormatException>()),
      );
      final offset = RunFile.fromJson(
        run.toJson()..['start'] = '2026-09-24T16:00:00+10:00',
      );
      expect(offset.start, DateTime.utc(2026, 9, 24, 6));
    });

    test('a Kotlin-shaped file is read; the store must export stored bytes', () {
      const kotlin =
          '{"schema":1,"id":"0a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d",'
          '"device":"Pixel 8","app":"app.runsolo/1.0",'
          '"start":"2026-09-24T06:00:00.000Z","end":"2026-09-24T06:10:00.000Z",'
          '"tz":"Australia/Sydney","mode":"free","preset":null,"units":"km",'
          '"laps":[{"i":0,"t0":0,"t1":600000,"d0":0.0,"d1":1500.25,"kind":"manual"}],'
          '"pauses":[],"gaps":[],'
          '"samples":[[0,-33.86,151.21,20.0,6.0,0.0,0.0,null],'
          '[1000,-33.86,151.21004,20.0,6.0,3.5,3.5,120]]}';
      final decoded = RunFileCodec.decode(kotlin);
      expect(decoded.laps.single.d1M, 1500.25);
      expect(decoded.samples.last.hr, 120);
      // The canonical form differs in number formatting from Kotlin's, so
      // export must hand out the original bytes, not a re-encode.
      expect(RunFileCodec.encode(decoded), isNot(kotlin));
      final canonical = RunFileCodec.encode(decoded);
      expect(RunFileCodec.encode(RunFileCodec.decode(canonical)), canonical);
    });
  });

  group('P2-8/P2-9 import fidelity', () {
    final run = fixture('four_by_four_manual_clean_hr').run;

    test('own TCX export carries the uuid and re-imports with the same id', () {
      final tcx = const TcxExporter().export(run);
      expect(
        XmlDocument.parse(tcx).findAllElements('Notes').single.innerText,
        'runsolo:${run.id}',
      );
      final imported = const TcxImporter().import(tcx, tz: 'Australia/Sydney');
      expect(imported.id, run.id);
      expect(imported.tz, 'Australia/Sydney');
      expect(planImport([imported], {run.id}).toImport, isEmpty);
    });

    test('lap StartTime keeps milliseconds', () {
      final last = run.laps.last.t1Ms;
      final shifted = run.copyWith(
        laps: run.laps
            .map(
              (l) => l.copyWith(
                t0Ms: l.t0Ms == 0 ? 0 : l.t0Ms + 400,
                t1Ms: l.t1Ms == last ? l.t1Ms : l.t1Ms + 400,
              ),
            )
            .toList(),
      );
      final imported = const TcxImporter().import(
        const TcxExporter(homeTrim: false).export(shifted),
      );
      expect(imported.laps[1].t0Ms, shifted.laps[1].t0Ms);
    });

    test(
      'watch auto-laps (TriggerMethod Distance) are auto and default to free',
      () {
        final tcx = const TcxExporter(homeTrim: false)
            .export(run)
            .replaceAll(
              '<TriggerMethod>Manual</TriggerMethod>',
              '<TriggerMethod>Distance</TriggerMethod>',
            );
        final imported = const TcxImporter().import(tcx);
        expect(imported.laps.every((l) => l.kind == LapKind.auto), isTrue);
        expect(imported.mode, RunMode.free);
      },
    );

    test('naive TCX times are UTC, never device-local', () {
      final tcx = const TcxExporter(homeTrim: false)
          .export(run)
          .replaceAll('.000Z<', '<');
      expect(const TcxImporter().import(tcx).start, run.start);
    });

    test('mixed DistanceMeters falls back to haversine for the whole file', () {
      final tcx = const TcxExporter(homeTrim: false)
          .export(run)
          .replaceFirst(
            RegExp(r'<DistanceMeters>[^<]*</DistanceMeters>\s*<HeartRateBpm>'),
            '<HeartRateBpm>',
          );
      final imported = const TcxImporter().import(tcx);
      expect(imported.distanceM, closeTo(run.distanceM, run.distanceM * 0.01));
      final maxDist = imported.samples
          .map((s) => s.distM)
          .reduce((a, b) => a > b ? a : b);
      expect(maxDist, imported.distanceM);
    });
  });

  group('P2-10 trim and tolerance', () {
    test('with a 12 s GPS lag the trim is what makes the pace exact', () {
      final f = fixture('gps_lag_12s');
      final trimmed = engine.analyze(f.run, now: fixedNow).fourByFour!;
      expect(
        trimmed.avgWorkPaceSecPerKm,
        closeTo(f.expected.avgWorkPaceSecPerKm!, 0.5),
      );
      const untrimmed = RunEngine(
        constants: EngineConstants(trimStartMs: 0, trimEndMs: 0),
      );
      final raw = untrimmed.analyze(f.run, now: fixedNow).fourByFour!;
      expect(
        (raw.avgWorkPaceSecPerKm! - f.expected.avgWorkPaceSecPerKm!).abs(),
        greaterThan(3),
      );
    });

    test('jittered fixture tolerances are tighter than the run floor', () {
      final e = fixture('noisy_gps_phone_jitter').expected;
      expect(e.toleranceSecPerKm, lessThanOrEqualTo(3));
      expect(e.recoveryToleranceSecPerKm, lessThanOrEqualTo(6));
    });

    test('jitter bias holds across seeds', () {
      for (final seed in [2, 3, 4]) {
        final s = generator.generate(
          SyntheticSpec(
            name: 'jitter$seed',
            seed: seed,
            preset: Preset.standard,
            jitterSigmaM: 2,
            accuracyM: 12,
            segments: SyntheticSpecs.fourByFour(),
          ),
        );
        final m = engine.analyze(s.run, now: fixedNow).fourByFour!;
        expect(
          m.avgWorkPaceSecPerKm,
          closeTo(
            s.expected.avgWorkPaceSecPerKm!,
            s.expected.toleranceSecPerKm,
          ),
          reason: 'seed $seed',
        );
      }
    });
  });

  group('P3 rounding at the floor, per-rep priors', () {
    final d1 = DateTime.utc(2026, 9, 1);
    final d2 = DateTime.utc(2026, 9, 5);

    test('a printed delta never sits inside the printed floor', () {
      // delta 14.4 rounds to 14 = the printed run-2 floor → NO REAL CHANGE.
      final v = engine
          .analyze(
            runWithPaces([283.6, 283.6, 283.6, 283.6], start: d2),
            priors: [prior('00000000-0000-4000-8000-000000000901', d1, 298)],
            now: fixedNow,
          )
          .verdict!;
      expect(v.headline, VerdictHeadline.noRealChange);
      // delta 14.6 rounds to 15 → FASTER.
      final f = engine
          .analyze(
            runWithPaces([283.4, 283.4, 283.4, 283.4], start: d2),
            priors: [prior('00000000-0000-4000-8000-000000000902', d1, 298)],
            now: fixedNow,
          )
          .verdict!;
      expect(f.headline, VerdictHeadline.faster);
      expect(f.subline, startsWith('Work pace 15 s/km faster'));
    });

    test('PriorRun carries per-rep paces for the "vs last" column', () {
      final a = engine.analyze(
        fixture('preset_4x4_auto_standard').run,
        now: fixedNow,
      );
      expect(a.asPrior(fixedNow)!.repPacesSecPerKm.length, 4);
      final g = engine.analyze(fixture('gps_dropout_rep2').run, now: fixedNow);
      expect(g.asPrior(fixedNow), isNull);
    });
  });
}
