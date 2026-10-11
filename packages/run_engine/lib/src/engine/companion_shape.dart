/// What the Run companion gets in place of a GPS track: a route SHAPE and
/// per-km splits.
///
/// The shape is made on the phone and is all the server ever sees of where a
/// run went:
///
/// 1. Fixes are projected to flat metres around the run's own centre. Those
///    metres exist only inside [routeShape].
/// 2. The ends are cut off, so the outline does not show exactly where the run
///    began or finished (for most runs that is home): first every fix inside
///    a secret per-install privacy zone is clipped at each end ([PrivacyZone]),
///    then a random 150-300 m more (a fresh length per run per end). The zone
///    is what stops many runs from the same door being intersected down to
///    the door: its edge is the same every time, and its centre is a secret
///    offset from home that never leaves the phone.
/// 3. The path is turned so its longest direction is horizontal, so north is
///    not a hint.
/// 4. Douglas-Peucker thins it to at most [kRouteMaxPoints] points, and it is
///    turned half a turn if needed so it starts on the left (a rule about the
///    direction of travel, never about the compass).
/// 5. It is moved to the corner and scaled so its longer side is exactly
///    [kRouteGrid], then rounded to whole numbers. Scale, position and
///    orientation are gone; only the outline is left.
///
/// Pure Dart, no I/O. See docs/privacy section 2b for what this is for.
library;

import 'dart:math' as math;

import '../model/run_file.dart';
import 'hr_zones.dart';
import 'metrics.dart';

/// The most points a route shape may have.
const int kRouteMaxPoints = 120;

/// The route is whole numbers 0..kRouteGrid; the longer side is exactly this.
const int kRouteGrid = 255;

/// A run whose fixes span less than this (metres, corner to corner) is a
/// treadmill or GPS drift, not a route.
const double kRouteMinSpanM = 60;

/// Each end of the route is cut by a random length in this range (metres of
/// path), fresh per run per end, so no fixed radius can be read back.
const double kRouteTrimMinM = 150;
const double kRouteTrimMaxM = 300;

/// Fixes less accurate than this (metres) are left out.
const double kRouteMaxAccuracyM = 50;

/// Per-km splits are sent only for runs up to this many.
const int kMaxSplits = 100;

/// A bit of road left after the last full km is its own split when it is
/// longer than this (the server's video check counts a piece over 20 m).
const double kMinPartialSplitM = 20;

typedef Pt = (double x, double y);

