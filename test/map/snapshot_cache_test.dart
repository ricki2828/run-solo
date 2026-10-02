@Timeout(Duration(seconds: 30))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/map/snapshot_cache.dart';

void main() {
  late Directory dir;
  late MapSnapshotCache cache;
  final png = Uint8List.fromList([1, 2, 3, 4]);

  String key({
    String id = 'run-1',
    int v = 1,
    String hash = 'abc',
    double w = 360,
    double h = 148,
    double dpr = 2.5,
  }) => MapSnapshotCache.keyFor(
    runId: id,
    styleVersion: v,
    routeHash: hash,
    width: w,
    height: h,
    pixelRatio: dpr,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('map_cache');
    cache = MapSnapshotCache(() async => dir);
  });
  tearDown(() => dir.delete(recursive: true));

  RouteGeometry route({double lat = -33.0, String label = '1'}) =>
      RouteGeometry(
        points: [GeoPoint(lat, 151.0), const GeoPoint(-33.01, 151.01)],
        markers: [
          RouteMarker(
            kind: RouteMarkerKind.lap,
            point: GeoPoint(lat, 151.0),
            label: label,
            lapIndex: 0,
          ),
        ],
        bounds: const GeoBounds(
          south: -33.01,
          west: 151.0,
          north: -33.0,
          east: 151.01,
        ),
      );

  test('key changes with run, style, route hash, size and dpr', () {
    final base = key();
    expect(key(id: 'run-2'), isNot(base));
    expect(key(v: 2), isNot(base));
    expect(key(hash: 'def'), isNot(base));
    expect(key(w: 400), isNot(base));
    expect(key(dpr: 3), isNot(base));
    expect(key(), base);
  });

  test('route fingerprint: stable, and changes with points or markers', () {
    expect(routeFingerprint(route()), routeFingerprint(route()));
    expect(
      routeFingerprint(route(lat: -33.001)),
      isNot(routeFingerprint(route())),
    );
    expect(
      routeFingerprint(route(label: '2')),
      isNot(routeFingerprint(route())),
    );
  });

  test('miss then hit, from disk on a fresh cache instance', () async {
    expect(await cache.read(key()), isNull);
    await cache.write(key(), png);
    expect(await cache.read(key()), png);
    final fresh = MapSnapshotCache(() async => dir);
    expect(await fresh.read(key()), png);
  });

  test('changed route or size is a miss', () async {
    await cache.write(key(), png);
    final fresh = MapSnapshotCache(() async => dir);
    expect(await fresh.read(key(hash: 'def')), isNull);
    expect(await fresh.read(key(w: 400)), isNull);
  });

  test('writing a new key prunes the same run only', () async {
    await cache.write(key(), png);
    await cache.write(key(id: 'run-2'), png);
    await cache.write(key(hash: 'def'), png);
    final fresh = MapSnapshotCache(() async => dir);
    expect(await fresh.read(key()), isNull);
    expect(await fresh.read(key(hash: 'def')), png);
    expect(await fresh.read(key(id: 'run-2')), png);
  });

  test('run id prefix is not confused by a longer id', () async {
    await cache.write(key(id: 'run-1'), png);
    await cache.write(key(id: 'run-12', v: 2), png);
    final fresh = MapSnapshotCache(() async => dir);
    expect(await fresh.read(key(id: 'run-1')), png);
  });

  test('size cap evicts least recently used first', () async {
    final big = Uint8List(400);
    final small = MapSnapshotCache(() async => dir, maxBytes: 1000);
    await small.write(key(id: 'a'), big);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await small.write(key(id: 'b'), big);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Touch a so b is now the oldest.
    final fresh1 = MapSnapshotCache(() async => dir, maxBytes: 1000);
    expect(await fresh1.read(key(id: 'a')), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await fresh1.write(key(id: 'c'), big);
    final fresh2 = MapSnapshotCache(() async => dir, maxBytes: 1000);
    expect(await fresh2.read(key(id: 'b')), isNull);
    expect(await fresh2.read(key(id: 'a')), isNotNull);
    expect(await fresh2.read(key(id: 'c')), isNotNull);
  });

  test(
    'orphans of deleted runs are removed; empty live set deletes nothing',
    () async {
      await cache.write(key(id: 'run-1'), png);
      await cache.write(key(id: 'run-2'), png);
      await cache.pruneOrphans({});
      var fresh = MapSnapshotCache(() async => dir);
      expect(await fresh.read(key(id: 'run-2')), png);
      await cache.pruneOrphans({'run-1'});
      fresh = MapSnapshotCache(() async => dir);
      expect(await fresh.read(key(id: 'run-1')), png);
      expect(await fresh.read(key(id: 'run-2')), isNull);
    },
  );

  test('stray temp files are swept on first use', () async {
    final tmp = File('${dir.path}/run-1_v1_abc_1x1@1.00.tmp')
      ..writeAsBytesSync([9]);
    await cache.read(key());
    expect(tmp.existsSync(), isFalse);
  });

  test('retry cap: 3 transient failures persist across app opens', () async {
    final k = key();
    expect(await cache.mayRender(k), isTrue);
    for (var i = 0; i < 3; i++) {
      // A new instance = a new app open: session block is gone.
      final open = MapSnapshotCache(() async => dir);
      expect(await open.mayRender(k), isTrue, reason: 'try ${i + 1}');
      await open.recordFailure(k, MapFailure.transient);
      expect(await open.mayRender(k), isFalse, reason: 'same session');
    }
    final next = MapSnapshotCache(() async => dir);
    expect(await next.mayRender(k), isFalse);
    // Other size, same run + route: same record. Changed route: fresh.
    expect(await next.mayRender(key(w: 400)), isFalse);
    expect(await next.mayRender(key(hash: 'def')), isTrue);
  });

  test('blank snapshot backs off 7 days, then may retry', () async {
    final k = key();
    final t0 = DateTime(2026, 10, 1);
    await cache.recordFailure(k, MapFailure.blank, now: t0);
    final next = MapSnapshotCache(() async => dir);
    expect(
      await next.mayRender(k, now: t0.add(const Duration(days: 6))),
      isFalse,
    );
    expect(
      await next.mayRender(k, now: t0.add(const Duration(days: 8))),
      isTrue,
    );
  });

  test(
    'transient failure retries on the next open, not within 7 days gate',
    () async {
      final k = key();
      await cache.recordFailure(k, MapFailure.transient);
      final next = MapSnapshotCache(() async => dir);
      expect(await next.mayRender(k), isTrue);
    },
  );

  test('permanent failure blocks this session only, never persisted', () async {
    final k = key();
    await cache.recordFailure(k, MapFailure.permanent);
    expect(await cache.mayRender(k), isFalse);
    final next = MapSnapshotCache(() async => dir);
    expect(await next.mayRender(k), isTrue);
  });

  test('success clears the failure record', () async {
    final k = key();
    await cache.recordFailure(k, MapFailure.transient);
    await cache.clearFailures(k);
    final next = MapSnapshotCache(() async => dir);
    expect(await next.mayRender(k), isTrue);
  });

  test('unusable directory is a miss, never a throw', () async {
    final bad = MapSnapshotCache(() async => throw const FileSystemException());
    expect(await bad.read('k'), isNull);
    await bad.write('k', png);
    expect(await bad.mayRender('k_v1_a_1x1@1.00'), isTrue);
    await bad.recordFailure('k', MapFailure.transient);
  });
}
