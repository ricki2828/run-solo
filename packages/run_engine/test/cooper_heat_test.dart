import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Phase 4 HV1 (plan §3.3, WARN-10): Cooper heat line from the Mantzios
/// 5000 m WBGT slope, capped 3%, on a no-sun WBGT blended towards BoM by
/// sun and wind (plan v2.2). Needs verification: the approximations, the
/// blend bands and the cap.
void main() {
  // Cooper 1968: VO2 = (d − 504.9) / 44.73; 2800 m → 51.3.
  double vo2(double m) => (m - 504.9) / 44.73;
  CooperHeatAdjustment at(double t, double dew, {double? sw, double? wind}) =>
      CooperHeat.adjust(
        tempC: t,
        dewPointC: dew,
        shortwaveWm2: sw,
        windMs: wind,
      );

  test('raw VO2 of the fixture', () => expect(vo2(2800), closeTo(51.3, 0.05)));

  group('worked examples (plan v2.2 §3.3, 2800 m, raw VO2 51.3)', () {
    // (case, air, dew, SW, wind, WBGT_0, WBGT_bom (null = not in the
    // plan), w, WBGT, adj, VO2 est.)
    const rows = [
      (
        '07:30 parkrun',
        20.0,
        15.0,
        60.0,
        2.0,
        17.7,
        null,
        0.0,
        17.7,
        0.008,
        51.8,
      ),
      (
        'humid dawn',
        22.0,
        18.0,
        120.0,
        1.5,
        20.0,
        24.5,
        0.0,
        20.0,
        0.015,
        52.3,
      ),
      (
        'blend low edge',
        22.0,
        14.0,
        150.0,
        1.0,
        18.4,
        22.7,
        0.0,
        18.4,
        0.010,
        52.0,
      ),
      (
        'blend midpoint',
        22.0,
        14.0,
        250.0,
        1.0,
        18.4,
        22.7,
        0.5,
        20.5,
        0.017,
        52.4,
      ),
      (
        'blend high edge',
        22.0,
        14.0,
        350.0,
        1.0,
        18.4,
        22.7,
        1.0,
        22.7,
        0.023,
        52.8,
      ),
      (
        'sun, breezy',
        22.0,
        14.0,
        350.0,
        4.0,
        18.4,
        22.7,
        0.5,
        20.5,
        0.017,
        52.4,
      ),
      ('hot sunny', 28.0, 21.0, 800.0, 1.0, 24.6, 29.6, 1.0, 29.6, 0.030, 53.2),
    ];
    for (final (name, t, dew, sw, wind, w0, wb, w, wbgt, adj, v) in rows) {
      test(name, () {
        final h = at(t, dew, sw: sw, wind: wind);
        expect(h.wbgtNoSunC, closeTo(w0, 0.05));
        if (wb != null) expect(h.wbgtBomC, closeTo(wb, 0.05));
        expect(h.bomWeight, closeTo(w, 1e-12));
        expect(h.wbgtC, closeTo(wbgt, 0.06));
        expect(h.fraction, closeTo(adj, 0.0005));
        expect(vo2(h.distance(2800)!), closeTo(v, 0.05));
      });
    }

    test('hot sunny: 4.4% before the cap, 2886.6 m after it', () {
      final h = at(28, 21, sw: 800, wind: 1);
      expect(0.003 * (h.wbgtC - 15), closeTo(0.044, 0.0005));
      expect(h.fraction, 0.03);
      expect(h.distance(2800), closeTo(2886.6, 0.05));
    });
  });

  group('blend weight', () {
    double w({double? sw, double? wind}) =>
        CooperHeat.bomWeight(shortwaveWm2: sw, windMs: wind);

    test('sun band 150 → 350 W/m², linear, clamped', () {
      expect(w(sw: 0, wind: 1), 0);
      expect(w(sw: 150, wind: 1), 0);
      expect(w(sw: 200, wind: 1), closeTo(0.25, 1e-12));
      expect(w(sw: 350, wind: 1), 1);
      expect(w(sw: 900, wind: 1), 1);
    });
    test('wind band edges: 2 m/s full weight, 6 m/s none', () {
      expect(w(sw: 800, wind: 0), 1);
      expect(w(sw: 800, wind: 2), 1);
      expect(w(sw: 800, wind: 4), closeTo(0.5, 1e-12));
      expect(w(sw: 800, wind: 6), 0);
      expect(w(sw: 800, wind: 12), 0);
      expect(at(22, 14, sw: 800, wind: 6).wbgtC, closeTo(18.4, 0.05));
      expect(at(22, 14, sw: 800, wind: 2).wbgtC, closeTo(22.7, 0.05));
    });
    test('no hard switch: a tiny change in sun or wind is a tiny change', () {
      final a = at(22, 14, sw: 249, wind: 3.99);
      final b = at(22, 14, sw: 251, wind: 4.01);
      expect((a.fraction! - b.fraction!).abs(), lessThan(0.0002));
    });
    test('a windy sunny morning damps the heat line', () {
      // 22 / 14 in full sun: still air gets the BoM estimate, 7 m/s gets
      // none of it (above the 6 m/s band edge). 25 km/h unconverted would
      // read as 25 "m/s" and look identical to this windy case, which is why
      // W1 asks for and normalises m/s.
      final still = at(22, 14, sw: 800, wind: 1);
      final windy = at(22, 14, sw: 800, wind: 7);
      expect(still.fraction, closeTo(0.023, 0.0005));
      expect(windy.bomWeight, 0);
      expect(windy.fraction, closeTo(0.010, 0.0005));
      expect(windy.fraction, lessThan(still.fraction!));
      final vStill = vo2(still.distance(2800)!);
      final vWindy = vo2(windy.distance(2800)!);
      expect(still.line(vStill), contains('52.8'));
      expect(windy.line(vWindy), contains('52.0'));
    });

    test('missing sun or wind: w = 0 (no-sun estimate)', () {
      expect(w(wind: 1), 0);
      expect(w(sw: 800), 0);
      expect(w(), 0);
      expect(at(22, 14).wbgtC, closeTo(18.4, 0.05));
    });
  });

  group('slope, optimum and cap', () {
    test('0 up to 15 °C WBGT, never a cold bonus', () {
      expect(CooperHeat.fractionForWbgt(15), 0);
      expect(CooperHeat.fractionForWbgt(5), 0);
      expect(CooperHeat.fractionForWbgt(-10), 0);
      expect(at(-5, -10, sw: 800, wind: 1).fraction, 0);
    });
    test('0.3% per °C above 15', () {
      expect(CooperHeat.fractionForWbgt(16), closeTo(0.003, 1e-12));
      expect(CooperHeat.fractionForWbgt(20), closeTo(0.015, 1e-12));
    });
    test('3% cap reached at 25 °C WBGT and held above it', () {
      expect(CooperHeat.fractionForWbgt(25), closeTo(0.03, 1e-12));
      expect(CooperHeat.fractionForWbgt(24.9), lessThan(0.03));
      expect(CooperHeat.fractionForWbgt(32), 0.03);
    });
  });

  group('Hadley "too hot" edge (°F sum > 180)', () {
    test('just below: the capped line; just above: raw only', () {
      // 32 + 32.2 °C → 179.56 °F: inside the table.
      final below = at(32, 32.2, sw: 800, wind: 1);
      expect(below.tooHot, isFalse);
      expect(below.fraction, 0.03);
      expect(below.line(52.9), startsWith('Heat-adjusted estimate 52.9'));
      // 32.5 + 32.5 °C → 181 °F.
      final above = at(32.5, 32.5, sw: 800, wind: 1);
      expect(above.tooHot, isTrue);
      expect(above.fraction, isNull);
      expect(above.distance(2800), isNull);
      expect(above.line(null), 'Too hot to compare, raw only');
    });
  });

  group('from the sidecar weather', () {
    test('ok record with sun and wind', () {
      final w = WeatherRecord.fromJson({
        'status': 'ok',
        'temp_c': 22,
        'dew_point_c': 14,
        'rh': 60,
        'shortwave_w_m2': 400,
        'wind_ms': 3,
      });
      final h = CooperHeat.of(w)!;
      expect(h.bomWeight, closeTo(0.75, 1e-12)); // sun 1 × wind 0.75
      expect(h.wbgtC, closeTo(18.4 + 0.75 * 4.3, 0.1));
    });
    test('a record without sun and wind: no-sun (w = 0)', () {
      final w = WeatherRecord.fromJson({
        'status': 'ok',
        'temp_c': 22,
        'dew_point_c': 14,
      });
      expect(CooperHeat.of(w)!.bomWeight, 0);
    });
    test('pending, failed, skipped or none: nothing', () {
      for (final s in ['pending', 'failed', 'skipped']) {
        expect(CooperHeat.of(WeatherRecord.fromJson({'status': s})), isNull);
      }
      expect(CooperHeat.of(null), isNull);
    });
  });

  group('copy', () {
    test('the line is a separate estimate, rounded only at display', () {
      final h = at(22, 14, sw: 800, wind: 1);
      final v = vo2(h.distance(2800)!);
      expect(h.line(v), 'Heat-adjusted estimate 52.8 · 22 °C, dew point 14');
      expect(h.fraction, isNot(0.023), reason: 'stored unrounded');
    });
    test('strings with a heat number carry an estimate marker', () {
      // Same list as PD1's carriesEstimateMarker (#32); switch to it once
      // PD1 merges.
      bool marked(String s) => const [
        'estimate',
        'est.',
        'about',
        'research-based',
        'predicted',
      ].any(s.toLowerCase().contains);
      expect(marked(at(22, 14, sw: 800, wind: 1).line(52.8)!), isTrue);
      expect(marked(CooperHeat.disclosure), isTrue);
      expect(marked(CooperHeat.caveat), isTrue);
      expect(CooperHeat.caveat, endsWith('treat it as a rough estimate.'));
      expect(CooperHeat.caveat, contains('may not fit'));
      for (final s in [
        CooperHeat.caveat,
        CooperHeat.tooHotLine,
        CooperHeat.disclosure,
      ]) {
        expect(s, isNot(contains('—')), reason: 'no em dashes');
      }
    });
  });
}
