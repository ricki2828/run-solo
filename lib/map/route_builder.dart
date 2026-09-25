/// Samples → route geometry for the post-run map (plan §18.3). Pure Dart so
/// it unit-tests without a platform view: accepted (fixed) samples only,
/// lap-marker positions at each lap end, and the bounds to fit. `MapSurface`
/// draws it; the route-shape fallback draws the same points on a canvas.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

@immutable
class GeoPoint {
  const GeoPoint(this.lat, this.lon);
  final double lat;
  final double lon;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'GeoPoint($lat, $lon)';
}

@immutable
class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });
  final double south;
  final double west;
  final double north;
  final double east;

  GeoPoint get centre => GeoPoint((south + north) / 2, (west + east) / 2);
}

enum RouteMarkerKind { start, finish, work, recovery, lap }

@immutable
class RouteMarker {
  const RouteMarker({
    required this.point,
    required this.kind,
    this.label,
    this.lapIndex,
  });
  final GeoPoint point;
  final RouteMarkerKind kind;

  /// Lap number chip text; null for start / finish dots.
  final String? label;
  final int? lapIndex;
}

@immutable
class RouteGeometry {
  const RouteGeometry({
    required this.points,
    required this.markers,
    required this.bounds,
  });

  final List<GeoPoint> points;
  final List<RouteMarker> markers;

  /// Null when fewer than one fixed sample (indoor / no GPS): no map.
  final GeoBounds? bounds;

  bool get isEmpty => points.length < 2;
}

abstract final class RouteBuilder {
  /// Accepted samples only (`hasFix`, accuracy ≤ [maxAccuracyM]). Lap markers
  /// sit at the sample nearest each lap's `t1`; with a 4x4 detection work
  /// reps get `work` markers and recoveries `recovery` (addendum A4 "the map
  /// reads as the rep bars do"), else plain numbered `lap` markers.
  static RouteGeometry build(
    engine.RunFile run, {
    engine.RepDetection? detection,
    double maxAccuracyM = 25,
  }) {
    final fixed = run.samples
        .where((s) => s.hasFix && (s.accM == null || s.accM! <= maxAccuracyM))
        .toList();
    final points = [for (final s in fixed) GeoPoint(s.lat!, s.lon!)];
    if (points.length < 2) {
      return const RouteGeometry(points: [], markers: [], bounds: null);
    }
    final markers = <RouteMarker>[
      RouteMarker(point: points.first, kind: RouteMarkerKind.start),
    ];
    final workEnds = <int, int>{}; // lap index → rep number
    final recoveryEnds = <int>{};
    if (detection != null) {
      for (final rep in detection.reps) {
        workEnds[rep.work.index] = rep.number;
        if (rep.recovery != null) recoveryEnds.add(rep.recovery!.index);
      }
    }
    final laps = detection?.laps ?? run.laps;
    for (final lap in laps) {
      if (lap.kind == engine.LapKind.pause) continue;
      if (lap == laps.last && detection == null) break; // finish dot covers it
      final s = _nearest(fixed, lap.t1Ms);
      if (s == null) continue;
      final p = GeoPoint(s.lat!, s.lon!);
      if (detection != null) {
        final rep = workEnds[lap.index];
        if (rep != null) {
          markers.add(
            RouteMarker(
              point: p,
              kind: RouteMarkerKind.work,
              label: '$rep',
              lapIndex: lap.index,
            ),
          );
        } else if (recoveryEnds.contains(lap.index)) {
          markers.add(
            RouteMarker(
              point: p,
              kind: RouteMarkerKind.recovery,
              label: 'R',
              lapIndex: lap.index,
            ),
          );
        }
      } else {
        markers.add(
          RouteMarker(
            point: p,
            kind: RouteMarkerKind.lap,
            label: '${lap.index + 1}',
            lapIndex: lap.index,
          ),
        );
      }
    }
    markers.add(RouteMarker(point: points.last, kind: RouteMarkerKind.finish));
    return RouteGeometry(
      points: points,
      markers: markers,
      bounds: boundsOf(points),
    );
  }

  static engine.Sample? _nearest(List<engine.Sample> fixed, int tMs) {
    engine.Sample? best;
    var bestD = 1 << 30;
    for (final s in fixed) {
      final d = (s.tMs - tMs).abs();
      if (d < bestD) {
        bestD = d;
        best = s;
      }
      if (s.tMs > tMs) break;
    }
    return best;
  }

  static GeoBounds boundsOf(List<GeoPoint> points) {
    var south = double.infinity, north = -double.infinity;
    var west = double.infinity, east = -double.infinity;
    for (final p in points) {
      south = math.min(south, p.lat);
      north = math.max(north, p.lat);
      west = math.min(west, p.lon);
      east = math.max(east, p.lon);
    }
    // A perfectly still route (treadmill with a fix) still needs an area.
    if (north - south < 1e-4) {
      north += 5e-5;
      south -= 5e-5;
    }
    if (east - west < 1e-4) {
      east += 5e-5;
      west -= 5e-5;
    }
    return GeoBounds(south: south, west: west, north: north, east: east);
  }
}
