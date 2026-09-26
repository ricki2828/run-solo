import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// v1 plan §18.5 / Phase 3 W1: Hadley heat table, coarse location, the
/// Open-Meteo request and the hour pick.
void main() {
  group('Hadley table (°F temperature + dew point)', () {
    double? f(double sum) => HeatModel.fractionForSumF(sum);

    test('band edges, interpolated low edge → high edge (W1)', () {
      expect(f(100), 0);
      expect(f(101), 0);
      expect(f(110), closeTo(0.005, 1e-12));
      expect(f(111), closeTo(0.005, 1e-12));
      expect(f(150.5), closeTo(0.045, 1e-12));
      expect(f(180), closeTo(0.10, 1e-12));
      expect(f(181), isNull, reason: 'too hot to compare');
      expect(f(180.01), isNull);
      // Inside a band: 141–150 runs 3 → 4.5%.
      expect(f(145.5), closeTo(0.0375, 1e-12));
    });

    test('never a cold bonus', () {
      expect(f(20), 0);
      expect(f(-40), 0);
      expect(HeatModel.of(tempC: -5, dewPointC: -10).fraction, 0);
    });

    test('metric fixture: 28 °C, dew point 21 °C = 152.2 °F → ≈ 4.7%', () {
      final h = HeatModel.of(tempC: 28, dewPointC: 21);
      expect(h.sumF, closeTo(152.2, 1e-9));
      expect(h.fraction, closeTo(0.047, 0.0005));
      expect(h.fraction!, lessThan(0.06), reason: 'never above its band top');
    });

    test('monotone and continuous across the whole range', () {
      var prev = 0.0;
      for (var s = 90.0; s <= 180; s += 0.25) {
        final v = f(s)!;
        expect(v, greaterThanOrEqualTo(prev), reason: 'at $s');
        expect(v - prev, lessThan(0.001), reason: 'no jump at $s');
        prev = v;
      }
    });

    test('adjusts a pace, a duration and a fixed-time distance', () {
      final h = HeatModel.of(tempC: 28, dewPointC: 21);
      final adj = h.fraction!;
      expect(h.pace(300), closeTo(300 * (1 - adj), 1e-9));
      expect(h.duration(1500), closeTo(1500 * (1 - adj), 1e-9));
      // Cooper: the distance cool conditions would have given.
      expect(h.distance(2800), closeTo(2800 / (1 - adj), 1e-9));
      final hot = HeatModel.of(tempC: 38, dewPointC: 28);
      expect(hot.tooHot, isTrue);
      expect(hot.pace(300), isNull);
      expect(hot.distance(2800), isNull);
    });

    test('dew point from relative humidity (Magnus)', () {
      expect(HeatModel.dewPointFromRh(28, 65), closeTo(20.9, 0.3));
      expect(HeatModel.dewPointFromRh(20, 100), closeTo(20, 0.05));
      expect(HeatModel.dewPointFromRh(10, 50), closeTo(0.1, 0.3));
    });
  });

  group('request', () {
    final run = fixture('preset_4x4_auto_standard').run;

    test('the URL carries 1-dp coordinates only, rounded before building', () {
      final first = run.samples.firstWhere((s) => s.hasFix);
      final req = WeatherRequest.forRun(
        run,
        now: run.start.add(const Duration(hours: 2)),
      )!;
      final q = req.uri.queryParameters;
      final lat = q['latitude']!;
      final lon = q['longitude']!;
      expect(RegExp(r'^-?\d+\.\d$').hasMatch(lat), isTrue, reason: lat);
      expect(RegExp(r'^-?\d+\.\d$').hasMatch(lon), isTrue, reason: lon);
      expect(double.parse(lat), closeTo(first.lat!, 0.05 + 1e-9));
      expect(double.parse(lon), closeTo(first.lon!, 0.05 + 1e-9));
      // Nothing in the whole URL has more than one decimal.
      expect(
        RegExp(r'\d\.\d\d').hasMatch(req.uri.toString()),
        isFalse,
        reason: req.uri.toString(),
      );
      expect(req.location.lat, double.parse(lat));
      expect(req.uri.host, 'api.open-meteo.com');
      expect(q['past_days'], '92');
      expect(q['timezone'], 'UTC');
      expect(
        q['hourly'],
        'temperature_2m,relative_humidity_2m,dew_point_2m,'
        'shortwave_radiation,wind_speed_10m',
      );
      expect(q['wind_speed_unit'], 'ms');
    });

    test('a 4-day-old run uses the forecast API, never the archive (W2)', () {
      final req = WeatherRequest.forRun(
        run,
        now: run.start.add(const Duration(days: 4)),
      )!;
      expect(req.uri.host, 'api.open-meteo.com');
    });

    test('a 6-month-old run uses the archive for its own date', () {
      final req = WeatherRequest.forRun(
        run,
        now: run.start.add(const Duration(days: 180)),
      )!;
      expect(req.uri.host, 'archive-api.open-meteo.com');
      final day = req.midpoint.toIso8601String().substring(0, 10);
      expect(req.uri.queryParameters['start_date'], day);
      expect(req.uri.queryParameters['end_date'], day);
    });

    test('rounding', () {
      final l = CoarseLocation.round(-33.8688, 151.2093);
      expect((l.latText, l.lonText), ('-33.9', '151.2'));
      expect(CoarseLocation.round(0.04, -0.04).lonText, '0.0');
    });

    test('every coordinate leaves as one decimal within 0.05°', () {
      final re = RegExp(r'^-?\d{1,3}\.\d$');
      for (var lat = -89.99; lat <= 89.99; lat += 0.137) {
        for (final lon in [
          -179.96,
          -151.25,
          -0.05,
          0.049999,
          18.4241,
          179.95,
        ]) {
          final l = CoarseLocation.round(lat, lon);
          expect(re.hasMatch(l.latText), isTrue, reason: l.latText);
          expect(re.hasMatch(l.lonText), isTrue, reason: l.lonText);
          expect((l.lat - lat).abs(), lessThanOrEqualTo(0.05 + 1e-9));
          expect((l.lon - lon).abs(), lessThanOrEqualTo(0.05 + 1e-9));
          // What is stored is exactly what is sent.
          expect(l.lat, double.parse(l.latText));
          expect(l.lon, double.parse(l.lonText));
        }
      }
    });

    test('an indoor run sends nothing', () {
      expect(
        WeatherRequest.forRun(
          fixture('treadmill_indoor').run,
          now: DateTime.utc(2026, 9, 25),
        ),
        isNull,
      );
    });
  });

  group('hour pick', () {
    final run = fixture('preset_4x4_auto_standard').run;
    final now = run.start.add(const Duration(hours: 2));
    final req = WeatherRequest.forRun(run, now: now)!;
    String hourText(DateTime t) => t.toUtc().toIso8601String().substring(0, 13);

    Map<String, Object?> body(
      List<DateTime> hours, {
      List<Object?>? temps,
      List<Object?>? dews,
      List<Object?>? suns,
      List<Object?>? winds,
    }) => {
      'hourly': {
        'time': [for (final h in hours) '${hourText(h)}:00'],
        'temperature_2m': temps ?? [for (final _ in hours) 28],
        'relative_humidity_2m': [for (final _ in hours) 65],
        'dew_point_2m': dews ?? [for (final _ in hours) 21],
        'shortwave_radiation': ?suns,
        'wind_speed_10m': ?winds,
      },
    };

    DateTime floorHour(DateTime t) =>
        DateTime.utc(t.year, t.month, t.day, t.hour);

    test('nearest hour to the midpoint; adj from temperature + dew point', () {
      final h0 = floorHour(req.midpoint);
      final r = req.parse(
        body(
          [
            h0.subtract(const Duration(hours: 1)),
            h0,
            h0.add(const Duration(hours: 1)),
          ],
          temps: [10, 28, 11],
          dews: [5, 21, 6],
          suns: [0, 310, 420],
          winds: [5.5, 3.2, 2.0],
        ),
        now: now,
      );
      expect(r.status, WeatherStatus.ok);
      expect(r.tempC, 28);
      expect(r.dewPointC, 21);
      expect(r.rh, 65);
      expect(r.adj, closeTo(0.047, 0.0005));
      expect(r.shortwaveWm2, 310);
      expect(r.windMs, 3.2);
      expect((r.latR, r.lonR), (req.location.lat, req.location.lon));
      // Round trip through the sidecar object.
      final back = WeatherRecord.fromJson(r.toJson())!;
      expect(back.status, WeatherStatus.ok);
      expect(back.heat!.fraction, closeTo(r.adj!, 1e-12));
      expect((back.shortwaveWm2, back.windMs), (310, 3.2));
      expect(r.toJson().keys, [
        'status',
        'fetched_at',
        'lat_r',
        'lon_r',
        'temp_c',
        'rh',
        'dew_point_c',
        'adj',
        'shortwave_w_m2',
        'wind_ms',
        'source',
      ]);
    });

    test('raw Open-Meteo response pins the wind unit (m/s)', () {
      final h = '${hourText(floorHour(req.midpoint))}:00';
      // Shape of a real forecast response with wind_speed_unit=ms.
      final raw =
          '''
{"latitude":-33.875,"longitude":151.25,"utc_offset_seconds":0,
 "timezone":"UTC","hourly_units":{"time":"iso8601","temperature_2m":"°C",
 "relative_humidity_2m":"%","dew_point_2m":"°C","shortwave_radiation":"W/m²",
 "wind_speed_10m":"m/s"},
 "hourly":{"time":["$h"],"temperature_2m":[22.0],"relative_humidity_2m":[60],
 "dew_point_2m":[14.0],"shortwave_radiation":[350.0],"wind_speed_10m":[1.4]}}''';
      final r = req.parse(jsonDecode(raw) as Map<String, Object?>, now: now);
      expect(r.status, WeatherStatus.ok);
      expect(r.windMs, 1.4);
      expect(r.shortwaveWm2, 350);
      // The same hour served in the default km/h reads as the same wind.
      final kmh = raw
          .replaceFirst('"wind_speed_10m":"m/s"', '"wind_speed_10m":"km/h"')
          .replaceFirst('"wind_speed_10m":[1.4]', '"wind_speed_10m":[5.04]');
      expect(
        req.parse(jsonDecode(kmh) as Map<String, Object?>, now: now).windMs,
        closeTo(1.4, 1e-9),
      );
    });

    test('wind is m/s: asked for, and a declared km/h is converted', () {
      final h0 = floorHour(req.midpoint);
      Map<String, Object?> withUnit(String? unit) => {
        ...body([h0], suns: [500], winds: [18]),
        'hourly_units': {'wind_speed_10m': ?unit},
      };
      expect(req.uri.queryParameters['wind_speed_unit'], 'ms');
      expect(req.parse(withUnit('m/s'), now: now).windMs, 18);
      expect(req.parse(withUnit(null), now: now).windMs, 18);
      expect(req.parse(withUnit('km/h'), now: now).windMs, closeTo(5, 1e-9));
      final knots = req.parse(withUnit('kn'), now: now);
      expect(knots.windMs, isNull, reason: 'unknown unit: dropped');
      expect(knots.status, WeatherStatus.ok);
    });

    test('no sun or wind (or a null one) is still ok: Cooper uses no-sun', () {
      final h0 = floorHour(req.midpoint);
      final missing = req.parse(body([h0]), now: now);
      expect(missing.status, WeatherStatus.ok);
      expect((missing.shortwaveWm2, missing.windMs), (null, null));
      final nulls = req.parse(
        body([h0], suns: [null], winds: [null]),
        now: now,
      );
      expect(nulls.status, WeatherStatus.ok);
      expect(nulls.adj, closeTo(0.047, 0.0005));
      expect(nulls.shortwaveWm2, isNull);
    });

    test('a null value keeps it pending, never ok, no adj', () {
      final h0 = floorHour(req.midpoint);
      final r = req.parse(body([h0], temps: [null]), now: now);
      expect(r.status, WeatherStatus.pending);
      expect(r.adj, isNull);
      expect(r.tempC, isNull);
    });

    test('the hour not in the response yet → pending', () {
      final far = req.midpoint.subtract(const Duration(hours: 5));
      expect(
        req.parse(body([floorHour(far)]), now: now).status,
        WeatherStatus.pending,
      );
      expect(req.parse(const {}, now: now).status, WeatherStatus.pending);
    });

    test('too hot to compare: ok, shown, adj null', () {
      final h0 = floorHour(req.midpoint);
      final r = req.parse(
        body([h0], temps: [38], dews: [28]),
        now: now,
      );
      expect(r.status, WeatherStatus.ok);
      expect(r.tempC, 38);
      expect(r.adj, isNull);
      expect(r.heat!.tooHot, isTrue);
    });
  });

  group('analysis twin (verdict stays raw)', () {
    final run = fixture('preset_4x4_auto_standard').run;
    RunSidecar withWeather(double temp, double dew) => RunSidecar(
      runId: run.id,
      weather: WeatherRecord(
        status: WeatherStatus.ok,
        fetchedAt: fixedNow,
        latR: -33.9,
        lonR: 151.2,
        tempC: temp,
        rh: 65,
        dewPointC: dew,
        adj: HeatModel.of(tempC: temp, dewPointC: dew).fraction,
      ).toJson(),
    );

    test(
      'adjusted twin and line; the verdict is word for word the raw one',
      () {
        final raw = engine.analyze(run, now: fixedNow);
        final hot = engine.analyze(
          run,
          sidecar: withWeather(28, 21),
          now: fixedNow,
        );
        expect(
          hot.verdict!.toJson()..remove('computed_at'),
          raw.verdict!.toJson()..remove('computed_at'),
        );
        final adj = hot.heat!.fraction!;
        expect(
          hot.heatAdjustedWorkPaceSecPerKm,
          closeTo(raw.intervals!.avgWorkPaceSecPerKm! * (1 - adj), 1e-9),
        );
        expect(
          hot.heatLine,
          'Heat-adjusted estimate: '
          '${PaceFormat.pace(hot.heatAdjustedWorkPaceSecPerKm!, run.units)} '
          '(28 °C, dew point 21).',
        );
        expect(raw.heatLine, isNull);
        expect(raw.heatAdjustedWorkPaceSecPerKm, isNull);
      },
    );

    test('cool: no line; too hot: said, not adjusted; pending: nothing', () {
      expect(
        engine
            .analyze(run, sidecar: withWeather(12, 5), now: fixedNow)
            .heatLine,
        isNull,
      );
      final tooHot = engine.analyze(
        run,
        sidecar: withWeather(38, 28),
        now: fixedNow,
      );
      expect(tooHot.heatLine, 'Too hot to compare (38 °C, dew point 28).');
      expect(tooHot.heatAdjustedWorkPaceSecPerKm, isNull);
      final pending = engine.analyze(
        run,
        sidecar: RunSidecar(
          runId: run.id,
          weather: const WeatherRecord(status: WeatherStatus.pending).toJson(),
        ),
        now: fixedNow,
      );
      expect(pending.weather!.status, WeatherStatus.pending);
      expect(pending.heatLine, isNull);
    });
  });
}