/// Douglas-Peucker. Keeps the first and last point and every point further
/// than [epsilon] from the chord of the piece it sits in. Iterative, so a long
/// track cannot overflow the stack. A closed loop (first = last) is handled by
/// measuring from the point itself.
List<Pt> douglasPeucker(List<Pt> pts, double epsilon) {
  if (pts.length < 3) return List.of(pts);
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    final (ax, ay) = pts[a];
    final (bx, by) = pts[b];
    final dx = bx - ax, dy = by - ay;
    final norm = math.sqrt(dx * dx + dy * dy);
    var best = -1.0;
    var at = -1;
    for (var i = a + 1; i < b; i++) {
      final (px, py) = pts[i];
      final d = norm < 1e-12
          ? math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay))
          : ((dy * (px - ax) - dx * (py - ay)).abs() / norm);
      if (d > best) {
        best = d;
        at = i;
      }
    }
    if (best > epsilon && at > 0) {
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

/// Thins [pts] with Douglas-Peucker to at most [maxPoints], growing epsilon
/// from a fine start until it fits. Always keeps both ends.
List<Pt> simplifyTo(List<Pt> pts, int maxPoints, {double? startEpsilon}) {
  if (pts.length <= maxPoints) return List.of(pts);
  var minX = pts.first.$1, maxX = minX, minY = pts.first.$2, maxY = minY;
  for (final p in pts) {
    minX = math.min(minX, p.$1);
    maxX = math.max(maxX, p.$1);
    minY = math.min(minY, p.$2);
    maxY = math.max(maxY, p.$2);
  }
  final span = math.max(maxX - minX, maxY - minY);
  var eps = startEpsilon ?? span * 0.002;
  if (eps <= 0) eps = 1e-9;
  var out = douglasPeucker(pts, eps);
  var guard = 0;
  while (out.length > maxPoints && guard++ < 60) {
    eps *= 1.3;
    out = douglasPeucker(pts, eps);
  }
  if (out.length > maxPoints) {
    // Cannot happen with a growing epsilon, but the cap is a promise: fall
    // back to an even pick that keeps both ends.
    out = [
      for (var i = 0; i < maxPoints; i++)
        pts[(i * (pts.length - 1) / (maxPoints - 1)).round()],
    ];
  }
  return out;
}

/// A secret circle around a place the runner often starts from, kept on the
/// phone only (never sent, never in any payload). Fixes inside it are clipped
/// from the start and the end of every route. The centre is offset from the
/// real start by up to half the radius, and the radius is random in
/// [kZoneMinRadiusM]..[kZoneMaxRadiusM], so what the server can learn from
/// many runs is the zone, never the door.
class PrivacyZone {
  const PrivacyZone(this.lat, this.lon, this.radiusM);
  final double lat;
  final double lon;
  final double radiusM;

  Map<String, Object?> toJson() => {'lat': lat, 'lon': lon, 'r': radiusM};

  static PrivacyZone? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = j['lat'], lon = j['lon'], r = j['r'];
    if (lat is! num || lon is! num || r is! num) return null;
    if (lat.abs() > 90 || lon.abs() > 180 || r < 50 || r > 2000) return null;
    return PrivacyZone(lat.toDouble(), lon.toDouble(), r.toDouble());
  }

  /// Metres from the zone's centre to ([lat], [lon]), flat-earth.
  double distanceM(double lat, double lon) {
    final dy = (lat - this.lat) * 110540.0;
    final dx = (lon - this.lon) * 111320.0 * math.cos(this.lat * math.pi / 180);
    return math.sqrt(dx * dx + dy * dy);
  }
}

const double kZoneMinRadiusM = 250;
const double kZoneMaxRadiusM = 400;

/// At most this many zones are kept.
const int kMaxZones = 3;

/// The zones to use for a run that starts at ([lat], [lon]): [zones], plus a
/// new one if the start is outside every zone and there is room. A new zone is
/// centred up to half its radius away from the start, in a random direction,
/// so the start is always inside it and the centre is not the start.
List<PrivacyZone> ensureZoneFor(
  List<PrivacyZone> zones,
  double lat,
  double lon, {
  math.Random? random,
}) {
  if (zones.any((z) => z.distanceM(lat, lon) <= z.radiusM)) return zones;
  if (zones.length >= kMaxZones) return zones;
  final rng = random ?? math.Random.secure();
  final r =
      kZoneMinRadiusM + rng.nextDouble() * (kZoneMaxRadiusM - kZoneMinRadiusM);
  final d = rng.nextDouble() * r / 2;
  final a = rng.nextDouble() * 2 * math.pi;
  final zlat = lat + d * math.sin(a) / 110540.0;
  final zlon =
      lon + d * math.cos(a) / (111320.0 * math.cos(lat * math.pi / 180));
  return [...zones, PrivacyZone(zlat, zlon, r)];
}

/// The first usable fix of [samples], or null.
(double, double)? startFix(Iterable<Sample> samples) {
  for (final s in samples) {
    if (s.lat != null &&
        s.lon != null &&
        (s.accM == null || s.accM! <= kRouteMaxAccuracyM)) {
      return (s.lat!, s.lon!);
    }
  }
  return null;
}

/// Drops the points at the start, and at the end, that lie inside any of
/// [circles] (x, y, radius in the same flat metres as [pts]). Only the ends:
/// a pass through the zone mid-route is left alone.
List<Pt> clipZoneEnds(List<Pt> pts, List<(double, double, double)> circles) {
  bool inside(Pt p) => circles.any((c) {
    final dx = p.$1 - c.$1, dy = p.$2 - c.$2;
    return dx * dx + dy * dy <= c.$3 * c.$3;
  });
  var a = 0, b = pts.length;
  while (a < b && inside(pts[a])) {
    a++;
  }
  while (b > a && inside(pts[b - 1])) {
    b--;
  }
  return pts.sublist(a, b);
}

