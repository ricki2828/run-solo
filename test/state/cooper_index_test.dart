import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/cooper_result_screen.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/boards.dart';
import 'package:run_solo/state/history_store.dart';

import '../run_fixtures.dart';

/// C1 on the file store (W5b: History carries no analysis there). The
/// 12-minute test's figures travel in the index row, so the rank chip, the
/// change line, Trend → Test, the Cooper board and LC1's cooperHistory read
/// them without decoding a run.
void main() {
  late Directory dir;
  final stores = <FileRunStore>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-cooper-');
  });
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  final a = cooperTestFile(n: 1, start: DateTime.utc(2026, 6, 10, 6), mps: 3.8);
  final b = cooperTestFile(n: 2, start: DateTime.utc(2026, 7, 15, 6), mps: 3.9);
  final c = cooperTestFile(n: 3, start: DateTime.utc(2026, 9, 20, 6), mps: 4.1);
  final paused = cooperTestFile(
    n: 4,
    start: DateTime.utc(2026, 9, 22, 6),
    pausedAtS: 400,
  );

  Future<FileRunStore> store() async {
    // Best efforts built, as on a phone once the batch lands (#71: chips
    // say "Checking your boards" until then).
    final s = FileRunStore(Directory('${dir.path}/runs'))
      ..deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(s);
    await s.importBundles([
      for (final r in [a, b, c, paused]) engine.RunBundle(run: r),
    ]);
    await s.list();
    await s.derivedIdle;
    return s;
  }

  test('list() rows carry the test figures, not an analysis', () async {
    final s = await store();
    final rows = await s.list();
    final third = rows.firstWhere((r) => r.id == c.id);
    expect(third.analysis, isNull, reason: 'W5b: figures come from the index');
    final fig = third.cooper!;
    expect(fig.valid, isTrue);
    expect(fig.testDistanceM, closeTo(2952, 1e-6));
    expect(fig.vo2, closeTo(engine.CooperProjection.vo2(2952), 1e-6));
    expect(fig.minuteM, hasLength(12));
    final p = rows.firstWhere((r) => r.id == paused.id).cooper!;
    expect(p.valid, isFalse);
    expect(p.vo2, isNull);
  });

  test('rank chip, change line and Trend tests read from list()', () async {
    final s = await store();
    final tests = cooperTests(await s.list());
    expect([for (final t in tests) t.id], [a.id, b.id, c.id]);
    final boards = await s.boards();
    List<BoardChip> chips(String id) =>
        boards.chipsFor(id, units: Units.km, names: engine.EventNames.generic);
    expect(chips(a.id).single.label, 'First test on your board');
    expect(chips(b.id).first.pb, isTrue, reason: 'faster than a, that day');
    expect(chips(b.id).first.boardKey, engine.ComparisonKey.cooper);
    expect(chips(c.id).first.label, startsWith('New best test · VO2 est. '));
    expect(
      chips(paused.id).where((c) => c.boardKey == engine.ComparisonKey.cooper),
      isEmpty,
      reason: 'no estimate, no test board',
    );
    final prior = tests.sublist(0, 2);
    expect(
      engine.CooperResult.changeLine(tests[2].vo2, c.start, [
        for (final t in prior) (t.date, t.vo2),
      ]),
      startsWith('VO2 est. +'),
    );
  });

  test(
    'the Cooper board and LC1 history get the raw VO2 from the row',
    () async {
      final s = await store();
      await s.list();
      final entries = (await s.readIndex()).entries;
      final inputs = [for (final e in entries.values) e.boardInput()];
      final vo2s = {
        for (final i in inputs)
          if (i.cooperVo2 != null) i.runId: i.cooperVo2,
      };
      expect(vo2s.keys.toSet(), {a.id, b.id, c.id}, reason: 'paused has none');
      final board = engine.Leaderboards.fold(
        inputs,
      )[engine.ComparisonKey.cooper]!;
      expect(board.pb!.runId, c.id);
      expect(board.length, 3);
    },
  );
}
