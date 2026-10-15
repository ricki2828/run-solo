import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Ricki's real out-and-back (Gualdo Cattaneo, 12 and 14 Oct 2026, about 4.7
/// km) and the grouping rules for out-and-backs and Free runs.
const _lat0 = -33.8688, _lon0 = 151.2093;
final _kLon = 111320.0 * math.cos(_lat0 * math.pi / 180);

RouteSignature _sig(List<List<num>> xy, double lengthM) => RouteSignature(
  points: [
    for (final p in xy)
      SigPoint(
        _lat0 + p[1].toDouble() / 111320.0,
        _lon0 + p[0].toDouble() / _kLon,
      ),
  ],
  lengthM: lengthM,
);

TrailRunFacts _facts(
  String id,
  int day,
  RouteSignature r, {
  bool trail = true,
}) => TrailRunFacts(
  id: id,
  start: DateTime.utc(2026, 10, day),
  movingMs: (r.lengthM * 365).round(),
  distanceM: r.lengthM,
  route: r,
  gradeFactor: 1,
  trailMode: trail,
);

void main() {
  final fx = jsonDecode(
    File('test/fixtures/trail_grouping/gualdo_cattaneo.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final runs = (fx['runs'] as List).cast<Map<String, dynamic>>();
  RouteSignature real(int i) => _sig(
    (runs[i]['xy_m'] as List).map((p) => (p as List).cast<num>()).toList(),
    (runs[i]['distance_m'] as num).toDouble(),
  );

  test('his 12 and 14 Oct runs are the same out and back', () {
    final a = real(0), b = real(1);
    expect(RouteMatch.same(a, b), isTrue);
    // Turn points differ by tens of metres, not hundreds.
    expect(RouteMatch.turnGapM(a, b), lessThan(150));
  });

  group('wrong trail safety', () {
    // A 3 km out and back and variations, in a local frame.
    RouteSignature oab(double turn, {double y = 0, double? lengthM}) => _sig([
      [0, y],
      [turn, y],
      [0, y],
    ], lengthM ?? turn * 2);
    final base = oab(1500);

    test('a turn 100 m early or late is the same trail, 50 m too', () {
      expect(RouteMatch.same(base, oab(1400)), isTrue);
      expect(RouteMatch.same(base, oab(1600)), isTrue);
      expect(RouteMatch.same(base, oab(1450)), isTrue);
      expect(RouteMatch.turnGapM(base, oab(1400)), closeTo(100, 5));
    });

    test('lengths still have to be within 10 percent', () {
      expect(RouteMatch.same(base, oab(1300)), isFalse);
      expect(RouteMatch.same(base, oab(1700)), isFalse);
    });

    test('a parallel track 60 m away is another trail', () {
      expect(RouteMatch.same(base, oab(1500, y: 60)), isFalse);
    });

    test(
      'an out and back run from its other end is the same trail (as before)',
      () {
        final other = _sig([
          [1500, 0],
          [0, 0],
          [1500, 0],
        ], 3000);
        // Out and backs have always counted as loops, which may start anywhere.
        expect(RouteMatch.same(base, other), isTrue);
      },
    );

    test('a different trail with the same start that parts after a km', () {
      final branch = _sig([
        [0, 0],
        [1000, 0],
        [1500, 500],
        [1000, 0],
        [0, 0],
      ], 3414);
      expect(RouteMatch.same(base, branch), isFalse);
    });

    test('an out and back is not matched to a loop of the same length', () {
      final loop = _sig([
        [0, 0],
        [750, 0],
        [750, 750],
        [0, 750],
        [0, 0],
      ], 3000);
      expect(RouteMatch.same(base, loop), isFalse);
    });

    test(
      'two out and backs that share the start but turn on different legs',
      () {
        final bent = _sig([
          [0, 0],
          [700, 0],
          [700, 800],
          [700, 0],
          [0, 0],
        ], 3000);
        expect(RouteMatch.same(base, bent), isFalse);
      },
    );
  });

  group('Free runs join a trail', () {
    final a = real(0), b = real(1);

    test(
      'a Free run on a Trail run\'s route joins its group, not a new one',
      () {
        final groups = Trails.group([
          _facts('t1', 12, a),
          _facts('f1', 13, b, trail: false),
        ]);
        expect(groups, hasLength(1));
        expect(groups.single.runs.map((r) => r.id), ['t1', 'f1']);
        expect(groups.single.anchor.id, 't1');
      },
    );

    test('Free runs on one route are a trail of their own', () {
      final groups = Trails.group([
        _facts('f1', 12, a, trail: false),
        _facts('f2', 14, b, trail: false),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.runs.map((r) => r.id), ['f1', 'f2']);
    });

    test('the earliest run anchors the group, Free or not', () {
      final groups = Trails.group([
        _facts('f0', 10, a, trail: false),
        _facts('t1', 12, a),
        _facts('t2', 14, b),
      ]);
      expect(groups.single.anchor.id, 'f0');
      expect(groups.single.runs.map((r) => r.id), ['f0', 't1', 't2']);
      expect(groups.single.key, 'trail:f0');
    });

    test(
      'a Free run on other ground does not join, it is a group of its own',
      () {
        final elsewhere = _sig([
          [0, 3000],
          [1500, 3000],
          [0, 3000],
        ], 3000);
        final groups = Trails.group([
          _facts(
            't1',
            12,
            _sig([
              [0, 0],
              [1500, 0],
              [0, 0],
            ], 3000),
          ),
          _facts('f1', 13, elsewhere, trail: false),
        ]);
        expect(groups, hasLength(2));
        expect(groups.first.runs.map((r) => r.id), ['t1']);
      },
    );

    test(
      'the verdict of a Trail run sees the Free run and compares on pace',
      () {
        final cur = _facts('t2', 14, b);
        final free = _facts('f1', 12, a, trail: false);
        final r = TrailVerdict.of(cur, [free]);
        expect(r.basis, TrailBasis.sameTrail);
        expect(r.runsOnTrail, 2);
      },
    );

    test('a Free run is not a trail run for the effort fallback', () {
      // Different ground: no group, so the verdict falls back on effort,
      // which must not count the Free run as a recent trail run.
      final cur = _facts('t2', 14, b);
      final elsewhere = _sig([
        [0, 3000],
        [1500, 3000],
        [0, 3000],
      ], 3000);
      final free = _facts('f1', 12, elsewhere, trail: false);
      final r = TrailVerdict.of(cur, [free]);
      expect(r.basis, isNot(TrailBasis.sameTrail));
      expect(r.basis, isNot(TrailBasis.effortPace));
    });
  });
}
