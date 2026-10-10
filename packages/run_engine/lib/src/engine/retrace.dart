import 'dart:math' as math;

import 'elevation.dart';

/// Which way the runner is covering the old track.
enum RetraceDirection {
  /// Heading back the way they came (out-and-back).
  reverse,

  /// Covering the same line again in the same direction (a second lap).
  same,
}

/// What [RetraceDetector] knows right now. Immutable; read it after each
/// [RetraceDetector.add].
class RetraceState {
  const RetraceState({
    this.retracing = false,
    this.direction,
    this.distanceToStartM,
    this.climbAheadM,
    this.descentAheadM,
    this.heightVsStartM,
  });

  /// Nothing known yet.
  static const RetraceState none = RetraceState();

  /// True once the runner has been on their own earlier track, matching it
  /// within [RetraceDetector.matchRadiusM] with a heading that is roughly
  /// opposite or the same, for [RetraceDetector.sustainM] of running.
  /// Stays true through a short GPS gap and drops once the runner has left
  /// the old track for [RetraceDetector.gapToleranceM].
  final bool retracing;

  /// Null unless [retracing].
  final RetraceDirection? direction;

  /// Metres along the RECORDED track (not straight line) from the matched
  /// point on the old track back to the start. Null unless [retracing].
  final double? distanceToStartM;

  /// Elevation gained / lost on the stretch of the old track still ahead of
  /// the runner: for [RetraceDirection.reverse] from the matched point back
  /// to the start; for [RetraceDirection.same] from the matched point on
  /// along the old track up to where the repeat began. Positive metres,
  /// dead-banded like the live climb total. Null unless [retracing] and the
  /// track has at least two elevations on that stretch.
  final double? climbAheadM;
  final double? descentAheadM;

  /// Current elevation minus the elevation at the start (metres, + above).
  /// Available as soon as one elevation was offered, retracing or not.
  final double? heightVsStartM;

  @override
  String toString() =>
      'RetraceState(retracing: $retracing, dir: $direction, '
      'toStart: $distanceToStartM, climb: $climbAheadM, '
      'descent: $descentAheadM, height: $heightVsStartM)';
}

/// Knows when the runner is retracing a section of their own track, e.g. an
/// out-and-back on a trail. Pure Dart; feed it the live track.
///
///     final d = RetraceDetector();
///     final s = d.add(lat: lat, lon: lon, elevM: elevM);
///     if (s.retracing) { /* s.distanceToStartM ... */ }
///
/// [add] takes points in order, about 1 Hz; the recorder's simplified route
/// points are fine (matching is against segments, not points). `elevM` is
/// any consistent elevation (barometer-smoothed, or the [ClimbTracker]
/// net climb); only differences are used.
class RetraceDetector {
  RetraceDetector({
    this.matchRadiusM = 25,
    this.sustainM = 100,
    this.gapToleranceM = 30,
    this.reverseMinGapM = 40,
    this.sameMinGapM = 150,
    this.maxHeadingDiffDeg = 45,
  });

  /// Distance from the old track that counts as being on it.
  final double matchRadiusM;

  /// How far the runner must stay on the old track before
  /// [RetraceState.retracing] turns true (rides out GPS jitter).
  final double sustainM;

  /// Distance run off the old track before a streak ends.
  final double gapToleranceM;

  /// Track the runner must have covered since a segment before it can match
  /// (reverse: lets a hairpin turn match; same: stops a runner matching
  /// their own trail).
  final double reverseMinGapM;
  final double sameMinGapM;

  /// How far off exactly opposite / exactly the same still counts.
  final double maxHeadingDiffDeg;

  /// A point closer than this to the previous kept point only updates the
  /// elevation.
  static const double minStepM = 2;

  // Local metres, x east / y north, about the first point.
  double _lat0 = 0, _lon0 = 0, _cosLat = 1;
  final List<double> _x = [], _y = [], _s = [];
  final List<double?> _e = [];
  double? _firstElev, _lastElev;
  double? _dist0;

  // The current streak of matching.
  bool _hasStreak = false;
  RetraceDirection? _dir;
  double _streakStartS = 0, _streakStartX = 0, _streakStartY = 0;
  double _lastMatchOwnS = 0, _matchS = 0;
  int _matchSeg = 0;
  double _matchT = 0;

