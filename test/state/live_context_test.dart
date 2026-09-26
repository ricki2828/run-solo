import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/live_context.dart';

import '../run_fixtures.dart';

/// Phase 4 LC1 builder, app side: candidates prepared off the UI isolate
/// (when Start opens), the Start's live context planned over them inside
/// 150 ms, or none.
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);
  late Directory dir;
  late Directory runsDir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-live-');
    runsDir = Directory('${dir.path}/runs');
  });
  // Stores that build derived data: their background writes land before
  // the directory goes (#60 review P3).
  final stores = <FileRunStore>[];
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  /// Free runs long enough for the 5K board (40 min at 6:00/km).
  Future<FileRunStore> storeWithFreeRuns(int n, {int from = 1}) async {
    final store = FileRunStore(runsDir);
    // The live context reads derived data: build it (tests default to none).
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    await store.importBundles([
      for (var i = from; i < from + n; i++)
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
    'prepared: a 5K board with both earlier runs, splits from Start',
    () async {
      final store = await storeWithFreeRuns(2);
      final src = LiveContextSource(indexFile: store.indexFile);
      await src.prepare();
      final ctx = await src.build(mode: RecordMode.free);
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

  test(
    'not prepared for this index: none at Start, ready right after',
    () async {
      final store = await storeWithFreeRuns(2);
      final src = LiveContextSource(indexFile: store.indexFile);
      expect(
        await src.build(mode: RecordMode.free),
        isNull,
        reason: 'Start never decodes the index itself',
      );
      await src.prepare(); // the one build() kicked off, or a fresh one
      expect(await src.build(mode: RecordMode.free), isNotNull);
    },
  );

  test('one earlier run: no board, no context (nothing said)', () async {
    final store = await storeWithFreeRuns(1);
    final src = LiveContextSource(indexFile: store.indexFile);
    await src.prepare();
    expect(await src.build(mode: RecordMode.free), isNull);
  });

  test('no index yet, or a damaged one: none, prepare never throws', () async {
    final f = File('${dir.path}/state/index.json');
    final src = LiveContextSource(indexFile: f);
    await src.prepare();
    expect(await src.build(mode: RecordMode.free), isNull);
    f
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    await src.prepare();
    expect(await src.build(mode: RecordMode.free), isNull);
  });

  test('over the 150 ms budget: none, and Start is not held up', () async {
    final store = await storeWithFreeRuns(2);
    final src = LiveContextSource(indexFile: store.indexFile)
      ..beforeFold = () => Future<void>.delayed(const Duration(seconds: 2));
    await src.prepare();
    final sw = Stopwatch()..start();
    final ctx = await src.build(mode: RecordMode.free);
    sw.stop();
    expect(ctx, isNull);
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test(
    'a changed index: the last candidates race, then the new ones',
    () async {
      final store = await storeWithFreeRuns(2);
      final src = LiveContextSource(indexFile: store.indexFile);
      await src.prepare();
      expect(
        (await src.build(mode: RecordMode.free))!.boards.single.entries,
        hasLength(2),
      );
      await storeWithFreeRuns(1, from: 9);
      // The index moved after prepare: the candidates we had still race
      // (a derived batch landing after Start opened must not lose the
      // compare), and a fresh prepare starts.
      expect(
        (await src.build(mode: RecordMode.free))!.boards.single.entries,
        hasLength(2),
      );
      await src.prepare();
      expect(
        (await src.build(mode: RecordMode.free))!.boards.single.entries,
        hasLength(3),
      );
    },
  );

  test(
    '200 runs: prepare off the UI isolate, Start plans fast (host)',
    () async {
      // Measures this host, not the A-series phone the plan budgets for.
      final store = await storeWithFreeRuns(200);
      final src = LiveContextSource(indexFile: store.indexFile);
      final prep = Stopwatch()..start();
      await src.prepare();
      prep.stop();
      final start = Stopwatch()..start();
      final ctx = await src.build(mode: RecordMode.free);
      start.stop();
      expect(ctx!.boards.first.entries.length, lessThanOrEqualTo(20));
      // ignore: avoid_print
      print(
        'live context, 200 runs: prepare ${prep.elapsedMilliseconds} ms '
        '(background isolate), Start ${start.elapsedMilliseconds} ms',
      );
      expect(start.elapsedMilliseconds, lessThan(150));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
