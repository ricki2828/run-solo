import '../model/run_file.dart';
import 'heat_model.dart';

/// Where a run's weather stands (v1 plan §18.5 data model).
enum WeatherStatus {
  /// Not fetched yet, or the provider had no value for the hour: retried.
  pending,
  ok,

  /// A 4xx or a run the provider cannot cover: never retried.
  failed,

  /// Indoor run (no fixes): no fetch, no location to send.
  skipped,
}

/// The sidecar's `weather` object (schema 2+). Only the 0.1°-rounded
/// location is ever stored.
class WeatherRecord {
  const WeatherRecord({
    required this.status,
    this.fetchedAt,
    this.latR,
    this.lonR,
    this.tempC,
    this.rh,
    this.dewPointC,
    this.adj,
    this.shortwaveWm2,
    this.windMs,
    this.source = openMeteo,
  });

  static const String openMeteo = 'open-meteo';

  final WeatherStatus status;
  final DateTime? fetchedAt;
  final double? latR;
  final double? lonR;
  final double? tempC;
  final double? rh;
  final double? dewPointC;

  /// Slowdown fraction; null when not ok or too hot to compare.
  final double? adj;

  /// Sun (W/m², mean over the preceding hour) and 10 m wind (m/s) at the
  /// run's hour: the Cooper heat line (Phase 4 HV1, WARN-10) picks its WBGT
  /// approximation from them. Optional: null keeps the record `ok` and the
  /// Cooper falls back to the no-sun estimate.
  final double? shortwaveWm2;
  final double? windMs;
  final String source;

  bool get isOk => status == WeatherStatus.ok;

  /// The adjustment, recomputed from the stored temperature and dew point
  /// (the stored `adj` is a cache for the index).
  HeatAdjustment? get heat => isOk && tempC != null && dewPointC != null
      ? HeatModel.of(tempC: tempC!, dewPointC: dewPointC!)
      : null;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'fetched_at': fetchedAt?.toUtc().toIso8601String(),
    'lat_r': latR,
    'lon_r': lonR,
    'temp_c': tempC,
    'rh': rh,
    'dew_point_c': dewPointC,
    'adj': adj,
    'shortwave_w_m2': shortwaveWm2,
    'wind_ms': windMs,
    'source': source,
  };

  /// Lenient: the sidecar carries `weather` opaquely; anything this build
  /// cannot read is treated as absent (the run is simply fetched again).
  static WeatherRecord? fromJson(Map<String, Object?>? j) {
    if (j == null) return null;
    final status = WeatherStatus.values
        .where((s) => s.name == j['status'])
        .firstOrNull;
    if (status == null) return null;
    double? d(String k) => (j[k] is num) ? (j[k]! as num).toDouble() : null;
    final at = j['fetched_at'];
    return WeatherRecord(
      status: status,
      fetchedAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      latR: d('lat_r'),
      lonR: d('lon_r'),
      tempC: d('temp_c'),
      rh: d('rh'),
      dewPointC: d('dew_point_c'),
      adj: d('adj'),
      shortwaveWm2: d('shortwave_w_m2'),
      windMs: d('wind_ms'),
      source: (j['source'] as String?) ?? openMeteo,
    );
  }
}

/// A coarse location: rounded to 0.1° (about 11 km N–S) BEFORE anything is
/// built from it; the only form that ever leaves the engine.
class CoarseLocation {
  const CoarseLocation._(this.lat, this.lon);

  final double lat;
  final double lon;

  /// The run's first sample with a fix, rounded; null for an indoor run.
  static CoarseLocation? ofRun(RunFile run) {
    for (final s in run.samples) {
      if (s.hasFix) return round(s.lat!, s.lon!);
    }
    return null;
  }

  static CoarseLocation round(double lat, double lon) =>
      CoarseLocation._(_r1(lat), _r1(lon));

  static double _r1(double v) => (v * 10).round() / 10;

  /// Exactly one decimal, as sent: "-33.9".
  String get latText => lat.toStringAsFixed(1);
  String get lonText => lon.toStringAsFixed(1);
}

/// Open-Meteo request for one run (v1 plan §18.5, W2, N5): the forecast API
/// with `past_days=92` for runs up to 90 days old (it serves the recent past
/// with no delay), the archive (ERA5, ~5-day delay) only for older runs, so
/// the 3–5-day gap never hits the archive. No key, no identifier: the URL
/// carries the rounded location and the dates only. Sun and wind ride along
/// in the same call for the Cooper heat line (Phase 4 WARN-10); wind comes
/// in m/s.
class WeatherRequest {
  const WeatherRequest._(this.uri, this.location, this.midpoint);

