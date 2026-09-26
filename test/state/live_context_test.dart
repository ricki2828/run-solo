import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/live_context.dart';

import '../run_fixtures.dart';

/// Phase 4 LC1 builder, app side: the Start's live context from index.json
/// and its derived data, 150 ms or none.
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);
  late Directory dir;
  late Directory runsDir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-live-');
    runsDir = Directory('${dir.path}/runs');
  });
  // The builder reads derived data, which tests only build when a store opts
  // in (test/flutter_test_config.dart); wait for it before the dir goes.
  final stores = <FileRunStore>[];
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  /// Free runs long enough for the 5K board (40 min at 6:00/km).
  Future<FileRunStore> storeWithFreeRuns(int n) async {
    final store = FileRunStore(runsDir);
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    await store.importBundles([
      for (var i = 1; i <= n; i++)
        engine.RunBundle(
          run: freeRunFile(
            n: i,
            start: d1.add(Duration(days: 2 * i)),
            seconds: 2400,
          ),
        ),
    ]);
    await store.list();
    await store.derivedIdle;
    return store;
  }

  test('off by default until LV2 (in-app mute) ships', () {
    expect(kLiveCompare, isFalse);
  });

  test(
    'two earlier Free runs: a 5K board with both, splits from Start',
    () async {
      final store = await storeWithFreeRuns(2);
      final ctx = await LiveContextSource(indexFile: store.indexFile)
          .build(mode: RecordMode.free);
      expect(ctx, isNotNull);
      final board = ctx!.boards.single;
      expect(board.key, 'be:5000');
      expect(board.kind, LiveBoardKind.distance);
      expect(board.targetM, 5000);
      expect(board.entries, hasLength(2));
      expect(board.entries.first.fromStartSplitsMs, hasLength(5));
      expect(ctx.nudges!.version, 0, reason: 'LC1 stub');
      expect(ctx.engineVersion, engine.engineVersion);
      expect(ctx.coachingMuted, isFalse);
    },
  );

  test('one earlier run: no board, no context (nothing said)', () async {
    final store = await storeWithFreeRuns(1);
    expect(
      await LiveContextSource(indexFile: store.indexFile)
          .build(mode: RecordMode.free),
      isNull,
    );
  });

  test('no index yet, or a damaged one: none', () async {
    final src = LiveContextSource(
      indexFile: File('${dir.path}/state/index.json'),
    );
    expect(await src.build(mode: RecordMode.free), isNull);
    File('${dir.path}/state/index.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(await src.build(mode: RecordMode.free), isNull);
  });

  test('over the 150 ms budget: none, and Start is not held up', () async {
    final store = await storeWithFreeRuns(2);
    final src = LiveContextSource(indexFile: store.indexFile)
      ..beforeFold = () => Future<void>.delayed(const Duration(seconds: 2));
    final sw = Stopwatch()..start();
    final ctx = await src.build(mode: RecordMode.free);
    sw.stop();
    expect(ctx, isNull);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('cached per index version; a new index is read again', () async {
    final store = await storeWithFreeRuns(2);
    final src = LiveContextSource(indexFile: store.indexFile);
    expect(
      (await src.build(mode: RecordMode.free))!.boards.single.entries,
      hasLength(2),
    );
    await store.importBundles([
      engine.RunBundle(
        run: freeRunFile(
          n: 9,
          start: d1.add(const Duration(days: 30)),
          seconds: 2400,
        ),
      ),
    ]);
    await store.list();
    await store.derivedIdle;
    expect(
      (await src.build(mode: RecordMode.free))!.boards.single.entries,
      hasLength(3),
    );
  });
}
