import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('run file codec', () {
    final run = fixture('four_by_four_manual_clean_hr').run;

    test('decode → encode is byte-identical', () {
      final text = RunFileCodec.encode(run);
      final again = RunFileCodec.encode(RunFileCodec.decode(text));
      expect(again, text);
    });

    test('preserves header, laps, spans and samples', () {
      final back = RunFileCodec.decode(RunFileCodec.encode(run));
      expect(back.id, run.id);
      expect(back.mode, run.mode);
      expect(back.preset, run.preset);
      expect(back.units, run.units);
      expect(back.start, run.start);
      expect(back.laps.length, run.laps.length);
      expect(back.laps.last.kind, LapKind.manual);
      expect(back.samples.length, run.samples.length);
      expect(back.samples[100].hr, run.samples[100].hr);
      expect(back.hasHr, isTrue);
    });

    test('preset round-trips', () {
      final withPreset = run.copyWith(
        preset: const Preset(reps: 5, workSeconds: 240, recoverySeconds: 150),
      );
      final back = RunFileCodec.decode(RunFileCodec.encode(withPreset));
      expect(back.preset, withPreset.preset);
    });

    test('null hr is never 0', () {
      final noHr = fixture('four_by_four_manual_clean').run;
      expect(noHr.samples.every((s) => s.hr == null), isTrue);
      final text = RunFileCodec.encode(noHr);
      expect(text, isNot(contains(',0]')));
    });

    group('rejects malformed input', () {
      Map<String, Object?> valid() =>
          jsonDecode(RunFileCodec.encode(run)) as Map<String, Object?>;

      void expectRejected(Map<String, Object?> json, String why) {
        expect(
          () => RunFile.fromJson(json),
          throwsA(isA<RunFileFormatException>()),
          reason: why,
        );
      }

      test('not JSON', () {
        expect(
          () => RunFileCodec.decode('{not json'),
          throwsA(isA<RunFileFormatException>()),
        );
        expect(
          () => RunFileCodec.decode('[1,2]'),
          throwsA(isA<RunFileFormatException>()),
        );
      });

      test(
        'wrong schema',
        () => expectRejected(valid()..['schema'] = 2, 'schema'),
      );
      test('bad uuid', () => expectRejected(valid()..['id'] = 'RUN-1', 'id'));
      test(
        'unknown mode',
        () => expectRejected(valid()..['mode'] = 'tempo', 'mode'),
      );
      test(
        'unknown units',
        () => expectRejected(valid()..['units'] = 'furlong', 'units'),
      );
      test(
        'missing samples',
        () => expectRejected(valid()..remove('samples'), 'samples'),
      );
      test(
        'bad date',
        () => expectRejected(valid()..['start'] = 'yesterday', 'start'),
      );

      test('preset out of range', () {
        expectRejected(
          valid()
            ..['preset'] = {
              'reps': 7,
              'workSeconds': 240,
              'recoverySeconds': 180,
            },
          'reps 7',
        );
        expectRejected(
          valid()
            ..['preset'] = {
              'reps': 4,
              'workSeconds': 0,
              'recoverySeconds': 180,
            },
          'work 0',
        );
      });

      test('sample with 7 fields', () {
        final j = valid();
        (j['samples'] as List)[0] = [0, null, null, null, null, null, 0];
        expectRejected(j, 'short sample');
      });

      test('sample lat without lon', () {
        final j = valid();
        (j['samples'] as List)[0] = [0, -33.8, null, null, null, null, 0, null];
        expectRejected(j, 'lat without lon');
      });

      test('hr of 0', () {
        final j = valid();
        (j['samples'] as List)[0] = [0, null, null, null, null, null, 0, 0];
        expectRejected(j, 'hr 0');
      });

      test('samples not increasing in t', () {
        final j = valid();
        final samples = j['samples'] as List;
        samples[1] = [0, null, null, null, null, null, 0, null];
        expectRejected(j, 'duplicate t');
      });

      test('distance decreasing', () {
        final j = valid();
        final samples = j['samples'] as List;
        samples[10] = [10000, null, null, null, null, null, -1, null];
        expectRejected(j, 'dist < previous');
      });

      test('lap with t1 < t0', () {
        final j = valid();
        (j['laps'] as List)[0] = {
          'i': 0,
          't0': 10,
          't1': 5,
          'd0': 0,
          'd1': 0,
          'kind': 'manual',
        };
        expectRejected(j, 'lap t1 < t0');
      });

      test('lap kind unknown', () {
        final j = valid();
        ((j['laps'] as List)[0] as Map)['kind'] = 'sprint';
        expectRejected(j, 'lap kind');
      });

      test('laps out of order', () {
        final j = valid();
        final laps = j['laps'] as List;
        final first = laps[0];
        laps[0] = laps[1];
        laps[1] = first;
        expectRejected(j, 'lap index order');
      });

      test('span not a pair', () {
        final j = valid();
        j['pauses'] = [
          [1, 2, 3],
        ];
        expectRejected(j, 'span');
      });
    });
  });

  group('sidecar codec', () {
    final verdict = engine
        .analyze(fixture('preset_4x4_auto_standard').run, now: fixedNow)
        .verdict!;
    final sidecar = RunSidecar(
      runId: '00000000-0000-4000-8000-000000000005',
      lapEdits: const [LapEdit.merge(2), LapEdit.split(3, 1234000)],
      runTypeOverride: RunMode.free,
      notes: 'windy',
      frozenVerdict: verdict,
    );

    test('round trip is byte-identical and lossless', () {
      final text = RunSidecarCodec.encode(sidecar);
      final back = RunSidecarCodec.decode(text);
      expect(RunSidecarCodec.encode(back), text);
      expect(back.lapEdits, sidecar.lapEdits);
      expect(back.runTypeOverride, RunMode.free);
      expect(back.notes, 'windy');
      final fv = back.frozenVerdict!;
      expect(fv.headline, verdict.headline);
      expect(fv.subline, verdict.subline);
      expect(fv.floorSecPerKm, 10);
      expect(fv.bandSecPerKm, 10);
      expect(fv.engineVersion, engineVersion);
      expect(fv.computedAt, fixedNow);
      expect(fv.setIds, verdict.setIds);
    });

    test('frozen verdict carries floor, band, engine_version, computed_at', () {
      final json = sidecar.toJson()['frozen_verdict'] as Map<String, Object?>;
      expect(
        json.keys,
        containsAll([
          'floor_s_per_km',
          'band_s_per_km',
          'engine_version',
          'computed_at',
          'set_ids',
          'baseline_s_per_km',
        ]),
      );
    });

    test('empty sidecar', () {
      const empty = RunSidecar(runId: '00000000-0000-4000-8000-000000000005');
      expect(empty.isEmpty, isTrue);
      expect(
        RunSidecarCodec.decode(RunSidecarCodec.encode(empty)).isEmpty,
        isTrue,
      );
    });

    test('withLapEdit and withOverride unfreeze the verdict', () {
      expect(sidecar.withLapEdit(const LapEdit.merge(0)).frozenVerdict, isNull);
      expect(sidecar.withLapEdit(const LapEdit.merge(0)).lapEdits.length, 3);
      expect(sidecar.withOverride(RunMode.fourByFour).frozenVerdict, isNull);
      expect(sidecar.withOverride(null).runTypeOverride, isNull);
    });

    test('rejects malformed input', () {
      expect(
        () => RunSidecarCodec.decode('nope'),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () =>
            RunSidecar.fromJson({'schema': 1, 'run_id': 'x', 'lap_edits': []}),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => RunSidecar.fromJson({
          'schema': 1,
          'run_id': sidecar.runId,
          'lap_edits': [
            {'op': 'drop', 'index': 1},
          ],
        }),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => RunSidecar.fromJson({
          'schema': 1,
          'run_id': sidecar.runId,
          'lap_edits': [],
          'run_type_override': 'tempo',
        }),
        throwsA(isA<RunFileFormatException>()),
      );
    });
  });
}
