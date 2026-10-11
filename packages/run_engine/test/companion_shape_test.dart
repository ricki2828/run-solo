import 'dart:convert';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// A closed, lopsided loop in flat metres (longer than wide, not a circle, so
/// its principal axis is clear and its start is not symmetric).
List<(double, double)> loopMetres({int n = 400, double scale = 1}) => [
  for (var i = 0; i <= n; i++)
    (
      scale *
          (600 * math.cos(2 * math.pi * i / n) +
              60 * math.sin(6 * 2 * math.pi * i / n)),
      scale *
          (230 * math.sin(2 * math.pi * i / n) +
              40 * math.cos(3 * 2 * math.pi * i / n)),
    ),
];

/// Flat metres around ([lat], [lon]) as GPS samples, 1 s apart, optionally
/// turned by [turn] radians first.
List<Sample> gps(
  List<(double, double)> metres, {
  double lat = 1.3521,
  double lon = 103.8198,
  double turn = 0,
  double? acc,
}) {
  final c = math.cos(turn), s = math.sin(turn);
  final kx = 111320.0 * math.cos(lat * math.pi / 180);
  return [
    for (var i = 0; i < metres.length; i++)
      Sample(
        tMs: i * 1000,
        lat: lat - (metres[i].$1 * s + metres[i].$2 * c) / 110540.0,
        lon: lon + (metres[i].$1 * c - metres[i].$2 * s) / kx,
        accM: acc,
        distM: i * 3.0,
      ),
  ];
}

/// routeShape with the end trim off, for tests of the normalisation alone.
List<List<int>>? shapeNoTrim(Iterable<Sample> s) =>
    routeShape(s, trimMinM: 0, trimMaxM: 0);

int longestSide(List<List<int>> r) {
  final xs = r.map((p) => p[0]), ys = r.map((p) => p[1]);
  return math.max(
    xs.reduce(math.max) - xs.reduce(math.min),
    ys.reduce(math.max) - ys.reduce(math.min),
  );
}

