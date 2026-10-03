import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Schema 7: the route a run followed, kept in the run file.
void main() {
  final dir = Directory('test/fixtures/contract');
  RunFile load(String path) =>
      RunFileCodec.decode(File(path).readAsStringSync());

  group('from the Kotlin writer', () {
    final run = load('${dir.path}/followed_route.json');

    test('the planned route and the one off-route span', () {
      expect(run.readSchema, 7);
      final r = run.route!;
      expect(r.id, 'contract-route');
      expect(r.name, 'Park loop');
      expect(r.points, hasLength(101));
      expect(r.hasElevation, isTrue);
      expect(r.points.first.lat, closeTo(-33.8688, 1e-6));
      expect(r.offRouteCount, 1);
      expect(r.offRoute.single.t0Ms, 120000);
      expect(r.offRoute.single.t1Ms, 157000);
      expect(r.offRouteMs, 37000);
    });

    test('it survives a re-encode and decode, byte for byte', () {
      final once = RunFileCodec.encode(run);
      final back = RunFileCodec.decode(once);
      expect(RunFileCodec.encode(back), once);
      expect(back.route!.offRoute.single.t1Ms, 157000);
      expect(back.route!.points.length, run.route!.points.length);
    });

    test('copyWith keeps it, and can drop it', () {
      expect(run.copyWith(mode: RunMode.trail).route, isNotNull);
      expect(run.copyWith(route: null).route, isNull);
    });

    test('analysis is unchanged by it: a free run is a free run', () {
      final a = engine.analyze(run, now: fixedNow);
      expect(a.mode, RunMode.free);
    });

    test('Run this route again prefers the stored planned route', () {
      final saved = const RouteImporter().fromFollowed(
        run.route!,
        now: DateTime.utc(2026, 10, 3),
      );
      expect(saved.id, 'contract-route');
      expect(saved.name, 'Park loop');
      expect(saved.distanceM, closeTo(1000, 5));
      expect(saved.climbM, isNotNull);
    });
  });

  group('older files', () {
    test('every frozen schema-6 file reads with no route', () {
      final files = Directory('${dir.path}/schema6')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'));
      expect(files, isNotEmpty);
      for (final f in files) {
        final run = load(f.path);
        expect(run.readSchema, 6, reason: f.path);
        expect(run.route, isNull, reason: f.path);
      }
    });

    test('a run with no route writes no route key', () {
      final run = load('${dir.path}/free_run_no_laps.json');
      expect(run.route, isNull);
      expect(
        (jsonDecode(RunFileCodec.encode(run)) as Map).containsKey('route'),
        isFalse,
      );
    });
  });

  group('strictness', () {
    Map<String, Object?> base() =>
        jsonDecode(File('${dir.path}/followed_route.json').readAsStringSync())
            as Map<String, Object?>;

    test('an unknown key inside the route is a newer file', () {
      final j = base();
      (j['route'] as Map<String, Object?>)['extra'] = 1;
      expect(
        () => RunFile.fromJson(j),
        throwsA(isA<RunFileNewerVersionException>()),
      );
    });

    test('a route with one point or a bad point is refused', () {
      final j = base();
      (j['route'] as Map<String, Object?>)['pts'] = [
        [1.0, 2.0],
      ];
      expect(() => RunFile.fromJson(j), throwsA(isA<RunFileFormatException>()));
      final k = base();
      (k['route'] as Map<String, Object?>)['pts'] = [
        [1.0, 2.0],
        ['x', 2.0],
      ];
      expect(() => RunFile.fromJson(k), throwsA(isA<RunFileFormatException>()));
    });
  });
}
