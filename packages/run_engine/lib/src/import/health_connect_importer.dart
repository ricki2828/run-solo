import '../model/run_file.dart';
import '../run_mode.dart';
import 'import_util.dart';

/// One timed value read from Health Connect (heart rate bpm, speed m/s).
/// Epoch milliseconds, UTC.
class HcValue {
  const HcValue(this.epochMs, this.value);
  final int epochMs;
  final double value;
}

/// One Health Connect `DistanceRecord`: [meters] covered between the two
/// instants. Watches write one per few seconds up to one per lap.
class HcDistance {
  const HcDistance(this.startMs, this.endMs, this.meters);
  final int startMs;
  final int endMs;
  final double meters;
}

/// One Health Connect `ExerciseRoute` location.
class HcRoutePoint {
  const HcRoutePoint(this.epochMs, this.lat, this.lon, [this.altM]);
  final int epochMs;
  final double lat;
  final double lon;
  final double? altM;
}

/// A running `ExerciseSessionRecord` and the records read for its window,
/// as plain data. The platform layer fills it; this package never touches
/// Health Connect, so the conversion is testable on any host.
class HcRunSession {
  const HcRunSession({
    required this.sessionId,
    required this.startMs,
    required this.endMs,
    this.zoneOffsetMin,
    this.sourcePackage = 'unknown',
    this.title,
    this.distance = const [],
    this.heartRate = const [],
    this.speed = const [],
    this.route = const [],
    this.routeConsentRequired = false,
  });

  /// Health Connect's record id (stable per record on this phone).
  final String sessionId;
  final int startMs;
  final int endMs;

  /// The session's own zone offset in minutes; null when the writing app left
  /// it unset (then the importer says UTC, like TCX).
  final int? zoneOffsetMin;

  /// The app that wrote the session (e.g. `com.garmin.android.apps.connectmobile`).
  final String sourcePackage;
  final String? title;
  final List<HcDistance> distance;
  final List<HcValue> heartRate;
  final List<HcValue> speed;
  final List<HcRoutePoint> route;

  /// Health Connect withheld the route until the runner consents for this
  /// session; the run imports without it.
  final bool routeConsentRequired;
}

/// Health Connect session -> schema-7 [RunFile] (the same model the recorder,
/// TCX and GPX produce), so every downstream feature (analysis, true pace,
/// companion summary) works unchanged.
///
/// The grid is [stepMs] ticks from start to end. Distance is the cumulative sum
/// of the distance records (pro-rated inside a record), heart rate is the
/// latest reading at most [hrMaxAgeMs] old, speed likewise, position is the
/// latest route point at most [routeMaxAgeMs] old. A session with no distance
/// records but a route falls back to haversine over the route; with neither it
/// is rejected ([ImportFormatException]) because it has nothing to coach.
class HealthConnectImporter {
  const HealthConnectImporter({
    this.stepMs = 5000,
    this.hrMaxAgeMs = 30000,
    this.routeMaxAgeMs = 15000,
  });

  final int stepMs;
  final int hrMaxAgeMs;
  final int routeMaxAgeMs;

  /// The Health Connect session id as a run id: the same session imports to
  /// the same uuid, so dedupe by id keeps working.
  static String runIdFor(String sessionId) =>
      deterministicUuid('healthconnect:$sessionId');

