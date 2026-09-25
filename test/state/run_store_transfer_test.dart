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
}
