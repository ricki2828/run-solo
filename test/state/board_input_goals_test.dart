import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../run_fixtures.dart';

/// W5b: the boards fold over index entries, so `boardInput()` must carry
/// every board's inputs. It dropped the time-window distances and goal
/// results, leaving the 30 min, 1 hour and custom goal boards empty on a
/// device (rs-plan-opus). Checked on FileRunStore, never the memory store.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  final stores = <FileRunStore>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-goalboards-');
  });
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  engine.RunFile goalRun(int n, engine.SessionSpec spec) => freeRunFile(
    n: n,
    start: d1.add(Duration(days: n)),
    seconds: 2000,
  ).copyWith(mode: engine.RunMode.intervals, session: spec);

  Future<Map<String, engine.Leaderboard>> boardsOf(
    List<engine.RunFile> runs,
  ) async {
    final store = FileRunStore(Directory('${dir.path}/runs'));
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    await store.importBundles([for (final r in runs) engine.RunBundle(run: r)]);
    await store.list();
    await store.derivedIdle;
    // Read back from disk, as a fresh app open would.
    final index = await RunIndex.read(store.indexFile);
    return engine.Leaderboards.fold(
      index.entries.values.map((e) => e.boardInput()),
    );
  }

  test('a 30 min goal run lands on the 30 min board', () async {
    final run = goalRun(1, engine.SessionSpec.goalTime(1800, '30 min'));
    final boards = await boardsOf([run]);
    final b = boards[engine.BestTimeWindow.min30.key];
    expect(b, isNotNull, reason: 'boards: ${boards.keys}');
    expect(b!.rankOf(run.id), 1);
    expect(b.pb!.metric, greaterThan(4000));
  });

  test('a custom goal run lands on its own goal board', () async {
    final spec = engine.SessionSpec.goalTime(1500, '25 min');
    final run = goalRun(2, spec);
    final key = engine.GoalCatalogue.boardKeyOf(spec);
    expect(engine.ComparisonKey.isGoal(key), isTrue);
    final boards = await boardsOf([run]);
    expect(boards[key]?.rankOf(run.id), 1, reason: 'boards: ${boards.keys}');
  });

  test('a 12-minute test lands on the Cooper board (A11.6 item 3)', () async {
    final slow = cooperTestFile(n: 4, start: d1, mps: 3.8);
    final fast = cooperTestFile(
      n: 5,
      start: d1.add(const Duration(days: 7)),
      mps: 4.2,
    );
    final boards = await boardsOf([slow, fast]);
    final b = boards[engine.ComparisonKey.cooper];
    expect(b, isNotNull, reason: 'boards: ${boards.keys}');
    expect(b!.length, 2);
    expect(b.pb!.runId, fast.id);
  });

  test('the goal result round-trips through the index row', () async {
    final run = goalRun(3, engine.SessionSpec.goalTime(1800, '30 min'));
    await boardsOf([run]);
    final index = await RunIndex.read(stores.single.indexFile);
    final row = index.entries[run.id]!.row!;
    expect(row.version, IndexRow.currentVersion);
    expect(row.goal, isNotNull);
    expect(row.goal!.reached, isTrue);
    expect(IndexRow.fromJson(row.toJson())!.goal!.toJson(), row.goal!.toJson());
  });

  group('a run on a treadmill stays off the outdoor boards (7-Nov)', () {
    final spec = engine.SessionSpec.goalDistance(5000, '5K');

    engine.RunFile beltGoal(int n) =>
        cooperBeltFile(
          n: n,
          start: d1.add(Duration(days: n)),
          distanceM: 5000,
        ).copyWith(
          mode: engine.RunMode.intervals,
          session: spec,
          laps: const [
            engine.Lap(
              index: 0,
              t0Ms: 0,
              t1Ms: 1500000,
              d0M: 0,
              d1M: 0,
              kind: engine.LapKind.manual,
            ),
            engine.Lap(
              index: 1,
              t0Ms: 1500000,
              t1Ms: 1700000,
              d0M: 0,
              d1M: 0,
              kind: engine.LapKind.manual,
            ),
          ],
        );

    Future<List<RunIndexEntry>> entriesOf(List<engine.RunFile> runs) async {
      final store = FileRunStore(Directory('${dir.path}/runs'));
      store.deriveBatch = FileRunStore.deriveInIsolate;
      stores.add(store);
      await store.importBundles([
        for (final r in runs) engine.RunBundle(run: r),
      ]);
      await store.list();
      await store.derivedIdle;
      final index = await RunIndex.read(store.indexFile);
      return index.entries.values.toList();
    }

    test('a goal run on a belt has no goal result for the boards', () async {
      final run = beltGoal(10);
      final entries = await entriesOf([run]);
      final e = entries.single;
      // The index keeps the run and its goal result for History...
      expect(e.row!.treadmillInclinePct, 1.0);
      expect(e.row!.goal?.reached, isTrue);
      // ...but the boards never see it.
      final input = e.boardInput();
      expect(input.goal, isNull);
      expect(input.goalBoardKey, isNull);
      expect(input.efforts, isEmpty);
      final boards = engine.Leaderboards.fold([input]);
      expect(boards.values.every((b) => b.rankOf(run.id) == null), isTrue);
    });

    test('the same goal outdoors does reach the goal board', () async {
      final outdoor = freeRunFile(
        n: 11,
        start: d1.add(const Duration(days: 11)),
        seconds: 2000,
      ).copyWith(mode: engine.RunMode.intervals, session: spec);
      final e = (await entriesOf([outdoor])).single;
      expect(e.boardInput().goalBoardKey, isNotNull);
    });

    test(
      'a belt test is not on the Cooper board beside an outdoor one',
      () async {
        final outdoor = cooperTestFile(n: 12, start: d1, mps: 3.8);
        final belt = cooperBeltFile(
          n: 13,
          start: d1.add(const Duration(days: 7)),
          distanceM: 3400,
        );
        final entries = await entriesOf([outdoor, belt]);
        final boards = engine.Leaderboards.fold(
          entries.map((e) => e.boardInput()),
        );
        final b = boards[engine.ComparisonKey.cooper]!;
        expect(b.length, 1);
        expect(b.rankOf(belt.id), isNull);
        expect(b.pb!.runId, outdoor.id);
      },
    );
  });
}
