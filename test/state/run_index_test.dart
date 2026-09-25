import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../run_fixtures.dart';

/// Phase 3 W5: `files/state/index.json`, a per-run summary cache kept in
/// line with the run files AND their sidecars.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  late Directory runsDir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-index-');
    runsDir = Directory('${dir.path}/runs');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<FileRunStore> storeWith(List<engine.RunFile> runs) async {
    final store = FileRunStore(runsDir);
    await store.importBundles([for (final r in runs) engine.RunBundle(run: r)]);
    return store;
  }

  Map<String, Object?> rawEntry(FileRunStore s, String id) {
    final j = jsonDecode(s.indexFile.readAsStringSync()) as Map;
    return (j['runs'] as List).cast<Map<String, Object?>>().firstWhere(
      (e) => e['id'] == id,
    );
  }

  test('list() writes one entry per run, at files/state/index.json', () async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final r2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 3)));
    final store = await storeWith([r1, r2]);
    await store.list();
    expect(store.indexFile.path, '${dir.path}/state/index.json');
    final index = await store.readIndex();
    expect(index.entries.keys.toSet(), {r1.id, r2.id});
    final e = index.entries[r2.id]!;
    expect(e.mode, engine.RunMode.intervals);
    expect(e.templateId, 'norwegian-4x4');
    expect(e.comparisonKey, 't240x*');
    expect(e.repCount, 4);
    expect(e.start, r2.start);
    expect(e.verdictHash, isNotNull);
    expect(e.engineVersion, engine.engineVersion);
    expect(e.sidecarMtimeMs, isNotNull, reason: 'list() froze a verdict');
    expect(e.sidecarHash, isNotNull);
    expect(e.prior, isNotNull);
    expect(e.prior!.comparisonKey, 't240x*');
    expect(e.headlineSecPerKm, closeTo(e.prior!.avgWorkPaceSecPerKm, 1e-9));
    // Round trip.
    expect(RunIndex.decode(index.encode()).entries[r2.id], e);
  });

  test('a second list() with nothing changed does not rewrite it', () async {
    final store = await storeWith([fourByFourFile(n: 1, start: d1)]);
    await store.list();
    final text = store.indexFile.readAsStringSync();
    final stamp = store.indexFile.statSync().modified;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await store.list();
    expect(store.indexFile.readAsStringSync(), text);
    expect(store.indexFile.statSync().modified, stamp);
  });

  test('a fresh entry is reused; a sidecar-only change rebuilds it '
      '(re-check INFO: sidecar mtime, not just the run file)', () async {
    final synthetic = fourByFourSynthetic(n: 1, start: d1, missedPress: true);
    final r = synthetic.run;
    final store = await storeWith([r]);
    await store.list();
    final before = (await store.readIndex()).entries[r.id]!;
    expect(before.verdictHash, isNotNull);

    // Tamper with the cached headline only: a fresh entry is trusted.
    final j = jsonDecode(store.indexFile.readAsStringSync()) as Map;
    ((j['runs'] as List).single as Map)['headline_s_per_km'] = 1.0;
    store.indexFile.writeAsStringSync(jsonEncode(j));
    await store.list();
    expect(rawEntry(store, r.id)['headline_s_per_km'], 1.0);

    // Fix-laps touches only the sidecar: the entry is rebuilt at once.
    for (final e in synthetic.expected.rescueEdits) {
      await store.applyLapEdit(r.id, e);
    }
    await store.list();
    final after = (await store.readIndex()).entries[r.id]!;
    expect(after.headlineSecPerKm, isNot(1.0));
    expect(after.sidecarHash, isNot(before.sidecarHash));
    expect(after.verdictHash, isNot(before.verdictHash));
  });

  test('an entry from another engine version is rebuilt', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final store = await storeWith([r]);
    await store.list();
    final j = jsonDecode(store.indexFile.readAsStringSync()) as Map;
    final e = (j['runs'] as List).single as Map;
    e['engine_version'] = engine.engineVersion - 1;
    e['headline_s_per_km'] = 1.0;
    store.indexFile.writeAsStringSync(jsonEncode(j));
    await store.list();
    expect(rawEntry(store, r.id)['engine_version'], engine.engineVersion);
    expect(rawEntry(store, r.id)['headline_s_per_km'], isNot(1.0));
  });

  test('delete drops the entry; a damaged cache is rebuilt', () async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final r2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 3)));
    final store = await storeWith([r1, r2]);
    await store.list();
    await store.delete(r1.id);
    expect((await store.readIndex()).entries.keys, [r2.id]);

    store.indexFile.writeAsStringSync('{not json');
    expect((await store.readIndex()).entries, isEmpty);
    await store.list();
    expect((await store.readIndex()).entries.keys, [r2.id]);
  });

  test('a run gone from disk drops out on the next list()', () async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final store = await storeWith([r1]);
    await store.list();
    File('${runsDir.path}/run-${r1.id}.json.gz').deleteSync();
    await store.list();
    expect((await store.readIndex()).entries, isEmpty);
  });

  test('PriorRun survives the cache round trip', () {
    final p = engine.PriorRun(
      id: 'a',
      start: d1,
      avgWorkPaceSecPerKm: 281.5,
      fadeSecPerKm: 4,
      recoveryPaceSecPerKm: 390,
      timeInZoneSeconds: 600,
      meanWorkHr: 170,
      meanWorkHrFraction: 0.9,
      metresPerBeat: 1.2,
      repPacesSecPerKm: const [280, null, 283, 284],
      comparisonKey: 'd400x*',
    );
    expect(
      jsonEncode(engine.PriorRun.fromJson(p.toJson()).toJson()),
      jsonEncode(p.toJson()),
    );
  });
}