  RetraceState _state = RetraceState.none;
  RetraceState get state => _state;

  /// Number of kept track points.
  int get length => _x.length;

  /// Total recorded track length so far, metres.
  double get trackLengthM => _s.isEmpty ? 0 : _s.last;

  void reset() {
    _x.clear();
    _y.clear();
    _s.clear();
    _e.clear();
    _segHead.clear();
    _firstElev = _lastElev = null;
    _dist0 = null;
    _hasStreak = false;
    _dir = null;
    _state = RetraceState.none;
  }

  /// Feeds one accepted fix. [distM] is the caller's own distance run (the
  /// recorder's filtered, pause-frozen total); when given, the along-track
  /// distances use it instead of summing raw fix-to-fix steps, which GPS
  /// noise inflates. Only differences are used. Without it the detector
  /// sums the steps itself.
  RetraceState add({
    required double lat,
    required double lon,
    double? elevM,
    double? distM,
  }) {
    if (elevM != null) {
      _firstElev ??= elevM;
      _lastElev = elevM;
    }
    if (_x.isEmpty) {
      _lat0 = lat;
      _lon0 = lon;
      _cosLat = math.cos(lat * math.pi / 180);
    }
    final x = (lon - _lon0) * _mPerDeg * _cosLat;
    final y = (lat - _lat0) * _mPerDeg;
    if (_x.isNotEmpty) {
      final step = _hyp(x - _x.last, y - _y.last);
      if (step < minStepM) {
        return _state = _withHeight(_state);
      }
      if (distM != null) {
        _s.add(math.max(_s.last, distM - (_dist0 ??= distM)));
      } else {
        _s.add(_s.last + step);
      }
    } else {
      _dist0 = distM;
      _s.add(0);
    }
    _x.add(x);
    _y.add(y);
    _e.add(elevM);
    _update();
    return _state;
  }

  RetraceState _withHeight(RetraceState s) => RetraceState(
    retracing: s.retracing,
    direction: s.direction,
    distanceToStartM: s.distanceToStartM,
    climbAheadM: s.climbAheadM,
    descentAheadM: s.descentAheadM,
    heightVsStartM: _height,
  );

  double? get _height => (_firstElev == null || _lastElev == null)
      ? null
      : _lastElev! - _firstElev!;

  void _update() {
    final here = _x.length - 1;
    final sNow = _s[here];
    final head = _ownHeading(here);
    _Match? best;
    if (head != null && here >= 2) {
      for (var k = 0; k + 1 < here; k++) {
        // Segments are in track order, so once one is too recent for the
        // shortest gap, all later ones are.
        if (_s[k + 1] > sNow - reverseMinGapM) break;
        final m = _project(k, _x[here], _y[here]);
        if (m.distM > matchRadiusM) continue;
        final diff = _angleDiff(head, _segHeading(k));
        RetraceDirection? dir;
        if (diff >= 180 - maxHeadingDiffDeg) {
          dir = RetraceDirection.reverse;
        } else if (diff <= maxHeadingDiffDeg &&
            _s[k + 1] <= sNow - sameMinGapM) {
          dir = RetraceDirection.same;
        }
        if (dir == null) continue;
        if (best == null || m.distM < best.distM) {
          best = _Match(
            m.distM,
            _s[k] + m.t * (_s[k + 1] - _s[k]),
            k,
            m.t,
            dir,
          );
        }
      }
    }
    if (best != null) {
      // The match must move along the old track the way the runner moves
      // along the new one, otherwise it is a fresh streak.
      final consistent =
          _hasStreak &&
          _dir == best.dir &&
          (best.dir == RetraceDirection.reverse
              ? best.s <= _matchS + 40
              : best.s >= _matchS - 40);
      if (!consistent) {
        _hasStreak = true;
        _dir = best.dir;
        _streakStartS = sNow;
        _streakStartX = _x[here];
        _streakStartY = _y[here];
      }
      _lastMatchOwnS = sNow;
      _matchS = best.s;
      _matchSeg = best.seg;
      _matchT = best.t;
    } else if (_hasStreak && sNow - _lastMatchOwnS > gapToleranceM) {
      _hasStreak = false;
      _dir = null;
    }

    var retracing = false;
    if (_hasStreak) {
      final run = _lastMatchOwnS - _streakStartS;
      final disp = _hyp(_x[here] - _streakStartX, _y[here] - _streakStartY);
      // Net progress as well as path length: GPS wander around one spot
      // piles up path length without going anywhere.
      retracing = run >= sustainM && disp >= sustainM * 0.5;
    }
    if (!retracing) {
      _state = RetraceState(heightVsStartM: _height);
      return;
    }
    final dir = _dir!;
    final (climb, descent) = _ahead(dir, here);
    _state = RetraceState(
      retracing: true,
      direction: dir,
      distanceToStartM: _matchS,
      climbAheadM: climb,
      descentAheadM: descent,
      heightVsStartM: _height,
    );
  }

