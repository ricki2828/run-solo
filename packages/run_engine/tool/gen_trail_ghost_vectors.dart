// Writes test/fixtures/trail_ghost/vectors.json: the shared Dart/Kotlin parity
// vectors for the trail ghost. Each vector is a set of known trails (in the
// JSON the recorder takes), a run (one accepted fix a second: t, lat, lon,
// accuracy, active ms, run distance) and the ghost's state after every fix, from
// THIS implementation. The Kotlin twin (core-jvm TrailGhostParityTest) and
// trail_ghost_parity_test.dart replay the file and compare every field. Never
// edit the file by hand: change a tracker, regenerate, review the diff.
//
//     dart run tool/gen_trail_ghost_vectors.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';

const lat0 = -33.8688, lon0 = 151.2093;
final kLon = 111320.0 * math.cos(lat0 * math.pi / 180);
double lat(double y) => lat0 + y / 111320.0;
double lon(double x) => lon0 + x / kLon;

typedef P = (double, double);

List<P> densify(List<P> corners, double stepM) {
  final out = <P>[corners.first];
  for (var i = 1; i < corners.length; i++) {
    final (ax, ay) = corners[i - 1];
    final (bx, by) = corners[i];
    final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    final n = math.max(1, (len / stepM).ceil());
    for (var k = 1; k <= n; k++) {
      out.add((ax + (bx - ax) * k / n, ay + (by - ay) * k / n));
    }
  }
  return out;
}

GhostTrail trail(
  List<P> corners, {
  String id = 't1',
  double bestMps = 4,
  double? lastMps = 3.5,
  double? turnAlongM,
}) {
  final pts = densify(corners, 25);
  final ll = <double>[];
  final cum = <double>[];
  var d = 0.0;
  for (var i = 0; i < pts.length; i++) {
    ll
      ..add(lat(pts[i].$2))
      ..add(lon(pts[i].$1));
    if (i > 0) {
      d += math.sqrt(
        math.pow(pts[i].$1 - pts[i - 1].$1, 2) +
            math.pow(pts[i].$2 - pts[i - 1].$2, 2),
      );
    }
    cum.add(d);
  }
  GhostProfile profile(String runId, int dateMs, double mps) => GhostProfile(
    runId: runId,
    dateMs: dateMs,
    ms: [for (final c in cum) (c / mps * 1000).floor()],
  );
  return GhostTrail(
    id: id,
    name: 'Trail $id',
    latLon: ll,
    best: profile('best', 1000, bestMps),
    last: lastMps == null ? null : profile('last', 2000, lastMps),
    turnAlongM: turnAlongM,
  );
}

Map<String, Object?> trailJson(GhostTrail t) => {
  'id': t.id,
  'name': t.name,
  'll': t.latLon,
  'best': {'runId': t.best.runId, 'dateMs': t.best.dateMs, 'ms': t.best.ms},
  'last': t.last == null
      ? null
      : {'runId': t.last!.runId, 'dateMs': t.last!.dateMs, 'ms': t.last!.ms},
  'turnM': t.turnAlongM,
};

class Fix {
  Fix(this.t, this.x, this.y, this.acc, this.activeMs, this.distM);
  final int t;
  final double x, y, acc, distM;
  final int activeMs;
}

/// A runner along [corners] at [mps], one fix a second, [noiseM] of wobble.
List<Fix> runner(
  List<List<P>> legs, {
  double mps = 4,
  double noiseM = 0,
  int seed = 1,
  double acc = 5,
  List<(int, int)> stops = const [],
}) {
  final rnd = math.Random(seed);
  final out = <Fix>[];
  var t = 0, active = 0;
  var dist = 0.0;
  for (final leg in legs) {
    for (final (x, y) in densify(leg, mps)) {
      final nx = x + (noiseM > 0 ? (rnd.nextDouble() * 2 - 1) * noiseM : 0);
      final ny = y + (noiseM > 0 ? (rnd.nextDouble() * 2 - 1) * noiseM : 0);
      out.add(Fix(t, nx, ny, acc, active, dist));
      t += 1000;
      active += 1000;
      dist += mps;
    }
  }
  return out;
}

