import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Plan §4 W1: import is the inverse of export. The dogfood → Play path:
/// `.debug` files (schema 1, `free` with manual laps + an override sidecar)
/// import into the Play build, dedupe by uuid and keep their frozen verdict.
void main() {
  final fourByFour = fixture('four_by_four_manual_clean_hr').run;
  final lapsRun = fixture('laps_run_manual_clean_hr').run;

  String asSchema1(RunFile run) {
    final j = run.toJson();
    j['schema'] = 1;
    if (run.mode == RunMode.laps) j['mode'] = 'free';
    return jsonEncode(j);
  }

  group('bundle codec', () {
    test('encode → decode is byte-identical, sidecar included', () {
      final sidecar = RunSidecar(
        runId: fourByFour.id,
        notes: 'windy',
      ).withLapEdit(const LapEdit.keep(1));
      final bundle = RunBundle(run: fourByFour, sidecar: sidecar);
      final text = RunBundleCodec.encode(bundle);
      final j = jsonDecode(text) as Map<String, Object?>;
      expect(j['kind'], RunBundleCodec.kind);
      expect(j['schema'], 2);
      final back = RunBundleCodec.decode(text);
      expect(RunBundleCodec.encode(back), text);
      expect(back.sidecar!.notes, 'windy');
      expect(back.sidecar!.lapEdits, [const LapEdit.keep(1)]);
    });

    test('a run without a sidecar exports with sidecar null', () {
      final text = RunBundleCodec.encode(RunBundle(run: lapsRun));
      expect((jsonDecode(text) as Map)['sidecar'], isNull);
      expect(RunBundleCodec.decode(text).sidecar, isNull);
    });

    test('a bare schema-1 dogfood run file imports and reads as laps', () {
      final b = RunBundleCodec.decode(asSchema1(lapsRun));
      expect(b.run.mode, RunMode.laps);
      expect(b.run.readSchema, 1);
      expect(b.sidecar, isNull);
      expect(b.id, lapsRun.id);
    });

    test('a bare schema-2 run file imports', () {
      final b = RunBundleCodec.decode(RunFileCodec.encode(fourByFour));
      expect(b.run.mode, RunMode.fourByFour);
      expect(RunFileCodec.encode(b.run), RunFileCodec.encode(fourByFour));
    });

    test('sidecar run_id must match the run', () {
      final wrong = RunSidecar(runId: lapsRun.id);
      expect(
        () => RunBundle(run: fourByFour, sidecar: wrong),
        throwsA(isA<RunFileFormatException>()),
      );
      final text = jsonEncode({
        'kind': RunBundleCodec.kind,
        'schema': 2,
        'run': fourByFour.toJson(),
        'sidecar': wrong.toJson(),
      });
      expect(
        () => RunBundleCodec.decode(text),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('newer export, run or sidecar is reported as newer', () {
      final base = {
        'kind': RunBundleCodec.kind,
        'schema': 2,
        'run': fourByFour.toJson(),
        'sidecar': null,
      };
      expect(
        () => RunBundleCodec.decode(jsonEncode({...base, 'schema': 3})),
        throwsA(isA<RunFileNewerVersionException>()),
      );
      expect(
        () => RunBundleCodec.decode(
          jsonEncode({...base, 'run': fourByFour.toJson()..['schema'] = 3}),
        ),
        throwsA(isA<RunFileNewerVersionException>()),
      );
      expect(
        () => RunBundleCodec.decode(
          jsonEncode({
            ...base,
            'sidecar': RunSidecar(runId: fourByFour.id).toJson()
              ..['schema'] = 3,
          }),
        ),
        throwsA(isA<RunFileNewerVersionException>()),
      );
    });

    test('malformed input is rejected, never a crash', () {
      for (final text in [
        '',
        'nope',
        '[]',
        '{}',
        '{"kind":"other"}',
        '{"kind":"runsolo-export","run":{},"sidecar":null}',
        '{"kind":"runsolo-export","schema":"2","run":{},"sidecar":null}',
        '{"kind":"runsolo-export","schema":2,"run":5}',
        '{"kind":"runsolo-export","schema":2,"run":{},"sidecar":"x"}',
        '{"samples":[]}',
      ]) {
        expect(
          () => RunBundleCodec.decode(text),
          throwsA(isA<RunFileFormatException>()),
          reason: text,
        );
      }
    });
  });

  group('dogfood → Play import keeps the frozen verdict', () {
    test('v1 free file + v1 override sidecar: frozen verdict restores', () {
      // On the .debug build: a by-feel 4x4 recorded as v1 `free` with manual
      // laps, overridden to 4x4 and frozen.
      final v1Run = RunFileCodec.decode(asSchema1(lapsRun));
      final sidecar0 = RunSidecar(runId: v1Run.id)
          .withOverride(RunMode.fourByFour);
      final first = engine.analyze(
        v1Run,
        sidecar: sidecar0,
        profile: profile,
        now: fixedNow,
      );
      final frozen = first.freezeInto(sidecar0);
      // Exported from the .debug build (this engine, schema 2) …
      final text = RunBundleCodec.encode(
        RunBundle(run: v1Run, sidecar: frozen),
      );
      // … imported into the Play build.
      final plan = planBundleImport([RunBundleCodec.decode(text)], const {});
      expect(plan.toImport.length, 1);
      final imported = plan.toImport.single;
      expect(imported.run.mode, RunMode.laps);
      final again = engine.analyze(
        imported.run,
        sidecar: imported.sidecar,
        profile: profile,
        now: fixedNow.add(const Duration(days: 7)),
      );
      expect(again.verdictSource, VerdictSource.frozen);
      expect(again.verdict!.computedAt, first.verdict!.computedAt);
      expect(again.verdict!.subline, first.verdict!.subline);
      expect(again.mode, RunMode.fourByFour);
    });
  });

  group('uuid dedupe on bundles', () {
    test(
      'skips existing ids and repeats within the batch; never overwrites',
      () {
        final a = RunBundle(run: fourByFour);
        final b = RunBundle(
          run: lapsRun,
          sidecar: RunSidecar(runId: lapsRun.id, notes: 'incoming'),
        );
        final plan = planBundleImport([a, b, a], {b.id});
        expect(plan.toImport.map((x) => x.id), [a.id]);
        expect(plan.alreadyOnDeviceIds, [b.id]);
        expect(plan.duplicateIds, [a.id]);
        expect(plan.skippedIds, [b.id, a.id]);
      },
    );

    test('within a batch the copy with a sidecar wins over a bare file, in '
        'either order (P2-2)', () {
      final bare = RunBundle(run: fourByFour);
      final withSidecar = RunBundle(
        run: fourByFour,
        sidecar: RunSidecar(
          runId: fourByFour.id,
          notes: 'keep me',
        ).withOverride(RunMode.laps),
      );
      for (final batch in [
        [bare, withSidecar],
        [withSidecar, bare],
      ]) {
        final plan = planBundleImport(batch, const {});
        expect(plan.toImport.length, 1);
        expect(plan.toImport.single.sidecar?.notes, 'keep me');
        expect(plan.duplicateIds, [fourByFour.id]);
        expect(plan.alreadyOnDeviceIds, isEmpty);
      }
      // Two sidecar copies: first wins (never merged).
      final other = RunBundle(
        run: fourByFour,
        sidecar: RunSidecar(runId: fourByFour.id, notes: 'second'),
      );
      expect(
        planBundleImport([
          withSidecar,
          other,
        ], const {}).toImport.single.sidecar!.notes,
        'keep me',
      );
      // First-seen order is kept even when a later copy wins.
      final plan = planBundleImport([
        bare,
        RunBundle(run: lapsRun),
        withSidecar,
      ], const {});
      expect(plan.toImport.map((x) => x.id), [fourByFour.id, lapsRun.id]);
      expect(plan.toImport.first.sidecar, isNotNull);
    });

    test('importing the same export twice is a no-op the second time', () {
      final text = RunBundleCodec.encode(RunBundle(run: fourByFour));
      final first = planBundleImport([RunBundleCodec.decode(text)], const {});
      expect(first.toImport.length, 1);
      final second = planBundleImport(
        [RunBundleCodec.decode(text)],
        {first.toImport.single.id},
      );
      expect(second.toImport, isEmpty);
      expect(second.alreadyOnDeviceIds, [fourByFour.id]);
      expect(second.duplicateIds, isEmpty);
    });

    test('a bare v1 file and its v2 re-export share the uuid', () {
      final v1 = RunBundleCodec.decode(asSchema1(lapsRun));
      final v2 = RunBundleCodec.decode(
        RunBundleCodec.encode(RunBundle(run: lapsRun)),
      );
      final plan = planBundleImport([v1, v2], const {});
      expect(plan.toImport.length, 1);
      expect(plan.duplicateIds, [lapsRun.id]);
    });
  });
}
