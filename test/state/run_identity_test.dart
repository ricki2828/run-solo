import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/places.dart';
import 'package:run_solo/state/run_index.dart';

import '../run_fixtures.dart';

/// Run identity: the title (time of day + session name), the place from the
/// phone's geocoder, the 300 m reuse rule, and the index row that carries
/// them to History and Home.
void main() {
  RunSummary at(
    int hour, {
    RecordMode mode = RecordMode.intervals,
    String? title,
    engine.SessionSpec? spec,
  }) => RunSummary(
    id: 'x',
    mode: mode,
    start: DateTime(2026, 9, 24, hour).toUtc(),
    durationMs: 600000,
    distanceM: 2000,
    laps: 1,
    spec: spec,
    customTitle: title,
  );

  group('runIdentityTitle', () {
    test('time of day and the session name, never a bare 4x4', () {
      expect(runIdentityTitle(at(6)), 'Early Norwegian 4x4');
      expect(runIdentityTitle(at(8)), 'Morning Norwegian 4x4');
      expect(
        runIdentityTitle(at(19, mode: RecordMode.free)),
        'Evening Free run',
      );
      expect(runIdentityTitle(at(22, mode: RecordMode.laps)), 'Night Laps run');
    });

    test('a preset is called by its own name', () {
      final spec = engine.SessionCatalogue.expand('400s');
      expect(runIdentityTitle(at(12, spec: spec)), 'Lunch ${spec.name}');
      expect(spec.name, contains('400 m'));
    });

    test('the runner\'s own name wins, whatever the time', () {
      expect(runIdentityTitle(at(8, title: 'Hill day')), 'Hill day');
    });
  });

  test('time of day uses the recorded offset, else the phone zone', () {
    // 06:00 in +10:00 is 20:00 UTC the day before.
    final start = DateTime.utc(2026, 9, 23, 20);
    RunSummary run({int? offset}) => RunSummary(
      id: 'x',
      mode: RecordMode.free,
      start: start,
      durationMs: 1,
      distanceM: 1,
      laps: 0,
      utcOffsetMin: offset,
    );
    expect(runIdentityTitle(run(offset: 600)), 'Early Free run');
    expect(runWhereWhen(run(offset: 600)), 'Thu 24 Sep · 6:00');
    expect(run().localStart, start.toLocal());
  });

  test('where and when: place first, then day and time; no place no gap', () {
    final start = DateTime(2026, 9, 24, 6).toUtc();
    expect(whereWhen('Albert Park', start), 'Albert Park · Thu 24 Sep · 6:00');
    expect(whereWhen(null, start), 'Thu 24 Sep · 6:00');
  });

  group('PlaceResolver on a FileRunStore', () {
    late Directory dir;
    late FileRunStore store;
    final d1 = DateTime.utc(2026, 9, 10, 6);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('runsolo-place-');
      store = FileRunStore(Directory('${dir.path}/runs'));
    });
    tearDown(() async {
      await store.derivedIdle;
      dir.deleteSync(recursive: true);
    });

    engine.RunFile shifted(engine.RunFile r, double dLat) => r.copyWith(
      samples: [
        for (final s in r.samples)
          s.lat == null ? s : s.copyWith(lat: s.lat! + dLat),
      ],
    );

    test('names the start, saves it, and the index row carries it', () async {
      final r = freeRunFile(n: 1, start: d1);
      await store.importBundles([engine.RunBundle(run: r)]);
      final gw = FakePlaceGateway(name: 'Albert Park');
      final places = PlaceResolver(store: store, gateway: gw);
      expect(await places.ensure(r.id), 'Albert Park');
      expect((await store.load(r.id))!.sidecar.place, 'Albert Park');
      final listed = (await store.list()).single;
      expect(listed.place, 'Albert Park');
      expect(listed.startPoint, isNotNull);
      expect(runWhereWhen(listed), startsWith('Albert Park · '));
      // Already named: the geocoder is not asked again.
      await places.ensure(r.id);
      expect(gw.calls, hasLength(1));
    });

    test('a run starting within 300 m reuses the earlier name', () async {
      final a = freeRunFile(n: 1, start: d1);
      // About 220 m north of the first start.
      final b = shifted(
        freeRunFile(n: 2, start: d1.add(const Duration(days: 2))),
        0.002,
      );
      await store.importBundles([
        engine.RunBundle(run: a),
        engine.RunBundle(run: b),
      ]);
      final gw = FakePlaceGateway(name: 'Albert Park');
      final places = PlaceResolver(store: store, gateway: gw);
      await places.ensure(a.id);
      gw.name = 'St Kilda Road';
      expect(await places.ensure(b.id), 'Albert Park');
      expect(gw.calls, hasLength(1), reason: 'reused, not geocoded');
    });

    test('beyond 300 m asks the geocoder again', () async {
      final a = freeRunFile(n: 1, start: d1);
      // About 1.1 km north.
      final b = shifted(
        freeRunFile(n: 2, start: d1.add(const Duration(days: 2))),
        0.01,
      );
      await store.importBundles([
        engine.RunBundle(run: a),
        engine.RunBundle(run: b),
      ]);
      final gw = FakePlaceGateway(name: 'Albert Park');
      final places = PlaceResolver(store: store, gateway: gw);
      await places.ensure(a.id);
      gw.name = 'Fitzroy';
      expect(await places.ensure(b.id), 'Fitzroy');
      expect(gw.calls, hasLength(2));
    });

    test(
      'geocoder failure: no place, nothing written, retried next session',
      () async {
        final r = freeRunFile(n: 1, start: d1);
        await store.importBundles([engine.RunBundle(run: r)]);
        final gw = FakePlaceGateway(name: 'Albert Park', fails: true);
        final places = PlaceResolver(store: store, gateway: gw);
        expect(await places.ensure(r.id), isNull);
        expect((await store.load(r.id))!.sidecar.place, isNull);
        expect((await store.list()).single.place, isNull);
        // Same session: no second attempt for the same run.
        gw.fails = false;
        expect(await places.ensure(r.id), isNull);
        expect(gw.calls, hasLength(1));
        // Next session (old run, lazy backfill) tries again and succeeds.
        expect(
          await PlaceResolver(store: store, gateway: gw).ensure(r.id),
          'Albert Park',
        );
      },
    );

    test('stops asking after three failed sessions', () async {
      final r = freeRunFile(n: 1, start: d1);
      await store.importBundles([engine.RunBundle(run: r)]);
      final gw = FakePlaceGateway(fails: true);
      for (var i = 0; i < 5; i++) {
        await PlaceResolver(store: store, gateway: gw).ensure(r.id);
      }
      expect(gw.calls, hasLength(3));
      expect((await store.load(r.id))!.sidecar.placeTries, 3);
    });

    test(
      'a geocoder that never answers times out and frees the slot',
      () async {
        final r = freeRunFile(n: 1, start: d1);
        await store.importBundles([engine.RunBundle(run: r)]);
        final gw = FakePlaceGateway(name: 'Albert Park', hangs: true);
        final places = PlaceResolver(
          store: store,
          gateway: gw,
          timeout: const Duration(milliseconds: 50),
        );
        expect(await places.ensure(r.id), isNull);
        expect((await store.load(r.id))!.sidecar.placeTries, 1);
        // Another run is not stalled behind it.
        final b = freeRunFile(n: 2, start: d1.add(const Duration(days: 1)));
        await store.importBundles([engine.RunBundle(run: b)]);
        gw.hangs = false;
        expect(await places.ensure(b.id), 'Albert Park');
      },
    );

    test('finish records the UTC offset once; old runs have none', () async {
      final r = freeRunFile(n: 1, start: d1);
      await store.importBundles([engine.RunBundle(run: r)]);
      expect((await store.list()).single.utcOffsetMin, isNull);
      final places = PlaceResolver(
        store: store,
        gateway: FakePlaceGateway(name: 'Albert Park'),
      );
      final at = DateTime.parse('2026-09-10T08:00:00+10:00');
      await places.onFinished(r.id, now: at);
      await store.setUtcOffset(r.id, 0);
      final s = (await store.list()).single;
      expect(s.utcOffsetMin, at.timeZoneOffset.inMinutes);
      expect(s.place, 'Albert Park');
    });

    test('a coordinate-looking answer is never stored', () async {
      final r = freeRunFile(n: 1, start: d1);
      await store.importBundles([engine.RunBundle(run: r)]);
      final places = PlaceResolver(
        store: store,
        gateway: FakePlaceGateway(name: '-33.86, 151.20'),
      );
      expect(await places.ensure(r.id), isNull);
      expect((await store.load(r.id))!.sidecar.place, isNull);
    });

    test('an indoor run has no start, so no place and no lookup', () async {
      final r = fourByFourFile(n: 1, start: d1, indoor: true);
      await store.importBundles([engine.RunBundle(run: r)]);
      final gw = FakePlaceGateway(name: 'Albert Park');
      expect(
        await PlaceResolver(store: store, gateway: gw).ensure(r.id),
        isNull,
      );
      expect(gw.calls, isEmpty);
    });

    test('rename survives a recalculation and clears with null', () async {
      final r = fourByFourFile(n: 1, start: d1);
      await store.importBundles([engine.RunBundle(run: r)]);
      await store.setTitle(r.id, 'Hill day');
      expect((await store.list()).single.customTitle, 'Hill day');
      // A fix-laps style edit unfreezes and recomputes the verdict.
      await store.setOverride(r.id, RecordMode.laps);
      await store.setOverride(r.id, null);
      expect((await store.load(r.id))!.sidecar.title, 'Hill day');
      expect((await store.list()).single.customTitle, 'Hill day');
      await store.setTitle(r.id, null);
      expect((await store.list()).single.customTitle, isNull);
    });
  });

  group('IndexRow migration', () {
    test('a version-4 row (no identity fields) still reads', () {
      final row = IndexRow.fromJson({
        'v': 4,
        'laps': 8,
        'session': null,
        'verdict': null,
        'reps': null,
        'work_s_per_km': null,
        'fade_s_per_km': null,
        'recovery_s_per_km': null,
        'rep_paces_s_per_km': <Object?>[],
        'rep_clean': <Object?>[],
        'eligible': false,
        'cooper': null,
        'goal': null,
      })!;
      expect(row.version, 4);
      expect(row.place, isNull);
      expect(row.title, isNull);
      expect(row.startLat, isNull);
    });

    test('an old row is stale once, then identity round-trips', () async {
      final dir = Directory.systemTemp.createTempSync('runsolo-idx-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FileRunStore(Directory('${dir.path}/runs'));
      final r = freeRunFile(n: 1, start: DateTime.utc(2026, 9, 10, 6));
      await store.importBundles([engine.RunBundle(run: r)]);
      await store.setPlace(r.id, 'Albert Park');
      await store.list();
      await store.derivedIdle;
      final text = store.indexFile.readAsStringSync();
      // Rewrite the row as an older build left it.
      store.indexFile.writeAsStringSync(
        text.replaceAll('"v":${IndexRow.currentVersion}', '"v":4'),
      );
      final listed = (await store.list()).single;
      expect(listed.place, 'Albert Park');
      final e = (await store.readIndex()).entries[r.id]!;
      expect(e.row!.version, IndexRow.currentVersion);
      expect(e.row!.place, 'Albert Park');
      expect(e.row!.startLat, closeTo(-33.86, 0.01));
      await store.derivedIdle;
    });
  });
}