Map<String, Object?> vector(
  String name,
  List<GhostTrail> trails,
  List<Fix> fixes,
) {
  final g = TrailGhostTracker(trails);
  final points = <List<Object?>>[];
  final states = <List<Object?>>[];
  final events = <int>[];
  for (final f in fixes) {
    final ev = g.offer(f.t, lat(f.y), lon(f.x), f.acc, f.activeMs, f.distM);
    for (final e in ev) {
      events.add(e.t);
    }
    points.add([f.t, lat(f.y), lon(f.x), f.acc, f.activeMs, f.distM]);
    final s = g.state;
    states.add(
      s == null
          ? [null]
          : [
              s.trailId,
              s.alongM,
              s.off,
              s.aheadBestMs,
              s.aheadLastMs,
              s.turnCue,
              s.toTurnM,
            ],
    );
  }
  return {
    'name': name,
    'trails': [for (final t in trails) trailJson(t)],
    'points': points,
    'states': states,
    'turnEvents': events,
  };
}

void main() {
  const straight = <P>[(0, 0), (2000, 0)];
  const oab = <P>[(0, 0), (1000, 0), (1000, 6), (0, 6)];
  const loop = <P>[(0, 0), (600, 0), (600, 600), (0, 600), (0, 20)];
  final a = trail(const [(0, 0), (800, 0), (800, 800)], id: 'a');
  final b = trail(const [(0, 0), (800, 0), (1600, 0)], id: 'b');
  final vectors = <Map<String, Object?>>[
    vector('straight_match_noisy', [
      trail(straight),
    ], runner([straight], mps: 4.6, noiseM: 6, seed: 7)),
    vector(
      'straight_slow_behind',
      [trail(straight)],
      runner([
        const [(0, 0), (900, 0)],
      ], mps: 3),
    ),
    vector(
      'last_is_best',
      [trail(straight, lastMps: null)],
      runner(
        [
          const [(0, 0), (1200, 0)],
        ],
        mps: 4.4,
        noiseM: 3,
        seed: 2,
      ),
    ),
    vector('out_and_back_turnaround', [
      trail(oab, turnAlongM: 1000),
    ], runner([oab], noiseM: 4, seed: 3)),
    vector(
      'loop_joined_late',
      [trail(loop)],
      runner(
        [
          const [(300, 0), (600, 0), (600, 600)],
        ],
        mps: 5,
        noiseM: 5,
        seed: 4,
      ),
    ),
    vector(
      'leaves_and_returns',
      [trail(straight)],
      runner([
        const [(0, 0), (600, 0), (600, 120), (600, 0), (1000, 0)],
      ]),
    ),
    vector(
      'shared_start_hands_over',
      [a, b],
      runner(
        [
          const [(0, 0), (800, 0), (1600, 0)],
        ],
        noiseM: 4,
        seed: 5,
      ),
    ),
    vector(
      'parallel_never_matches',
      [trail(straight)],
      runner([
        const [(0, 100), (1500, 100)],
      ]),
    ),
    vector(
      'reversed_never_matches',
      [trail(straight)],
      runner([
        const [(2000, 0), (0, 0)],
      ]),
    ),
    vector(
      'diverges_before_confirm',
      [trail(straight)],
      runner([
        const [(0, 0), (200, 0), (300, 400), (1500, 400)],
      ]),
    ),
  ];
  // One vector per line: the diff of a regenerated file stays reviewable.
  final body = [for (final v in vectors) '  ${jsonEncode(v)}'].join(',\n');
  File('test/fixtures/trail_ghost/vectors.json').writeAsStringSync(
    '{"note":"Generated by tool/gen_trail_ghost_vectors.dart. Never edit by hand.",\n"vectors":[\n$body\n]}\n',
  );
  stdout.writeln('wrote ${vectors.length} vectors');
}
