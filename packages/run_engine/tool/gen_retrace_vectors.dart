// Writes test/fixtures/retrace/vectors.json: the shared Dart/Kotlin parity
// vectors for RetraceDetector. Each vector is a track (lat, lon, elev) and the
// RetraceState after every point, from THIS implementation. The Kotlin twin
// (core-jvm RetraceParityTest) and retrace_parity_test.dart both replay the
// file and compare every field to 0.5 m. Never edit the file by hand: change
// a detector, regenerate, and review the diff.
//
//     dart run tool/gen_retrace_vectors.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';

const _mPerDeg = 111320.0;

double _profile(double alongM) =>
    alongM <= 300 ? alongM * 0.08 : 24 - (alongM - 300) * 0.06;

List<List<double?>> _outAndBack() {
  final pts = <List<double?>>[];
  for (var m = 0.0; m <= 600; m += 3) {
    pts.add([m / _mPerDeg, 0.0, _profile(m)]);
  }
  for (var m = 600.0; m >= 0; m -= 3) {
    pts.add([m / _mPerDeg, 4 / _mPerDeg, _profile(m)]);
  }
  return pts;
}

List<List<double?>> _loop() {
  final pts = <List<double?>>[];
  const r = 150.0;
  for (var s = 0.0; s <= 2 * math.pi * r * 0.95; s += 3) {
    final a = s / r;
    pts.add([
      r * math.sin(a) / _mPerDeg,
      r * (1 - math.cos(a)) / _mPerDeg,
      10.0 * math.sin(a),
    ]);
  }
  return pts;
}

List<List<double?>> _jitter() {
  final rnd = math.Random(3);
  double n() => (rnd.nextDouble() - 0.5) * 16;
  final pts = <List<double?>>[];
  // The 4th value is the recorder's filtered distance run (true, not noisy).
  for (var m = 0.0; m <= 600; m += 3) {
    pts.add([(m + n()) / _mPerDeg, n() / _mPerDeg, _profile(m) + n() * 0.1, m]);
  }
  for (var m = 600.0; m >= 150; m -= 3) {
    pts.add([
      (m + n()) / _mPerDeg,
      n() / _mPerDeg,
      _profile(m) + n() * 0.1,
      1200 - m,
    ]);
  }
  return pts;
}

List<List<double?>> _lShape() {
  final pts = <List<double?>>[];
  for (var m = 0.0; m <= 300; m += 3) {
    pts.add([m / _mPerDeg, 0.0, 0.0]);
  }
  for (var m = 3.0; m <= 300; m += 3) {
    pts.add([300 / _mPerDeg, m / _mPerDeg, m * 0.05]);
  }
  for (var m = 300.0; m >= 100; m -= 3) {
    pts.add([302 / _mPerDeg, m / _mPerDeg, m * 0.05]);
  }
  return pts;
}

/// A circle run 1.3 times round: the second pass re-covers the first in the
/// SAME direction, so it must read as RetraceDirection.same once past the
/// same-direction gap.
List<List<double?>> _sameLoop() {
  final pts = <List<double?>>[];
  const r = 120.0;
  const circ = 2 * math.pi * r;
  for (var s = 0.0; s <= circ * 1.3; s += 3) {
    final a = s / r;
    pts.add([
      r * math.sin(a) / _mPerDeg,
      r * (1 - math.cos(a)) / _mPerDeg,
      8.0 * math.sin(a),
      s,
    ]);
  }
  return pts;
}

/// A figure-8: the two strands cross at about 90 degrees, so the crossing is
/// never a retrace.
List<List<double?>> _figureEight() {
  final pts = <List<double?>>[];
  const a = 120.0;
  // Gerono lemniscate, about 3 m between points.
  var s = 0.0;
  double? px, py;
  for (var i = 0; i <= 1000; i++) {
    final th = i / 1000 * 2 * math.pi;
    final x = a * math.sin(th);
    final y = a * math.sin(th) * math.cos(th);
    if (px != null) s += math.sqrt(math.pow(x - px, 2) + math.pow(y - py!, 2));
    px = x;
    py = y;
    if (i % 3 == 0) {
      pts.add([y / _mPerDeg, x / _mPerDeg, 0.0, s]);
    }
  }
  return pts;
}

