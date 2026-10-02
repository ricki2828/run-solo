import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../engine/elevation.dart';
import '../import/import_util.dart';
import '../model/run_file.dart';

/// Follow a route: a route kept on the phone. Built from a GPX or TCX file the
/// runner picked, or from one of their own past runs ("Run this route again").
/// The points are simplified (at most [maxPoints]) and the distance and climb
/// are worked out from those same points, so the library, the live "to go" and
/// the recorder's own figures agree. Nothing here reads or writes a file.

enum RouteSource { gpx, tcx, run }

class RoutePoint {
  const RoutePoint(this.lat, this.lon, [this.ele]);
  final double lat;
  final double lon;

  /// Metres, null when the file or run had none at this point.
  final double? ele;
}

class SavedRoute {
  const SavedRoute({
    required this.id,
    required this.name,
    required this.points,
    required this.distanceM,
    this.climbM,
    required this.createdAt,
    required this.source,
  });

  /// At most this many points go to the recorder (the native contract caps at
  /// 5,000; 2,000 keeps the journal line and the map line small).
  static const int maxPoints = 2000;

  /// Shorter than this is a stub, not a route to follow.
  static const double minDistanceM = 200;

  /// Longer than this is not a run the app will follow (a day's ride).
  static const double maxDistanceM = 300000;

  final String id;
  final String name;
  final List<RoutePoint> points;
  final double distanceM;

  /// Total ascent of the route's own elevation, null when it has none.
  final double? climbM;
  final DateTime createdAt;
  final RouteSource source;

  double get startLat => points.first.lat;
  double get startLon => points.first.lon;
  bool get hasElevation => climbM != null;

  /// Flat `[lat, lon, ...]` for the recorder.
  List<double> get latLon => [
    for (final p in points) ...[p.lat, p.lon],
  ];

  /// One elevation per point, or null when the route has none.
  List<double>? get elevM =>
      hasElevation ? [for (final p in points) p.ele ?? 0] : null;

  SavedRoute renamed(String name) => SavedRoute(
    id: id,
    name: name,
    points: points,
    distanceM: distanceM,
    climbM: climbM,
    createdAt: createdAt,
    source: source,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'distanceM': _r(distanceM, 1),
    if (climbM != null) 'climbM': _r(climbM!, 1),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'source': source.name,
    // [lat, lon] or [lat, lon, ele], the same shape the run file uses for samples.
    'points': [
      for (final p in points) [p.lat, p.lon, if (p.ele != null) p.ele],
    ],
  };

  /// Throws [FormatException] for a record this build cannot read.
  factory SavedRoute.fromJson(Map<String, Object?> j) {
    final pts = j['points'];
    if (pts is! List || pts.length < 2) {
      throw const FormatException('route needs at least two points');
    }
    final points = <RoutePoint>[
      for (final p in pts)
        if (p is List && p.length >= 2)
          RoutePoint(
            (p[0] as num).toDouble(),
            (p[1] as num).toDouble(),
            p.length > 2 && p[2] is num ? (p[2] as num).toDouble() : null,
          )
        else
          throw const FormatException('bad route point'),
    ];
    final climb = j['climbM'];
    return SavedRoute(
      id: j['id']! as String,
      name: j['name']! as String,
      points: points,
      distanceM: (j['distanceM']! as num).toDouble(),
      climbM: climb is num ? climb.toDouble() : null,
      createdAt: DateTime.parse(j['createdAt']! as String),
      source: RouteSource.values.firstWhere(
        (s) => s.name == j['source'],
        orElse: () => RouteSource.gpx,
      ),
    );
  }

  static double _r(double v, int places) {
    final f = math.pow(10, places);
    return (v * f).round() / f;
  }
}

/// Turns raw points into a [SavedRoute]: drops repeats, simplifies, measures.
class RouteBuilder {
  const RouteBuilder._();

  /// The dead band the route's own elevation is measured with: the recorder's
  /// native `RoutePath.CLIMB_THRESHOLD_M`, so "climb to go" starts at this total.
  static const double climbThresholdM = 4;

  /// Horizontal tolerance when simplifying (kills GPS jitter, keeps corners).
  static const double toleranceM = 3;

  /// Vertical tolerance: a point that carries a hill's top or a dip stays.
  static const double elevToleranceM = 2;

