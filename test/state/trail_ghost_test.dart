import 'dart:math' as math;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/trails.dart';
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
    // The busiest first (the loop, three runs), then the northern trail (run 4).
    expect(trails.last.best.runId, runs[3].id);
    final loop = trails.first;
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
      final loop = trailsOf(store).first;
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

  test(
    'the trail carries its smoothed elevation and climbs to Pigeon',
    () async {
      final store = await storeWith(runs);
      final loop = trailsOf(store).first;
      final n = loop.latLon.length ~/ 2;
      expect(loop.elevSrc, 'baro');
      expect(loop.elevM, hasLength(n));
      // The fixture is a sine of 18 m: smoothed, it stays inside 40 +- 18.
      for (final v in loop.elevM!) {
        expect(v, inInclusiveRange(21, 59));
      }
      expect(loop.climbs, isNotEmpty);
      final wire = TrailGhostSource.toPigeon(loop);
      expect(wire.elevM, loop.elevM);
      expect(wire.elevSrc, 'baro');
      expect(wire.climbs, hasLength(loop.climbs.length));
      final c = wire.climbs!.first;
      expect(c.endM, greaterThan(c.startM));
      expect(c.gainM, greaterThanOrEqualTo(15));
      expect(c.avgGradePct, greaterThan(0));
    },
  );

  test(
    'a compare build over the 150 ms budget still carries the trails',
    () async {
      final store = await storeWith(runs);
      final src = LiveContextSource(
        indexFile: store.indexFile,
        trailGhosts: TrailGhostSource(
          indexFile: store.indexFile,
          runDirs: [runsDir, store.archiveDir],
        ),
      )..beforeFold = () => Future<void>.delayed(const Duration(seconds: 2));
      await src.prepare();
      await src.trailGhosts!.prepare();
      final ctx = await src.build(mode: RecordMode.trail);
      expect(ctx, isNotNull);
      expect(ctx!.boards, isEmpty);
      expect(ctx.trails, hasLength(2));
      // A mode with no ghost still gets nothing on a timeout.
      expect(await src.build(mode: RecordMode.intervals), isNull);
    },
  );

  test(
    'a Free run on the same route joins the trail: boards and ghost',
    () async {
      final trail1 = trailLoopRun(n: 1, start: d1, secPerKm: 420);
      final free2 = trailLoopRun(
        n: 2,
        start: d1.add(const Duration(days: 2)),
        secPerKm: 380,
      ).copyWith(mode: engine.RunMode.free);
      final store = await storeWith([trail1, free2]);
      final all = await store.list();
      expect(all.firstWhere((r) => r.id == free2.id).row?.route, isNotNull);
      final boards = trailBoards(all);
      expect(boards, hasLength(1));
      expect(boards.single.runs.map((r) => r.id), [trail1.id, free2.id]);
      // The ghost knows it too: the Free run is the best (and the last) on it.
      final trails = trailsOf(store);
      expect(trails, hasLength(1));
      expect(trails.single.best.runId, free2.id);
      // A road run on other ground in Free mode is a group of one: no board.
      final other = trailLoopRun(
        n: 3,
        start: d1.add(const Duration(days: 3)),
        dLat: 0.05,
      ).copyWith(mode: engine.RunMode.free);
      final store2 = await storeWith([trail1, free2, other]);
      expect(trailBoards(await store2.list()), hasLength(1));
    },
  );

  // An out and back along a straight road, [turnM] to the turn, at
  // [secPerKm]: the road is the same, only where the runner turned differs.
  engine.RunFile oabRun({
    required int n,
    required DateTime start,
    required double turnM,
    required int secPerKm,
    engine.RunMode mode = engine.RunMode.trail,
  }) {
    const lat0 = 37.4, lon0 = 24.9, mPerDeg = 111194.9;
    final kx = math.cos(lat0 * math.pi / 180) * mPerDeg;
    final base = freeRunFile(
      n: n,
      start: start,
      seconds: (secPerKm * 2 * turnM / 1000).round(),
      secPerKm: secPerKm,
    );
    final total = base.distanceM;
    return base.copyWith(
      mode: mode,
      elevSrc: engine.ElevSource.baro,
      samples: [
        for (final s in base.samples)
          s.copyWith(
            lat: lat0,
            lon: lon0 + turnM * (1 - (2 * s.distM / total - 1).abs()) / kx,
            elevM: 40.0,
          ),
      ],
    );
  }

  test('a run that turned much earlier is not the ghost\'s best', () async {
    // 4000 m and 4250 m out: the same road, 250 m apart at the turn. The
    // faster run is the early one; it must not be the reference for a run
    // that goes to the far turn, or the way back reads minutes behind.
    final early = oabRun(n: 1, start: d1, turnM: 4000, secPerKm: 330);
    final late = oabRun(
      n: 2,
      start: d1.add(const Duration(days: 2)),
      turnM: 4250,
      secPerKm: 400,
    );
    final store = await storeWith([early, late]);
    final trails = trailsOf(store);
    expect(trails, hasLength(1));
    expect(trails.single.best.runId, late.id, reason: 'the early turn is out');
    // A third run, the late turn at the late pace: level all the way back.
    final again = oabRun(
      n: 3,
      start: d1.add(const Duration(days: 4)),
      turnM: 4250,
      secPerKm: 400,
    );
    final g = engine.TrailGhostTracker(trails);
    var worst = 0;
    var back = 0;
    for (final s in again.samples) {
      g.offer(s.tMs, s.lat!, s.lon!, 5, s.tMs, s.distM);
      final st = g.state;
      if (st != null && st.aheadBestMs != null && s.distM > 4500) {
        back++;
        worst = math.max(worst, st.aheadBestMs!.abs());
      }
    }
    expect(back, greaterThan(100), reason: 'a way back was run and read');
    expect(worst, lessThan(15000));
  });

  test('turn points close together share one best', () async {
    final a = oabRun(n: 1, start: d1, turnM: 4000, secPerKm: 330);
    final b = oabRun(
      n: 2,
      start: d1.add(const Duration(days: 2)),
      turnM: 4040,
      secPerKm: 400,
    );
    final trails = trailsOf(await storeWith([a, b]));
    expect(trails.single.best.runId, a.id);
  });

  test('six one-off Free runs do not evict a two-run trail', () async {
    final trailRuns = [
      trailLoopRun(n: 1, start: d1, secPerKm: 420),
      trailLoopRun(n: 2, start: d1.add(const Duration(days: 1)), secPerKm: 400),
    ];
    final oneOffs = [
      for (var i = 0; i < 6; i++)
        trailLoopRun(
          n: 10 + i,
          start: d1.add(Duration(days: 10 + i)),
          dLat: 0.03 * (i + 1),
        ).copyWith(mode: engine.RunMode.free),
    ];
    final trails = trailsOf(await storeWith([...trailRuns, ...oneOffs]));
    expect(trails, hasLength(1));
    expect(trails.single.best.runId, trailRuns[1].id);
  });

  test('no trail runs gives no trails and no context', () async {
    final store = await storeWith([
      freeRunFile(n: 1, start: d1, seconds: 1800),
    ]);
    // A one-off Free run is not a known trail.
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
