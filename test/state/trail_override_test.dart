import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/trail_facts.dart';
import 'package:run_solo/state/trail_ghost.dart';
import 'package:run_solo/state/trails.dart';

import '../run_fixtures.dart';

/// The runner's split / merge of a trail, end to end on the file store: the
/// call is kept in the run's sidecar (so it survives an index re-derive) and
/// every reader of the grouping honours it: boards, verdict, the in-run ghost
/// and the companion trail block.
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);
  late Directory dir;
  late Directory runsDir;
  final stores = <FileRunStore>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-override-');
    runsDir = Directory('${dir.path}/runs');
  });
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  FileRunStore open() {
    final store = FileRunStore(runsDir);
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    return store;
  }

  Future<FileRunStore> storeWith(List<engine.RunFile> runs) async {
    final store = open();
    await store.importBundles([for (final r in runs) engine.RunBundle(run: r)]);
    await store.list();
    await store.derivedIdle;
    return store;
  }

  List<engine.GhostTrail> ghostOf(FileRunStore s) => TrailGhostSource.buildAt(
    s.indexFile.path,
    [runsDir.path, s.archiveDir.path],
  );

  // A null `last` means the last run is the best (see GhostTrail.last).
  String lastIdOf(engine.GhostTrail t) => t.last?.runId ?? t.best.runId;

  Future<List<List<String>>> groupsOf(FileRunStore s) async => [
    for (final g in engine.Trails.group(trailFactsOfAll(await s.list())))
      [for (final r in g.runs) r.id],
  ];

  // The loop, run three times (420, 380, 400 s/km), and a second trail about
  // 1.1 km north, run twice.
  final loop = [
    trailLoopRun(n: 1, start: d1, secPerKm: 420),
    trailLoopRun(n: 2, start: d1.add(const Duration(days: 2)), secPerKm: 380),
    trailLoopRun(n: 3, start: d1.add(const Duration(days: 4)), secPerKm: 400),
  ];
  final north = [
    trailLoopRun(
      n: 4,
      start: d1.add(const Duration(days: 5)),
      secPerKm: 390,
      dLat: 0.01,
    ),
    trailLoopRun(
      n: 5,
      start: d1.add(const Duration(days: 6)),
      secPerKm: 395,
      dLat: 0.01,
    ),
  ];
  final all = [...loop, ...north];
  const split = engine.TrailOverride.split();

  test('an override survives an index re-derive', () async {
    final store = await storeWith(all);
    await store.setTrailOverride(loop[1].id, split);
    await store.setTrailOverride(
      north[0].id,
      engine.TrailOverride.join(loop[0].id),
    );
    var runs = await store.list();
    expect(runs.firstWhere((r) => r.id == loop[1].id).trailOverride, split);

    // Throw the whole index away: every row is derived again from the files.
    await store.derivedIdle;
    await store.indexFile.delete();
    final again = open();
    runs = await again.list();
    await again.derivedIdle;
    expect(runs.firstWhere((r) => r.id == loop[1].id).trailOverride, split);
    expect(
      runs.firstWhere((r) => r.id == north[0].id).trailOverride,
      engine.TrailOverride.join(loop[0].id),
    );
    expect(runs.firstWhere((r) => r.id == loop[0].id).trailOverride, isNull);
    // And the row carries it through its own JSON, as written to the index.
    final row = runs.firstWhere((r) => r.id == loop[1].id).row!;
    expect(IndexRow.fromJson(row.toJson())!.trailOverride, split);
  });

  test('an override is a sidecar field, so it moves with the run', () async {
    final store = await storeWith(all);
    await store.setTrailOverride(loop[1].id, split);
    final bundles = await store.exportBundles();
    final b = bundles.firstWhere((b) => b.run.id == loop[1].id);
    expect(b.sidecar?.trailOverride, split);
    await store.setTrailOverride(loop[1].id, null);
    expect(
      (await store.list()).firstWhere((r) => r.id == loop[1].id).trailOverride,
      isNull,
    );
  });

  test('a split run leaves the board and the ghost', () async {
    final store = await storeWith(all);
    var trails = ghostOf(store);
    expect(trails, hasLength(2));
    expect(
      lastIdOf(trails.firstWhere((t) => t.best.runId == loop[1].id)),
      loop[2].id,
    );

    await store.setTrailOverride(loop[1].id, split);
    final runs = await store.list();

    // The board: the loop is now runs 1 and 3 only.
    final boards = trailBoards(runs);
    expect(boards.map((g) => g.runs.map((r) => r.id).toList()), [
      [north[0].id, north[1].id],
      [loop[0].id, loop[2].id],
    ]);

    // The ghost: the loop's best is no longer the split run. The split run is
    // a trail of its own, as a single Trail run always is.
    trails = ghostOf(store);
    expect(trails, hasLength(3));
    final theLoop = trails.firstWhere((t) => lastIdOf(t) == loop[2].id);
    expect(theLoop.best.runId, loop[2].id); // 400 beats 420 once 380 is out
    final alone = trails.firstWhere((t) => t.best.runId == loop[1].id);
    expect(alone.id, isNot(theLoop.id));
    expect(lastIdOf(alone), loop[1].id);
  });

  test('a split run has no same-trail verdict', () async {
    final store = await storeWith(all);
    await store.setTrailOverride(loop[2].id, split);
    final runs = await store.list();
    final facts = trailFactsOfAll(runs);
    final cur = facts.firstWhere((f) => f.id == loop[2].id);
    expect(
      engine.TrailVerdict.of(cur, facts).basis,
      isNot(engine.TrailBasis.sameTrail),
    );
    final other = facts.firstWhere((f) => f.id == loop[0].id);
    expect(
      engine.TrailVerdict.of(
        facts.firstWhere((f) => f.id == loop[1].id),
        facts,
      ).basis,
      engine.TrailBasis.sameTrail,
    );
    expect(other.override, isNull);
  });

  test('a merged run joins the board and the ghost', () async {
    // 4.5 km round the same loop: 25% shorter, so it never matches by itself.
    final small = trailLoopRun(
      n: 6,
      start: d1.add(const Duration(days: 8)),
      secPerKm: 350,
      km: 4.5,
      loopKm: 4.5,
    );
    final store = await storeWith([...loop, small]);
    expect(await groupsOf(store), [
      [loop[0].id, loop[1].id, loop[2].id],
      [small.id],
    ]);

    await store.setTrailOverride(
      small.id,
      engine.TrailOverride.join(loop[0].id),
    );
    final runs = await store.list();
    expect(await groupsOf(store), [
      [loop[0].id, loop[1].id, loop[2].id, small.id],
    ]);
    expect(trailBoards(runs).single.runs.map((r) => r.id), contains(small.id));

    final trails = ghostOf(store);
    expect(trails, hasLength(1));
    // It is the latest run on the trail, so it is the ghost's last run.
    expect(lastIdOf(trails.single), small.id);
  });

  test('the companion trail block counts a merged run on its trail', () async {
    final small = trailLoopRun(
      n: 6,
      start: d1.add(const Duration(days: 8)),
      secPerKm: 350,
      km: 4.5,
      loopKm: 4.5,
    );
    final store = await storeWith([...loop, small]);
    final before = trailGroupOf(small.id, trailFactsOfAll(await store.list()));
    expect(before!.runs, hasLength(1));
    await store.setTrailOverride(
      small.id,
      engine.TrailOverride.join(loop[0].id),
    );
    final g = trailGroupOf(small.id, trailFactsOfAll(await store.list()))!;
    expect(g.runs, hasLength(4));
    final asOf = trailAsOf(g, small.id)!;
    expect(asOf.runs, hasLength(4));
    expect(asOf.anchorId, loop[0].id);
  });

  test('joining one run never merges its trail into the other', () async {
    final store = await storeWith(all);
    expect(await groupsOf(store), [
      [loop[0].id, loop[1].id, loop[2].id],
      [north[0].id, north[1].id],
    ]);

    // The runner says north run 4 is the loop. Only run 4 moves.
    await store.setTrailOverride(
      north[0].id,
      engine.TrailOverride.join(loop[0].id),
    );
    expect(await groupsOf(store), [
      [loop[0].id, loop[1].id, loop[2].id, north[0].id],
      [north[1].id],
    ]);
    final trails = ghostOf(store);
    expect(trails, hasLength(2));
    // North run 5 stays a trail of its own: it is in no loop profile.
    final ownTrail = trails.firstWhere((t) => t.best.runId == north[1].id);
    expect(lastIdOf(ownTrail), north[1].id);
    final theLoop = trails.firstWhere((t) => t.id != ownTrail.id);
    for (final id in [theLoop.best.runId, lastIdOf(theLoop)]) {
      expect(id, isNot(north[1].id));
    }
  });

  test('without an override nothing moves', () async {
    final store = await storeWith(all);
    expect((await store.list()).every((r) => r.trailOverride == null), isTrue);
    expect(ghostOf(store), hasLength(2));
  });
}