/// Cuts [startM] of path off the start and [endM] off the end of [pts]. The
/// first kept point is at least [startM] along the track from the true start,
/// the last at least [endM] from the true end. Empty when less than two points
/// are left.
List<Pt> trimEnds(List<Pt> pts, double startM, double endM) {
  if (pts.length < 2) return const [];
  final cum = List<double>.filled(pts.length, 0);
  for (var i = 1; i < pts.length; i++) {
    final dx = pts[i].$1 - pts[i - 1].$1, dy = pts[i].$2 - pts[i - 1].$2;
    cum[i] = cum[i - 1] + math.sqrt(dx * dx + dy * dy);
  }
  final total = cum.last;
  final out = <Pt>[
    for (var i = 0; i < pts.length; i++)
      if (cum[i] >= startM && cum[i] <= total - endM) pts[i],
  ];
  return out.length < 2 ? const [] : out;
}

/// Rotates [pts] about their centre so the longest direction (principal axis)
/// is horizontal. The compass is gone; the path may still run either way along
/// that axis, which [startOnLeft] settles.
List<Pt> alignToLongestAxis(List<Pt> pts) {
  final n = pts.length;
  if (n < 2) return pts;
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.$1;
    cy += p.$2;
  }
  cx /= n;
  cy /= n;
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (final p in pts) {
    final dx = p.$1 - cx, dy = p.$2 - cy;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final c = math.cos(-theta), s = math.sin(-theta);
  return [
    for (final p in pts)
      ((p.$1 - cx) * c - (p.$2 - cy) * s, (p.$1 - cx) * s + (p.$2 - cy) * c),
  ];
}

/// Turns [pts] half a turn if its first third sits right of its last third, so
/// the path reads left to right. A rule about the direction of travel, never
/// about the compass.
List<Pt> startOnLeft(List<Pt> pts) {
  final n = pts.length;
  if (n < 2) return pts;
  final third = math.max(1, n ~/ 3);
  var first = 0.0, last = 0.0;
  for (var i = 0; i < third; i++) {
    first += pts[i].$1;
    last += pts[n - 1 - i].$1;
  }
  return first > last ? [for (final p in pts) (-p.$1, -p.$2)] : pts;
}

/// Moves [pts] to the corner and scales them so the longer side is exactly
/// [grid]; whole numbers; consecutive duplicates dropped. Null when nothing
/// is left to draw (fewer than two distinct points).
List<List<int>>? normaliseToGrid(List<Pt> pts, {int grid = kRouteGrid}) {
  if (pts.length < 2) return null;
  var minX = pts.first.$1, maxX = minX, minY = pts.first.$2, maxY = minY;
  for (final p in pts) {
    minX = math.min(minX, p.$1);
    maxX = math.max(maxX, p.$1);
    minY = math.min(minY, p.$2);
    maxY = math.max(maxY, p.$2);
  }
  final span = math.max(maxX - minX, maxY - minY);
  if (!(span > 0)) return null;
  final k = grid / span;
  final out = <List<int>>[];
  for (final p in pts) {
    final q = [((p.$1 - minX) * k).round(), ((p.$2 - minY) * k).round()];
    if (out.isEmpty || out.last[0] != q[0] || out.last[1] != q[1]) out.add(q);
  }
  return out.length < 2 ? null : out;
}

