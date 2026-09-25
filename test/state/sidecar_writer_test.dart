import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/sidecar_writer.dart';

import '../run_fixtures.dart';

/// Phase 3 eng-review BLOCK-1: every sidecar write is a serialised
/// read-modify-write per run id; nothing a user edits is ever lost to a
/// concurrent `list()`.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-sidecar-');
  });
  tearDown(() => dir.delete(recursive: true));

  group('SidecarWriter', () {
    test('two concurrent transforms on one id both land', () async {
      final w = SidecarWriter();
      final f = File('${dir.path}/run-a.edits.json');
      final gate = Completer<void>();
      var reads = 0;
      w.afterRead = (_) async {
        // Hold the first writer after its read, as a slow list() would.
        if (reads++ == 0) await gate.future;
      };
      final first = w.update('a', f, (s) => s.copyWith(notes: 'first'));
      final second = w.update(
        'a',
        f,
        (s) => s.withLapEdit(const engine.LapEdit.merge(1)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await Future.wait([first, second]);
      final onDisk = (await SidecarWriter.read(f))!;
      expect(onDisk.notes, 'first');
      expect(onDisk.lapEdits.single.index, 1);
    });

    test('different ids do not wait for each other', () async {
      final w = SidecarWriter();
      final gate = Completer<void>();
      w.afterRead = (id) async {
        if (id == 'a') await gate.future;
      };
      final a = w.update(
        'a',
        File('${dir.path}/a.edits.json'),
        (s) => s.copyWith(notes: 'a'),
      );
      final b = await w.update(
        'b',
        File('${dir.path}/b.edits.json'),
        (s) => s.copyWith(notes: 'b'),
      );
      expect(b.notes, 'b');
      gate.complete();
      expect((await a).notes, 'a');
    });

    test('a throwing transform writes nothing and does not block the '
        'queue', () async {
      final w = SidecarWriter();
      final f = File('${dir.path}/run-a.edits.json');
      await w.update('a', f, (s) => s.copyWith(notes: 'kept'));
      await expectLater(
        w.update('a', f, (_) => throw StateError('refused')),
        throwsStateError,
      );
      final after = await w.update('a', f, (s) => s.copyWith(notes: 'next'));
      expect(after.notes, 'next');
      expect(
        dir.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
        reason: 'no tmp file left behind',
      );
    });

    test('no write when the content is unchanged', () async {
      final w = SidecarWriter();
      final f = File('${dir.path}/run-a.edits.json');
      await w.update('a', f, (s) => s.copyWith(notes: 'x'));
      final before = f.statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await w.update('a', f, (s) => s.copyWith(notes: 'x'));
      await w.update('a', f, (s) => s);
      expect(f.statSync().modified, before);
    });

    test(
      'a missing sidecar with an identity transform is not created',
      () async {
        final w = SidecarWriter();
        final f = File('${dir.path}/run-a.edits.json');
        await w.update('a', f, (s) => s);
        expect(f.existsSync(), isFalse);
      },
    );

    test('a newer-schema sidecar is never rewritten (W6)', () async {
      final w = SidecarWriter();
      final f = File('${dir.path}/run-a.edits.json')
        ..writeAsStringSync('{"schema": 99, "run_id": "a"}');
      await expectLater(
        w.update('a', f, (s) => s.copyWith(notes: 'x')),
        throwsA(isA<engine.RunFileNewerVersionException>()),
      );
      expect(f.readAsStringSync(), '{"schema": 99, "run_id": "a"}');
    });
  });

  group('FileRunStore through the writer', () {
    test('list() racing a fix-laps edit on the same run keeps both: the '
        'edit and a verdict computed from it', () async {
      final synthetic = fourByFourSynthetic(n: 1, start: d1, missedPress: true);
      final r = synthetic.run;
      final runsDir = Directory('${dir.path}/runs');
      final store = FileRunStore(runsDir);
      await store.importBundles([engine.RunBundle(run: r)]);
      final edits = synthetic.expected.rescueEdits;
      expect(edits, isNotEmpty);

      // list() scans the run with no edits and analyses it; before it can
      // freeze that (no-edit) verdict, the user's edits land in full.
      var raced = false;
      store.afterAnalyse = () async {
        if (raced) return;
        raced = true;
        for (final e in edits) {
          await store.applyLapEdit(r.id, e);
        }
      };
      await store.list();
      store.afterAnalyse = null;

      final sidecar = (await SidecarWriter.read(
        File('${runsDir.path}/run-${r.id}.edits.json'),
      ))!;
      expect(sidecar.lapEdits.length, edits.length, reason: 'edit kept');
      final frozen = sidecar.frozenVerdict!;
      expect(
        frozen.inputsKey,
        engine.Verdict.inputsKeyFor(sidecar.lapEdits, sidecar.runTypeOverride),
        reason: 'the stale no-edit verdict was not frozen over the edit',
      );
      expect(frozen.headline, engine.VerdictHeadline.baselineSet);
      final d = await store.load(r.id);
      expect(d!.analysis.verdictSource, engine.VerdictSource.frozen);
    });

    test('list() writes nothing once every verdict is frozen', () async {
      final r = fourByFourFile(n: 1, start: d1);
      final runsDir = Directory('${dir.path}/runs');
      final store = FileRunStore(runsDir);
      await store.importBundles([engine.RunBundle(run: r)]);
      await store.list();
      final f = File('${runsDir.path}/run-${r.id}.edits.json');
      final before = f.readAsStringSync();
      final stamp = f.statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await store.list();
      await store.list();
      expect(f.readAsStringSync(), before);
      expect(f.statSync().modified, stamp);
    });
  });

  test('an engine bump with the same text adds no history line', () {
    final v = engine.Verdict(
      stage: engine.VerdictStage.baseline,
      headline: engine.VerdictHeadline.baselineSet,
      subline: 'Same words.',
      floorSecPerKm: 10,
      bandSecPerKm: 10,
      engineVersion: 1,
      computedAt: d1,
    );
    final bumped = engine.Verdict(
      stage: v.stage,
      headline: v.headline,
      subline: v.subline,
      floorSecPerKm: 10,
      bandSecPerKm: 10,
      engineVersion: 2,
      computedAt: d1,
    );
    final s = engine.RunSidecar(runId: 'a')
        .withFrozenVerdict(v)
        .withFrozenVerdict(bumped);
    expect(s.frozenVerdict!.engineVersion, 2);
    expect(s.verdictHistory, isEmpty);
  });
}
