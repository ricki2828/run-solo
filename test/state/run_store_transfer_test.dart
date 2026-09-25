import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';

import '../run_fixtures.dart';

/// Plan §4: runs move between installs as RunBundles; uuid dedupe never
/// overwrites; sidecars (edits + frozen verdict) travel with the run.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);

  test(
    'memory store: export carries the frozen sidecar, import dedupes',
    () async {
      final r1 = fourByFourFile(n: 1, start: d1);
      final r2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 3)));
      final source = MemoryRunStore(files: [r1, r2]);
      await source.list(); // analyses + freezes verdicts
      final bundles = await source.exportBundles();
      expect(bundles.map((b) => b.run.id), containsAll([r1.id, r2.id]));
      expect(bundles.every((b) => b.sidecar?.frozenVerdict != null), isTrue);

      final text = bundles.map(engine.RunBundleCodec.encode).toList();
      final decoded = text.map(engine.RunBundleCodec.decode).toList();

      final target = MemoryRunStore(files: [r1]);
      final result = await target.importBundles(decoded);
      expect(result.imported, 1);
      expect(result.skippedIds, [r1.id]);
      final listed = await target.list();
      expect(listed.map((r) => r.id).toSet(), {r1.id, r2.id});
      // The imported sidecar's verdict is restored, not recomputed.
      final d = await target.load(r2.id);
      expect(d!.analysis.verdictSource, engine.VerdictSource.frozen);

      // A second import of the same files changes nothing.
      final again = await target.importBundles(decoded);
      expect(again.imported, 0);
      expect(again.skippedIds.length, 2);
    },
  );

  test(
    'engine bump: an engineVersion-1 frozen verdict is shown, not recomputed',
    () async {
      final r1 = fourByFourFile(n: 1, start: d1);
      final fresh = MemoryRunStore(files: [r1]);
      await fresh.list();
      final current = (await fresh.load(r1.id))!.sidecar.frozenVerdict!;
      // Pretend an older engine froze different words for the same inputs.
      final old = engine.Verdict(
        stage: current.stage,
        headline: engine.VerdictHeadline.holding,
        subline: 'Words the runner already saw.',
        floorSecPerKm: current.floorSecPerKm,
        bandSecPerKm: current.bandSecPerKm,
        engineVersion: current.engineVersion - 1,
        computedAt: current.computedAt,
        inputsKey: current.inputsKey,
      );
      final sidecar = engine.RunSidecar(runId: r1.id).withFrozenVerdict(old);
      final store = MemoryRunStore(files: [r1], sidecars: {r1.id: sidecar});
      final listed = await store.list();
      expect(listed.single.verdict!.subline, 'Words the runner already saw.');
      expect(listed.single.verdict!.engineVersion, current.engineVersion - 1);
      expect(store.written, isEmpty, reason: 'sidecar not rewritten');
      final d = await store.load(r1.id);
      expect(d!.summary.verdict!.headline, engine.VerdictHeadline.holding);
      // Fix-laps changes the inputs: the engine's fresh verdict takes over.
      final edited = await store.applyLapEdit(
        r1.id,
        const engine.LapEdit.keep(1),
      );
      expect(edited.summary.verdict!.engineVersion, current.engineVersion);
      expect(
        edited.sidecar.verdictHistory.map((v) => v.subline),
        contains('Words the runner already saw.'),
      );
    },
  );

  test(
    'file store: no index, no WAL; rebuilds from files on every open',
    () async {
      final dir = await Directory.systemTemp.createTemp('runsolo-store-');
      addTearDown(() => dir.delete(recursive: true));
      final runsDir = Directory('${dir.path}/runs');
      final r1 = fourByFourFile(n: 1, start: d1);
      final writer = FileRunStore(runsDir);
      final result = await writer.importBundles([engine.RunBundle(run: r1)]);
      expect(result.imported, 1);
      await writer.list(); // freezes the verdict into the sidecar
      final names =
          runsDir.listSync().map((e) => e.uri.pathSegments.last).toList()
            ..sort();
      expect(names, ['run-${r1.id}.edits.json', 'run-${r1.id}.json.gz']);
      expect(
        names.where((n) => n.contains('wal') || n.contains('.db')),
        isEmpty,
      );
      // A "restored" install: a fresh store over the same files, nothing else.
      final restored = FileRunStore(runsDir);
      final listed = await restored.list();
      expect(listed.single.id, r1.id);
      expect(listed.single.verdict, isNotNull);
      expect(
        (await restored.load(r1.id))!.analysis.verdictSource,
        engine.VerdictSource.frozen,
      );
    },
  );
}