  RunFile import(HcRunSession s, {Units units = Units.km}) {
    final durMs = s.endMs - s.startMs;
    if (durMs < 1000) throw ImportFormatException('session shorter than 1 s');
    final route = [...s.route]..sort((a, b) => a.epochMs.compareTo(b.epochMs));
    final hr = [...s.heartRate]..sort((a, b) => a.epochMs.compareTo(b.epochMs));
    final spd = [...s.speed]..sort((a, b) => a.epochMs.compareTo(b.epochMs));
    final dist = [...s.distance]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final ticks = <int>[for (var t = 0; t < durMs; t += stepMs) t, durMs];
    final cum = _cumulative(s, dist, route, ticks);
    if (cum == null) {
      throw ImportFormatException('no distance records and no route');
    }

    var hrI = -1;
    var spI = -1;
    var rI = -1;
    final samples = <Sample>[];
    for (var i = 0; i < ticks.length; i++) {
      final abs = s.startMs + ticks[i];
      while (hrI + 1 < hr.length && hr[hrI + 1].epochMs <= abs) {
        hrI++;
      }
      while (spI + 1 < spd.length && spd[spI + 1].epochMs <= abs) {
        spI++;
      }
      while (rI + 1 < route.length && route[rI + 1].epochMs <= abs) {
        rI++;
      }
      final h = hrI >= 0 && abs - hr[hrI].epochMs <= hrMaxAgeMs
          ? hr[hrI].value.round()
          : null;
      final p = rI >= 0 && abs - route[rI].epochMs <= routeMaxAgeMs
          ? route[rI]
          : null;
      double? v;
      if (spI >= 0 && abs - spd[spI].epochMs <= hrMaxAgeMs) {
        v = spd[spI].value;
      } else if (i > 0) {
        v = (cum[i] - cum[i - 1]) / ((ticks[i] - ticks[i - 1]) / 1000);
      }
      samples.add(
        Sample(
          tMs: ticks[i],
          lat: p?.lat,
          lon: p?.lon,
          altM: p?.altM,
          accM: null,
          speedMps: v == null || v.isNaN || v < 0 ? null : v,
          distM: cum[i],
          hr: h == null || h <= 0 ? null : h,
        ),
      );
    }

    return RunFile(
      id: runIdFor(s.sessionId),
      device: s.sourcePackage,
      app: 'import:healthconnect',
      start: DateTime.fromMillisecondsSinceEpoch(s.startMs, isUtc: true),
      end: DateTime.fromMillisecondsSinceEpoch(s.endMs, isUtc: true),
      tz: _tz(s.zoneOffsetMin),
      // Another app's run has no lap structure we can trust (same rule as
      // GPX): a free run; the speed-stream fallback can still look for reps.
      mode: RunMode.free,
      session: null,
      units: units,
      laps: const [],
      samples: samples,
    );
  }

  /// Cumulative metres at each tick, or null when nothing measures distance.
  static List<double>? _cumulative(
    HcRunSession s,
    List<HcDistance> dist,
    List<HcRoutePoint> route,
    List<int> ticks,
  ) {
    if (dist.isNotEmpty) {
      return [for (final t in ticks) _distanceAt(dist, s.startMs + t)];
    }
    if (route.length < 2) return null;
    // Haversine along the route, read at each tick.
    final run = <double>[0];
    for (var i = 1; i < route.length; i++) {
      run.add(
        run.last +
            haversineM(
              route[i - 1].lat,
              route[i - 1].lon,
              route[i].lat,
              route[i].lon,
            ),
      );
    }
    final out = <double>[];
    var j = 0;
    for (final t in ticks) {
      final abs = s.startMs + t;
      while (j + 1 < route.length && route[j + 1].epochMs <= abs) {
        j++;
      }
      out.add(abs < route.first.epochMs ? 0 : run[j]);
    }
    return out;
  }

  static double _distanceAt(List<HcDistance> dist, int abs) {
    var m = 0.0;
    for (final r in dist) {
      if (abs >= r.endMs) {
        m += r.meters;
      } else if (abs > r.startMs && r.endMs > r.startMs) {
        m += r.meters * (abs - r.startMs) / (r.endMs - r.startMs);
      }
    }
    return m;
  }

  static String _tz(int? offsetMin) {
    if (offsetMin == null) return 'UTC';
    final a = offsetMin.abs();
    final hh = (a ~/ 60).toString().padLeft(2, '0');
    final mm = (a % 60).toString().padLeft(2, '0');
    return '${offsetMin < 0 ? '-' : '+'}$hh:$mm';
  }
}
