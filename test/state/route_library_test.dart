import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/route_library.dart';

import '../route_fixtures.dart';
import '../run_fixtures.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 2, 8);

  RouteLibrary library([RouteStore? store]) =>
      RouteLibrary(store ?? MemoryRouteStore(), now: () => t0);

  group('CRUD', () {
    test('imports a GPX file as a route and lists it', () async {
      final lib = library();
      final r = await lib.importText(gpxText(name: 'Park hill'));
      expect(r.name, 'Park hill');
      // The fixture's track weaves a little either side of due north.
      expect(r.distanceM, inInclusiveRange(3000, 3600));
      expect(r.climbM, closeTo(100, 8));
      expect(lib.routes.map((e) => e.id), [r.id]);
      expect(lib.byId(r.id), same(r));
    });

    test('the same file twice is one route', () async {
      final lib = library();
      final a = await lib.importText(gpxText());
      final b = await lib.importText(gpxText());
      expect(b.id, a.id);
      expect(lib.routes, hasLength(1));
    });

    test('a past run becomes a route under the run id', () async {
      final lib = library();
      final run = freeRunFile(n: 1, start: DateTime.utc(2026, 9, 24, 6));
      final r = await lib.addFromRun(run, name: 'Saturday loop');
      expect(r.id, 'run-${run.id}');
      expect(r.source, engine.RouteSource.run);
      expect((await lib.addFromRun(run)).id, r.id);
      expect(lib.routes, hasLength(1));
    });

    test('rename trims and clips; a blank name changes nothing', () async {
      final lib = library();
      final r = await lib.add(testRoute());
      await lib.rename(r.id, '  Long lunch loop  ');
      expect(lib.byId(r.id)!.name, 'Long lunch loop');
      await lib.rename(r.id, '   ');
      expect(lib.byId(r.id)!.name, 'Long lunch loop');
      await lib.rename(r.id, 'x' * 80);
      expect(lib.byId(r.id)!.name, hasLength(RouteLibrary.maxNameLength));
    });

    test('delete removes it and only it', () async {
      final lib = library();
      final a = await lib.add(testRoute(id: 'a', name: 'A'));
      final b = await lib.add(testRoute(id: 'b', name: 'B'));
      await lib.remove(a.id);
      expect(lib.routes.map((r) => r.id), ['b']);
      await lib.remove('missing');
      expect(lib.byId(b.id), isNotNull);
    });

    test('newest first, and the library is capped', () async {
      final lib = library();
      for (var i = 0; i < RouteLibrary.maxRoutes; i++) {
        await lib.add(
          engine.RouteBuilder.build(
            id: 'r$i',
            name: 'R$i',
            raw: routePoints(),
            source: engine.RouteSource.gpx,
            createdAt: t0.add(Duration(minutes: i)),
          ),
        );
      }
      expect(lib.routes.first.id, 'r${RouteLibrary.maxRoutes - 1}');
      expect(
        () => lib.add(testRoute(id: 'one-too-many')),
        throwsA(isA<RouteLibraryFull>()),
      );
    });

    test('a bad file is refused and nothing is added', () async {
      final lib = library();
      await expectLater(
        lib.importText('<gpx></gpx>'),
        throwsA(isA<engine.ImportFormatException>()),
      );
      expect(lib.routes, isEmpty);
    });
  });

  group('file store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('routes'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('routes survive a restart, with elevation', () async {
      final a = library(FileRouteStore(dir));
      final r = await a.importText(gpxText(name: 'Kept'));
      final b = library(FileRouteStore(dir));
      await b.load();
      expect(b.routes.single.id, r.id);
      expect(b.routes.single.name, 'Kept');
      expect(b.routes.single.climbM, closeTo(r.climbM!, 0.2));
      expect(b.routes.single.points.length, r.points.length);
    });

    test('delete is persisted', () async {
      final a = library(FileRouteStore(dir));
      final r = await a.add(testRoute());
      await a.remove(r.id);
      final b = library(FileRouteStore(dir));
      await b.load();
      expect(b.routes, isEmpty);
    });

    test(
      'a damaged file reads as no routes, a damaged route is skipped',
      () async {
        final store = FileRouteStore(dir);
        File('${dir.path}/routes.json').writeAsStringSync('{ nope');
        expect(await store.load(), isEmpty);
        await store.save([testRoute(id: 'ok')]);
        final text = File('${dir.path}/routes.json').readAsStringSync();
        File('${dir.path}/routes.json').writeAsStringSync(
          text.replaceFirst(
            '"routes":[',
            '"routes":[{"id":"bad","points":[]},',
          ),
        );
        expect((await store.load()).map((r) => r.id), ['ok']);
      },
    );
  });
}
