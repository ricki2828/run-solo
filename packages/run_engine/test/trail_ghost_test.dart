import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _lat0 = -33.8688, _lon0 = 151.2093;
final _kLon = 111320.0 * math.cos(_lat0 * math.pi / 180);

(double, double) _ll(double x, double y) =>
    (_lat0 + y / 111320.0, _lon0 + x / _kLon);

/// A synthetic trail run: samples every second along [corners] at [mps],
/// with an optional pause of [pauseMs] after [pauseAtMs].
RunFile _run(
  String id,
  List<(double, double)> corners, {
  double mps = 4,
  int? pauseAtMs,
  int pauseMs = 0,
  double Function(double along)? elev,
  ElevSource? src,
}) {
  final base = fixture('easy_free_run').run;
  final pts = <(double, double)>[corners.first];
  for (var i = 1; i < corners.length; i++) {
    final (ax, ay) = corners[i - 1];
    final (bx, by) = corners[i];
    final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    final n = math.max(1, (len / mps).ceil());
    for (var k = 1; k <= n; k++) {
      pts.add((ax + (bx - ax) * k / n, ay + (by - ay) * k / n));
    }
  }
  final samples = <Sample>[];
  var t = 0;
  var dist = 0.0;
  for (var i = 0; i < pts.length; i++) {
    if (pauseAtMs != null && t == pauseAtMs) t += pauseMs;
    final (la, lo) = _ll(pts[i].$1, pts[i].$2);
    if (i > 0) {
      dist += math.sqrt(
        math.pow(pts[i].$1 - pts[i - 1].$1, 2) +
            math.pow(pts[i].$2 - pts[i - 1].$2, 2),
      );
    }
    samples.add(
      Sample(
        tMs: t,
        lat: la,
        lon: lo,
        accM: 5,
        distM: dist,
        elevM: elev?.call(dist),
      ),
    );
    t += 1000;
  }
  final r = base.copyWith(
    id: id,
    mode: RunMode.trail,
    samples: samples,
    laps: const [],
    elevSrc: src,
    pauses: pauseAtMs == null
        ? const []
        : [Span(pauseAtMs + 1000 - 1000, pauseAtMs + pauseMs)],
  );
  return r;
}

