import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../run_fixtures.dart';

/// Phase 3 W5b: History reads `index.json`. A fresh entry is never decoded;
/// each trigger rebuilds only the entries it affects.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  late Directory runsDir;
  var profile = const engine.UserProfile(age: 40);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-w5b-');
    runsDir = Directory('${dir.path}/runs');
    profile = const engine.UserProfile(age: 40);
  });
  // Stores that build derived data in the background: wait for them before
  // the directory goes.
  final stores = <FileRunStore>[];
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  Future<FileRunStore> storeWith(List<engine.RunFile> runs) async {
    final store = FileRunStore(runsDir, profile: () => profile);
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    await store.importBundles([for (final r in runs) engine.RunBundle(run: r)]);
    return store;
  }

  String name(engine.RunFile r) => 'run-${r.id}.json.gz';

  final a1 = fourByFourFile(n: 1, start: d1);
  final a2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 2)));
  final a3 = fourByFourFile(n: 3, start: d1.add(const Duration(days: 4)));
  final free = freeRunFile(n: 4, start: d1.add(const Duration(days: 1)));

  Future<FileRunStore> warm() async {
    final store = await storeWith([a1, a2, a3, free]);
    await store.list();
    await store.derivedIdle;
    store.decoded.clear();
    return store;
  }

  test('a second list() decodes nothing and shows the same rows', () async {
    final store = await storeWith([a1, a2, a3, free]);
    final first = await store.list();
    expect(store.decoded, hasLength(4));
    await store.derivedIdle;
    store.decoded.clear();
    final second = await store.list();
    expect(store.decoded, isEmpty);
    expect([for (final r in second) r.id], [for (final r in first) r.id]);
    final row = second.firstWhere((r) => r.id == a3.id);
    expect(row.analysis, isNull, reason: 'figures come from the index');
    expect(row.detectedReps, 4);
    expect(row.comparisonKey, 't240x*');
    expect(row.verdict!.stage, engine.VerdictStage.vsMedian);
    expect(row.workPaceSecPerKm, isNotNull);
    expect(row.eligibleAsPrior, isTrue);
    expect(row.cleanRepPacesSecPerKm.whereType<double>(), hasLength(4));
    expect(second.firstWhere((r) => r.id == free.id).mode, RecordMode.free);
  });

  test('index rows match the analysed path (load)', () async {
    final store = await warm();
    final rows = await store.list();
    for (final id in [a1.id, a2.id, a3.id]) {
      final d = (await store.load(id))!;
      final row = rows.firstWhere((r) => r.id == id);
      expect(row.verdict!.subline, d.analysis.verdict!.subline);
      expect(row.workPaceSecPerKm, d.analysis.intervals!.avgWorkPaceSecPerKm);
      expect(row.detectedReps, d.analysis.intervals!.reps.length);
    }
  });

  test('load() decodes only its own run', () async {
    final store = await warm();
    await store.load(a2.id);
    expect(store.decoded, [name(a2)]);
  });

  test(
    'an edit to an earlier run rebuilds the later runs of its key only',
    () async {
      final store = await warm();
      final before = await store.list();
      store.decoded.clear();
      // a1 stops being an interval run: a2 loses its only prior.
      await store.setOverride(a1.id, RecordMode.laps);
      // setOverride's load() rebuilt a1 and the later runs of its key.
      expect(store.decoded.toSet(), {name(a1), name(a2), name(a3)});
      store.decoded.clear();
      final after = await store.list();
      // Already rebuilt by the load() inside setOverride.
      expect(store.decoded, isEmpty);
      // a2 and a3 were re-analysed with the new priors; their verdicts are
      // frozen (plan §5: only fix-laps, override or an engine bump
      // recompute one), so the words stay; a1's row is now Laps.
      final v2before = before.firstWhere((r) => r.id == a2.id).verdict!;
      final v2after = after.firstWhere((r) => r.id == a2.id).verdict!;
      expect(v2after.subline, v2before.subline);
      final r1 = after.firstWhere((r) => r.id == a1.id);
      expect(r1.mode, RecordMode.laps);
      expect(r1.verdict, isNull);
    },
  );

  test('a sidecar change that moves no prior (a note) rebuilds that run '
      'only', () async {
    final store = await warm();
    final sc = File('${runsDir.path}/run-${a2.id}.edits.json');
    sc.writeAsStringSync(
      engine.RunSidecarCodec.encode(
        engine.RunSidecarCodec.decode(sc.readAsStringSync())
            .copyWith(notes: 'windy'),
      ),
    );
    await store.list();
    expect(store.decoded, [name(a2)]);
  });

  test('a weather write (W1 backfill) never cascades', () async {
    final store = await warm();
    for (final r in [a1, a2]) {
      await store.setWeather(
        r.id,
        const engine.WeatherRecord(status: engine.WeatherStatus.skipped),
      );
    }
    await store.list();
    expect(store.decoded.toSet(), {name(a1), name(a2)});
  });

  test('a changed prior cascades to later runs of its key only', () async {
    final store = await warm();
    // a2 drops its last rep: its prior (pace, rep paces) changes.
    await store.applyLapEdit(a2.id, const engine.LapEdit.drop(7));
    expect(store.decoded.toSet(), containsAll({name(a2), name(a3)}));
    expect(store.decoded, isNot(contains(name(a1))));
    expect(store.decoded, isNot(contains(name(free))));
  });

  test('an event-name change rebuilds every entry', () async {
    final store = await warm();
    final before = (await store.readIndex()).inputs;
    final other = FileRunStore(
      runsDir,
      profile: () => profile,
      runEngine: const engine.RunEngine(
        names: engine.EventNames(parkrun: 'Saturday 5K'),
      ),
    );
    await other.list();
    expect(other.decoded, hasLength(4));
    final after = (await other.readIndex()).inputs;
    expect(after, isNot(before));
    expect(after, contains('Saturday 5K'));
  });

  test('a max-HR change rebuilds every entry and keeps derived data', () async {
    final store = await warm();
    final before = await store.readIndex();
    expect(before.entries[a1.id]!.derived, isNotNull);
    profile = const engine.UserProfile(age: 40, maxHr: 176);
    await store.list();
    expect(store.decoded, hasLength(4));
    final after = await store.readIndex();
    expect(after.inputs, isNot(before.inputs));
    for (final id in [a1.id, a2.id, a3.id]) {
      expect(after.entries[id]!.derived, isNotNull, reason: id);
      expect(
        after.entries[id]!.derived!.toJson(),
        before.entries[id]!.derived!.toJson(),
      );
    }
    store.decoded.clear();
    await store.list();
    expect(store.decoded, isEmpty, reason: 'stable once rebuilt');
  });

  test('delete marks later runs of its key stale, not others', () async {
    final store = await warm();
    await store.delete(a1.id);
    final index = await store.readIndex();
    expect(index.entries[a2.id]!.row, isNull);
    expect(index.entries[a3.id]!.row, isNull);
    expect(index.entries[free.id]!.row, isNotNull);
    store.decoded.clear();
    final rows = await store.list();
    expect(store.decoded.toSet(), {name(a2), name(a3)});
    expect(rows.map((r) => r.id), isNot(contains(a1.id)));
    expect(rows.firstWhere((r) => r.id == a2.id).verdict, isNotNull);
  });

  test('an entry from before W5b (no row) is rebuilt once', () async {
    final store = await warm();
    final index = await store.readIndex();
    store.indexFile.writeAsStringSync(
      RunIndex({
        for (final e in index.entries.values) e.id: e.withoutRow(),
      }, inputs: index.inputs).encode(),
    );
    await store.list();
    expect(store.decoded, hasLength(4));
    expect((await store.readIndex()).entries[a1.id]!.derived, isNotNull);
  });

  test('leftover tmp files older than a minute are swept', () async {
    final store = await warm();
    final old = DateTime.now().subtract(const Duration(minutes: 5));
    final oldSidecarTmp = File(
      '${runsDir.path}/run-${a1.id}.edits.json.123_4.tmp',
    )..writeAsStringSync('x');
    oldSidecarTmp.setLastModifiedSync(old);
    final oldIndexTmp = File('${store.indexFile.path}.123_5.tmp')
      ..writeAsStringSync('x');
    oldIndexTmp.setLastModifiedSync(old);
    final fresh = File('${runsDir.path}/run-${a2.id}.edits.json.123_6.tmp')
      ..writeAsStringSync('x');
    final unrelated = File('${runsDir.path}/notes.tmp')..writeAsStringSync('x');
    unrelated.setLastModifiedSync(old);
    await store.list();
    expect(oldSidecarTmp.existsSync(), isFalse);
    expect(oldIndexTmp.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue, reason: 'may be a write in progress');
    expect(unrelated.existsSync(), isTrue);
  });
}
