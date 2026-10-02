import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// A route is a straight-ish out-and-back we can place anywhere; a different
/// trail is the same shape 3 km north.
RouteSignature route({double dLat = 0, bool loop = true, double sizeM = 600}) {
  const lat0 = 37.4, lon0 = 24.9;
  final k = sizeM / 111194.9;
  final pts = loop
      ? [
          RoutePoint(lat0 + dLat, lon0),
          RoutePoint(lat0 + dLat + k, lon0 + k),
          RoutePoint(lat0 + dLat + 2 * k, lon0),
          RoutePoint(lat0 + dLat + k, lon0 - k),
          RoutePoint(lat0 + dLat, lon0),
        ]
      : [
          RoutePoint(lat0 + dLat, lon0),
          RoutePoint(lat0 + dLat + 3 * k, lon0 + k),
        ];
  return RouteSignature(
    points: pts,
    lengthM: loop ? 4 * k * 111194.9 : 3.2 * 111194.9 * k,
  );
}

TrailRunFacts run(
  String id,
  DateTime start,
  int movingSec, {
  RouteSignature? r,
  double? climb = 300,
  double? gap = 360,
  String? street = 'Kastro',
  double distanceM = 6000,
}) => TrailRunFacts(
  id: id,
  start: start,
  movingMs: movingSec * 1000,
  distanceM: distanceM,
  climbM: climb,
  gapSecPerKm: gap,
  route: r,
  street: street,
);