void main() {
  group('Douglas-Peucker', () {
    test('a straight line is two points; a corner is kept', () {
      final line = [for (var i = 0; i < 50; i++) (i * 1.0, i * 2.0)];
      expect(douglasPeucker(line, 0.01), [(0.0, 0.0), (49.0, 98.0)]);
      final corner = [
        for (var i = 0; i <= 10; i++) (i * 1.0, 0.0),
        for (var i = 1; i <= 10; i++) (10.0, i * 1.0),
      ];
      expect(douglasPeucker(corner, 0.01), [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0, 10.0),
      ]);
    });

    test('keeps points further than epsilon, drops those within it', () {
      final bump = [
        (0.0, 0.0),
        (5.0, 0.4),
        (10.0, 0.0),
        (15.0, 3.0),
        (20.0, 0.0),
      ];
      expect(douglasPeucker(bump, 2.5).map((p) => p.$1), [0.0, 15.0, 20.0]);
      expect(douglasPeucker(bump, 1).map((p) => p.$1), [0.0, 10.0, 15.0, 20.0]);
      expect(douglasPeucker(bump, 0.1), bump);
    });

    test('a closed loop keeps its far side', () {
      final ring = [
        for (var i = 0; i <= 60; i++)
          (math.cos(2 * math.pi * i / 60), math.sin(2 * math.pi * i / 60)),
      ];
      final out = douglasPeucker(ring, 0.05);
      expect(out.first, ring.first);
      expect(out.last, ring.last);
      expect(out.length, greaterThan(6));
      expect(out.any((p) => p.$1 < -0.9), isTrue);
    });

    test('a very long track does not overflow the stack', () {
      final wiggle = [
        for (var i = 0; i < 200000; i++) (i * 1.0, math.sin(i / 3) * 10),
      ];
      expect(douglasPeucker(wiggle, 0.5).length, lessThan(wiggle.length));
    });

    test('always the same answer for the same track', () {
      final a = douglasPeucker(loopMetres(), 3);
      final b = douglasPeucker(loopMetres(), 3);
      expect(a, b);
    });
  });

  group('simplifyTo', () {
    test('never more than the cap, ends kept, a noisy long track fits', () {
      final rnd = math.Random(5);
      final noisy = [
        for (final p in loopMetres(n: 6000))
          (p.$1 + rnd.nextDouble() * 4, p.$2 + rnd.nextDouble() * 4),
      ];
      for (final cap in [120, 60, 20, 5]) {
        final out = simplifyTo(noisy, cap);
        expect(out.length, lessThanOrEqualTo(cap), reason: 'cap $cap');
        expect(out.length, greaterThanOrEqualTo(2));
        expect(out.first, noisy.first);
        expect(out.last, noisy.last);
      }
    });

    test('a short track is left alone', () {
      final few = [(0.0, 0.0), (1.0, 5.0), (2.0, 0.0)];
      expect(simplifyTo(few, 120), few);
    });
  });

  group('normalise', () {
    test('corner at zero, longer side exactly the grid, whole numbers', () {
      final out = normaliseToGrid([(-40.0, 12.0), (60.0, 12.0), (60.0, 52.0)])!;
      expect(out, [
        [0, 0],
        [255, 0],
        [255, 102],
      ]);
      expect(out.expand((p) => p), everyElement(isA<int>()));
    });

    test('a vertical line scales on y; a single point is nothing', () {
      expect(normaliseToGrid([(3.0, 1.0), (3.0, 9.0)]), [
        [0, 0],
        [0, 255],
      ]);
      expect(normaliseToGrid([(3.0, 1.0), (3.0, 1.0)]), isNull);
      expect(normaliseToGrid([(3.0, 1.0)]), isNull);
    });

    test('points that land on the same cell are not repeated', () {
      final out = normaliseToGrid([
        (0.0, 0.0),
        (0.1, 0.0),
        (0.2, 0.0),
        (1000.0, 0.0),
      ])!;
      expect(out, [
        [0, 0],
        [255, 0],
      ]);
    });
  });

  group('routeShape', () {
    final route = shapeNoTrim(gps(loopMetres()))!;

    test(
      'at most 120 points, whole numbers on the grid, touching the corner',
      () {
        expect(route.length, inInclusiveRange(2, kRouteMaxPoints));
        for (final p in route) {
          expect(p, hasLength(2));
          for (final c in p) {
            expect(c, isA<int>());
            expect(c, inInclusiveRange(0, kRouteGrid));
          }
        }
        expect(route.map((p) => p[0]).reduce(math.min), 0);
        expect(route.map((p) => p[1]).reduce(math.min), 0);
        expect(longestSide(route), kRouteGrid);
      },
    );

    test('a long, busy track still comes out at 120 points or fewer', () {
      final rnd = math.Random(2);
      final busy = [
        for (final p in loopMetres(n: 7000))
          (p.$1 + rnd.nextDouble() * 6, p.$2 + rnd.nextDouble() * 6),
      ];
      final r = shapeNoTrim(gps(busy))!;
      expect(r.length, lessThanOrEqualTo(kRouteMaxPoints));
      expect(longestSide(r), kRouteGrid);
    });

    // The shape is all that leaves the phone: where it was, how big it was and
    // which way it faced do not.
    test('the same run in another city gives the same shape', () {
      final akl = shapeNoTrim(gps(loopMetres(), lat: -36.85, lon: 174.76))!;
      final nyc = shapeNoTrim(gps(loopMetres(), lat: 40.71, lon: -74.0))!;
      expect(akl.length, route.length);
      expect(nyc.length, route.length);
      for (var i = 0; i < route.length; i++) {
        for (var k = 0; k < 2; k++) {
          expect((akl[i][k] - route[i][k]).abs(), lessThanOrEqualTo(2));
          expect((nyc[i][k] - route[i][k]).abs(), lessThanOrEqualTo(2));
        }
      }
    });

    test('the same loop at three times the size gives the same shape', () {
      final big = shapeNoTrim(gps(loopMetres(scale: 3)))!;
      expect(big.length, route.length);
      for (var i = 0; i < route.length; i++) {
        for (var k = 0; k < 2; k++) {
          expect((big[i][k] - route[i][k]).abs(), lessThanOrEqualTo(2));
        }
      }
    });

    test(
      'north is not in it: the loop run facing any way gives the same shape',
      () {
        for (final turn in [math.pi / 2, math.pi, 2.1, -0.7]) {
          final r = shapeNoTrim(gps(loopMetres(), turn: turn))!;
          expect(r.length, route.length, reason: 'turn $turn');
          for (var i = 0; i < route.length; i++) {
            for (var k = 0; k < 2; k++) {
              expect(
                (r[i][k] - route[i][k]).abs(),
                lessThanOrEqualTo(2),
                reason: 'turn $turn point $i',
              );
            }
          }
        }
      },
    );

    test('no coordinate leaves the phone: nothing in the output is a latitude, a longitude or a fraction', () {
      final json = jsonEncode(route);
      expect(json, isNot(contains('.')));
      expect(json, isNot(contains('103')));
      expect(json, isNot(contains('1.35')));
      // Every number is a whole number a byte can hold.
      for (final n in RegExp(r'\d+').allMatches(json)) {
        expect(int.parse(n[0]!), lessThanOrEqualTo(255));
      }
    });

    test('the way runs left to right', () {
      final first = route.take(route.length ~/ 3).map((p) => p[0]);
      final last = route.reversed.take(route.length ~/ 3).map((p) => p[0]);
      double mean(Iterable<int> xs) => xs.reduce((a, b) => a + b) / xs.length;
      expect(mean(first), lessThanOrEqualTo(mean(last)));
    });

    test('a treadmill or a standing still has no shape', () {
      expect(
        routeShape([
          for (var i = 0; i < 100; i++) Sample(tMs: i * 1000, distM: i * 3.0),
        ]),
        isNull,
      );
      final drift = gps([
        for (var i = 0; i < 100; i++) (i % 5 * 1.0, i % 3 * 1.0),
      ]);
      expect(routeShape(drift), isNull);
      expect(routeShape(gps([(0.0, 0.0)])), isNull);
      expect(routeShape(const []), isNull);
    });

    test('fixes with poor accuracy are left out', () {
      expect(routeShape(gps(loopMetres(), acc: 80)), isNull);
      final mixed = gps(loopMetres());
      final spoiled = [
        for (var i = 0; i < mixed.length; i++)
          i % 7 == 0
              ? Sample(
                  tMs: mixed[i].tMs,
                  lat: 1.9,
                  lon: 104.5,
                  accM: 120,
                  distM: mixed[i].distM,
                )
              : mixed[i],
      ];
      final r = shapeNoTrim(spoiled)!;
      expect(longestSide(r), kRouteGrid);
      // The spoiled fixes would have stretched the shape a long way; left out,
      // it is the same loop (same height, give or take the thinned points).
      int high(List<List<int>> x) => x.map((p) => p[1]).reduce(math.max);
      expect((high(r) - high(route)).abs(), lessThan(8));
    });
  });

  group('the ends are cut off (home privacy zone)', () {
    double along(List<Pt> pts, int upTo) {
      var d = 0.0;
      for (var i = 1; i <= upTo; i++) {
        d += math.sqrt(
          math.pow(pts[i].$1 - pts[i - 1].$1, 2) +
              math.pow(pts[i].$2 - pts[i - 1].$2, 2),
        );
      }
      return d;
    }

    test('trimEnds: first and last kept points are at least the trim away along the track', () {
      final track = loopMetres();
      final total = along(track, track.length - 1);
      for (final (a, b) in [(150.0, 150.0), (300.0, 160.0), (210.5, 299.9)]) {
        final out = trimEnds(track, a, b);
        final i0 = track.indexOf(out.first);
        final i1 = track.indexOf(out.last);
        expect(along(track, i0), greaterThanOrEqualTo(a));
        expect(total - along(track, i1), greaterThanOrEqualTo(b));
        expect(out.length, lessThan(track.length));
      }
    });

    test('a track shorter than both trims has no shape', () {
      expect(
        trimEnds([for (var i = 0; i < 50; i++) (i * 5.0, 0.0)], 150, 150),
        isEmpty,
      );
      final short = gps([for (var i = 0; i < 100; i++) (i * 4.0, 0.0)]);
      expect(
        routeShape(short, trimMinM: 250, trimMaxM: 250),
        isNull,
      ); // 400 m: two cuts of at least 150 m leave under 100 m
    });

    test('the cut is random per run and per end, always inside 150-300 m', () {
      final track = loopMetres(n: 2000);
      final total = along(track, track.length - 1);
      final starts = <double>{}, ends = <double>{};
      for (var seed = 0; seed < 40; seed++) {
        final rng = math.Random(seed);
        final a =
            kRouteTrimMinM +
            rng.nextDouble() * (kRouteTrimMaxM - kRouteTrimMinM);
        final b =
            kRouteTrimMinM +
            rng.nextDouble() * (kRouteTrimMaxM - kRouteTrimMinM);
        final out = trimEnds(track, a, b);
        final g0 = along(track, track.indexOf(out.first));
        final g1 = total - along(track, track.indexOf(out.last));
        expect(g0, inInclusiveRange(150, 300 + 4));
        expect(g1, inInclusiveRange(150, 300 + 4));
        starts.add(g0.roundToDouble());
        ends.add(g1.roundToDouble());
      }
      expect(starts.length, greaterThan(10));
      expect(ends.length, greaterThan(10));
    });

    test(
      'routeShape: with the default trim the outline is not the whole loop',
      () {
        // A straight 3 km out-and-forward track: the true start is at x = 0.
        // Trimmed, the shape is shorter than the untrimmed one, and it differs by run.
        final line = gps([
          for (var i = 0; i < 1000; i++) (i * 3.0, 20 * math.sin(i / 40)),
        ]);
        final full = shapeNoTrim(line)!;
        final a = routeShape(line, random: math.Random(1))!;
        final b = routeShape(line, random: math.Random(2))!;
        expect(longestSide(a), kRouteGrid);
        expect(a, isNot(full));
        expect(a, isNot(b));
      },
    );
  });

  group('privacy zones (hidden circle around places you start from)', () {
    const homeLat = 1.3521, homeLon = 103.8198;

    /// A run from home: out along [heading] for 1.2 km, round a loop, back.
    List<(double, double)> runFromHome(double heading, math.Random rnd) {
      final c = math.cos(heading), s = math.sin(heading);
      final pts = <(double, double)>[];
      for (var i = 0; i <= 400; i++) {
        pts.add((
          c * i * 3.0 + rnd.nextDouble() * 4,
          s * i * 3.0 + rnd.nextDouble() * 4,
        ));
      }
      final end = pts.last;
      for (var i = 1; i <= 300; i++) {
        final t = 2 * math.pi * i / 300;
        pts.add((end.$1 + 150 * math.sin(t), end.$2 + 150 * (1 - math.cos(t))));
      }
      for (var i = 400; i >= 0; i--) {
        pts.add((
          c * i * 3.0 + rnd.nextDouble() * 4,
          s * i * 3.0 + rnd.nextDouble() * 4,
        ));
      }
      return pts;
    }

    test('ensureZoneFor: a start inside a zone adds none; outside adds one around it', () {
      final rng = math.Random(3);
      final one = ensureZoneFor(const [], homeLat, homeLon, random: rng);
      expect(one, hasLength(1));
      final z = one.single;
      expect(z.radiusM, inInclusiveRange(kZoneMinRadiusM, kZoneMaxRadiusM));
      // The start is inside, the centre is not the start, and not further than half the radius.
      final d = z.distanceM(homeLat, homeLon);
      expect(d, lessThanOrEqualTo(z.radiusM / 2 + 0.01));
      expect(d, greaterThan(0));
      expect(
        ensureZoneFor(one, homeLat + 0.001, homeLon, random: rng),
        same(one),
      );
      final two = ensureZoneFor(one, homeLat + 0.05, homeLon, random: rng);
      expect(two, hasLength(2));
    });

    test('no cap and no eviction: a later place still gets a zone, the first one stays', () {
      final rng = math.Random(4);
      var zs = <PrivacyZone>[];
      for (var i = 0; i < 12; i++) {
        zs = ensureZoneFor(zs, homeLat + i * 0.05, homeLon, random: rng);
      }
      expect(zs, hasLength(12));
      final first = zs.first;
      final again = ensureZoneFor(
        zs,
        homeLat + 12 * 0.05,
        homeLon,
        random: rng,
      );
      expect(again, hasLength(13));
      expect(again.first, same(first));
      // Back at the first place: its own zone, not a new one.
      expect(ensureZoneFor(again, homeLat, homeLon, random: rng), same(again));
    });

    test(
      'the centre is uniform over the disc, not piled up near the place',
      () {
        final rng = math.Random(21);
        final ratios = <double>[];
        for (var i = 0; i < 4000; i++) {
          final z = ensureZoneFor(
            const [],
            homeLat,
            homeLon,
            random: rng,
          ).single;
          ratios.add(z.distanceM(homeLat, homeLon) / z.radiusM);
        }
        ratios.sort();
        // Area-uniform over a disc of radius R/2: median 0.5 * sqrt(0.5) * R, about 0.354 R.
        expect(ratios[ratios.length ~/ 2], closeTo(0.354, 0.02));
        expect(ratios.last, lessThanOrEqualTo(0.5001));
      },
    );

    test('a zone for where the run finishes too (work, the gym)', () {
      final rng = math.Random(8);
      final track = gps([
        for (var i = 0; i <= 500; i++) (i * 6.0, 30 * math.sin(i / 25)),
      ]);
      final zs = ensureZonesForRun(const [], track, random: rng);
      expect(zs, hasLength(2));
      final end = endFix(track)!;
      expect(zs.any((z) => z.distanceM(end.$1, end.$2) <= z.radiusM), isTrue);
      expect(ensureZonesForRun(zs, track, random: rng), same(zs));
    });

    test('20 runs to the same office: no outline ends nearer than half the zone radius', () {
      final rng = math.Random(15);
      var zones = <PrivacyZone>[];
      for (var k = 0; k < 20; k++) {
        // Each run finishes at the same office door (within a few tens of metres), 3 km on.
        final jitter = rng.nextDouble() * 0.0004;
        final pts = <(double, double)>[
          for (var i = 0; i <= 600; i++)
            (
              i * 5.0 + rng.nextDouble() * 3,
              25 * math.sin(i / 40) + rng.nextDouble() * 3,
            ),
        ];
        final base = gps(pts, lat: homeLat + jitter, lon: homeLon);
        final samples = base;
        zones = ensureZonesForRun(zones, samples, random: rng);
        final t = prepareTrack(samples, zones: zones, random: rng)!;
        final end = endFix(samples)!;
        final ex = (end.$2 - t.lon0) * t.kx, ey = -(end.$1 - t.lat0) * 110540.0;
        final last = t.pts.last;
        final z = zones.firstWhere(
          (z) => z.distanceM(end.$1, end.$2) <= z.radiusM,
        );
        expect(
          math.sqrt(math.pow(last.$1 - ex, 2) + math.pow(last.$2 - ey, 2)),
          greaterThan(z.radiusM / 2),
          reason: 'run $k',
        );
      }
      expect(zones.length, lessThanOrEqualTo(3));
    });

    test(
      'only the ends are clipped: a pass through the zone mid-route stays',
      () {
        final c = [(0.0, 0.0, 100.0)];
        final track = <Pt>[
          for (var i = 0; i < 50; i++) (i * 2.0, 0.0), // starts in the zone
          for (var i = 50; i < 100; i++) (250.0 + i, 300.0), // away
          for (var i = 0; i < 20; i++)
            (i * 2.0, 10.0), // through the zone mid-route
          for (var i = 20; i < 60; i++) (300.0 + i, 200.0), // away again
          for (var i = 0; i < 30; i++) (i * 3.0, 5.0), // ends in the zone
        ];
        final out = clipZoneEnds(track, c);
        expect(out.first.$2, 300.0);
        expect(out.last.$1, 359.0);
        expect(out.any((p) => p.$2 == 10.0), isTrue);
      },
    );

    test('a zone is read back from json, and a bad one is refused', () {
      const z = PrivacyZone(1.3, 103.8, 321);
      final back = PrivacyZone.fromJson(z.toJson())!;
      expect([back.lat, back.lon, back.radiusM], [1.3, 103.8, 321]);
      expect(PrivacyZone.fromJson({'lat': 'x', 'lon': 1, 'r': 300}), isNull);
      expect(PrivacyZone.fromJson({'lat': 1, 'lon': 1, 'r': 5}), isNull);
      expect(PrivacyZone.fromJson(null), isNull);
    });

    test('20 runs from the same door: no outline ever starts or ends nearer than half the zone radius, and never inside the zone', () {
      for (var seed = 0; seed < 5; seed++) {
        final rng = math.Random(seed);
        final zones = ensureZoneFor(const [], homeLat, homeLon, random: rng);
        final z = zones.single;
        var nearest = double.infinity;
        for (var k = 0; k < 20; k++) {
          final heading = [0.0, 1.9, 4.4][k % 3] + rng.nextDouble() * 0.1;
          final samples = gps(
            runFromHome(heading, rng),
            lat: homeLat,
            lon: homeLon,
          );
          final t = prepareTrack(samples, zones: zones, random: rng)!;
          final hx = (homeLon - t.lon0) * t.kx;
          final hy = -(homeLat - t.lat0) * 110540.0;
          final cx = (z.lon - t.lon0) * t.kx;
          final cy = -(z.lat - t.lat0) * 110540.0;
          for (final p in [t.pts.first, t.pts.last]) {
            final fromHome = math.sqrt(
              math.pow(p.$1 - hx, 2) + math.pow(p.$2 - hy, 2),
            );
            final fromCentre = math.sqrt(
              math.pow(p.$1 - cx, 2) + math.pow(p.$2 - cy, 2),
            );
            expect(
              fromCentre,
              greaterThan(z.radiusM),
              reason: 'seed $seed run $k',
            );
            expect(
              fromHome,
              greaterThan(z.radiusM / 2),
              reason: 'seed $seed run $k',
            );
            nearest = math.min(nearest, fromHome);
          }
        }
        // Twenty runs do not close in on the door: the best any of them did is still outside half the radius.
        expect(nearest, greaterThan(z.radiusM / 2), reason: 'seed $seed');
      }
    });

    test('without a zone the random trim alone can come close, which is why the zone exists', () {
      final rng = math.Random(11);
      var nearest = double.infinity;
      for (var k = 0; k < 40; k++) {
        final samples = gps(runFromHome(0.3, rng), lat: homeLat, lon: homeLon);
        final t = prepareTrack(samples, random: rng)!;
        final hx = (homeLon - t.lon0) * t.kx,
            hy = -(homeLat - t.lat0) * 110540.0;
        nearest = math.min(
          nearest,
          math.sqrt(
            math.pow(t.pts.first.$1 - hx, 2) + math.pow(t.pts.first.$2 - hy, 2),
          ),
        );
      }
      expect(nearest, lessThan(170));
    });

    test(
      'the zone secret is in no payload: not its centre, not its radius',
      () {
        final rng = math.Random(9);
        final zones = ensureZoneFor(const [], homeLat, homeLon, random: rng);
        final z = zones.single;
        final run = RunFile(
          id: 'zone-secret',
          device: 'test',
          app: 'test',
          start: DateTime.utc(2026, 10, 2),
          end: DateTime.utc(2026, 10, 2, 0, 30),
          tz: 'UTC',
          mode: RunMode.free,
          units: Units.km,
          laps: const [],
          samples: gps(runFromHome(0.7, rng), lat: homeLat, lon: homeLon),
        );
        final wire = jsonEncode(companionShapeFields(run, privacyZones: zones));
        expect(wire, contains('"route"'));
        for (final secret in [
          z.lat.toString(),
          z.lon.toString(),
          z.radiusM.toString(),
          z.radiusM.round().toString().padLeft(3, '0') == '' ? 'x' : '"r"',
          'zone',
          'privacy',
        ]) {
          expect(wire, isNot(contains(secret)), reason: secret);
        }
        // And the route is whole numbers on the grid, as ever.
        expect(
          jsonEncode(companionShapeFields(run, privacyZones: zones)['route']),
          isNot(contains('.')),
        );
      },
    );
  });

  group('per-km splits', () {
    RunFile runOf(List<Sample> samples) => RunFile(
      id: 'split-test',
      device: 'test',
      app: 'test',
      start: DateTime.utc(2026, 10, 2),
      end: DateTime.utc(
        2026,
        10,
        2,
      ).add(Duration(milliseconds: samples.last.tMs)),
      tz: 'UTC',
      mode: RunMode.free,
      units: Units.km,
      laps: const [],
      samples: samples,
    );

    /// [secPerKm] for each km in turn, 1 s samples, ending at [km] km.
    RunFile steady(List<double> secPerKm, double km) {
      final out = <Sample>[Sample(tMs: 0, distM: 0)];
      var t = 0.0, d = 0.0;
      while (d < km * 1000 - 1e-6) {
        final pace =
            secPerKm[math.min((d / 1000).floor(), secPerKm.length - 1)];
        t += 1;
        d = math.min(km * 1000, d + 1000 / pace);
        out.add(Sample(tMs: (t * 1000).round(), distM: d));
      }
      return runOf(out);
    }

    test('full kms, then the bit left over', () {
      final run = steady([300, 310, 320], 2.6);
      final w = kmSplitWindows(run);
      expect(w.length, 3);
      expect([for (final x in w) x.km], [1.0, 1.0, closeTo(0.6, 0.002)]);
      expect(w[0].paceSecPerKm, closeTo(300, 2));
      expect(w[1].paceSecPerKm, closeTo(310, 2));
      expect(w[2].paceSecPerKm, closeTo(320, 3));
      // They tile the run: no gap, no overlap, the same clock as its duration.
      expect(w.first.t0Ms, 0);
      for (var i = 1; i < w.length; i++) {
        expect(w[i].t0Ms, w[i - 1].t1Ms);
      }
      expect(w.last.t1Ms, run.samples.last.tMs);
      final total = w.fold<double>(0, (a, x) => a + x.km * x.paceSecPerKm);
      expect(total, closeTo(run.end.difference(run.start).inSeconds, 1));
    });

    test('a few metres past a full km is not a split of its own', () {
      expect(kmSplitWindows(steady([300], 2.015)).length, 2);
      expect(kmSplitWindows(steady([300], 2.03)).length, 3);
    });

    test('under a km is one short split; no distance is none', () {
      final w = kmSplitWindows(steady([330], 0.7));
      expect(w.length, 1);
      expect(w.single.km, closeTo(0.7, 0.002));
      expect(
        kmSplitWindows(
          runOf([Sample(tMs: 0, distM: 0), Sample(tMs: 5000, distM: 2)]),
        ),
        isEmpty,
      );
    });

    test('more than 100 pieces sends none', () {
      expect(kmSplitWindows(steady([300], 100.0)).length, 100);
      expect(kmSplitWindows(steady([300], 100.5)), isEmpty);
    });

    group('wire fields', () {
      test('splits carry km, pace to a decimal and the zone; no zone without heart rate', () {
        final run = steady([300, 310, 320], 2.6);
        final f = companionShapeFields(run, withRoute: false);
        final s = (f['splits']! as List).cast<Map<String, Object?>>();
        expect(s.length, 3);
        expect(s[0].keys.toSet(), {'km', 'pace_s'});
        expect((s[0]['pace_s']! as double), closeTo(300, 2));
        expect(s[2]['km'], closeTo(0.6, 0.002));
        expect(f.containsKey('route'), isFalse);
        expect(f.containsKey('reps'), isFalse);
      });

      test('a split slower than an hour a km or faster than a minute drops all splits', () {
        final glitch = steady([300, 30, 300], 3);
        expect(companionShapeFields(glitch).containsKey('splits'), isFalse);
        final stopped = steady([300, 4000, 300], 3);
        expect(companionShapeFields(stopped).containsKey('splits'), isFalse);
      });

      test('the zone is the one the piece mostly ran in', () {
        final samples = [
          for (final s in steady([300, 300], 2).samples)
            Sample(tMs: s.tMs, distM: s.distM, hr: s.distM < 1000 ? 120 : 185),
        ];
        final f = companionShapeFields(
          runOf(samples),
          zones: HrZones.percentMax(190),
          withRoute: false,
        );
        final s = (f['splits']! as List).cast<Map<String, Object?>>();
        expect(s[0]['zone'], lessThan(s[1]['zone']! as int));
        expect(s[1]['zone'], 5);
      });

      test('the route is there only when asked for', () {
        final run = RunFile(
          id: 'r',
          device: 'test',
          app: 'test',
          start: DateTime.utc(2026, 10, 2),
          end: DateTime.utc(2026, 10, 2, 0, 6, 41),
          tz: 'UTC',
          mode: RunMode.free,
          units: Units.km,
          laps: const [],
          samples: gps(loopMetres()),
        );
        expect(companionShapeFields(run).containsKey('route'), isTrue);
        expect(
          companionShapeFields(run, withRoute: false).containsKey('route'),
          isFalse,
        );
        final j = jsonEncode(companionShapeFields(run));
        expect(j, isNot(contains('lat')));
        expect(j, isNot(contains('103.8')));
      });
    });
  });
}
