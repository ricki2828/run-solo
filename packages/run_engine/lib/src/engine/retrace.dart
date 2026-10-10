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

  /// Most points kept, like the recorder's live route: a bounded copy of a
  /// very long run. Past it the track stops growing, so the detector can no
  /// longer follow the runner: it drops any retrace (retracing false, no
  /// distance back, no climb ahead) rather than show a frozen answer, and
  /// only [RetraceState.heightVsStartM] keeps following the elevation.
  static const int maxPoints = 20000;

  /// A step longer than this between two accepted fixes is a GPS jump or a
  /// gap (a teleport, a first fix far away), not trail: it is a BREAK. It
  /// is never indexed or matched, adds nothing to the along-track distance,
  /// ends any streak, and no heading is taken across it. Without this a
  /// glitch to the other side of the planet would list a segment in
  /// millions of cells.
  static const double maxSegmentM = 150;

  /// Backstop: a segment whose box would touch more cells than this is not
  /// indexed (a real one, at most [maxSegmentM] long, touches under 40).
  static const int maxCellsPerSegment = 64;

  /// Cells in the spatial index (for tests: a jump must not grow it).
  int get indexedCellCount => _grid.length;

  /// The old stretch's climb and descent are recomputed only when the match
  /// has moved this far along the old track (or the streak is new): the
  /// answer moves slowly and the scan is O(track).
  static const double aheadRefreshM = 10;

  // Spatial index: 50 m cells; a segment is listed in every cell its box,
  // grown by the match radius, touches, so a point finds every segment
  // within the radius in ONE cell.
  static const double _cellM = 50;
  static const int _cellStride = 1048576;

  // Local metres, x east / y north, about the first point.
  double _lat0 = 0, _lon0 = 0, _cosLat = 1;
  final List<double> _x = [], _y = [], _s = [];
  final List<double?> _e = [];
  // Index of the first point of the contiguous chunk each point is in; a
  // break (see [maxSegmentM]) starts a new chunk.
  final List<int> _chunk = [];
  final Map<int, List<int>> _grid = {};
  double? _firstElev, _lastElev;
  double? _dist0;

  // Smoothed heading of old segment k, filled as segments become old enough
  // (see _matureHeadings).
  final List<double> _segHead = [];

  // The current streak of matching.
  bool _hasStreak = false;
  RetraceDirection? _dir;
  double _streakStartS = 0, _streakStartX = 0, _streakStartY = 0;
  double _lastMatchOwnS = 0, _matchS = 0;
  int _matchSeg = 0;
  double _matchT = 0;
  int _streakId = 0;

  // Cached climb/descent ahead.
  int _aheadStreak = -1;
  double _aheadAtS = 0;
  double? _aheadClimb, _aheadDescent;

  // The best candidate of one search (fields, so a search allocates nothing).
  double _projDist = 0, _projT = 0;

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
    _chunk.clear();
    _segHead.clear();
    _grid.clear();
    _firstElev = _lastElev = null;
    _dist0 = null;
    _hasStreak = false;
    _dir = null;
    _streakId = 0;
    _aheadStreak = -1;
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
      if (_x.length >= maxPoints) {
        _hasStreak = false;
        _dir = null;
        return _state = RetraceState(heightVsStartM: _height);
      }
      if (step < minStepM) {
        return _state = _withHeight(_state);
      }
      final jump = step > maxSegmentM;
      if (distM != null) {
        _s.add(math.max(_s.last, distM - (_dist0 ??= distM)));
      } else {
        _s.add(_s.last + (jump ? 0 : step));
      }
      _chunk.add(jump ? _x.length : _chunk.last);
      if (jump) {
        _hasStreak = false;
        _dir = null;
      }
    } else {
      _dist0 = distM;
      _s.add(0);
      _chunk.add(0);
    }
    _x.add(x);
    _y.add(y);
    _e.add(elevM);
    final here = _x.length - 1;
    if (here >= 1 && _chunk[here] == _chunk[here - 1]) _indexSegment(here - 1);
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

  static int _cellKey(int cx, int cy) => cx * _cellStride + cy;

  void _indexSegment(int k) {
    final r = matchRadiusM;
    final x0 = math.min(_x[k], _x[k + 1]) - r;
    final x1 = math.max(_x[k], _x[k + 1]) + r;
    final y0 = math.min(_y[k], _y[k + 1]) - r;
    final y1 = math.max(_y[k], _y[k + 1]) + r;
    final cx0 = (x0 / _cellM).floor(), cy0 = (y0 / _cellM).floor();
    final cx1 = (x1 / _cellM).floor();
    final cy1 = (y1 / _cellM).floor();
    if ((cx1 - cx0 + 1) * (cy1 - cy0 + 1) > maxCellsPerSegment) return;
    for (var cx = cx0; cx <= cx1; cx++) {
      for (var cy = cy0; cy <= cy1; cy++) {
        (_grid[_cellKey(cx, cy)] ??= <int>[]).add(k);
      }
    }
  }

  /// Computes the heading of every segment that is now old enough to be
  /// asked about (at least [reverseMinGapM] behind the runner along the
  /// track), once, in order.
  void _matureHeadings(double sNow) {
    while (_segHead.length + 1 < _x.length - 1 &&
        _s[_segHead.length + 1] <= sNow - reverseMinGapM) {
      final j = _segHead.length;
      final c0 = _chunk[j], c1 = _chunk[j + 1];
      var a = j;
      while (a > c0 && _dist(j, a) < _segHalfWindowM) {
        a--;
      }
      var b = j + 1;
      while (b < _x.length - 1 &&
          _chunk[b + 1] == c1 &&
          _dist(j + 1, b) < _segHalfWindowM) {
        b++;
      }
      _segHead.add(_bearing(_x[a], _y[a], _x[b], _y[b]));
    }
  }

  void _update() {
    final here = _x.length - 1;
    final sNow = _s[here];
    _matureHeadings(sNow);
    final head = _ownHeading(here);
    var found = false;
    var bestDist = 0.0, bestS = 0.0, bestT = 0.0;
    var bestSeg = 0;
    var bestDir = RetraceDirection.reverse;
    if (head != null && here >= 2) {
      final cell =
          _grid[_cellKey(
            (_x[here] / _cellM).floor(),
            (_y[here] / _cellM).floor(),
          )];
      if (cell != null) {
        for (var i = 0; i < cell.length; i++) {
          final k = cell[i];
          // Segments are listed in track order, so once one is too recent
          // for the shortest gap, all later ones are.
          if (k + 1 >= here || _s[k + 1] > sNow - reverseMinGapM) break;
          _project(k, _x[here], _y[here]);
          final d = _projDist;
          if (d > matchRadiusM) continue;
          final diff = _angleDiff(head, _segHead[k]);
          RetraceDirection? dir;
          if (diff >= 180 - maxHeadingDiffDeg) {
            dir = RetraceDirection.reverse;
          } else if (diff <= maxHeadingDiffDeg &&
              _s[k + 1] <= sNow - sameMinGapM) {
            dir = RetraceDirection.same;
          }
          if (dir == null) continue;
          // Nearest wins; a tie goes to the earlier segment.
          if (!found || d < bestDist || (d == bestDist && k < bestSeg)) {
            found = true;
            bestDist = d;
            bestT = _projT;
            bestSeg = k;
            bestS = _s[k] + bestT * (_s[k + 1] - _s[k]);
            bestDir = dir;
          }
        }
      }
    }
    if (found) {
      // The match must move along the old track the way the runner moves
      // along the new one, otherwise it is a fresh streak.
      final consistent =
          _hasStreak &&
          _dir == bestDir &&
          (bestDir == RetraceDirection.reverse
              ? bestS <= _matchS + 40
              : bestS >= _matchS - 40);
      if (!consistent) {
        _hasStreak = true;
        _dir = bestDir;
        _streakId++;
        _streakStartS = sNow;
        _streakStartX = _x[here];
        _streakStartY = _y[here];
      }
      _lastMatchOwnS = sNow;
      _matchS = bestS;
      _matchSeg = bestSeg;
      _matchT = bestT;
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
    if (_aheadStreak != _streakId ||
        (_matchS - _aheadAtS).abs() >= aheadRefreshM) {
      _computeAhead(dir, here);
      _aheadStreak = _streakId;
      _aheadAtS = _matchS;
    }
    _state = RetraceState(
      retracing: true,
      direction: dir,
      distanceToStartM: _matchS,
      climbAheadM: _aheadClimb,
      descentAheadM: _aheadDescent,
      heightVsStartM: _height,
    );
  }

  /// Elevation gain and loss on the old stretch still ahead (into the
  /// cache).
  void _computeAhead(RetraceDirection dir, int here) {
    final t = ClimbTracker(ClimbTracker.baroThresholdM);
    var n = 0;
    void feed(double e) {
      t.offer(e);
      n++;
    }

    final seg = _matchSeg;
    final eA = _e[seg], eB = _e[seg + 1];
    if (eA != null && eB != null) feed(eA + (eB - eA) * _matchT);
    if (dir == RetraceDirection.reverse) {
      for (var i = seg; i >= 0; i--) {
        final e = _e[i];
        if (e != null) feed(e);
      }
    } else {
      // On to where the repeat began, never past the runner's own position.
      for (var i = seg + 1; i < here && _s[i] < _streakStartS; i++) {
        final e = _e[i];
        if (e != null) feed(e);
      }
    }
    if (n < 2) {
      _aheadClimb = _aheadDescent = null;
    } else {
      _aheadClimb = t.ascentM;
      _aheadDescent = t.descentM;
    }
  }

  /// Heading baselines, straight-line: a few metres of GPS noise must not
  /// turn a heading, and noise inflates path length, so the baseline is the
  /// distance actually covered.
  static const double _ownBaselineM = 30;
  static const double _segHalfWindowM = 25;

  double _dist(int i, int j) => _hyp(_x[i] - _x[j], _y[i] - _y[j]);

  /// Bearing (degrees from north) of the runner's last [_ownBaselineM].
  double? _ownHeading(int here) {
    if (here < 1 || _chunk[here] == here) return null;
    final c = _chunk[here];
    var k = here - 1;
    while (k > c && _dist(here, k) < _ownBaselineM) {
      k--;
    }
    if (_dist(here, k) < _ownBaselineM / 2) return null;
    return _bearing(_x[k], _y[k], _x[here], _y[here]);
  }

  /// Distance from (px, py) to segment [k] into [_projDist], and where along
  /// it (0..1) into [_projT].
  void _project(int k, double px, double py) {
    final ax = _x[k], ay = _y[k];
    final dx = _x[k + 1] - ax, dy = _y[k + 1] - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0
        ? 0.0
        : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    _projDist = _hyp(px - cx, py - cy);
    _projT = t;
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