void main() {
  final loop = route();
  final d = DateTime(2026, 9, 12, 7);
  final d2 = DateTime(2026, 9, 20, 7);
  final d3 = DateTime(2026, 9, 28, 7);

  group('same trail', () {
    test('faster than the last run, with the climb on both', () {
      final old = run('a', d, 2600, r: loop, climb: 295);
      final now = run('b', d2, 2470, r: loop, climb: 310);
      final v = TrailVerdict.of(now, [old]);
      expect(v.basis, TrailBasis.sameTrail);
      expect(v.tone, TrailTone.faster);
      expect(v.headline, 'FASTER ON THIS TRAIL');
      expect(v.subline, '2:10 quicker than 12 Sep, your last run here.');
      expect(v.lines, contains('Climb 310 m, was 295 m.'));
      expect(v.lines, contains('Moving time 41:10, was 43:20.'));
      expect(v.lines, contains('Your best on this trail.'));
      expect(v.trailName, 'Kastro loop');
      expect(v.isTrailBest, isTrue);
      expect(v.deltaSec, 130);
    });

    test('slower than the last, and says where the best is', () {
      final a = run('a', d, 2400, r: loop);
      final b = run('b', d2, 2600, r: loop);
      final c = run('c', d3, 2700, r: loop);
      final v = TrailVerdict.of(c, [a, b]);
      expect(v.tone, TrailTone.slower);
      expect(v.headline, 'SLOWER ON THIS TRAIL');
      expect(v.subline, '1:40 slower than 20 Sep, your last run here.');
      expect(v.isTrailBest, isFalse);
      expect(
        v.lines,
        contains('Your best here is 40:00 (12 Sep). You were 5:00 off.'),
      );
      expect(v.runsOnTrail, 3);
      expect(v.lines.first, 'Kastro loop, your 3rd run here.');
    });

    test('inside the noise reads as no real change', () {
      final a = run('a', d, 2400, r: loop);
      final b = run('b', d2, 2410, r: loop);
      final v = TrailVerdict.of(b, [a]);
      expect(v.tone, TrailTone.same);
      expect(v.headline, 'NO REAL CHANGE');
      expect(v.subline, contains('Inside the run-to-run noise (0:36).'));
      expect(v.isTrailBest, isFalse);
    });

    test('the last run is also the best', () {
      final a = run('a', d, 2400, r: loop);
      final b = run('b', d2, 2700, r: loop);
      final v = TrailVerdict.of(b, [a]);
      expect(v.lines.last, 'That 12 Sep run is also your best here.');
      // A third run: the best is no longer the last one.
      final w = TrailVerdict.of(run('c', d3, 2900, r: loop), [a, b]);
      expect(
        w.lines.last,
        'Your best here is 40:00 (12 Sep). You were 8:20 off.',
      );
    });

    test('feet with miles', () {
      final a = run('a', d, 2600, r: loop, climb: 100);
      final b = run('b', d2, 2500, r: loop, climb: 100);
      final v = TrailVerdict.of(b, [a], units: Units.mi);
      expect(v.lines, contains('Climb 328 ft, was 328 ft.'));
    });

    test('a later run does not change an earlier verdict', () {
      final a = run('a', d, 2600, r: loop);
      final b = run('b', d2, 2500, r: loop);
      final c = run('c', d3, 2000, r: loop);
      final v = TrailVerdict.of(b, [a, c]);
      expect(v.runsOnTrail, 2);
      expect(v.subline, startsWith('1:40 quicker than 12 Sep'));
    });
  });

  group('no match: effort pace', () {
    test('no earlier trail run is a baseline', () {
      final v = TrailVerdict.of(run('a', d, 2600, r: loop, gap: 341), []);
      expect(v.basis, TrailBasis.baseline);
      expect(v.headline, 'BASELINE SET');
      expect(
        v.subline,
        'Effort pace 5:41/km over 6.0 km with 300 m of climb. Your next '
        'trail run gets a verdict.',
      );
    });

    test('a different trail is judged on effort pace vs the median', () {
      final others = [
        run('a', d, 2600, r: route(dLat: 0.05), gap: 380),
        run('b', d2, 2600, r: route(dLat: 0.09), gap: 370),
        run(
          'c',
          d2.add(const Duration(days: 1)),
          2600,
          r: route(dLat: 0.12),
          gap: 390,
        ),
      ];
      final v = TrailVerdict.of(run('n', d3, 2500, r: loop, gap: 350), others);
      expect(v.basis, TrailBasis.effortPace);
      expect(v.tone, TrailTone.faster);
      expect(v.headline, 'FASTER');
      expect(v.subline, contains('Effort pace 30 s/km quicker'));
      expect(v.subline, contains('(5:50 vs 6:20/km)'));
      expect(v.comparedWith, 'median');
    });

    test('slower and level read honestly', () {
      final others = [run('a', d, 2600, r: route(dLat: 0.05), gap: 360)];
      final slow = TrailVerdict.of(
        run('n', d3, 2600, r: loop, gap: 400),
        others,
      );
      expect(slow.tone, TrailTone.slower);
      expect(slow.headline, 'SLOWER');
      final level = TrailVerdict.of(
        run('n', d3, 2600, r: loop, gap: 365),
        others,
      );
      expect(level.tone, TrailTone.same);
      expect(level.subline, contains('Inside the noise (12 s/km).'));
    });

    test('a run with no route is judged on effort pace too', () {
      final a = run('a', d, 2600, r: loop, gap: 380);
      final v = TrailVerdict.of(run('n', d3, 2500, gap: 340), [a]);
      expect(v.basis, TrailBasis.effortPace);
      expect(v.tone, TrailTone.faster);
    });

    test('without elevation there is no verdict', () {
      final v = TrailVerdict.of(run('a', d, 2600, gap: null, climb: null), []);
      expect(v.headline, 'NO VERDICT');
      expect(v.basis, TrailBasis.none);
    });

    test('the wording has no em dash', () {
      final a = run('a', d, 2600, r: loop);
      for (final v in [
        TrailVerdict.of(run('b', d2, 2000, r: loop), [a]),
        TrailVerdict.of(run('b', d2, 2000, r: route(dLat: 0.1)), [a]),
        TrailVerdict.of(run('b', d2, 2000, r: loop), []),
      ]) {
        for (final s in [v.headline, v.subline, ...v.lines]) {
          expect(s.contains('—'), isFalse, reason: s);
        }
      }
    });
  });

  group('trail groups', () {
    test(
      'a run joins the earliest trail it matches; names come from the anchor',
      () {
        final a = run('a', d, 2600, r: loop);
        final b = run('b', d2, 2500, r: loop);
        final c = run('c', d3, 2500, r: route(dLat: 0.1), street: null);
        final groups = Trails.group([c, b, a]);
        expect(groups.length, 2);
        expect(groups.first.runs.map((r) => r.id), ['a', 'b']);
        expect(groups.first.key, 'trail:a');
        expect(groups.first.best.id, 'b');
        expect(Trails.groupOf('c', groups)!.name, 'Trail of 28 Sep');
        expect(groups.first.name, 'Kastro loop');
      },
    );

    test('a point-to-point trail is a trail, not a loop', () {
      final p = route(loop: false);
      final g = Trails.group([run('a', d, 2000, r: p)]);
      expect(g.single.name, 'Kastro trail');
    });
  });

  group('effort for the identity lanes', () {
    int? effort({
      double distanceM = 15000,
      int movingMs = 2 * 3600 * 1000,
      double? gap = 400,
      double? climb = 600,
      ElevSource? src = ElevSource.baro,
    }) => TrailEffort.effortMs(
      distanceM: distanceM,
      movingMs: movingMs,
      gapSecPerKm: gap,
      climbM: climb,
      elevSrc: src,
    );

    test('a hilly 15K counts at its effort time', () {
      // 15 km at 400 s/km effort = 6000 s, against 7200 s on the clock.
      expect(effort(), 6000 * 1000);
    });

    test('never more than the credit cap, never worse than the clock', () {
      expect(effort(gap: 200), (7200 * 1000 * 0.75).round());
      expect(effort(gap: 600), 7200 * 1000);
    });

    test('too short, flat, GPS-only or without GAP does not count', () {
      expect(effort(distanceM: 2000), isNull);
      expect(effort(climb: 30), isNull);
      expect(effort(src: ElevSource.gps), isNull);
      expect(effort(gap: null), isNull);
      expect(effort(src: null), isNull);
    });
  });
}
