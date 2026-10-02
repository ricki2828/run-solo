import 'dart:math' as math;

import '../model/run_file.dart';

/// A compact route signature: the run's GPS track simplified to a short
/// polyline, kept per run in the index so two runs can be compared without
/// opening either file ("same trail" verdict, boards). Start, end, bounding
/// box and length are read off the polyline, never stored twice.
///
/// Pure Dart, no I/O. Stays on the phone like the run file.
class RouteSignature {
  RouteSignature({required this.points, required this.lengthM})
    : assert(points.length >= 2);

  /// The simplified track, 5 dp (about 1 m), start to finish.
  final List<SigPoint> points;

  /// The run's distance, metres.
  final double lengthM;

  SigPoint get start => points.first;
  SigPoint get end => points.last;

  /// Finishes within [RouteMatch.endTolM] of where it started.
  bool get isLoop {
    final local = _Local(start);
    return _dist(local.project(start), local.project(end)) <=
        RouteMatch.endTolM;
  }

  /// (minLat, minLon, maxLat, maxLon).
  (double, double, double, double) get bbox {
    var minLat = points.first.lat, maxLat = minLat;
    var minLon = points.first.lon, maxLon = minLon;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    return (minLat, minLon, maxLat, maxLon);
  }

  /// Under this distance a run has no usable route.
  static const double minLengthM = 500;

  /// The polyline is thinned until it has at most this many points.
  static const int maxPoints = 60;

  /// Fixes worse than this accuracy are left out.
  static const double maxAccuracyM = 50;

  /// Null for a run with no GPS track or under [minLengthM].
  static RouteSignature? of(RunFile run) {
    if (run.distanceM < minLengthM) return null;
    final raw = <SigPoint>[
      for (final s in run.samples)
        if (s.lat != null && s.lon != null && (s.accM ?? 0) <= maxAccuracyM)
          SigPoint(s.lat!, s.lon!),
    ];
    if (raw.length < 2) return null;
    final line = _Local(raw.first);
    final xy = [for (final p in raw) line.project(p)];
    var eps = 10.0;
    var keep = _simplify(xy, eps);
    while (keep.length > maxPoints) {
      eps *= 1.5;
      keep = _simplify(xy, eps);
    }
    if (keep.length < 2) return null;
    return RouteSignature(
      points: [
        for (final i in keep) SigPoint(_dp5(raw[i].lat), _dp5(raw[i].lon)),
      ],
      lengthM: run.distanceM,
    );
  }

  static double _dp5(double v) => (v * 1e5).round() / 1e5;

  /// `{len, p}`: length in metres and the points as 1e-5 degree integers,
  /// the first absolute, each next as a delta from the one before.
  Map<String, Object?> toJson() {
    final out = <int>[];
    var pLat = 0, pLon = 0;
    for (final p in points) {
      final la = (p.lat * 1e5).round(), lo = (p.lon * 1e5).round();
      out
        ..add(la - pLat)
        ..add(lo - pLon);
      pLat = la;
      pLon = lo;
    }
    return {'len': lengthM.round(), 'p': out};
  }

  /// Null for anything unreadable (the row is then rebuilt).
  static RouteSignature? fromJson(Object? j) {
    if (j is! Map) return null;
    final len = (j['len'] as num?)?.toDouble();
    final p = j['p'];
    if (len == null || p is! List || p.length < 4 || p.length.isOdd) {
      return null;
    }
    final pts = <SigPoint>[];
    var la = 0, lo = 0;
    for (var i = 0; i < p.length; i += 2) {
      la += (p[i] as num).toInt();
      lo += (p[i + 1] as num).toInt();
      pts.add(SigPoint(la / 1e5, lo / 1e5));
    }
    return RouteSignature(points: pts, lengthM: len);
  }

  /// Douglas-Peucker over metres; returns the indices kept.
  static List<int> _simplify(List<_Pt> p, double eps) {
    final keep = <int>{0, p.length - 1};
    final stack = <(int, int)>[(0, p.length - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      var far = -1;
      var farD = eps;
      for (var i = a + 1; i < b; i++) {
        final d = _segDist(p[i], p[a], p[b]);
        if (d > farD) {
          farD = d;
          far = i;
        }
      }
      if (far >= 0) {
        keep.add(far);
        stack
          ..add((a, far))
          ..add((far, b));
      }
    }
    return keep.toList()..sort();
  }
}

class SigPoint {
  const SigPoint(this.lat, this.lon);
  final double lat;
  final double lon;
}

class _Pt {
  const _Pt(this.x, this.y);
  final double x;
  final double y;
}

/// Equirectangular metres around an origin; plenty for a run's footprint.
class _Local {
  _Local(SigPoint origin)
    : _lat0 = origin.lat,
      _lon0 = origin.lon,
      _kx = math.cos(origin.lat * math.pi / 180) * _mPerDeg;

  static const double _mPerDeg = 111194.9;
  final double _lat0;
  final double _lon0;
  final double _kx;

  _Pt project(SigPoint p) =>
      _Pt((p.lon - _lon0) * _kx, (p.lat - _lat0) * _mPerDeg);
}

double _dist(_Pt a, _Pt b) => math.sqrt(_d2(a, b));
double _d2(_Pt a, _Pt b) =>
    (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y);

double _segDist(_Pt p, _Pt a, _Pt b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final l2 = dx * dx + dy * dy;
  if (l2 == 0) return _dist(p, a);
  final t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / l2).clamp(0.0, 1.0);
  return _dist(p, _Pt(a.x + t * dx, a.y + t * dy));
}

