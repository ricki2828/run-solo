import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/trail_ghost.dart';

import '../run_fixtures.dart';

/// The in-run ghost, app side: the trails a Start hands to the recorder are
/// built from the index (grouping) and two run files per trail (profiles),
/// and the engine's tracker, fed a later run, matches them.
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);
  late Directory dir;
  late Directory runsDir;
  final stores = <FileRunStore>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-ghost-');
    runsDir = Directory('${dir.path}/runs');
  });
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  Future<FileRunStore> storeWith(List<engine.RunFile> runs) async {
    final store = FileRunStore(runsDir);
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    await store.importBundles([for (final r in runs) engine.RunBundle(run: r)]);
    await store.list();
    await store.derivedIdle;
    return store;
  }

  List<engine.GhostTrail> trailsOf(FileRunStore s) => TrailGhostSource.buildAt(
    s.indexFile.path,
    [runsDir.path, s.archiveDir.path],
  );

  final runs = [
    trailLoopRun(n: 1, start: d1, secPerKm: 420),
    trailLoopRun(n: 2, start: d1.add(const Duration(days: 2)), secPerKm: 380),
    trailLoopRun(n: 3, start: d1.add(const Duration(days: 4)), secPerKm: 400),
    // A different trail (about 1.1 km north), run once.
    trailLoopRun(
      n: 4,
      start: d1.add(const Duration(days: 5)),
      secPerKm: 390,
      dLat: 0.01,
    ),
  ];

  test('each known trail is one entry with its best and last run', () async {
    final store = await storeWith(runs);
    final trails = trailsOf(store);
    expect(trails, hasLength(2));
    // Most recently run first: the northern trail (run 4), then the loop.
    expect(trails.first.best.runId, runs[3].id);
    final loop = trails.last;
    expect(loop.best.runId, runs[1].id); // the 380 s/km run
    expect(loop.last!.runId, runs[2].id); // the latest
    final n = loop.latLon.length ~/ 2;
    expect(n, inInclusiveRange(2, engine.GhostTrail.maxPoints));
    expect(loop.best.ms.length, n);
    expect(loop.last!.ms.length, n);
    // The best run's time at the far end of the trail is its moving time.
    final bestEnd = loop.best.ms.lastWhere((v) => v >= 0);
    expect(bestEnd / 1000, closeTo(runs[1].distanceM / 1000 * 380, 120));
  });

  test(
    'a later run on the trail is matched and compared, another is not',
    () async {
      final store = await storeWith(runs);
      final loop = trailsOf(store).last;
      // 360 s/km: faster than the best (380) over about 6 km.
      final again = trailLoopRun(
        n: 5,
        start: d1.add(const Duration(days: 8)),
        secPerKm: 360,
        noiseM: 5,
      );
      final g = engine.TrailGhostTracker([loop]);
      for (final s in again.samples) {
        if (s.lat == null) continue;
        g.offer(s.tMs, s.lat!, s.lon!, 5, s.tMs, s.distM);
      }
      final st = g.state!;
      expect(st.trailId, loop.id);
      expect(st.off, isFalse);
      final ahead = st.aheadBestMs!;
      expect(ahead, greaterThan(60000));
      expect(st.aheadLastMs!, greaterThan(ahead));

      final elsewhere = trailLoopRun(
        n: 6,
        start: d1.add(const Duration(days: 9)),
        dLat: 0.05,
      );
      final g2 = engine.TrailGhostTracker([loop]);
      for (final s in elsewhere.samples) {
        if (s.lat == null) continue;
        g2.offer(s.tMs, s.lat!, s.lon!, 5, s.tMs, s.distM);
      }
      expect(g2.state, isNull);
    },
  );

  test('the context carries the trails for Free and Trail runs only', () async {
    final store = await storeWith(runs);
    final src = LiveContextSource(
      indexFile: store.indexFile,
      trailGhosts: TrailGhostSource(
        indexFile: store.indexFile,
        runDirs: [runsDir, store.archiveDir],
      ),
    );
    await src.prepare();
    // The ghost's own prepare is not awaited by prepare(); let it land.
    await src.trailGhosts!.prepare();
    final ctx = src.trailsOnly(RecordMode.trail)!;
    expect(ctx.boards, isEmpty);
    expect(ctx.trails, hasLength(2));
    expect(ctx.trails!.first.best.ms, isNotEmpty);
    expect(src.trailsOnly(RecordMode.free), isNotNull);
    expect(src.trailsOnly(RecordMode.intervals), isNull);
    expect(src.trailsOnly(RecordMode.cooper), isNull);
  });

  test('no trail runs gives no trails and no context', () async {
    final store = await storeWith([
      freeRunFile(n: 1, start: d1, seconds: 1800),
    ]);
    expect(trailsOf(store), isEmpty);
    final src = LiveContextSource(
      indexFile: store.indexFile,
      trailGhosts: TrailGhostSource(
        indexFile: store.indexFile,
        runDirs: [runsDir, store.archiveDir],
      ),
    );
    await src.trailGhosts!.prepare();
    expect(src.trailsOnly(RecordMode.trail), isNull);
  });
}