  final Uri uri;
  final CoarseLocation location;

  /// The run's midpoint (UTC): the hour nearest to it is picked.
  final DateTime midpoint;

  static const int forecastMaxAgeDays = 90;

  /// Null for an indoor run (nothing to send).
  static WeatherRequest? forRun(RunFile run, {required DateTime now}) {
    final loc = CoarseLocation.ofRun(run);
    if (loc == null) return null;
    final mid = run.start
        .add(
          Duration(
            milliseconds: run.end.difference(run.start).inMilliseconds ~/ 2,
          ),
        )
        .toUtc();
    const hourly =
        'temperature_2m,relative_humidity_2m,dew_point_2m,'
        'shortwave_radiation,wind_speed_10m';
    final age = now.toUtc().difference(mid);
    final Uri uri;
    if (age.inDays <= forecastMaxAgeDays) {
      uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${loc.latText}'
        '&longitude=${loc.lonText}&hourly=$hourly&wind_speed_unit=ms'
        '&past_days=92&timezone=UTC',
      );
    } else {
      final day = _date(mid);
      uri = Uri.parse(
        'https://archive-api.open-meteo.com/v1/archive?latitude=${loc.latText}'
        '&longitude=${loc.lonText}&start_date=$day&end_date=$day'
        '&hourly=$hourly&wind_speed_unit=ms&timezone=UTC',
      );
    }
    return WeatherRequest._(uri, loc, mid);
  }

  /// Wind in m/s whatever the response says it sent: the request asks for
  /// `wind_speed_unit=ms` (the default is km/h, which would read 3.6×
  /// too windy and switch the Cooper sun estimate off). A declared km/h is
  /// converted; any other declared unit is dropped (null → no-sun).
  static num? _windMs(num? v, Object? units) {
    if (v == null) return null;
    final unit = units is Map ? units['wind_speed_10m'] : null;
    return switch (unit) {
      null || 'm/s' => v,
      'km/h' => v / 3.6,
      _ => null,
    };
  }

  static String _date(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// The hour nearest [midpoint] in an Open-Meteo `hourly` response.
  /// Returns `ok` with the values, or `pending` when the hour is missing
  /// (more than 90 minutes away) or any value is null: never `ok` from a
  /// null, and `adj` is never computed from one.
  WeatherRecord parse(Map<String, Object?> body, {required DateTime now}) {
    WeatherRecord pending() => WeatherRecord(
      status: WeatherStatus.pending,
      fetchedAt: now.toUtc(),
      latR: location.lat,
      lonR: location.lon,
    );
    final hourly = body['hourly'];
    if (hourly is! Map) return pending();
    final times = hourly['time'];
    final temps = hourly['temperature_2m'];
    final rhs = hourly['relative_humidity_2m'];
    final dews = hourly['dew_point_2m'];
    final suns = hourly['shortwave_radiation'];
    final winds = hourly['wind_speed_10m'];
    if (times is! List || temps is! List || rhs is! List || dews is! List) {
      return pending();
    }
    var best = -1;
    var bestGap = const Duration(days: 9999);
    for (var i = 0; i < times.length; i++) {
      final t = times[i];
      if (t is! String) continue;
      // Open-Meteo with timezone=UTC writes "2026-09-24T06:00" (no zone).
      final parsed = DateTime.tryParse(t.endsWith('Z') ? t : '${t}Z');
      if (parsed == null) continue;
      final gap = parsed.difference(midpoint).abs();
      if (gap < bestGap) {
        bestGap = gap;
        best = i;
      }
    }
    if (best < 0 || bestGap > const Duration(minutes: 90)) return pending();
    num? at(List l) =>
        best < l.length && l[best] is num ? l[best] as num : null;
    final temp = at(temps);
    final rh = at(rhs);
    final dew = at(dews);
    if (temp == null || rh == null || dew == null) return pending();
    final sun = suns is List ? at(suns) : null;
    final wind = winds is List
        ? _windMs(at(winds), body['hourly_units'])
        : null;
    final heat = HeatModel.of(
      tempC: temp.toDouble(),
      dewPointC: dew.toDouble(),
    );
    return WeatherRecord(
      status: WeatherStatus.ok,
      fetchedAt: now.toUtc(),
      latR: location.lat,
      lonR: location.lon,
      tempC: temp.toDouble(),
      rh: rh.toDouble(),
      dewPointC: dew.toDouble(),
      adj: heat.fraction,
      shortwaveWm2: sun?.toDouble(),
      windMs: wind?.toDouble(),
    );
  }
}