/// The track routeShape draws, before it is turned and scaled: flat metres
/// (y down) around the run's own centre with the privacy zones and the random
/// end trim already cut off. [lat0], [lon0] and [kx] are the frame, so a test
/// can put a place into it. Null when there is nothing to draw.
({List<Pt> pts, double lat0, double lon0, double kx})? prepareTrack(
  Iterable<Sample> samples, {
  List<PrivacyZone> zones = const [],
  math.Random? random,
  double trimMinM = kRouteTrimMinM,
  double trimMaxM = kRouteTrimMaxM,
}) {
  final fixes = <(double, double)>[
    for (final s in samples)
      if (s.lat != null &&
          s.lon != null &&
          (s.accM == null || s.accM! <= kRouteMaxAccuracyM))
        (s.lat!, s.lon!),
  ];
  if (fixes.length < 2) return null;
  // A very long track is thinned evenly first so Douglas-Peucker stays quick.
  const cap = 1500;
  var thin = fixes;
  if (fixes.length > cap) {
    thin = [
      for (var i = 0; i < cap; i++)
        fixes[(i * (fixes.length - 1) / (cap - 1)).round()],
    ];
  }
  var lat0 = 0.0, lon0 = 0.0;
  for (final f in thin) {
    lat0 += f.$1;
    lon0 += f.$2;
  }
  lat0 /= thin.length;
  lon0 /= thin.length;
  final kx = 111320.0 * math.cos(lat0 * math.pi / 180);
  // Flat metres around the run's own centre, y down. They go no further.
  final flat = <Pt>[
    for (final f in thin) ((f.$2 - lon0) * kx, -(f.$1 - lat0) * 110540.0),
  ];
  // 1. The secret zones, in the same frame.
  final clipped = clipZoneEnds(flat, [
    for (final z in zones)
      ((z.lon - lon0) * kx, -(z.lat - lat0) * 110540.0, z.radiusM),
  ]);
  // 2. A random trim on top, measured from the zone's edge.
  final rng = random ?? math.Random.secure();
  double pick() => trimMinM + rng.nextDouble() * (trimMaxM - trimMinM);
  final cut = trimEnds(clipped, pick(), pick());
  if (cut.length < 2) return null;
  return (pts: cut, lat0: lat0, lon0: lon0, kx: kx);
}

/// The route shape for [samples]: at most [maxPoints] whole-number points on a
/// [kRouteGrid] grid, longer side exactly the grid, touching x = 0 and y = 0,
/// no coordinates, no scale, no north. Null for an indoor run, a run with
/// fewer than two good fixes, or one under [kRouteMinSpanM].
///
/// The ends are cut: first by the privacy [zones], then by a random trim
/// ([random] picks the lengths, a secure one by default; [trimMinM] and
/// [trimMaxM] are the range, for tests).
List<List<int>>? routeShape(
  Iterable<Sample> samples, {
  int maxPoints = kRouteMaxPoints,
  List<PrivacyZone> zones = const [],
  math.Random? random,
  double trimMinM = kRouteTrimMinM,
  double trimMaxM = kRouteTrimMaxM,
}) {
  final t = prepareTrack(
    samples,
    zones: zones,
    random: random,
    trimMinM: trimMinM,
    trimMaxM: trimMaxM,
  );
  if (t == null) return null;
  final cut = t.pts;
  var minX = cut.first.$1, maxX = minX, minY = cut.first.$2, maxY = minY;
  for (final p in cut) {
    minX = math.min(minX, p.$1);
    maxX = math.max(maxX, p.$1);
    minY = math.min(minY, p.$2);
    maxY = math.max(maxY, p.$2);
  }
  final diag = math.sqrt(
    (maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY),
  );
  if (diag < kRouteMinSpanM) return null;
  final thinned = simplifyTo(alignToLongestAxis(cut), maxPoints);
  return normaliseToGrid(startOnLeft(thinned));
}

/// One km (or the bit left over) of a run, on the run's own clock.
class SplitWindow {
  const SplitWindow(this.t0Ms, this.t1Ms, this.km);
  final int t0Ms;
  final int t1Ms;

  /// How long the piece is: 1.0, except the last one.
  final double km;

  /// Seconds per km over the piece, pauses included (the clock the run's
  /// duration is on).
  double get paceSecPerKm => (t1Ms - t0Ms) / 1000 / km;
}