  /// Throws [ImportFormatException] when [raw] is not a followable route.
  static SavedRoute build({
    required String id,
    required String name,
    required List<RoutePoint> raw,
    required RouteSource source,
    required DateTime createdAt,
  }) {
    final pts = <RoutePoint>[];
    for (final p in raw) {
      if (!p.lat.isFinite ||
          !p.lon.isFinite ||
          p.lat.abs() > 90 ||
          p.lon.abs() > 180) {
        continue;
      }
      // A repeated position (a stop, a paused logger) adds nothing.
      if (pts.isNotEmpty &&
          haversineM(pts.last.lat, pts.last.lon, p.lat, p.lon) < 1) {
        continue;
      }
      pts.add(p);
    }
    if (pts.length < 2) throw ImportFormatException('no route points');
    // Elevation is used only when nearly every point has one; gaps are filled.
    final withEle = pts.where((p) => p.ele != null && p.ele!.isFinite).length;
    final complete = withEle >= pts.length * 0.9 && withEle >= 2;
    final filled = complete
        ? _fillElevation(pts)
        : [for (final p in pts) RoutePoint(p.lat, p.lon)];
    var tol = toleranceM;
    var simple = _simplify(filled, tol);
    while (simple.length > SavedRoute.maxPoints) {
      tol *= 1.5;
      simple = _simplify(filled, tol);
    }
    final rounded = [
      for (final p in simple)
        RoutePoint(
          _round(p.lat, 6),
          _round(p.lon, 6),
          p.ele == null ? null : _round(p.ele!, 1),
        ),
    ];
    var dist = 0.0;
    for (var i = 1; i < rounded.length; i++) {
      dist += haversineM(
        rounded[i - 1].lat,
        rounded[i - 1].lon,
        rounded[i].lat,
        rounded[i].lon,
      );
    }
    if (dist < SavedRoute.minDistanceM) {
      throw ImportFormatException('route is shorter than 200 m');
    }
    if (dist > SavedRoute.maxDistanceM) {
      throw ImportFormatException('route is longer than 300 km');
    }
    double? climb;
    if (complete) {
      final tracker = ClimbTracker(climbThresholdM);
      for (final p in rounded) {
        tracker.offer(p.ele!);
      }
      climb = tracker.ascentM;
    }
    return SavedRoute(
      id: id,
      name: name.trim().isEmpty ? 'Route' : name.trim(),
      points: rounded,
      distanceM: dist,
      climbM: climb,
      createdAt: createdAt,
      source: source,
    );
  }

  static double _round(double v, int places) {
    final f = math.pow(10, places);
    return (v * f).round() / f;
  }

  static List<RoutePoint> _fillElevation(List<RoutePoint> pts) {
    final out = <RoutePoint>[];
    for (var i = 0; i < pts.length; i++) {
      final e = pts[i].ele;
      if (e != null && e.isFinite) {
        out.add(pts[i]);
        continue;
      }
      // Linear between the nearest points that have one; the ends copy the nearest.
      int? a, b;
      for (var j = i - 1; j >= 0; j--) {
        if (pts[j].ele != null && pts[j].ele!.isFinite) {
          a = j;
          break;
        }
      }
      for (var j = i + 1; j < pts.length; j++) {
        if (pts[j].ele != null && pts[j].ele!.isFinite) {
          b = j;
          break;
        }
      }
      double v;
      if (a != null && b != null) {
        final f = (i - a) / (b - a);
        v = pts[a].ele! + (pts[b].ele! - pts[a].ele!) * f;
      } else {
        v = (a != null ? pts[a].ele! : pts[b!].ele!);
      }
      out.add(RoutePoint(pts[i].lat, pts[i].lon, v));
    }
    return out;
  }