void main() {
  const straight = [(0.0, 0.0), (2000.0, 0.0)];
  const oab = [(0.0, 0.0), (1000.0, 0.0), (1000.0, 6.0), (0.0, 6.0)];

  group('elevation and climbs', () {
    // 2 km: flat 0..600, a 40 m climb over 600..1000 (10%), flat to 1400,
    // then a 20 m descent back to 20 m by 2000. Noise of +-0.4 m.
    double hill(double d) {
      final noise = ((d * 7).round() % 5 - 2) * 0.2;
      if (d < 600) return noise;
      if (d < 1000) return (d - 600) / 400 * 40 + noise;
      if (d < 1400) return 40 + noise;
      return 40 - (d - 1400) / 600 * 20 + noise;
    }

    GhostTrail build(RunFile r) =>
        TrailGhostBuilder.build(id: 'k', name: 'Kastro', best: r, last: r)!;

    test('a barometer trail packs a smoothed profile and its one climb', () {
      final t = build(_run('h', straight, elev: hill, src: ElevSource.baro));
      expect(t.elevSrc, 'baro');
      expect(t.elevM!.length, t.latLon.length ~/ 2);
      expect(t.climbs, hasLength(1));
      final c = t.climbs.single;
      expect(c.startM, closeTo(600, 80));
      expect(c.endM, closeTo(1000, 80));
      expect(c.gainM, closeTo(40, 6));
      expect(c.avgGradePct, closeTo(10, 2.5));
      // Smoothed: no vertex-to-vertex jump from the +-0.4 m noise.
      for (var i = 1; i < t.elevM!.length; i++) {
        expect((t.elevM![i] - t.elevM![i - 1]).abs(), lessThan(3));
      }
    });

    test('GPS-only elevation gives the profile but no climbs', () {
      final t = build(_run('g', straight, elev: hill, src: ElevSource.gps));
      expect(t.elevSrc, 'gps');
      expect(t.elevM, isNotNull);
      expect(t.climbs, isEmpty);
    });

    test('a run with no elevation gives neither', () {
      final t = build(_run('n', straight));
      expect(t.elevM, isNull);
      expect(t.elevSrc, isNull);
      expect(t.climbs, isEmpty);
    });

    test('a flat trail and a small bump have no climbs', () {
      final bump = build(
        _run(
          'b',
          straight,
          src: ElevSource.baro,
          elev: (d) => d > 800 && d < 1000 ? (d - 800) / 200 * 8 : 0,
        ),
      );
      expect(bump.climbs, isEmpty);
    });

    test('a short run along a long trail leaves the unreached end flat', () {
      final full = _run('f', straight, elev: hill, src: ElevSource.baro);
      final half = _run(
        's',
        const [(0.0, 0.0), (1200.0, 0.0)],
        elev: hill,
        src: ElevSource.baro,
      );
      final t = TrailGhostBuilder.build(
        id: 'k',
        name: 'Kastro',
        best: half,
        last: full,
      )!;
      expect(t.elevM!.length, t.latLon.length ~/ 2);
      expect(t.climbs, hasLength(1));
    });
  });

  group('builder', () {
    test('geometry is bounded and the profile reads time at distance', () {
      final r = _run('a', straight, mps: 4);
      final g = TrailGhostBuilder.geometry(r)!;
      final n = g.length ~/ 2;
      expect(n, inInclusiveRange(2, GhostTrail.maxPoints));
      final path = GhostPath(g);
      expect(path.totalM, closeTo(2000, 30));
      final ms = TrailGhostBuilder.profile(path, r)!;
      expect(ms.length, n);
      // 4 m/s: 1000 m in about 250 s.
      final mid = path.interpolate(1000, ms)!;
      expect(mid, closeTo(250000, 4000));
      // Monotone.
      for (var i = 1; i < ms.length; i++) {
        expect(ms[i], greaterThanOrEqualTo(ms[i - 1]));
      }
    });

    test('a long trail stays under the vertex cap', () {
      final r = _run('long', const [(0.0, 0.0), (30000.0, 0.0)], mps: 3.5);
      final g = TrailGhostBuilder.geometry(r)!;
      expect(g.length ~/ 2, lessThanOrEqualTo(GhostTrail.maxPoints));
    });

    test('a pause comes out of the profile', () {
      final plain = _run('p', straight, mps: 4);
      final paused = _run(
        'p2',
        straight,
        mps: 4,
        pauseAtMs: 100000,
        pauseMs: 60000,
      );
      final geo = TrailGhostBuilder.geometry(plain)!;
      final path = GhostPath(geo);
      final a = TrailGhostBuilder.profile(path, plain)!;
      final b = TrailGhostBuilder.profile(path, paused)!;
      final end = path.size - 1;
      expect((a[end] - b[end]).abs(), lessThan(3000));
    });

    test('a shorter last run leaves -1 beyond where it went', () {
      final best = _run('best', straight, mps: 4);
      final last = _run('last', const [(0.0, 0.0), (1200.0, 0.0)], mps: 3);
      final t = TrailGhostBuilder.build(
        id: 't',
        name: 'T',
        best: best,
        last: last,
      )!;
      expect(t.best.ms.last, greaterThan(0));
      expect(t.last, isNotNull);
      expect(t.last!.ms.last, -1);
      expect(t.last!.ms.first, greaterThanOrEqualTo(0));
    });

    test(
      'out and back has a turnaround, a loop and a one way trail do not',
      () {
        final o = TrailGhostBuilder.geometry(_run('o', oab))!;
        final turn = TrailGhostBuilder.turnaround(o);
        expect(turn, isNotNull);
        expect(turn, closeTo(1000, 40));
        expect(
          TrailGhostBuilder.turnaround(
            TrailGhostBuilder.geometry(_run('s', straight))!,
          ),
          isNull,
        );
        final loop = TrailGhostBuilder.geometry(
          _run('l', const [
            (0.0, 0.0),
            (600.0, 0.0),
            (600.0, 600.0),
            (0.0, 600.0),
            (0.0, 20.0),
          ]),
        )!;
        expect(TrailGhostBuilder.turnaround(loop), isNull);
      },
    );
  });

  group('replay of a recorded run through the tracker', () {
    test('a second run on the same trail is matched and compared', () {
      final first = _run('first', straight, mps: 4);
      final trail = TrailGhostBuilder.build(
        id: 't',
        name: 'T',
        best: first,
        last: first,
      )!;
      final second = _run('second', straight, mps: 5);
      final g = TrailGhostTracker([trail]);
      var active = 0;
      for (final s in second.samples) {
        g.offer(s.tMs, s.lat!, s.lon!, s.accM!, active, s.distM);
        active += 1000;
      }
      final st = g.state!;
      expect(st.trailId, 't');
      expect(st.lastIsBest, isTrue);
      // 2000 m at 5 m/s against 4 m/s: 500 s - 400 s.
      expect(st.aheadBestMs, closeTo(100000, 6000));
    });

    test('a run on another trail is not matched', () {
      final first = _run('first', straight, mps: 4);
      final trail = TrailGhostBuilder.build(
        id: 't',
        name: 'T',
        best: first,
        last: first,
      )!;
      final other = _run('other', const [(0.0, 300.0), (2000.0, 300.0)]);
      final g = TrailGhostTracker([trail]);
      var active = 0;
      for (final s in other.samples) {
        g.offer(s.tMs, s.lat!, s.lon!, s.accM!, active, s.distM);
        active += 1000;
      }
      expect(g.state, isNull);
    });
  });

  test('a trail refuses a profile of the wrong size', () {
    expect(
      () => GhostTrail(
        id: 'x',
        name: 'x',
        latLon: const [0, 0, 0.001, 0.001],
        best: const GhostProfile(runId: 'r', dateMs: 0, ms: [0]),
      ),
      throwsArgumentError,
    );
  });
}