/// Per-km splits for the companion's cards: each full km, then the road left
/// over if it is more than [kMinPartialSplitM]. Times are the run's elapsed
/// clock, so they add up to the duration the summary reports. Empty for a run
/// with no distance, or one with more than [kMaxSplits] pieces.
List<SplitWindow> kmSplitWindows(RunFile run) {
  final s = run.samples;
  if (s.length < 2) return const [];
  final dist = run.distanceM;
  if (dist < kMinPartialSplitM) return const [];
  final out = <SplitWindow>[];
  var mark = 1000.0;
  var prevT = s.first.tMs;
  for (var i = 1; i < s.length && mark <= dist; i++) {
    final a = s[i - 1], b = s[i];
    while (mark <= dist && b.distM >= mark) {
      final f = b.distM == a.distM
          ? 1.0
          : (mark - a.distM) / (b.distM - a.distM);
      final tAt = a.tMs + ((b.tMs - a.tMs) * f).round();
      out.add(SplitWindow(prevT, tAt, 1.0));
      prevT = tAt;
      mark += 1000;
    }
  }
  final left = dist - out.length * 1000.0;
  if (left > kMinPartialSplitM && s.last.tMs > prevT) {
    out.add(SplitWindow(prevT, s.last.tMs, left / 1000));
  }
  return out.length > kMaxSplits ? const [] : out;
}

/// The HR zone (1-5) the run mostly ran in between [t0Ms] and [t1Ms], weighted
/// by time; null when no sample there has a heart rate.
int? dominantZone(RunFile run, HrZones zones, int t0Ms, int t1Ms) {
  final samples = run.samples;
  final secs = List<double>.filled(6, 0);
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final hr = s.hr;
    if (hr == null || s.tMs < t0Ms || s.tMs >= t1Ms) continue;
    final dtMs = i + 1 < samples.length
        ? (samples[i + 1].tMs - s.tMs).clamp(0, 5000)
        : 1000;
    secs[zones.zoneOf(hr)] += dtMs / 1000;
  }
  var best = 0;
  for (var z = 1; z <= 5; z++) {
    if (secs[z] > secs[best]) best = z;
  }
  return best == 0 ? null : best;
}

/// The most reps sent.
const int kMaxReps = 60;

double _r1(double v) => (v * 10).roundToDouble() / 10;

/// The `route`, `splits` and `reps` keys of the companion's run summary, built
/// in one place for the app and for the history replay. Each is left out when
/// it cannot be made well (the server refuses a value outside its bounds, and
/// a refused run would never get its note), so a missing key is normal:
///
/// - `route` only with [withRoute] (the runner's "Show route shape on cards"
///   switch): [routeShape].
/// - `splits`: `[{km, pace_s, zone?}]`, one per km and a last short piece; only
///   when every pace is a believable 60..3600 s/km.
/// - `reps`: `[{time_s, zone?}]` for a structured run, one per clean rep.
///
/// [zones] gives each piece its HR zone; without it (or without a heart rate)
/// pieces carry none.
Map<String, Object?> companionShapeFields(
  RunFile run, {
  HrZones? zones,
  IntervalMetrics? intervals,
  bool withRoute = true,
  List<PrivacyZone> privacyZones = const [],
}) {
  final out = <String, Object?>{};
  if (withRoute) {
    final r = routeShape(run.samples, zones: privacyZones);
    if (r != null) out['route'] = r;
  }
  final windows = kmSplitWindows(run);
  final pieces = <Map<String, Object?>>[];
  for (final w in windows) {
    final pace = _r1(w.paceSecPerKm);
    if (!(pace >= 60 && pace <= 3600)) {
      pieces.clear();
      break;
    }
    final z = zones == null ? null : dominantZone(run, zones, w.t0Ms, w.t1Ms);
    pieces.add({
      'km': (w.km * 1000).round() / 1000,
      'pace_s': pace,
      'zone': ?z,
    });
  }
  if (pieces.isNotEmpty) out['splits'] = pieces;
  final reps = <Map<String, Object?>>[];
  for (final r in intervals?.reps ?? const <RepMetrics>[]) {
    // An interrupted or dropped rep would read as a fast "best rep".
    if (!r.clean) continue;
    final t = _r1(r.trimmedSeconds);
    if (!(t > 0 && t <= 3600)) {
      reps.clear();
      break;
    }
    final z = zones == null
        ? null
        : dominantZone(run, zones, r.trimmedT0Ms, r.trimmedT1Ms);
    reps.add({'time_s': t, 'zone': ?z});
  }
  if (reps.isNotEmpty && reps.length <= kMaxReps) out['reps'] = reps;
  return out;
}
