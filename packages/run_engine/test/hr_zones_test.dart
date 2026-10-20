import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  group('reserve', () {
    // Plain Karvonen. Whoop's own zones for rest 54 / max 188 are 108,
    // 136, 149, 162, 176: up to about 2 bpm off (unknown internal
    // rounding), so exact matching is what Custom is for (see below).
    test('rest 54 / max 188 is plain Karvonen', () {
      final z = HrZones.reserve(54, 188);
      expect(
        [for (var k = 1; k <= 5; k++) z.bottom(k)],
        [108, 134, 148, 161, 175],
      );
      expect([for (var k = 1; k <= 4; k++) z.top(k)], [133, 147, 160, 174]);
      expect(z.top(5), isNull);
      expect(z.zoneOf(133), 1);
      expect(z.zoneOf(134), 2);
      expect(z.zoneOf(188), 5);
    });

    test('rest must be below max', () {
      expect(() => HrZones.reserve(190, 188), throwsArgumentError);
    });
  });

  group('percentMax', () {
    test('buckets exactly like the old share-of-max rule', () {
      for (final max in [150.0, 171.0, 190.0, 187.5, 200.0]) {
        final z = HrZones.percentMax(max);
        for (var hr = 40; hr <= 230; hr++) {
          final f = hr / max;
          final old = f < 0.6
              ? 1
              : f < 0.7
              ? 2
              : f < 0.8
              ? 3
              : f < 0.9
              ? 4
              : 5;
          // Old tracker compared hr >= max * share.
          var oldTracker = 1;
          for (var k = 5; k >= 2; k--) {
            if (hr >= max * const [0, 0, 0.60, 0.70, 0.80, 0.90][k]) {
              oldTracker = k;
              break;
            }
          }
          expect(z.zoneOf(hr), oldTracker, reason: 'max $max hr $hr');
          // The display-side fraction rule agrees away from float edges.
          if ((f * 10 - (f * 10).round()).abs() > 1e-9) {
            expect(z.zoneOf(hr), old, reason: 'max $max hr $hr');
          }
        }
      }
    });

    test('exact boundaries match the old hr / max maths', () {
      final z = HrZones.percentMax(190);
      int old(int hr) {
        final f = hr / 190;
        return f < 0.6
            ? 1
            : f < 0.7
            ? 2
            : f < 0.8
            ? 3
            : f < 0.9
            ? 4
            : 5;
      }

      for (final hr in [113, 114, 132, 133, 151, 152, 170, 171]) {
        expect(z.zoneOf(hr), old(hr), reason: 'hr $hr');
      }
      expect(
        [
          for (final hr in [114, 133, 152, 171]) z.zoneOf(hr),
        ],
        [2, 3, 4, 5],
      );
    });

    test('max 190 boundaries are 114 / 133 / 152 / 171', () {
      final z = HrZones.percentMax(190);
      expect(
        [for (var k = 2; k <= 5; k++) z.lowerBound(k)],
        [114, 133, 152, 171],
      );
    });
  });

  group('custom', () {
    test('accepts ascending bounds in range', () {
      final z = HrZones.custom([120, 140, 160, 180], z1Floor: 100);
      expect(z.zoneOf(119), 1);
      expect(z.zoneOf(120), 2);
      expect(z.bottom(1), 100);
    });

    test('accepts the Whoop zones for rest 54 / max 188 exactly', () {
      final z = HrZones.custom([136, 149, 162, 176], z1Floor: 108);
      expect(
        [for (var k = 1; k <= 5; k++) z.bottom(k)],
        [108, 136, 149, 162, 176],
      );
      expect([for (var k = 1; k <= 4; k++) z.top(k)], [135, 148, 161, 175]);
    });

    test('rejects non-ascending, equal, out-of-range and wrong length', () {
      expect(HrZones.validate([120, 120, 160, 180]), isNotNull);
      expect(HrZones.validate([120, 110, 160, 180]), isNotNull);
      expect(HrZones.validate([59, 110, 160, 180]), isNotNull);
      expect(HrZones.validate([120, 140, 160, 231]), isNotNull);
      expect(HrZones.validate([120, 140, 160]), isNotNull);
      expect(HrZones.validate([120, 140, 160, 180], z1Floor: 120), isNotNull);
      expect(HrZones.validate([120, 140, 160, 180], z1Floor: 59), isNotNull);
      expect(HrZones.validate([60, 140, 160, 230]), isNull);
      expect(() => HrZones.custom([120, 120, 160, 180]), throwsArgumentError);
    });
  });

  test('tracker keeps hysteresis on custom zones', () {
    final t = HrZoneTracker(
      zones: HrZones.custom([120, 140, 160, 180]),
      dwellMs: 0,
      minChangeIntervalMs: 0,
    );
    expect(t.update(0, 130).zone, 2);
    // 141 is inside the 2 bpm hysteresis above 140: stays Z2.
    expect(t.update(1000, 141).zone, 2);
    expect(t.update(2000, 142).zone, 3);
  });

  group('positionInZone', () {
    test('bottom 0, middle 0.5, next bottom 1 (percentMax 200)', () {
      final z = HrZones.percentMax(200); // bottoms 100, 120, 140, 160, 180
      expect(z.positionInZone(2, 120), 0);
      expect(z.positionInZone(2, 130), 0.5);
      expect(z.positionInZone(2, 140), 1);
      expect(z.positionInZone(1, 110), 0.5);
    });

    test('clamps below the bottom and above the top', () {
      final z = HrZones.percentMax(200);
      expect(z.positionInZone(3, 100), 0);
      expect(z.positionInZone(3, 200), 1);
    });

    test('Z5 uses the Z4 width', () {
      final z = HrZones.percentMax(200); // Z4 width 20 -> Z5 180..200
      expect(z.positionInZone(5, 180), 0);
      expect(z.positionInZone(5, 190), 0.5);
      expect(z.positionInZone(5, 200), 1);
      expect(z.positionInZone(5, 230), 1);
    });

    test('custom zones', () {
      final z = HrZones.custom([120, 140, 160, 180], z1Floor: 100);
      expect(z.positionInZone(1, 110), 0.5);
      expect(z.positionInZone(3, 150), 0.5);
      expect(z.positionInZone(5, 190), 0.5);
    });

    test('reserve zones (rounded bounds)', () {
      final z = HrZones.reserve(54, 188); // 108, 134, 148, 161, 175
      expect(z.positionInZone(2, 141), 0.5);
    });

    test('zone outside 1..5 is 0.5', () {
      final z = HrZones.percentMax(200);
      expect(z.positionInZone(0, 150), 0.5);
      expect(z.positionInZone(6, 150), 0.5);
    });
  });
}
