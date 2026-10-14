import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/topo/pack_manager.dart';
import 'package:run_solo/topo/pack_models.dart';

import 'fake_pack_server.dart';

void main() {
  contractTests();
  late FakePackServer server;
  late Directory dir;

  setUp(() async {
    server = await FakePackServer.start();
    dir = Directory.systemTemp.createTempSync('runsolo-topo-');
  });
  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  PackManager manager({int cap = kDefaultStorageCap, Uri? base}) => PackManager(
    root: Directory('${dir.path}/topo'),
    baseUrl: base ?? server.base,
    capBytes: cap,
    idleTimeout: const Duration(seconds: 5),
  );

  Future<PackManager> withIndex(
    List<Map<String, Object?>> regions, {
    int cap = kDefaultStorageCap,
  }) async {
    server.setIndex(regions);
    final m = manager(cap: cap);
    await m.load();
    await m.refreshRegions();
    return m;
  }

  File partOf(String id, String name) =>
      File('${dir.path}/topo/$id/$name.part');

  test('no network on load or on construction', () async {
    server.setIndex([server.addPack('milos')]);
    final m = manager();
    await m.load();
    expect(server.requests, isEmpty);
    expect(m.regions, isEmpty);
    await m.refreshRegions();
    expect(server.requests, ['/maps/regions.json']);
    expect(m.regions.single.id, 'milos');
  });

  test('every request names the app in User-Agent', () async {
    final m = await withIndex([server.addPack('milos')]);
    await m.download('milos');
    expect(server.userAgents, isNotEmpty);
    expect(
      server.userAgents.every((u) => u == 'RunSupreme/0.1.0+4 (Android)'),
      isTrue,
    );
  });

  test(
    'refresh is cached on disk and a new manager reads it offline',
    () async {
      server.setIndex([server.addPack('milos', name: 'Milos, Greece')]);
      final m = manager();
      await m.load();
      await m.refreshRegions();
      server.requests.clear();
      final again = manager();
      await again.load();
      expect(again.regions.single.name, 'Milos, Greece');
      expect(server.requests, isEmpty);
    },
  );

  test('no base url refuses every network call', () async {
    final none = PackManager(root: Directory('${dir.path}/topo'));
    await none.load();
    Matcher notConfigured() => throwsA(
      isA<PackException>().having(
        (e) => e.kind,
        'kind',
        PackErrorKind.notConfigured,
      ),
    );
    await expectLater(none.refreshRegions(), notConfigured());
    expect(none.regions, isEmpty);
    expect(server.requests, isEmpty);
  });

  test('a failed connection keeps its real cause in detail', () async {
    final m = PackManager(
      root: Directory('${dir.path}/topo'),
      baseUrl: server.base,
      clientFactory: _ThrowingClient.new,
    );
    await m.load();
    await expectLater(
      m.refreshRegions(),
      throwsA(
        isA<PackException>()
            .having(
              (e) => e.message,
              'message',
              'Could not reach the map server.',
            )
            .having(
              (e) => e.detail,
              'detail',
              'HandshakeException: certificate expired',
            ),
      ),
    );
    expect(m.refreshError?.detail, contains('HandshakeException'));
  });

  test('a bad index keeps the last good one', () async {
    final m = await withIndex([server.addPack('milos')]);
    server.files['/maps/regions.json'] = Uint8List.fromList(
      utf8.encode('{"regions":[{"id":"x"}]}'),
    );
    await expectLater(
      m.refreshRegions(),
      throwsA(
        isA<PackException>().having(
          (e) => e.kind,
          'kind',
          PackErrorKind.badIndex,
        ),
      ),
    );
    expect(m.regions.single.id, 'milos');
    expect(m.refreshError, isNotNull);
  });

  test('download installs: verified, renamed, no parts left', () async {
    final m = await withIndex([server.addPack('milos')]);
    expect(m.statusOf('milos').kind, PackStatusKind.notInstalled);
    expect(await m.download('milos'), isTrue);
    expect(m.statusOf('milos').kind, PackStatusKind.installed);
    final pack = m.installed.single;
    for (final f in m.regions.single.files) {
      expect(File(pack.pathOf(f.name)).lengthSync(), f.size);
      expect(partOf('milos', f.name).existsSync(), isFalse);
    }
    expect(m.usedBytes, greaterThanOrEqualTo(m.regions.single.totalBytes));
    // A new manager sees it without any network.
    server.requests.clear();
    final again = manager();
    await again.load();
    expect(again.installed.single.id, 'milos');
    expect(server.requests, isEmpty);
  });

  test(
    'installed.json is written last: nothing installed mid-download',
    () async {
      final m = await withIndex([server.addPack('milos')]);
      server.cutAfter = 1000;
      await expectLater(m.download('milos'), throwsA(isA<PackException>()));
      expect(m.installed, isEmpty);
      expect(
        File('${dir.path}/topo/milos/installed.json').existsSync(),
        isFalse,
      );
    },
  );

  test('resumes with a Range request after the connection is cut', () async {
    final m = await withIndex([server.addPack('milos', bytes: 400000)]);
    final first = m.regions.single.files.first;
    server.cutAfter = 150000;
    await expectLater(
      m.download('milos'),
      throwsA(
        isA<PackException>().having(
          (e) => e.kind,
          'kind',
          PackErrorKind.offline,
        ),
      ),
    );
    final kept = partOf('milos', first.name).lengthSync();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(first.size));
    expect(m.statusOf('milos').kind, PackStatusKind.failed);
    expect(m.statusOf('milos').partialBytes, kept);

    server.ranges.clear();
    expect(await m.download('milos'), isTrue);
    expect(server.ranges.first, 'bytes=$kept-');
    expect(
      File(m.installed.single.pathOf(first.name)).lengthSync(),
      first.size,
    );
  });

  test('resumes after the app was killed (a fresh manager)', () async {
    var m = await withIndex([server.addPack('milos', bytes: 400000)]);
    server.cutAfter = 100000;
    await expectLater(m.download('milos'), throwsA(isA<PackException>()));
    m.dispose();
    m = manager();
    await m.load();
    expect(m.statusOf('milos').partialBytes, greaterThan(0));
    server.ranges.clear();
    expect(await m.download('milos'), isTrue);
    expect(server.ranges.first, startsWith('bytes='));
    expect(m.installed.single.id, 'milos');
  });

  test('a server that ignores Range restarts the file from zero', () async {
    final m = await withIndex([server.addPack('milos', bytes: 200000)]);
    server.cutAfter = 50000;
    await expectLater(m.download('milos'), throwsA(isA<PackException>()));
    server.ignoreRange = true;
    expect(await m.download('milos'), isTrue);
    final f = m.regions.single.files.first;
    expect(File(m.installed.single.pathOf(f.name)).lengthSync(), f.size);
  });

  test('a corrupted file is rejected, discarded and never installed', () async {
    final entry = server.addPack('milos');
    final files = entry['files']! as List;
    (files[1] as Map<String, Object?>)['sha256'] = 'ab' * 32;
    final m = await withIndex([entry]);
    await expectLater(
      m.download('milos'),
      throwsA(
        isA<PackException>().having(
          (e) => e.kind,
          'kind',
          PackErrorKind.checksum,
        ),
      ),
    );
    expect(m.installed, isEmpty);
    expect(partOf('milos', 'terrain.pmtiles').existsSync(), isFalse);
    expect(
      File('${dir.path}/topo/milos/terrain.pmtiles').existsSync(),
      isFalse,
    );
    expect(m.statusOf('milos').kind, PackStatusKind.failed);
  });

  test('a 404 fails with an http error and keeps nothing installed', () async {
    final entry = server.addPack('milos');
    server.files.remove('/maps/milos/v1/terrain.pmtiles');
    final m = await withIndex([entry]);
    await expectLater(
      m.download('milos'),
      throwsA(
        isA<PackException>().having((e) => e.kind, 'kind', PackErrorKind.http),
      ),
    );
    expect(m.installed, isEmpty);
  });

  test('delete frees the space and the pack', () async {
    final m = await withIndex([server.addPack('milos')]);
    await m.download('milos');
    expect(m.usedBytes, greaterThan(0));
    await m.delete('milos');
    expect(m.installed, isEmpty);
    expect(m.usedBytes, 0);
    expect(Directory('${dir.path}/topo/milos').existsSync(), isFalse);
    expect(m.statusOf('milos').kind, PackStatusKind.notInstalled);
  });

  test('delete also clears a half-finished download', () async {
    final m = await withIndex([server.addPack('milos', bytes: 400000)]);
    server.cutAfter = 100000;
    await expectLater(m.download('milos'), throwsA(isA<PackException>()));
    expect(m.statusOf('milos').partialBytes, greaterThan(0));
    await m.delete('milos');
    expect(m.statusOf('milos').partialBytes, 0);
    expect(m.usedBytes, 0);
  });

  test(
    'version update: offered, replaces files, old files never mixed',
    () async {
      final m = await withIndex([server.addPack('milos', seed: 1)]);
      await m.download('milos');
      final old = File(m.installed.single.pathOf('basemap.pmtiles'))
          .readAsBytesSync();
      server.setIndex([server.addPack('milos', version: 'v2', seed: 9)]);
      await m.refreshRegions();
      expect(m.statusOf('milos').kind, PackStatusKind.updateAvailable);
      // The old pack keeps serving while the update is on offer.
      expect(m.packCovering(36.7, 24.4)!.version, 'v1');

      expect(await m.download('milos'), isTrue);
      expect(m.statusOf('milos').kind, PackStatusKind.installed);
      expect(m.installed.single.version, 'v2');
      final fresh = File(m.installed.single.pathOf('basemap.pmtiles'))
          .readAsBytesSync();
      expect(fresh, isNot(old));
      expect(fresh, server.files['/maps/milos/v2/basemap.pmtiles']);
    },
  );

  test(
    'a failed update leaves the old version installed and working',
    () async {
      final m = await withIndex([server.addPack('milos', seed: 1)]);
      await m.download('milos');
      final entry = server.addPack('milos', version: 'v2', seed: 9);
      server.files.remove('/maps/milos/v2/terrain.pmtiles');
      server.setIndex([entry]);
      await m.refreshRegions();
      await expectLater(m.download('milos'), throwsA(isA<PackException>()));
      expect(m.installed.single.version, 'v1');
      expect(m.packCovering(36.7, 24.4), isNotNull);
    },
  );

  test('a stale part from an older version is dropped, not resumed', () async {
    final m = await withIndex([server.addPack('milos', bytes: 400000)]);
    server.cutAfter = 100000;
    await expectLater(m.download('milos'), throwsA(isA<PackException>()));
    server.setIndex([server.addPack('milos', version: 'v2', seed: 5)]);
    await m.refreshRegions();
    server.ranges.clear();
    expect(await m.download('milos'), isTrue);
    expect(server.ranges.first, isNull);
    expect(m.installed.single.version, 'v2');
  });

  group('storage cap', () {
    test('refuses before any file is fetched, with the shortfall', () async {
      final m = await withIndex([server.addPack('milos')], cap: 100000);
      server.requests.clear();
      await expectLater(
        m.download('milos'),
        throwsA(
          isA<PackException>()
              .having((e) => e.kind, 'kind', PackErrorKind.storageCap)
              .having(
                (e) => e.bytes,
                'bytes',
                m.regions.single.totalBytes - 100000,
              ),
        ),
      );
      expect(server.requests, isEmpty);
      expect(m.installed, isEmpty);
    });

    test('counts what is already installed', () async {
      final a = server.addPack('a');
      final b = server.addPack('b', bbox: const [10, 10, 11, 11]);
      final total = regionOf(a).totalBytes;
      final m = await withIndex([a, b], cap: total + total ~/ 2);
      await m.download('a');
      await expectLater(
        m.download('b'),
        throwsA(
          isA<PackException>().having(
            (e) => e.kind,
            'kind',
            PackErrorKind.storageCap,
          ),
        ),
      );
      await m.delete('a');
      expect(await m.download('b'), isTrue);
    });

    test('an update does not count the files it replaces', () async {
      final a = server.addPack('a');
      final total = regionOf(a).totalBytes;
      final m = await withIndex([a], cap: total + 2000);
      await m.download('a');
      server.setIndex([server.addPack('a', version: 'v2', seed: 3)]);
      await m.refreshRegions();
      expect(await m.download('a'), isTrue);
    });
  });

  test('cancel keeps the partial and returns false', () async {
    final m = await withIndex([server.addPack('milos', bytes: 3000000)]);
    final done = m.download('milos');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    m.cancel('milos');
    expect(await done, isFalse);
    expect(m.installed, isEmpty);
    expect(m.statusOf('milos').kind, PackStatusKind.notInstalled);
    expect(await m.download('milos'), isTrue);
  });

  test('progress reaches the total and never exceeds it', () async {
    final m = await withIndex([server.addPack('milos')]);
    final seen = <double>[];
    m.addListener(() {
      final s = m.statusOf('milos');
      if (s.kind == PackStatusKind.downloading) seen.add(s.progress);
    });
    await m.download('milos');
    expect(seen, isNotEmpty);
    expect(seen.every((p) => p >= 0 && p <= 1), isTrue);
  });

  test('a pack that lost a file is not installed', () async {
    final m = await withIndex([server.addPack('milos')]);
    await m.download('milos');
    File('${dir.path}/topo/milos/terrain.pmtiles').deleteSync();
    final again = manager();
    await again.load();
    expect(again.installed, isEmpty);
    expect(again.packCovering(36.7, 24.4), isNull);
  });

  test('packCovering: inside, outside, and the tightest box wins', () async {
    final big = server.addPack('big', bbox: const [20, 30, 30, 40]);
    final small = server.addPack('small', bbox: const [24, 36, 25, 37]);
    final m = await withIndex([big, small]);
    await m.download('big');
    expect(m.packCovering(36.5, 24.5)!.id, 'big');
    await m.download('small');
    expect(m.packCovering(36.5, 24.5)!.id, 'small');
    expect(m.packCovering(39, 21)!.id, 'big');
    expect(m.packCovering(50, 5), isNull);
    expect(server.requests.where((r) => r.contains('regions')).length, 1);
  });

  test('pack ids and file names cannot escape the pack folder', () {
    final bad = {
      'id': '../x',
      'name': 'x',
      'bbox': [0, 0, 1, 1],
      'version': '1',
      'files': [
        {'name': 'a.pmtiles', 'size': 1, 'sha256': 'a'},
      ],
    };
    expect(() => PackRegion.fromJson(bad), throwsFormatException);
    bad['id'] = 'x';
    bad['files'] = [
      {'name': '../a', 'size': 1, 'sha256': 'a'},
    ];
    expect(() => PackRegion.fromJson(bad), throwsFormatException);
  });
}

void contractTests() {
  test('regions.json from tools/topo/make_regions_json.py parses', () {
    final j = jsonDecode(
      File('test/topo/fixtures/regions_milos.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(j['schema'], 1);
    final r = PackRegion.fromJson(
      ((j['regions']! as List).single as Map).cast<String, Object?>(),
    );
    expect(r.id, 'milos');
    expect(r.name, 'Milos, Greece');
    expect(r.files.map((f) => f.name).toSet(), {
      'basemap.pmtiles',
      'terrain.pmtiles',
      'contours.pmtiles',
    });
    expect(r.totalBytes, 3122553);
    expect(r.mapText, contains('OpenStreetMap'));
    expect(r.credits.length, greaterThanOrEqualTo(3));
    expect(r.contains(36.7, 24.4), isTrue);
  });
}

/// An HttpClient whose connection always fails the way a bad phone network
/// does.
class _ThrowingClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      Future.error(const HandshakeException('certificate expired'));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
