/// Gradient classes for a route line, so a climb shows before you reach it.
///
/// Pure Dart. The grade is measured across a smoothed window ([windowM] in
/// total, centred on each segment) because barometer and DEM elevation are
/// noisy point to point and would paint stripes. Four classes: flat (under
/// 3 %), up (3 to 8 %), steep (over 8 %) and down (under minus 3 %).
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import '../theme/tokens.dart';
import 'route_builder.dart';

enum GradientClass { flat, up, steep, down }

/// Line colours, from [AuroraGradient] (outside the zone ramp, the semantic
/// colours and the run-type identities; a test keeps that true).
abstract final class GradientColours {
  static const Color flat = AuroraGradient.flat;
  static const Color up = AuroraGradient.up;
  static const Color steep = AuroraGradient.steep;
  static const Color down = AuroraGradient.down;

  static Color of(GradientClass c) => switch (c) {
    GradientClass.flat => flat,
    GradientClass.up => up,
    GradientClass.steep => steep,
    GradientClass.down => down,
  };
}

const double flatBelow = 0.03;
const double steepAbove = 0.08;

GradientClass classOfGrade(double grade) {
  if (grade < -flatBelow) return GradientClass.down;
  if (grade < flatBelow) return GradientClass.flat;
  if (grade <= steepAbove) return GradientClass.up;
  return GradientClass.steep;
}

/// A run of consecutive points of one class (shares its end point with the
/// next run so the line has no gaps).
class GradientRun {
  const GradientRun(this.cls, this.points);
  final GradientClass cls;
  final List<GeoPoint> points;
}

double _distM(GeoPoint a, GeoPoint b) {
  const mPerDeg = 111320.0;
  final dy = (b.lat - a.lat) * mPerDeg;
  final dx = (b.lon - a.lon) * mPerDeg * math.cos(a.lat * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

/// Splits [points] into gradient runs, or null when fewer than two points
/// carry an elevation (no grade to show: the caller draws the plain line).
List<GradientRun>? gradientRuns(List<GeoPoint> points, {double windowM = 50}) {
  if (points.length < 2) return null;
  if (points.where((p) => p.ele != null).length < 2) return null;
  // Cumulative distance, and elevation filled across gaps.
  final cum = List<double>.filled(points.length, 0);
  for (var i = 1; i < points.length; i++) {
    cum[i] = cum[i - 1] + _distM(points[i - 1], points[i]);
  }
  final ele = List<double?>.generate(points.length, (i) => points[i].ele);
  double? last;
  for (var i = 0; i < ele.length; i++) {
    if (ele[i] == null) {
      ele[i] = last;
    } else {
      last = ele[i];
    }
  }
  last = null;
  for (var i = ele.length - 1; i >= 0; i--) {
    if (ele[i] == null) {
      ele[i] = last;
    } else {
      last = ele[i];
    }
  }
  final half = windowM / 2;
  final classes = <GradientClass>[];
  // Class of the segment i -> i+1, from the grade across the window centred
  // on its midpoint.
  var lo = 0, hi = 0;
  for (var i = 0; i < points.length - 1; i++) {
    final mid = (cum[i] + cum[i + 1]) / 2;
    while (lo < points.length - 1 && cum[lo + 1] <= mid - half) {
      lo++;
    }
    if (hi < i + 1) hi = i + 1;
    while (hi < points.length - 1 && cum[hi] < mid + half) {
      hi++;
    }
    final a = lo.clamp(0, i);
    final b = hi.clamp(i + 1, points.length - 1);
    final run = cum[b] - cum[a];
    final grade = run < 1 ? 0.0 : (ele[b]! - ele[a]!) / run;
    classes.add(classOfGrade(grade));
  }
  final out = <GradientRun>[];
  var start = 0;
  for (var i = 1; i <= classes.length; i++) {
    if (i == classes.length || classes[i] != classes[start]) {
      out.add(GradientRun(classes[start], points.sublist(start, i + 1)));
      start = i;
    }
  }
  return out;
}