  /// Douglas-Peucker in local metres; a point also stays when its elevation is
  /// more than [elevToleranceM] off the line between its neighbours.
  static List<RoutePoint> _simplify(List<RoutePoint> pts, double tolM) {
    if (pts.length <= 2) return List.of(pts);
    final cosLat = math.cos(pts.first.lat * math.pi / 180);
    const mPerDeg = 111320.0;
    final xs = [for (final p in pts) p.lon * mPerDeg * cosLat];
    final ys = [for (final p in pts) p.lat * mPerDeg];
    final keep = List<bool>.filled(pts.length, false);
    keep[0] = keep[pts.length - 1] = true;
    final stack = <(int, int)>[(0, pts.length - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      final dx = xs[b] - xs[a];
      final dy = ys[b] - ys[a];
      final len2 = dx * dx + dy * dy;
      var worst = -1.0;
      var at = -1;
      for (var i = a + 1; i < b; i++) {
        final t = len2 == 0
            ? 0.0
            : (((xs[i] - xs[a]) * dx + (ys[i] - ys[a]) * dy) / len2).clamp(
                0.0,
                1.0,
              );
        final horiz = math.sqrt(
          math.pow(xs[i] - (xs[a] + t * dx), 2) +
              math.pow(ys[i] - (ys[a] + t * dy), 2),
        );
        var score = horiz / tolM;
        final ea = pts[a].ele, eb = pts[b].ele, ei = pts[i].ele;
        if (ea != null && eb != null && ei != null) {
          final vert = (ei - (ea + (eb - ea) * t)).abs();
          score = math.max(score, vert / elevToleranceM);
        }
        if (score > worst) {
          worst = score;
          at = i;
        }
      }
      if (at >= 0 && worst > 1) {
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
}

/// A route out of a file or a run. Pure: the caller reads the file or the run.
class RouteImporter {
  const RouteImporter();

  /// GPX: a planned route (`<rte>`) wins; otherwise the recorded track (`<trk>`).
  /// Times are not needed. Throws [ImportFormatException].
  SavedRoute fromGpx(String text, {DateTime? now, String? fallbackName}) =>
      _fromXml(text, RouteSource.gpx, now, fallbackName);

  /// TCX: the trackpoints that have a position (a course or an activity).
  SavedRoute fromTcx(String text, {DateTime? now, String? fallbackName}) =>
      _fromXml(text, RouteSource.tcx, now, fallbackName);

  /// By content: a `<gpx` root is GPX, a `<TrainingCenterDatabase` root is TCX.
  SavedRoute fromFile(String text, {DateTime? now, String? fallbackName}) {
    final head = text.length > 600 ? text.substring(0, 600) : text;
    if (head.contains('<TrainingCenterDatabase')) {
      return fromTcx(text, now: now, fallbackName: fallbackName);
    }
    return fromGpx(text, now: now, fallbackName: fallbackName);
  }

  /// "Run this route again": a past run's recorded fixes, in order. The id is
  /// the run's, so the same run offered twice is one route.
  SavedRoute fromRun(RunFile run, {String? name, DateTime? now}) {
    final raw = <RoutePoint>[
      for (final s in run.samples)
        if (s.hasFix) RoutePoint(s.lat!, s.lon!, s.elevM ?? s.altM),
    ];
    return RouteBuilder.build(
      id: 'run-${run.id}',
      name: name ?? 'Past run',
      raw: raw,
      source: RouteSource.run,
      createdAt: now ?? DateTime.now().toUtc(),
    );
  }

  SavedRoute _fromXml(
    String text,
    RouteSource source,
    DateTime? now,
    String? fallbackName,
  ) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException catch (e) {
      throw ImportFormatException('not XML: ${e.message}');
    }
    final raw = <RoutePoint>[];
    String? name;
    if (source == RouteSource.gpx) {
      var pts = doc.findAllElements('rtept').toList();
      if (pts.isEmpty) pts = doc.findAllElements('trkpt').toList();
      if (pts.isEmpty) throw ImportFormatException('no <rtept> or <trkpt>');
      for (final p in pts) {
        final lat = double.tryParse(p.getAttribute('lat') ?? '');
        final lon = double.tryParse(p.getAttribute('lon') ?? '');
        if (lat == null || lon == null) continue;
        raw.add(
          RoutePoint(
            lat,
            lon,
            double.tryParse(p.getElement('ele')?.innerText.trim() ?? ''),
          ),
        );
      }
      name =
          doc
              .findAllElements('rte')
              .firstOrNull
              ?.getElement('name')
              ?.innerText ??
          doc
              .findAllElements('trk')
              .firstOrNull
              ?.getElement('name')
              ?.innerText ??
          doc
              .findAllElements('metadata')
              .firstOrNull
              ?.getElement('name')
              ?.innerText;
    } else {
      final pts = doc.findAllElements('Trackpoint').toList();
      if (pts.isEmpty) throw ImportFormatException('no <Trackpoint>');
      for (final p in pts) {
        final pos = p.getElement('Position');
        final lat = double.tryParse(
          pos?.getElement('LatitudeDegrees')?.innerText.trim() ?? '',
        );
        final lon = double.tryParse(
          pos?.getElement('LongitudeDegrees')?.innerText.trim() ?? '',
        );
        if (lat == null || lon == null) continue;
        raw.add(
          RoutePoint(
            lat,
            lon,
            double.tryParse(
              p.getElement('AltitudeMeters')?.innerText.trim() ?? '',
            ),
          ),
        );
      }
      name = doc
          .findAllElements('Course')
          .firstOrNull
          ?.getElement('Name')
          ?.innerText;
    }
    final clean = name?.trim();
    return RouteBuilder.build(
      id: deterministicUuid(text),
      name: clean != null && clean.isNotEmpty
          ? clean
          : (fallbackName ?? 'Imported route'),
      raw: raw,
      source: source,
      createdAt: now ?? DateTime.now().toUtc(),
    );
  }
}
