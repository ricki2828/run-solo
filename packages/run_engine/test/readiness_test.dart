import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  // A run's first 10 minutes at 1 Hz: [restSeconds] standing at [rest] bpm,
  // then running at 150.
  RunFile runWith({
    int restSeconds = 240,
    int rest = 58,
    bool hr = true,
    double restSpeed = 0.2,
  }) {
    final base = runWithPaces([280, 280, 280, 280], hr: true);
    return base.copyWith(
      samples: [
        for (var s = 0; s < 600; s++)
          Sample(
            tMs: s * 1000,
            speedMps: s < restSeconds ? restSpeed : 3.5,
            distM: s * 3.0,
            hr: !hr ? null : (s < restSeconds ? rest : 150),
          ),
      ],
    );
  }

  group('RestingHr', () {
    test('the lowest 2 minutes while standing', () {
      expect(RestingHr.of(runWith(rest: 58)), 58);
    });

    test('no strap, no figure', () {
      expect(RestingHr.of(runWith(hr: false)), isNull);
    });

    test('a runner who set off at once has no rest window', () {
      expect(RestingHr.of(runWith(restSeconds: 30)), isNull);
    });

    test('too high to be rest-ish is dropped', () {
      expect(RestingHr.of(runWith(rest: 130)), isNull);
    });

    test('a run too short for a window gives nothing', () {
      final tiny = runWith().copyWith(
        samples: [
          for (var s = 0; s < 60; s++)
            Sample(tMs: s * 1000, speedMps: 0.2, distM: 0, hr: 55),
        ],
      );
      expect(RestingHr.of(tiny), isNull);
    });
  });

  group('Readiness', () {
    final now = DateTime(2026, 10, 4, 9);
    ({DateTime date, int bpm}) r(int daysAgo, int bpm) =>
        (date: now.subtract(Duration(days: daysAgo)), bpm: bpm);

    test('normal against the 7-day median', () {
      final x = Readiness.of([
        r(0, 55),
        r(2, 54),
        r(4, 56),
        r(6, 55),
      ], now: now)!;
      expect(x.baselineBpm, 55);
      expect(x.takeItEasy, isFalse);
      expect(x.line, 'Recovered: resting HR normal');
    });

    test('up 6 bpm: take it easy', () {
      final x = Readiness.of([
        r(0, 61),
        r(2, 54),
        r(4, 56),
        r(6, 55),
      ], now: now)!;
      expect(x.delta, 6);
      expect(x.line, 'Take it easy: resting HR up 6 bpm');
      expect(x.detail, contains('Research-based'));
    });

    test('lower than baseline still reads recovered', () {
      final x = Readiness.of([
        r(0, 50),
        r(2, 54),
        r(4, 56),
        r(6, 55),
      ], now: now)!;
      expect(x.line, 'Recovered: resting HR normal');
    });

    test('hidden without enough baseline or a fresh reading', () {
      expect(Readiness.of([r(0, 60), r(2, 54), r(4, 56)], now: now), isNull);
      expect(Readiness.of(const [], now: now), isNull);
      expect(
        Readiness.of([r(4, 60), r(5, 54), r(6, 56), r(7, 55)], now: now),
        isNull,
        reason: 'latest reading is 4 days old',
      );
    });

    test('readings older than 7 days before the latest are not baseline', () {
      expect(
        Readiness.of([
          r(0, 60),
          r(2, 54),
          r(4, 56),
          r(9, 55),
          r(10, 55),
        ], now: now),
        isNull,
      );
    });
  });
}