  /// Elevation gain and loss on the old stretch still ahead.
  (double?, double?) _ahead(RetraceDirection dir, int here) {
    final series = <double>[];
    final seg = _matchSeg;
    final eA = _e[seg], eB = _e[seg + 1];
    if (eA != null && eB != null) series.add(eA + (eB - eA) * _matchT);
    if (dir == RetraceDirection.reverse) {
      for (var i = seg; i >= 0; i--) {
        final e = _e[i];
        if (e != null) series.add(e);
      }
    } else {
      // On to where the repeat began, never past the runner's own position.
      for (var i = seg + 1; i < here && _s[i] < _streakStartS; i++) {
        final e = _e[i];
        if (e != null) series.add(e);
      }
    }
    if (series.length < 2) return (null, null);
    final t = ClimbTracker(ClimbTracker.baroThresholdM);
    for (final e in series) {
      t.offer(e);
    }
    return (t.ascentM, t.descentM);
  }

  /// Heading baselines, straight-line: a few metres of GPS noise must not
  /// turn a heading, and noise inflates path length, so the baseline is the
  /// distance actually covered.
  static const double _ownBaselineM = 30;
  static const double _segHalfWindowM = 25;

  double _dist(int i, int j) => _hyp(_x[i] - _x[j], _y[i] - _y[j]);

  /// Bearing (degrees from north) of the runner's last [_ownBaselineM].
  double? _ownHeading(int here) {
    if (here < 1) return null;
    var k = here - 1;
    while (k > 0 && _dist(here, k) < _ownBaselineM) {
      k--;
    }
    if (_dist(here, k) < _ownBaselineM / 2) return null;
    return _bearing(_x[k], _y[k], _x[here], _y[here]);
  }

  // Smoothed heading of old segment k, computed once. Only asked for
  // segments at least [reverseMinGapM] behind the runner along the track;
  // the points after it are normally there by then, and the value is only
  // a heading, so a slightly short window is harmless.
  final List<double> _segHead = [];

  double _segHeading(int k) {
    while (_segHead.length <= k) {
      final j = _segHead.length;
      var a = j;
      while (a > 0 && _dist(j, a) < _segHalfWindowM) {
        a--;
      }
      var b = j + 1;
      while (b < _x.length - 1 && _dist(j + 1, b) < _segHalfWindowM) {
        b++;
      }
      _segHead.add(_bearing(_x[a], _y[a], _x[b], _y[b]));
    }
    return _segHead[k];
  }

  _Proj _project(int k, double px, double py) {
    final ax = _x[k], ay = _y[k];
    final dx = _x[k + 1] - ax, dy = _y[k + 1] - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0
        ? 0.0
        : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return _Proj(_hyp(px - cx, py - cy), t);
  }

  /// sqrt(dx^2 + dy^2), written out so the Kotlin twin rounds the same way.
  static double _hyp(double dx, double dy) => math.sqrt(dx * dx + dy * dy);

  static double _bearing(double x0, double y0, double x1, double y1) {
    final b = math.atan2(x1 - x0, y1 - y0) * 180 / math.pi;
    return (b + 360) % 360;
  }

  static double _angleDiff(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  static const double _mPerDeg = 111320;
}

class _Proj {
  _Proj(this.distM, this.t);
  final double distM;
  final double t;
}

class _Match {
  _Match(this.distM, this.s, this.seg, this.t, this.dir);
  final double distM;
  final double s;
  final int seg;
  final double t;
  final RetraceDirection dir;
}
