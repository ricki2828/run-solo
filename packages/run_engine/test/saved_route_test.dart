import 'dart:convert';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Points on a line going east from the Sydney CBD, [stepM] apart, with an
/// optional elevation (metres) from the distance along it.
List<List<double?>> _line(
  int n, {
  double stepM = 10,
  double? Function(double distM)? ele,
}) {
  const lat0 = -33.8688;
  const lon0 = 151.2093;
  final kLon = 111320 * math.cos(lat0 * math.pi / 180);
  return [
    for (var i = 0; i < n; i++)
      [lat0, lon0 + i * stepM / kLon, ele?.call(i * stepM)],
  ];
}

String _gpxRoute(List<List<double?>> pts, {String name = 'Hill loop'}) {
  final b = StringBuffer(
    '<?xml version="1.0"?><gpx version="1.1" creator="t"><metadata><name>meta</name></metadata><rte><name>$name</name>',
  );
  for (final p in pts) {
    b.write('<rtept lat="${p[0]}" lon="${p[1]}">');
    if (p[2] != null) b.write('<ele>${p[2]}</ele>');
    b.write('</rtept>');
  }
  b.write('</rte></gpx>');
  return b.toString();
}

String _gpxTrack(List<List<double?>> pts) {
  final b = StringBuffer('<gpx version="1.1" creator="watch"><trk><trkseg>');
  var t = DateTime.utc(2026, 9, 1, 6);
  for (final p in pts) {
    b.write('<trkpt lat="${p[0]}" lon="${p[1]}">');
    if (p[2] != null) b.write('<ele>${p[2]}</ele>');
    b.write('<time>${t.toIso8601String()}</time></trkpt>');
    t = t.add(const Duration(seconds: 3));
  }
  b.write('</trkseg></trk></gpx>');
  return b.toString();
}

String _tcx(List<List<double?>> pts) {
  final b = StringBuffer(
    '<TrainingCenterDatabase><Courses><Course><Name>Park loop</Name><Track>',
  );
  for (final p in pts) {
    b.write(
      '<Trackpoint><Position><LatitudeDegrees>${p[0]}</LatitudeDegrees><LongitudeDegrees>${p[1]}</LongitudeDegrees></Position>',
    );
    if (p[2] != null) b.write('<AltitudeMeters>${p[2]}</AltitudeMeters>');
    b.write('</Trackpoint>');
  }
  b.write('</Track></Course></Courses></TrainingCenterDatabase>');
  return b.toString();
}

