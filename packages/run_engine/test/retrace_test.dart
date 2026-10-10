import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

const _mPerDegLat = 111320.0;

/// Metres north / east of (0, 0) to a lat / lon pair.
(double, double) _ll(double northM, double eastM) =>
    (northM / _mPerDegLat, eastM / _mPerDegLat);

/// Elevation of the out leg at [alongM] metres (rises 40 m over the first
/// 500 m, falls 30 m over the next 500 m).
double _profile(double alongM) =>
    alongM <= 500 ? alongM * 0.08 : 40 - (alongM - 500) * 0.06;

RetraceState _feed(
  RetraceDetector d,
  double north,
  double east,
  double? elev,
) {
  final (lat, lon) = _ll(north, east);
  return d.add(lat: lat, lon: lon, elevM: elev);
}

void main() {
  test('out-and-back: retracing on the way back, not on the way out', () {
    final d = RetraceDetector();
    // Out: 1 km north at 3 m/s, a fix every second.
    for (var m = 0.0; m <= 1000; m += 3) {
      final s = _feed(d, m, 0, _profile(m));
      expect(s.retracing, isFalse, reason: 'out leg at $m m');
    }
    // Back: south, 4 m east of the outward line.
    var firstRetraceAt = -1.0;
    for (var m = 1000.0; m >= 0; m -= 3) {
      final s = _feed(d, m, 4, _profile(m));
      if (s.retracing && firstRetraceAt < 0) firstRetraceAt = m;
    }
    // Sustained ~100 m before it is believed, not on the first fix.
    expect(firstRetraceAt, inInclusiveRange(850, 920));
  });

  test('out-and-back readouts 300 m into the return', () {
    final d = RetraceDetector();
    for (var m = 0.0; m <= 1000; m += 3) {
      _feed(d, m, 0, _profile(m));
    }
    var mid = RetraceState.none;
    for (var m = 1000.0; m >= 700; m -= 3) {
      mid = _feed(d, m, 4, _profile(m));
    }
    expect(mid.retracing, isTrue);
    expect(mid.direction, RetraceDirection.reverse);
    // Along the recorded track from the matched point back to the start.
    expect(mid.distanceToStartM, closeTo(700, 15));
    // Ahead on the old track from 700 m: up 12 m to the crest, then down
    // 40 m to the start (3 m dead band either way).
    expect(mid.climbAheadM, closeTo(12, 4));
    expect(mid.descentAheadM, closeTo(40, 4));
    // The runner is at 28 m, the start at 0.
    expect(mid.heightVsStartM, closeTo(28, 1));
  });

  test('distance to start is along the track, not straight line', () {
    final d = RetraceDetector();
    // Out: 400 m north then 400 m east (an L); straight line to the start
    // from the far end is 566 m, the track is 800 m.
    for (var m = 0.0; m <= 400; m += 3) {
      _feed(d, m, 0, 0);
    }
    for (var m = 3.0; m <= 400; m += 3) {
      _feed(d, 400, m, 0);
    }
    var s = RetraceState.none;
    // Back along the east leg to 200 m east of the corner.
    for (var m = 400.0; m >= 200; m -= 3) {
      s = _feed(d, 402, m, 0);
    }
    expect(s.retracing, isTrue);
    // 400 north + 200 east.
    expect(s.distanceToStartM, closeTo(600, 15));
  });

  test('a circle with no retrace never flags', () {
    final d = RetraceDetector();
    const r = 150.0;
    const circ = 2 * math.pi * r;
    for (var s = 0.0; s <= circ * 0.95; s += 3) {
      final a = s / r;
      final st = _feed(d, r * math.sin(a), r * (1 - math.cos(a)), null);
      expect(st.retracing, isFalse, reason: 'at $s m');
    }
  });

  test('a rectangular loop (back a different way) never flags', () {
    final d = RetraceDetector();
    // 600 m north, 300 m east, 600 m south, 300 m west. The two long legs
    // are 300 m apart: far outside the 25 m match radius.
    for (var m = 0.0; m < 600; m += 3) {
      expect(_feed(d, m, 0, null).retracing, isFalse);
    }
    for (var m = 0.0; m < 300; m += 3) {
      expect(_feed(d, 600, m, null).retracing, isFalse);
    }
    for (var m = 600.0; m > 0; m -= 3) {
      expect(_feed(d, m, 300, null).retracing, isFalse);
    }
    for (var m = 300.0; m > 30; m -= 3) {
      expect(_feed(d, 0, m, null).retracing, isFalse);
    }
  });

  test('jittery GPS: a one-way run with +/-8 m noise never flags', () {
    final rnd = math.Random(42);
    final d = RetraceDetector();
    for (var m = 0.0; m <= 1500; m += 3) {
      final s = _feed(
        d,
        m + (rnd.nextDouble() - 0.5) * 16,
        (rnd.nextDouble() - 0.5) * 16,
        null,
      );
      expect(s.retracing, isFalse, reason: 'at $m m');
    }
  });

  test('jittery GPS: standing still for two minutes never flags', () {
    final rnd = math.Random(7);
    final d = RetraceDetector();
    for (var m = 0.0; m <= 300; m += 3) {
      _feed(d, m, 0, null);
    }
    for (var i = 0; i < 120; i++) {
      final s = _feed(
        d,
        300 + (rnd.nextDouble() - 0.5) * 12,
        (rnd.nextDouble() - 0.5) * 12,
        null,
      );
      expect(s.retracing, isFalse, reason: 'tick $i');
    }
  });

  test('jittery GPS: an out-and-back with +/-8 m noise still flags', () {
    final rnd = math.Random(3);
    final d = RetraceDetector();
    double n() => (rnd.nextDouble() - 0.5) * 16;
    for (var m = 0.0; m <= 1000; m += 3) {
      _feed(d, m + n(), n(), null);
    }
    var flagged = false;
    for (var m = 1000.0; m >= 600; m -= 3) {
      if (_feed(d, m + n(), n(), null).retracing) flagged = true;
    }
    expect(flagged, isTrue);
  });

  test('jitter holds across 30 seeds: one-way never flags, return does', () {
    for (var seed = 100; seed < 130; seed++) {
      final rnd = math.Random(seed);
      double n() => (rnd.nextDouble() - 0.5) * 16;
      final oneWay = RetraceDetector();
      for (var m = 0.0; m <= 1200; m += 3) {
        expect(
          _feed(oneWay, m + n(), n(), null).retracing,
          isFalse,
          reason: 'one-way seed $seed at $m m',
        );
      }
      final back = RetraceDetector();
      for (var m = 0.0; m <= 1000; m += 3) {
        _feed(back, m + n(), n(), null);
      }
      var flagged = false;
      for (var m = 1000.0; m >= 600; m -= 3) {
        if (_feed(back, m + n(), n(), null).retracing) flagged = true;
      }
      expect(flagged, isTrue, reason: 'return seed $seed');
    }
  });

  test('a short brush with the old track (under 100 m) does not flag', () {
    final d = RetraceDetector();
    for (var m = 0.0; m <= 600; m += 3) {
      _feed(d, m, 0, null);
    }
    // Swing east, run back south on a path 60 m away, then cross the line
    // westwards: only a short stretch is within 25 m of the old track.
    for (var e = 3.0; e <= 60; e += 3) {
      _feed(d, 600, e, null);
    }
    for (var m = 600.0; m >= 540; m -= 3) {
      expect(_feed(d, m, 60, null).retracing, isFalse);
    }
    for (var e = 57.0; e >= 0; e -= 3) {
      expect(_feed(d, 540, e, null).retracing, isFalse);
    }
  });

  test('leaving the old track ends the retrace', () {
    final d = RetraceDetector();
    for (var m = 0.0; m <= 1000; m += 3) {
      _feed(d, m, 0, null);
    }
    var s = RetraceState.none;
    for (var m = 1000.0; m >= 600; m -= 3) {
      s = _feed(d, m, 3, null);
    }
    expect(s.retracing, isTrue);
    // Branch off east, away from the old track.
    for (var e = 3.0; e <= 120; e += 3) {
      s = _feed(d, 600, e, null);
    }
    expect(s.retracing, isFalse);
  });

  test('same direction on a second lap flags once past the gap', () {
    final d = RetraceDetector();
    // Up the line, round a wide rectangle, then up the line again.
    for (var m = 0.0; m <= 600; m += 3) {
      _feed(d, m, 0, null);
    }
    for (var e = 3.0; e <= 200; e += 3) {
      _feed(d, 600, e, null);
    }
    for (var m = 600.0; m >= 0; m -= 3) {
      _feed(d, m, 200, null);
    }
    for (var e = 197.0; e >= 0; e -= 3) {
      _feed(d, 0, e, null);
    }
    var s = RetraceState.none;
    for (var m = 3.0; m <= 300; m += 3) {
      s = _feed(d, m, 0, null);
    }
    expect(s.retracing, isTrue);
    expect(s.direction, RetraceDirection.same);
  });

  test('height vs start is available from the first elevation', () {
    final d = RetraceDetector();
    expect(d.state.heightVsStartM, isNull);
    _feed(d, 0, 0, 100);
    expect(d.state.heightVsStartM, 0);
    _feed(d, 50, 0, 142);
    expect(d.state.heightVsStartM, 42);
    // Standing still still follows the elevation.
    _feed(d, 50.5, 0, 118);
    expect(d.state.heightVsStartM, 18);
    _feed(d, 90, 0, 82);
    expect(d.state.heightVsStartM, -18);
  });

  test('reset forgets the track', () {
    final d = RetraceDetector();
    for (var m = 0.0; m <= 200; m += 3) {
      _feed(d, m, 0, 5);
    }
    d.reset();
    expect(d.length, 0);
    expect(d.state.heightVsStartM, isNull);
  });
}
