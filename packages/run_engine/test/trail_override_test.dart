import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The runner's split / merge of a trail: `Trails.group` honours it before
/// any route match, and the hint says where a match is marginal.
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

/// An out and back from (0, y) with its turn [turn] m out.
RouteSignature _oab(double turn, {double y = 0, double? lengthM}) => _sig([
  [0, y],
  [turn, y],
  [0, y],
], lengthM ?? turn * 2);

TrailRunFacts _run(
  String id,
  int day,
  RouteSignature r, {
  TrailOverride? override,
  bool trail = true,
}) => TrailRunFacts(
  id: id,
  start: DateTime.utc(2026, 10, day),
  movingMs: (r.lengthM * 365).round(),
  distanceM: r.lengthM,
  route: r,
  gradeFactor: 1,
  trailMode: trail,
  override: override,
);

List<String> _ids(TrailGroup g) => [for (final r in g.runs) r.id];

void main() {
  // Two trails that never match: A along y = 0, B along y = 3000.
  final a = _oab(1500);
  final b = _oab(1500, y: 3000);

  group('split', () {
    test('a split run leaves its trail and is never regrouped', () {
      final groups = Trails.group([
        _run('a1', 1, a),
        _run('a2', 2, a, override: const TrailOverride.split()),
        _run('a3', 3, a),
      ]);
      expect(groups, hasLength(2));
      expect(_ids(Trails.groupOf('a1', groups)!), ['a1', 'a3']);
      expect(_ids(Trails.groupOf('a2', groups)!), ['a2']);
    });

    test('nothing matches through a split run, even when it is the first', () {
      final groups = Trails.group([
        _run('a1', 1, a, override: const TrailOverride.split()),
        _run('a2', 2, a),
        _run('a3', 3, a),
      ]);
      expect(_ids(Trails.groupOf('a2', groups)!), ['a2', 'a3']);
      // The trail re-anchors on its earliest remaining run.
      expect(Trails.groupOf('a2', groups)!.key, 'trail:a2');
      expect(_ids(Trails.groupOf('a1', groups)!), ['a1']);
    });

    test('the verdict of a split run has no trail to compare with', () {
      final cur = _run('a2', 2, a, override: const TrailOverride.split());
      final r = TrailVerdict.of(cur, [_run('a1', 1, a)]);
      expect(r.basis, isNot(TrailBasis.sameTrail));
    });
  });

  group('join', () {
    test('a joined run is on the trail whatever the routes say', () {
      final groups = Trails.group([
        _run('a1', 1, a),
        _run('a2', 2, a),
        _run('b1', 3, b, override: const TrailOverride.join('a1')),
      ]);
      expect(groups, hasLength(1));
      expect(_ids(groups.single), ['a1', 'a2', 'b1']);
      expect(groups.single.key, 'trail:a1');
    });

    test(
      'only the joined run moves: its old siblings stay where they were',
      () {
        final groups = Trails.group([
          _run('a1', 1, a),
          _run('b1', 2, b, override: const TrailOverride.join('a1')),
          _run('b2', 3, b),
          _run('b3', 4, b),
        ]);
        expect(_ids(Trails.groupOf('a1', groups)!), ['a1', 'b1']);
        expect(_ids(Trails.groupOf('b2', groups)!), ['b2', 'b3']);
      },
    );

    test('a join that is earlier than the trail keeps the trail anchor', () {
      final groups = Trails.group([
        _run('b0', 1, b, override: const TrailOverride.join('a1')),
        _run('a1', 2, a),
        _run('a2', 3, a),
      ]);
      final g = groups.single;
      expect(_ids(g), ['b0', 'a1', 'a2']);
      expect(g.anchorId, 'a1');
      expect(g.key, 'trail:a1');
      expect(g.refDistanceM, a.lengthM);
    });

    test('a join to a deleted run falls back to the automatic match', () {
      final groups = Trails.group([
        _run('a1', 1, a),
        _run('a2', 2, a, override: const TrailOverride.join('gone')),
        _run('b1', 3, b, override: const TrailOverride.join('gone')),
      ]);
      expect(_ids(Trails.groupOf('a2', groups)!), ['a1', 'a2']);
      expect(_ids(Trails.groupOf('b1', groups)!), ['b1']);
    });

    test('two runs that join each other fall back, they never loop', () {
      final groups = Trails.group([
        _run('x', 1, a, override: const TrailOverride.join('y')),
        _run('y', 2, b, override: const TrailOverride.join('x')),
      ]);
      expect(groups, hasLength(2));
    });

    test('a join onto a split run joins that run alone', () {
      final groups = Trails.group([
        _run('a1', 1, a, override: const TrailOverride.split()),
        _run('a2', 2, a),
        _run('b1', 3, b, override: const TrailOverride.join('a1')),
      ]);
      expect(_ids(Trails.groupOf('a1', groups)!), ['a1', 'b1']);
      expect(_ids(Trails.groupOf('a2', groups)!), ['a2']);
    });

    test('a joined run feeds the verdict as a run on that trail', () {
      final cur = _run('b2', 5, b, override: const TrailOverride.join('a1'));
      final r = TrailVerdict.of(cur, [_run('a1', 1, a)]);
      expect(r.basis, TrailBasis.sameTrail);
      expect(r.runsOnTrail, 2);
    });
  });

  group('candidates', () {
    test('nearest start first, own trail left out, far trails dropped', () {
      final near = _oab(1500, y: 200);
      final mid = _oab(1500, y: 1200);
      final far = _oab(1500, y: 9000);
      final groups = Trails.group([
        _run('own', 9, a),
        _run('mid', 2, mid),
        _run('near', 1, near),
        _run('far', 3, far),
      ]);
      final me = _run('own', 9, a);
      final c = Trails.candidates(me, groups);
      expect(c.map((x) => x.group.anchor.id), ['near', 'mid']);
      expect(c.first.startGapM, closeTo(200, 5));
    });

    test('a run with no route has none', () {
      final noRoute = TrailRunFacts(
        id: 'n',
        start: DateTime.utc(2026, 10, 1),
        movingMs: 1,
        distanceM: 1,
      );
      expect(
        Trails.candidates(noRoute, Trails.group([_run('a', 1, a)])),
        isEmpty,
      );
    });
  });

  group('looks off', () {
    test('a run well inside every gate has no hint', () {
      expect(RouteMatch.margin(a, _oab(1520, lengthM: 3040)), isNull);
    });

    test('a length near the 10% gate says so', () {
      final longer = _oab(1500, lengthM: 3000 * 1.08);
      final m = RouteMatch.margin(a, longer)!;
      expect(m.kind, MatchMarginKind.length);
      expect(m.value, closeTo(0.074, 0.01));
    });

    test('a turn gap near the limit says so', () {
      final m = RouteMatch.margin(a, _oab(1440))!;
      expect(m.kind, MatchMarginKind.turn);
      expect(m.value, closeTo(60, 5));
    });

    test('the anchor itself is never flagged', () {
      final g = Trails.group([_run('a1', 1, a), _run('a2', 2, _oab(1440))])
          .single;
      expect(Trails.marginOf(g, g.anchor), isNull);
      expect(Trails.marginOf(g, g.runs.last), isNotNull);
    });
  });

  group('sidecar', () {
    test('the override survives a JSON round trip, keyed by run id', () {
      for (final o in [
        const TrailOverride.split(),
        const TrailOverride.join('abc'),
      ]) {
        final s = RunSidecar(runId: 'r1', trailOverride: o);
        expect(s.isEmpty, isFalse);
        final back = RunSidecar.fromJson(s.toJson());
        expect(back.trailOverride, o);
      }
      expect(
        RunSidecar(runId: 'r1').toJson().containsKey('trail_override'),
        isFalse,
      );
    });

    test('copyWith can clear it and an unreadable one is ignored', () {
      final s = RunSidecar(
        runId: 'r1',
        trailOverride: const TrailOverride.split(),
      );
      expect(s.copyWith(trailOverride: null).trailOverride, isNull);
      expect(s.copyWith(title: 'x').trailOverride, const TrailOverride.split());
      final j = s.toJson()..['trail_override'] = {'kind': 'join'};
      expect(RunSidecar.fromJson(j).trailOverride, isNull);
    });
  });
}