void main() {
  const importer = RouteImporter();
  final now = DateTime.utc(2026, 10, 2, 8);

  group('GPX', () {
    test('a planned route imports with its name, distance and climb', () {
      // 1 km east, rising 60 m over the way.
      final r = importer.fromGpx(
        _gpxRoute(_line(101, ele: (d) => d * 0.06)),
        now: now,
      );
      expect(r.name, 'Hill loop');
      expect(r.source, RouteSource.gpx);
      expect(r.distanceM, closeTo(1000, 5));
      expect(r.climbM, closeTo(60, 4));
      expect(r.hasElevation, isTrue);
      expect(r.startLat, closeTo(-33.8688, 1e-6));
      expect(r.createdAt, now);
    });

    test('a recorded track imports without needing a route element', () {
      final r = importer.fromGpx(_gpxTrack(_line(101)), now: now);
      expect(r.distanceM, closeTo(1000, 5));
      expect(r.climbM, isNull);
      expect(r.name, 'Imported route');
      expect(r.elevM, isNull);
    });

    test('a long, jittery track is simplified under the point cap', () {
      final rnd = math.Random(3);
      final pts = _line(6000, stepM: 5)
        ..forEach((p) => p[0] = p[0]! + (rnd.nextDouble() - 0.5) * 2e-5);
      final r = importer.fromGpx(_gpxTrack(pts), now: now);
      expect(r.points.length, lessThanOrEqualTo(SavedRoute.maxPoints));
      expect(r.distanceM, closeTo(30000, 600));
    });

    test('the same file is the same route id', () {
      final text = _gpxRoute(_line(101));
      expect(importer.fromGpx(text).id, importer.fromGpx(text).id);
      expect(importer.fromGpx(text).id, isNot(importer.fromGpx('$text ').id));
    });

    test('a route with elevation on only some points fills the gaps', () {
      final pts = _line(101, ele: (d) => d * 0.05);
      pts[40][2] = null;
      pts[41][2] = null;
      final r = importer.fromGpx(_gpxRoute(pts), now: now);
      expect(r.hasElevation, isTrue);
      expect(r.elevM!.every((e) => e.isFinite), isTrue);
    });

    test('mostly missing elevation means no elevation at all', () {
      final pts = _line(101, ele: (d) => d * 0.05);
      for (var i = 0; i < 101; i += 2) {
        pts[i][2] = null;
      }
      expect(importer.fromGpx(_gpxRoute(pts), now: now).climbM, isNull);
    });

    test('too short, not XML and no points are refused', () {
      expect(
        () => importer.fromGpx(_gpxRoute(_line(10))),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        () => importer.fromGpx('not xml <'),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        () => importer.fromGpx('<gpx></gpx>'),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('a stop (repeated position) does not count', () {
      final pts = _line(101);
      final stopped = [
        ...pts.sublist(0, 50),
        for (var i = 0; i < 30; i++) List.of(pts[49]),
        ...pts.sublist(50),
      ];
      expect(
        importer.fromGpx(_gpxTrack(stopped), now: now).distanceM,
        closeTo(1000, 5),
      );
    });
  });

  test('TCX trackpoints import, named by the course', () {
    final r = importer.fromTcx(
      _tcx(_line(101, ele: (d) => d * 0.03)),
      now: now,
    );
    expect(r.name, 'Park loop');
    expect(r.source, RouteSource.tcx);
    expect(r.distanceM, closeTo(1000, 5));
    expect(r.climbM, closeTo(30, 3));
  });

  test('fromFile picks the format from the content', () {
    expect(importer.fromFile(_tcx(_line(101))).source, RouteSource.tcx);
    expect(importer.fromFile(_gpxRoute(_line(101))).source, RouteSource.gpx);
  });

  group('from a past run', () {
    test('uses the fixes in order and the run id', () {
      final run = fixture('easy_free_run').run;
      final r = importer.fromRun(run, name: 'Saturday loop', now: now);
      expect(r.id, 'run-${run.id}');
      expect(r.name, 'Saturday loop');
      expect(r.source, RouteSource.run);
      expect(r.distanceM, greaterThan(SavedRoute.minDistanceM));
      expect(r.points.first.lat, closeTo(run.samples.first.lat!, 1e-5));
    });

    test('an indoor run with no fixes cannot be a route', () {
      final run = fixture('easy_free_run').run;
      final indoor = run.copyWith(
        samples: [
          for (final s in run.samples)
            Sample(tMs: s.tMs, distM: s.distM, hr: s.hr),
        ],
      );
      expect(
        () => importer.fromRun(indoor),
        throwsA(isA<ImportFormatException>()),
      );
    });
  });

  group('JSON', () {
    test('round trips with and without elevation', () {
      for (final text in [
        _gpxRoute(_line(101, ele: (d) => d * 0.04)),
        _gpxRoute(_line(101)),
      ]) {
        final r = importer.fromGpx(text, now: now);
        final back = SavedRoute.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
        );
        expect(back.id, r.id);
        expect(back.name, r.name);
        expect(back.distanceM, closeTo(r.distanceM, 0.1));
        expect(back.climbM?.round(), r.climbM?.round());
        expect(back.points.length, r.points.length);
        expect(back.createdAt, r.createdAt);
      }
    });

    test('a damaged record throws a FormatException', () {
      expect(
        () => SavedRoute.fromJson({'points': []}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('the recorder gets flat lat/lon and one elevation per point', () {
    final r = importer.fromGpx(
      _gpxRoute(_line(101, ele: (d) => d * 0.03)),
      now: now,
    );
    expect(r.latLon.length, r.points.length * 2);
    expect(r.elevM!.length, r.points.length);
  });
}
