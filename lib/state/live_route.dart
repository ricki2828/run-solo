/// The live run's route so far, for the record screen's MAP view. Fed by
/// `RoutePointsEvent` deltas (about 1 Hz, simplified natively); a gap or a
/// recreated screen is caught up with `routeSince`. A read-only copy: the
/// recorder never reads it back, so a map that fails changes nothing about
/// the run.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../map/route_builder.dart';

class LiveRouteTrack extends ChangeNotifier {
  final List<GeoPoint> _points = [];

  /// Points so far (oldest first). Read-only view.
  List<GeoPoint> get points => List.unmodifiable(_points);

  /// Points from [index] on (no copy of the earlier ones).
  List<GeoPoint> since(int index) => _points.sublist(index.clamp(0, count));

  GeoPoint? get last => _points.isEmpty ? null : _points.last;
  int get count => _points.length;

  /// Applies a delta starting at point [fromIndex] (flat `[lat, lon, ...]`).
  /// Overlap with what is held is skipped. Returns false when the delta
  /// starts past the end (points were missed): the caller should
  /// [catchUp].
  bool apply(int fromIndex, List<double> latLon) {
    if (fromIndex > _points.length) return false;
    final skip = _points.length - fromIndex;
    var added = false;
    for (var i = skip * 2; i + 1 < latLon.length; i += 2) {
      _points.add(GeoPoint(latLon[i], latLon[i + 1]));
      added = true;
    }
    if (added) notifyListeners();
    return true;
  }

  /// Bumps when the route is cleared, so a display copy knows to restart.
  int get epoch => _epoch;
  int _epoch = 0;

  void clear() {
    _epoch++;
    if (_points.isEmpty) return;
    _points.clear();
    notifyListeners();
  }
}

/// Douglas-Peucker thinning for DISPLAY only (native keeps the full route):
/// returns at most about [maxPoints] points, always keeping the first and
/// last, by widening the tolerance until it fits.
List<GeoPoint> simplifyForDisplay(List<GeoPoint> pts, int maxPoints) {
  if (pts.length <= maxPoints) return List.of(pts);
  var tol = 1.0; // metres
  var out = pts;
  while (out.length > maxPoints) {
    out = _douglasPeucker(pts, tol);
    tol *= 2;
  }
  return out;
}

const double _mPerDeg = 111320;

List<GeoPoint> _douglasPeucker(List<GeoPoint> pts, double tolM) {
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  final cosLat = math.cos(pts.first.lat * math.pi / 180);
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var worst = -1.0;
    var at = -1;
    final ax = pts[a].lon * _mPerDeg * cosLat, ay = pts[a].lat * _mPerDeg;
    final bx = pts[b].lon * _mPerDeg * cosLat, by = pts[b].lat * _mPerDeg;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    for (var i = a + 1; i < b; i++) {
      final px = pts[i].lon * _mPerDeg * cosLat, py = pts[i].lat * _mPerDeg;
      final t = len2 == 0
          ? 0.0
          : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
      final d = math.sqrt(
        math.pow(px - (ax + t * dx), 2) + math.pow(py - (ay + t * dy), 2),
      );
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (at >= 0 && worst > tolM) {
      keep[at] = true;
      stack
        ..add((a, at))
        ..add((at, b));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}
