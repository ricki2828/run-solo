import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';

import '../run_fixtures.dart';

/// Phase 3 W2 on the file store: the heat-compare flip joins the index
/// fingerprint, so it recomputes every verdict (like an engine bump) and
/// flipping back restores them. History reads the index, so the rows are
/// what is checked here, not `RunSummary.analysis`.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  late Directory runsDir;
  var heat = false;
  final stores = <FileRunStore>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-w2-');
    runsDir = Directory('${dir.path}/runs');
    heat = false;
  });
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  final a1 = fourByFourFile(n: 1, start: d1);
  final a2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 2)));
  final a3 = fourByFourFile(n: 3, start: d1.add(const Duration(days: 4)));
  final free = freeRunFile(n: 4, start: d1.add(const Duration(days: 1)));

  Future<FileRunStore> warm() async {
    final store = FileRunStore(
      runsDir,
      profile: () => const engine.UserProfile(age: 40),
      heatCompare: () => heat,
    );
    store.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(store);
    await store.importBundles([
      for (final r in [a1, a2, a3, free]) engine.RunBundle(run: r),
    ]);
    await store.list();
    await store.derivedIdle;
    store.decoded.clear();
    return store;
  }

  engine.WeatherRecord ok(double temp, double dew) => engine.WeatherRecord(
    status: engine.WeatherStatus.ok,
    fetchedAt: d1,
    latR: -33.9,
    lonR: 151.2,
    tempC: temp,
    rh: 65,
    dewPointC: dew,
    adj: engine.HeatModel.of(tempC: temp, dewPointC: dew).fraction,
  );

  Map<String, Map<String, Object?>> verdicts(List<RunSummary> rows) => {
    for (final r in rows)
      if (r.verdict != null) r.id: r.verdict!.toJson()..remove('computed_at'),
  };

  test('off: the fingerprint is spelled as before W2', () async {
    final store = await warm();
    expect((await store.readIndex()).inputs, isNot(contains('h:')));
  });

  test('a flip rebuilds every entry; flipping back restores the verdicts '
      'and the fingerprint', () async {
    final store = await warm();
    final before = await store.readIndex();
    final original = verdicts(await store.list());
    expect(original.keys, containsAll([a1.id, a2.id, a3.id]));

    heat = true;
    final on = await store.list();
    expect(store.decoded, hasLength(4));
    expect((await store.readIndex()).inputs, endsWith(';h:1'));
    for (final r in on.where((r) => r.verdict != null)) {
      // No weather on any run: raw verdicts, each saying so.
      expect(r.verdict!.heatCompare, isTrue, reason: r.id);
      expect(r.verdict!.heatNote, engine.heatMissingNote, reason: r.id);
    }

    heat = false;
    store.decoded.clear();
    final back = await store.list();
    expect(store.decoded, hasLength(4));
    expect(verdicts(back), original);
    expect((await store.readIndex()).inputs, before.inputs);
    store.decoded.clear();
    await store.list();
    expect(store.decoded, isEmpty, reason: 'stable once rebuilt');
  });

  test('on: weather arriving later keeps the verdict and fills the trend '
      'twin', () async {
    final store = await warm();
    heat = true;
    final staged = verdicts(await store.list());
    await store.setWeather(a3.id, ok(28, 21));
    final rows = await store.list();
    expect(verdicts(rows)[a3.id], staged[a3.id]);
    final row = rows.firstWhere((r) => r.id == a3.id);
    expect(row.heatFraction, greaterThan(0.04));
    expect(
      row.heatAdjustedWorkPaceSecPerKm,
      closeTo(row.workPaceSecPerKm! * (1 - row.heatFraction!), 1e-9),
    );
  });
}
