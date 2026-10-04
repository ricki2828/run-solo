import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/hr_zone_choice.dart';
import 'package:run_solo/state/settings.dart';

/// Settings → Heart rate zones: persistence, lenient load, resolution.
void main() {
  final now = DateTime(2026, 10, 4);

  group('AppSettings zones json', () {
    test('old settings (no zone keys) load as share of max', () {
      final s = AppSettings.fromJson({'typedMaxHr': 185});
      expect(s.hrZoneMethod, engine.HrZoneMethod.percentMax);
      expect(s.restingHr, isNull);
      expect(s.customZones, isNull);
      expect(HrZoneChoice.resolve(s, now), engine.HrZones.percentMax(185));
    });

    test('round trip', () {
      final s = const AppSettings().copyWith(
        hrZoneMethod: engine.HrZoneMethod.custom,
        restingHr: 54,
        customZones: [108, 136, 149, 162, 176],
      );
      final r = AppSettings.fromJson(s.toJson());
      expect(r.hrZoneMethod, engine.HrZoneMethod.custom);
      expect(r.restingHr, 54);
      expect(r.customZones, [108, 136, 149, 162, 176]);
    });

    test('unknown or malformed values fall back', () {
      for (final bad in <Object?>['banana', null, <Object?>[]]) {
        final s = AppSettings.fromJson({
          'hrZoneMethod': bad,
          'restingHr': bad,
          'customZones': bad,
        });
        expect(s.hrZoneMethod, engine.HrZoneMethod.percentMax);
        expect(s.restingHr, isNull);
        expect(s.customZones, isNull);
      }
      // Wrong length, non-ascending, out of range and non-int tables drop.
      for (final bad in <Object?>[
        [100, 120, 140, 160],
        [100, 140, 130, 160, 180],
        [100, 120, 140, 160, 300],
        [100, 120, 'x', 160, 180],
      ]) {
        expect(AppSettings.fromJson({'customZones': bad}).customZones, isNull);
      }
      expect(AppSettings.fromJson({'restingHr': 5}).restingHr, isNull);
    });
  });

  group('HrZoneChoice.resolve', () {
    test('reserve uses typed resting and the resolved max', () {
      final s = const AppSettings().copyWith(
        hrZoneMethod: engine.HrZoneMethod.reserve,
        restingHr: 54,
        typedMaxHr: 188,
      );
      final z = HrZoneChoice.resolve(s, now);
      expect(
        [for (var k = 1; k <= 5; k++) z.bottom(k)],
        [108, 136, 149, 162, 176],
      );
    });

    test('reserve without a resting HR falls back to share of max', () {
      final s = const AppSettings().copyWith(
        hrZoneMethod: engine.HrZoneMethod.reserve,
        typedMaxHr: 188,
      );
      expect(HrZoneChoice.resolve(s, now), engine.HrZones.percentMax(188));
    });

    test('custom uses the table; no table falls back', () {
      final s = const AppSettings().copyWith(
        hrZoneMethod: engine.HrZoneMethod.custom,
        customZones: [100, 120, 140, 160, 180],
      );
      final z = HrZoneChoice.resolve(s, now);
      expect(z.method, engine.HrZoneMethod.custom);
      expect(z.zoneOf(140), 3);
      expect(
        HrZoneChoice.resolve(
          const AppSettings().copyWith(
            hrZoneMethod: engine.HrZoneMethod.custom,
          ),
          now,
        ).method,
        engine.HrZoneMethod.percentMax,
      );
    });
  });
}
