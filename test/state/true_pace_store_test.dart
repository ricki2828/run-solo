import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../run_fixtures.dart';

/// True Pace on the file store: History reads the index, so the rows carry
/// the true pace and the factors behind it (IndexRow v12), the verdict stays
/// frozen when weather arrives later, and there is no heat-compare flag in
/// the index fingerprint any more.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  late Directory runsDir;
  final stores = <FileRunStore>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-truepace-');
    runsDir = Directory('${dir.path}/runs');
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

  test('the index fingerprint carries no heat flag', () async {
    final store = await warm();
    expect((await store.readIndex()).inputs, isNot(contains('h:')));
  });

  test('no weather, no elevation: true pace is the actual pace', () async {
    final store = await warm();
    for (final r in await store.list()) {
      final row = r.row!;
      expect(row.version, IndexRow.currentVersion);
      expect(row.truePaceFactors.neutral, isTrue, reason: r.id);
      if (r.workPaceSecPerKm != null) {
        expect(
          r.trueWorkPaceSecPerKm,
          closeTo(r.workPaceSecPerKm!, 0.06),
          reason: r.id,
        );
      }
      if (row.truePaceSecPerKm != null) {
        expect(row.truePaceSecPerKm, closeTo(row.movingMs! / r.distanceM, 0.1));
      }
    }
  });

  test('weather arriving later keeps the verdict and fills the true pace '
      'twin', () async {
    final store = await warm();
    final staged = verdicts(await store.list());
    await store.setWeather(a3.id, ok(28, 21));
    final rows = await store.list();
    expect(verdicts(rows)[a3.id], staged[a3.id]);
    final row = rows.firstWhere((r) => r.id == a3.id);
    expect(row.heatFraction, greaterThan(0.04));
    expect(
      row.trueWorkPaceSecPerKm,
      closeTo(row.workPaceSecPerKm! * (1 - row.heatFraction!), 0.06),
    );
    expect(row.workFactors.heat, closeTo(1 - row.heatFraction!, 1e-3));
    expect(row.row!.heatFactor, closeTo(1 - row.heatFraction!, 1e-3));
    // The whole-run pace takes the heat out too.
    expect(row.truePaceSecPerKm, lessThan(row.row!.movingMs! / row.distanceM));
  });

  test('an old row (v11) is rebuilt once and gains the true pace', () async {
    final store = await warm();
    final index = await store.readIndex();
    final stale = {
      for (final e in index.entries.entries)
        e.key: RunIndexEntry.fromJson({
          ...e.value.toJson(),
          'row': {...e.value.row!.toJson(), 'v': IndexRow.currentVersion - 1},
        }),
    };
    await store.indexFile.writeAsString(
      RunIndex(stale, inputs: index.inputs).encode(),
    );
    await store.list();
    expect(store.decoded, hasLength(4));
    store.decoded.clear();
    await store.list();
    expect(store.decoded, isEmpty, reason: 'stable once rebuilt');
  });
}
