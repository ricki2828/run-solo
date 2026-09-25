import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Schema 1 → 2 (plan §18.7) and the three run types (§18.2).
void main() {
  /// Rewrites a run built by this engine as the bytes a schema-1 writer
  /// produced: `schema: 1` and today's `laps` spelled `free`.
  String asSchema1(RunFile run) {
    final j = run.toJson();
    j['schema'] = 1;
    if (run.mode == RunMode.laps) j['mode'] = 'free';
    return jsonEncode(j);
  }

  group('run file schema', () {
    final fourByFour = fixture('four_by_four_manual_clean_hr').run;
    final lapsRun = fixture('laps_run_manual_clean_hr').run;

    test('this build writes schema 2', () {
      final j = jsonDecode(RunFileCodec.encode(lapsRun)) as Map;
      expect(j['schema'], 2);
      expect(j['mode'], 'laps');
    });

    test('a schema-1 free file decodes as laps and re-encodes as schema 2', () {
      final text = asSchema1(lapsRun);
      expect(text, contains('"schema":1'));
      expect(text, contains('"mode":"free"'));
      final run = RunFileCodec.decode(text);
      expect(run.mode, RunMode.laps);
      expect(run.readSchema, 1);
      expect(run.laps.length, lapsRun.laps.length);
      final again = RunFileCodec.encode(run);
      expect(again, RunFileCodec.encode(lapsRun));
      expect(RunFileCodec.decode(again).readSchema, 2);
    });

    test('a schema-1 fourByFour file is unchanged by the bump', () {
      final run = RunFileCodec.decode(asSchema1(fourByFour));
      expect(run.mode, RunMode.fourByFour);
      expect(run.preset, fourByFour.preset);
      expect(RunFileCodec.encode(run), RunFileCodec.encode(fourByFour));
    });

    test('schema 2 spells every mode literally, including cooper', () {
      for (final m in RunMode.values) {
        final j = lapsRun.toJson()..['mode'] = m.name;
        if (m != RunMode.fourByFour) j['preset'] = null;
        expect(RunFile.fromJson(j).mode, m, reason: m.name);
      }
      // `free` under schema 2 is the new lap-less mode, not laps.
      expect(
        RunFile.fromJson(lapsRun.toJson()..['mode'] = 'free').mode,
        RunMode.free,
      );
    });

    test('schema 3 is newer, schema 0 and an unknown mode are malformed', () {
      expect(
        () => RunFile.fromJson(lapsRun.toJson()..['schema'] = 3),
        throwsA(isA<RunFileNewerVersionException>()),
      );
      expect(
        () => RunFile.fromJson(lapsRun.toJson()..['schema'] = 0),
        throwsA(
          isA<RunFileFormatException>().having(
            (e) => e,
            'not newer',
            isNot(isA<RunFileNewerVersionException>()),
          ),
        ),
      );
      expect(
        () => RunFile.fromJson(lapsRun.toJson()..['mode'] = 'tempo'),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('RunMode.decode maps free → laps only under schema 1', () {
      expect(RunMode.decode('free', schema: 1), RunMode.laps);
      expect(RunMode.decode('free', schema: 2), RunMode.free);
      expect(RunMode.decode('laps', schema: 2), RunMode.laps);
      expect(RunMode.decode('cooper', schema: 2), RunMode.cooper);
      // No v1 writer emitted these: under schema 1 they are corruption.
      for (final bad in ['laps', 'cooper', 'tempo']) {
        expect(
          () => RunMode.decode(bad, schema: 1),
          throwsA(isA<RunFileFormatException>()),
          reason: bad,
        );
      }
      expect(RunMode.fourByFour.lapCapable, isTrue);
      expect(RunMode.laps.lapCapable, isTrue);
      expect(RunMode.free.lapCapable, isFalse);
      expect(RunMode.cooper.lapCapable, isFalse);
    });
  });

  group('sidecar schema', () {
    const id = '00000000-0000-4000-8000-000000000035';

    test('this build writes schema 2 with null weather/cooper', () {
      final j = jsonDecode(
        RunSidecarCodec.encode(const RunSidecar(runId: id)),
      ) as Map;
      expect(j['schema'], 2);
      expect(j.containsKey('weather'), isTrue);
      expect(j['weather'], isNull);
      expect(j['cooper'], isNull);
    });

    test('a v1 override "free" reads as laps; v1 re-encodes as v2', () {
      final v1 = jsonEncode({
        'schema': 1,
        'run_id': id,
        'lap_edits': [],
        'run_type_override': 'free',
        'notes': null,
        'frozen_verdict': null,
        'verdict_history': [],
      });
      final s = RunSidecarCodec.decode(v1);
      expect(s.readSchema, 1);
      expect(s.runTypeOverride, RunMode.laps);
      expect(s.weather, isNull);
      final v2 = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(v2.readSchema, 2);
      expect(v2.runTypeOverride, RunMode.laps);
    });

    test('a v2 override "free" stays free', () {
      final s = RunSidecarCodec.decode(
        RunSidecarCodec.encode(
          const RunSidecar(runId: id, runTypeOverride: RunMode.free),
        ),
      );
      expect(s.runTypeOverride, RunMode.free);
    });

    test('weather and cooper objects survive decode → encode untouched', () {
      final text = jsonEncode({
        'schema': 2,
        'run_id': id,
        'lap_edits': [],
        'run_type_override': null,
        'notes': null,
        'frozen_verdict': null,
        'verdict_history': [],
        'weather': {
          'status': 'ok',
          'temp_c': 28.5,
          'rh': 70,
          'nested': {'k': 'v'},
        },
        'cooper': {'distance_m': 2800, 'vo2_raw': 51.31},
      });
      final s = RunSidecarCodec.decode(text);
      expect(s.weather!['temp_c'], 28.5);
      expect(s.cooper!['distance_m'], 2800);
      expect(s.isEmpty, isFalse);
      expect(RunSidecarCodec.encode(s), text);
      // A fix-laps edit rewrites the sidecar without dropping them.
      final edited = s.withLapEdit(const LapEdit.merge(0));
      expect(edited.weather, s.weather);
      expect(edited.cooper, s.cooper);
    });

    test(
      'schema 3 is newer (read-only), 0 or a non-object weather malformed',
      () {
        Map<String, Object?> base() => {
          'schema': 2,
          'run_id': id,
          'lap_edits': <Object?>[],
          'run_type_override': null,
          'notes': null,
          'frozen_verdict': null,
          'verdict_history': <Object?>[],
        };
        expect(
          () => RunSidecar.fromJson(base()..['schema'] = 3),
          throwsA(isA<RunFileNewerVersionException>()),
        );
        expect(
          () => RunSidecar.fromJson(base()..['schema'] = 0),
          throwsA(
            isA<RunFileFormatException>().having(
              (e) => e,
              'not newer',
              isNot(isA<RunFileNewerVersionException>()),
            ),
          ),
        );
        expect(
          () => RunSidecar.fromJson(base()..['weather'] = 'sunny'),
          throwsA(isA<RunFileFormatException>()),
        );
      },
    );
  });

  group('run types (§18.2): one trace, three modes', () {
    final asFourByFour = fixture('four_by_four_manual_clean_hr');
    final asLaps = fixture('laps_run_manual_clean_hr');
    final asFree = asLaps.run.copyWith(mode: RunMode.free, laps: const []);

    test('the two fixtures share the trace', () {
      expect(asLaps.run.samples.length, asFourByFour.run.samples.length);
      expect(asLaps.run.distanceM, closeTo(asFourByFour.run.distanceM, 0.01));
      expect(asLaps.run.laps.length, asFourByFour.run.laps.length);
      expect(asLaps.run.preset, isNull);
    });

    test('4x4: verdict, per-rep metrics, no lap table', () {
      final a = engine.analyze(
        asFourByFour.run,
        profile: profile,
        now: fixedNow,
      );
      expect(a.mode, RunMode.fourByFour);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(a.fourByFour!.reps.length, 4);
      expect(a.laps, isNull);
    });

    test('Laps: lap table, fastest, spread vs band, HR band; no verdict', () {
      final a = engine.analyze(asLaps.run, profile: profile, now: fixedNow);
      expect(a.mode, RunMode.laps);
      expect(a.verdict, isNull);
      expect(a.verdictSource, isNull);
      expect(a.fourByFour, isNull);
      expect(a.detection, isNull);
      final l = a.laps!;
      // warm-up + 4 × (work, recovery) + cool-down, all manual presses.
      expect(l.laps.length, 10);
      expect(
        l.laps.map((r) => r.number).toList(),
        List.generate(10, (i) => i + 1),
      );
      expect(l.laps.every((r) => r.scored), isTrue);
      // Independent check: pace = lap moving time ÷ lap distance from the
      // samples, no trimming, no pauses in this trace.
      final t = Trace(asLaps.run.samples);
      for (final r in l.laps) {
        final d = t.distAt(r.lap.t1Ms) - t.distAt(r.lap.t0Ms);
        expect(r.distanceM, closeTo(d, 0.01));
        expect(r.movingSeconds, closeTo(r.lap.durationMs / 1000, 0.001));
        expect(r.paceSecPerKm, closeTo(r.lap.durationMs / d, 0.01));
        expect(r.meanHr, isNotNull);
      }
      // Work laps are 2, 4, 6, 8; the first is the fastest (282 s/km true
      // speed, lag makes untrimmed paces slightly slower but ordered).
      expect(l.fastestLapNumber, 2);
      final paces = l.laps.map((r) => r.paceSecPerKm!).toList();
      final expectedSpread =
          paces.reduce((a, b) => a > b ? a : b) -
          paces.reduce((a, b) => a < b ? a : b);
      expect(l.spreadSecPerKm, closeTo(expectedSpread, 0.01));
      expect(l.spreadWithinBand, isFalse, reason: 'work vs recovery laps');
      expect(l.bandSecPerKm, 10);
      expect(l.hrPresent, isTrue);
      expect(l.maxHrUsed, 180, reason: 'age 40, nothing typed → 220−40');
      expect(l.avgHr, closeTo(a.freeRun.avgHr!, 0.001));
      expect(l.maxHr, t.peakHr(t.startMs, t.endMs + 1));
      expect(l.timeInBandSeconds, greaterThan(0));
      expect(l.observedMaxHrThisRun, closeTo(t.highest30sHr()!, 0.001));
      // Summary still present for the header.
      expect(a.freeRun.distanceM, closeTo(asLaps.run.distanceM, 0.01));
    });

    test('Laps → 4x4 override reproduces the by-feel verdict exactly', () {
      final direct = engine.analyze(
        asFourByFour.run,
        profile: profile,
        now: fixedNow,
      );
      final overridden = engine.analyze(
        asLaps.run,
        sidecar: RunSidecar(runId: asLaps.run.id)
            .withOverride(RunMode.fourByFour),
        profile: profile,
        now: fixedNow,
      );
      expect(overridden.mode, RunMode.fourByFour);
      expect(overridden.laps, isNull);
      expect(overridden.verdict!.headline, direct.verdict!.headline);
      expect(overridden.verdict!.subline, direct.verdict!.subline);
      expect(overridden.verdict!.hrLine, direct.verdict!.hrLine);
      expect(
        overridden.fourByFour!.avgWorkPaceSecPerKm,
        closeTo(direct.fourByFour!.avgWorkPaceSecPerKm!, 1e-9),
      );
      expect(overridden.eligibleAsPrior, isTrue);
    });

    test('4x4 → Laps override gives the lap table and drops the verdict', () {
      final a = engine.analyze(
        asFourByFour.run,
        sidecar: RunSidecar(runId: asFourByFour.run.id)
            .withOverride(RunMode.laps),
        profile: profile,
        now: fixedNow,
      );
      expect(a.mode, RunMode.laps);
      expect(a.verdict, isNull);
      expect(a.laps!.laps.length, 10);
      expect(a.eligibleAsPrior, isFalse);
      expect(a.asPrior(fixedNow), isNull);
    });

    test('Free: summary only, no laps, no verdict', () {
      final a = engine.analyze(asFree, profile: profile, now: fixedNow);
      expect(a.mode, RunMode.free);
      expect(a.verdict, isNull);
      expect(a.laps, isNull);
      expect(a.fourByFour, isNull);
      expect(a.freeRun.splitsSecPerUnit, isNotEmpty);
      expect(a.freeRun.avgHr, isNotNull);
    });

    test('cooper (reserved): summary only in Phase 2, never a 4x4', () {
      final a = engine.analyze(
        asLaps.run.copyWith(mode: RunMode.cooper),
        profile: profile,
        now: fixedNow,
      );
      expect(a.mode, RunMode.cooper);
      expect(a.verdict, isNull);
      expect(a.laps, isNull);
      expect(a.fourByFour, isNull);
      expect(a.eligibleAsPrior, isFalse);
    });

    test('Laps: pause laps dropped, short tail listed but not scored', () {
      final run = asLaps.run;
      final last = run.laps.last;
      final tail = Lap(
        index: run.laps.length,
        t0Ms: last.t1Ms,
        t1Ms: last.t1Ms + 4000,
        d0M: last.d1M,
        d1M: last.d1M + 10,
        kind: LapKind.manual,
      );
      final pauseLap = Lap(
        index: 0,
        t0Ms: 0,
        t1Ms: 0,
        d0M: 0,
        d1M: 0,
        kind: LapKind.pause,
      );
      final laps = [
        pauseLap,
        ...run.laps.map((l) => l.copyWith(index: l.index + 1)),
        tail.copyWith(index: run.laps.length + 1),
      ];
      final a = engine.analyze(
        run.copyWith(laps: laps),
        profile: profile,
        now: fixedNow,
      );
      final l = a.laps!;
      expect(l.laps.length, 11);
      expect(l.laps.last.scored, isFalse);
      expect(l.scoredLapCount, 10);
      expect(l.fastestLapNumber, 2, reason: 'the tail never wins');
    });
  });

  group('frozen verdicts survive the schema bump (rebuild keeps history)', () {
    test('v1 free file + v1 sidecar (override 4x4, frozen) → frozen', () {
      final lapsRun = fixture('laps_run_manual_clean_hr').run;
      // Before the bump: the app read the v1 file, analysed it with the
      // dogfood override to 4x4 and froze the verdict into a v1 sidecar.
      final v1Run = RunFileCodec.decode(asSchema1(lapsRun));
      final sidecar0 = RunSidecar(runId: v1Run.id)
          .withOverride(RunMode.fourByFour);
      final first = engine.analyze(
        v1Run,
        sidecar: sidecar0,
        profile: profile,
        now: fixedNow,
      );
      expect(first.verdictSource, VerdictSource.computed);
      final frozenSidecar = first.freezeInto(sidecar0);
      final v1SidecarText = jsonEncode(frozenSidecar.toJson()..['schema'] = 1);
      // After the bump: rebuild-from-files re-reads both and must restore,
      // not recompute.
      final run2 = RunFileCodec.decode(asSchema1(lapsRun));
      final sidecar2 = RunSidecarCodec.decode(v1SidecarText);
      expect(sidecar2.readSchema, 1);
      final second = engine.analyze(
        run2,
        sidecar: sidecar2,
        profile: profile,
        now: fixedNow.add(const Duration(days: 30)),
      );
      expect(second.verdictSource, VerdictSource.frozen);
      expect(second.verdict!.computedAt, first.verdict!.computedAt);
      expect(second.verdict!.subline, first.verdict!.subline);
    });
  });

  group('importers emit the schema-2 modes (§18.7)', () {
    RunFile tcxWithLaps(int lapCount) {
      final run = fixture('four_by_four_manual_clean').run;
      final laps = run.laps.take(lapCount).toList();
      return run.copyWith(laps: laps);
    }

    test('TCX: 0 laps → free, any laps → laps, never 4x4 by count (P2-1)', () {
      const exp = TcxExporter(homeTrim: false);
      const imp = TcxImporter();
      // The exporter writes one auto lap when a run has none, so build a
      // file with explicit lap counts through the exporter's lap loop.
      // A Garmin auto-km easy run has many <Lap>s and must not enter the
      // 4x4 trend; the 4x4 flip is a sidecar override.
      expect(imp.import(exp.export(tcxWithLaps(10))).mode, RunMode.laps);
      expect(imp.import(exp.export(tcxWithLaps(3))).mode, RunMode.laps);
      expect(
        imp.import(exp.export(tcxWithLaps(3)), mode: RunMode.fourByFour).mode,
        RunMode.fourByFour,
      );
      expect(imp.import(exp.export(tcxWithLaps(2))).mode, RunMode.laps);
      expect(imp.import(exp.export(tcxWithLaps(1))).mode, RunMode.laps);
      expect(
        imp.import(exp.export(tcxWithLaps(0))).mode,
        RunMode.free,
        reason: 'no <Lap> boundaries → free',
      );
    });
  });
}