/// Whether two runs went the same way round the same trail.
///
/// Rules (all must hold):
/// - lengths within [lengthTol] (10 %);
/// - the track overlaps: at least [minCover] (80 %) of each route lies within
///   [coverTolM] of the other, so a shared half or a parallel lane is not the
///   same trail;
/// - the direction agrees: the discrete Frechet distance between the two
///   routes, walked the same way, stays within [frechetTolM] plus the
///   sampling step. Start and finish must also sit within [endTolM], except
///   for a loop (finish within [endTolM] of its own start), which may be
///   started at any point round it.
///
/// A route run the other way round is a different trail: the Frechet walk
/// runs out of order, so it fails however much ground the two share.
abstract final class RouteMatch {
  static const double endTolM = 150;
  static const double lengthTol = 0.10;
  static const double coverTolM = 30;
  static const double minCover = 0.8;
  static const double frechetTolM = 50;

  /// Resampling step target, metres, and the cap on samples.
  static const double stepM = 25;
  static const int maxSamples = 160;

  static bool same(RouteSignature a, RouteSignature b) {
    final longer = math.max(a.lengthM, b.lengthM);
    if (longer <= 0 || (a.lengthM - b.lengthM).abs() / longer > lengthTol) {
      return false;
    }
    final local = _Local(a.start);
    final pa = [for (final p in a.points) local.project(p)];
    final pb = [for (final p in b.points) local.project(p)];
    final loopA = _dist(pa.first, pa.last) <= endTolM;
    final loopB = _dist(pb.first, pb.last) <= endTolM;
    final loops = loopA && loopB;
    if (!loops &&
        (_dist(pa.first, pb.first) > endTolM ||
            _dist(pa.last, pb.last) > endTolM)) {
      return false;
    }
    if (math.min(_cover(pa, pb), _cover(pb, pa)) < minCover) return false;

    final step = math.max(stepM, longer / maxSamples);
    final n = math.max(8, (longer / step).round());
    final ra = _resample(pa, n);
    final rb = _resample(pb, n);
    final tol = frechetTolM + step;
    if (!loops) return _frechet(ra, rb) <= tol;
    // Loops: try every starting point round b (the closing point repeats the
    // first, so it is dropped before rotating and added back).
    final ring = rb.sublist(0, rb.length - 1);
    for (var k = 0; k < ring.length; k++) {
      final rot = [...ring.sublist(k), ...ring.sublist(0, k)];
      rot.add(rot.first);
      if (_frechet(ra, rot) <= tol) return true;
    }
    return false;
  }

  /// The overlap figure, 0..1: the smaller of the two shares of a route that
  /// lies within [coverTolM] of the other. What the Frechet check adds is
  /// direction; this is "how much of the same ground".
  static double similarity(RouteSignature a, RouteSignature b) {
    final local = _Local(a.start);
    final pa = [for (final p in a.points) local.project(p)];
    final pb = [for (final p in b.points) local.project(p)];
    return math.min(_cover(pa, pb), _cover(pb, pa));
  }

  /// Share of [a]'s length (sampled every [stepM]) within [coverTolM] of [b].
  static double _cover(List<_Pt> a, List<_Pt> b) {
    final samples = _resample(a, math.max(8, (_length(a) / 10).round()));
    var hit = 0;
    for (final p in samples) {
      var best = double.infinity;
      for (var i = 0; i + 1 < b.length; i++) {
        best = math.min(best, _segDist(p, b[i], b[i + 1]));
        if (best <= coverTolM) break;
      }
      if (best <= coverTolM) hit++;
    }
    return hit / samples.length;
  }

  static double _length(List<_Pt> p) {
    var l = 0.0;
    for (var i = 1; i < p.length; i++) {
      l += _dist(p[i - 1], p[i]);
    }
    return l;
  }

  /// [n] + 1 points evenly spaced along the polyline, first and last kept.
  static List<_Pt> _resample(List<_Pt> p, int n) {
    final total = _length(p);
    if (total == 0) return List.filled(n + 1, p.first);
    final out = <_Pt>[p.first];
    var seg = 0;
    var walked = 0.0;
    for (var k = 1; k < n; k++) {
      final target = total * k / n;
      while (seg + 1 < p.length - 1 &&
          walked + _dist(p[seg], p[seg + 1]) < target) {
        walked += _dist(p[seg], p[seg + 1]);
        seg++;
      }
      final l = _dist(p[seg], p[seg + 1]);
      final t = l == 0 ? 0.0 : ((target - walked) / l).clamp(0.0, 1.0);
      out.add(
        _Pt(
          p[seg].x + t * (p[seg + 1].x - p[seg].x),
          p[seg].y + t * (p[seg + 1].y - p[seg].y),
        ),
      );
    }
    out.add(p.last);
    return out;
  }

  /// Discrete Frechet distance (Eiter and Mannila), rolling rows.
  static double _frechet(List<_Pt> a, List<_Pt> b) {
    var prev = List<double>.filled(b.length, 0);
    for (var i = 0; i < a.length; i++) {
      final cur = List<double>.filled(b.length, 0);
      for (var j = 0; j < b.length; j++) {
        final d = _dist(a[i], b[j]);
        if (i == 0 && j == 0) {
          cur[j] = d;
        } else if (i == 0) {
          cur[j] = math.max(cur[j - 1], d);
        } else if (j == 0) {
          cur[j] = math.max(prev[j], d);
        } else {
          cur[j] = math.max(
            math.min(prev[j], math.min(prev[j - 1], cur[j - 1])),
            d,
          );
        }
      }
      prev = cur;
    }
    return prev.last;
  }
}
