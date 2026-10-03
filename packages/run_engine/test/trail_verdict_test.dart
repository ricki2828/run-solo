import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// A route is a straight-ish out-and-back we can place anywhere; a different
/// trail is the same shape 3 km north.
RouteSignature route({double dLat = 0, bool loop = true, double sizeM = 600}) {
  const lat0 = 37.4, lon0 = 24.9;
  final k = sizeM / 111194.9;
  final pts = loop
      ? [
          SigPoint(lat0 + dLat, lon0),
          SigPoint(lat0 + dLat + k, lon0 + k),
          SigPoint(lat0 + dLat + 2 * k, lon0),
          SigPoint(lat0 + dLat + k, lon0 - k),
          SigPoint(lat0 + dLat, lon0),
        ]
      : [SigPoint(lat0 + dLat, lon0), SigPoint(lat0 + dLat + 3 * k, lon0 + k)];
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
  double heat = 1,
  String? street = 'Kastro',
  double distanceM = 6000,
}) => TrailRunFacts(
  id: id,
  start: start,
  movingMs: movingSec * 1000,
  distanceM: distanceM,
  climbM: climb,
  // [gap] is the hills-only pace the test wants; as a hills factor on the
  // actual pace. Null = no elevation at all.
  gradeFactor: gap == null ? null : gap / (movingSec * 1000 / distanceM),
  heatFactor: heat,
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

    test('same trail compares heat-adjusted moving time', () {
      // 2600 s on a cool day, then 2650 s on a hot one (6% slowdown): 2491 s
      // once the heat is out, so the hot run was the better one.
      final a = run('a', d, 2600, r: loop);
      final b = run('b', d2, 2650, r: loop, heat: 0.94);
      final v = TrailVerdict.of(b, [a]);
      expect(v.tone, TrailTone.faster);
      expect(v.headline, 'FASTER ON THIS TRAIL');
      expect(v.subline, '1:49 quicker than 12 Sep, your last run here.');
      expect(v.deltaSec, closeTo(2600 - 2650 * 0.94, 1e-9));
      expect(v.lines, contains('Moving time 44:10, was 43:20.'));
      expect(v.lines, contains('In cool conditions that is 41:31, was 43:20.'));
      expect(v.isTrailBest, isTrue);
      // Cool both times: no heat line, the clock is the comparison.
      final c = TrailVerdict.of(run('c', d3, 2650, r: loop), [a]);
      expect(c.tone, TrailTone.slower);
      expect(c.lines.any((l) => l.startsWith('In cool conditions')), isFalse);
    });

    test('the best on a trail is the best once the heat is out', () {
      final hot = run('a', d, 2640, r: loop, heat: 0.9); // 2376 cool
      final b = run('b', d2, 2500, r: loop);
      final g = Trails.group([hot, b]).single;
      expect(g.best.id, 'a');
      final v = TrailVerdict.of(run('c', d3, 2450, r: loop), [hot, b]);
      expect(
        v.lines.last,
        'Your best here is 39:36 (12 Sep, cool-day time). You were 1:14 off.',
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

  group('no match: true pace', () {
    test('no earlier trail run is a baseline', () {
      final v = TrailVerdict.of(run('a', d, 2600, r: loop, gap: 341), []);
      expect(v.basis, TrailBasis.baseline);
      expect(v.headline, 'BASELINE SET');
      expect(
        v.subline,
        '5:41 true pace (7:13 actual, hilly) over 6.0 km with 300 m of '
        'climb. Your next trail run gets a verdict.',
      );
    });

    test('a different trail is judged on true pace vs the median', () {
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
      expect(v.subline, contains('True pace 30 s/km quicker'));
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

    test('a run with no route is judged on true pace too', () {
      final a = run('a', d, 2600, r: loop, gap: 380);
      final v = TrailVerdict.of(run('n', d3, 2500, gap: 340), [a]);
      expect(v.basis, TrailBasis.effortPace);
      expect(v.tone, TrailTone.faster);
    });

    test('without elevation there is no verdict', () {
      final v = TrailVerdict.of(run('a', d, 2600, gap: null, climb: null), []);
      expect(v.headline, 'NO VERDICT');
      expect(v.basis, TrailBasis.none);
      expect(v.subline, 'No elevation on this run, so no true pace.');
    });

    test('heat is taken out of a hot trail run, and the actual pace stays', () {
      // 7:13 actual, hills 5:41, hot day (6%): 5:21 true.
      final a = run('a', d, 2600, r: route(dLat: 0.05), gap: 380);
      final v = TrailVerdict.of(
        run('n', d3, 2600, r: loop, gap: 380, heat: 0.94),
        [a],
      );
      expect(v.tone, TrailTone.faster);
      expect(v.subline, contains('True pace 23 s/km quicker'));
      expect(v.lines.last, contains('actual, hilly, hot day)'));
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

  group('trail scores for the identity lanes', () {
    test('a barometer trail run of 3 km or more is scored from its moving '
        'time', () {
      int? ms({double d = 15000, int t = 7200000, ElevSource? s}) =>
          TrailScore.movingMs(
            distanceM: d,
            movingMs: t,
            elevSrc: s ?? ElevSource.baro,
          );
      expect(ms(), 7200000);
      expect(ms(d: 2000, t: 600000), isNull);
      expect(ms(t: 0), isNull);
      // GPS-only altitude is too noisy for the grade model: no score.
      expect(
        TrailScore.movingMs(
          distanceM: 15000,
          movingMs: 7200000,
          elevSrc: ElevSource.gps,
        ),
        isNull,
      );
      expect(
        TrailScore.movingMs(distanceM: 15000, movingMs: 7200000, elevSrc: null),
        isNull,
      );
    });

    test('for scoring, hills and heat count at most 20% off the clock', () {
      const f = TruePaceFactors(grade: 0.75, heat: 0.92); // 0.69 combined
      expect(f.apply(7200 * 1000), closeTo(7200 * 1000 * 0.69, 1));
      expect(f.applyForScore(7200 * 1000), closeTo(7200 * 1000 * 0.8, 1e-6));
      // Inside the cap, scoring equals the display.
      const g = TruePaceFactors(grade: 0.9, heat: 0.95);
      expect(g.applyForScore(1000), g.apply(1000));
      expect(TruePace.factors(gradeFactor: 0.5).grade, TruePace.minGrade);
    });
  });
}