/// A 400 m stadium oval (two 84.4 m straights, two 36.5 m radius ends) run
/// three laps: lap 2 and 3 re-cover lap 1 in the same direction.
List<List<double?>> _oval3Laps() {
  const straight = 84.39;
  const r = 36.5;
  const lap = 2 * straight + 2 * math.pi * r;
  final pts = <List<double?>>[];
  for (var s = 0.0; s <= lap * 3; s += 3) {
    final u = s % lap;
    double x, y;
    if (u < straight) {
      x = u;
      y = 0;
    } else if (u < straight + math.pi * r) {
      final a = (u - straight) / r;
      x = straight + r * math.sin(a);
      y = r - r * math.cos(a);
    } else if (u < 2 * straight + math.pi * r) {
      x = straight - (u - straight - math.pi * r);
      y = 2 * r;
    } else {
      final a = (u - 2 * straight - math.pi * r) / r;
      x = -r * math.sin(a);
      y = 2 * r - (r - r * math.cos(a));
    }
    pts.add([y / _mPerDeg, x / _mPerDeg, 0.0, s]);
  }
  return pts;
}

/// A GPS teleport: 300 m north, a 500 km jump, 200 m more, a 500 km jump
/// back to the original line, then 250 m back south along it. The jumps are
/// breaks (never indexed, no distance, no streak across them), and the way
/// back over the original line is still recognised.
List<List<double?>> _gpsJump() {
  final pts = <List<double?>>[];
  for (var m = 0.0; m <= 300; m += 3) {
    pts.add([m / _mPerDeg, 0.0, m * 0.05]);
  }
  const far = 4.5; // degrees of latitude, about 500 km
  for (var m = 0.0; m <= 200; m += 3) {
    pts.add([far + m / _mPerDeg, 0.0, 15.0]);
  }
  for (var m = 300.0; m >= 50; m -= 3) {
    pts.add([m / _mPerDeg, 4 / _mPerDeg, m * 0.05]);
  }
  return pts;
}

Map<String, Object?> _vector(String name, List<List<double?>> pts) {
  final d = RetraceDetector();
  final states = <List<Object?>>[];
  for (final p in pts) {
    final s = d.add(
      lat: p[0]!,
      lon: p[1]!,
      elevM: p[2],
      distM: p.length > 3 ? p[3] : null,
    );
    states.add([
      s.retracing,
      s.direction?.name,
      s.distanceToStartM,
      s.climbAheadM,
      s.descentAheadM,
      s.heightVsStartM,
    ]);
  }
  return {'name': name, 'points': pts, 'states': states};
}

void main() {
  final out = {
    'about':
        'RetraceDetector parity vectors. points: [lat, lon, elev] or [lat, lon, elev, distM]. states: '
        '[retracing, direction, distanceToStartM, climbAheadM, descentAheadM, '
        'heightVsStartM] after each point. Generated by '
        'tool/gen_retrace_vectors.dart; never hand-edited.',
    'vectors': [
      _vector('out_and_back', _outAndBack()),
      _vector('loop', _loop()),
      _vector('jitter_out_and_back', _jitter()),
      _vector('l_shape_out_and_back', _lShape()),
      _vector('same_direction_loop', _sameLoop()),
      _vector('figure_eight', _figureEight()),
      _vector('oval_three_laps', _oval3Laps()),
      _vector('gps_jump_500km', _gpsJump()),
    ],
  };
  final f = File('test/fixtures/retrace/vectors.json')
    ..createSync(recursive: true);
  f.writeAsStringSync('${jsonEncode(out)}\n');
  stdout.writeln('wrote ${f.path} (${f.lengthSync()} bytes)');
}
