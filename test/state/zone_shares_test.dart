import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/zone_histogram.dart';

import '../run_fixtures.dart';

/// Time in zone maths: moving seconds per zone, then whole-percent shares.
void main() {
  final start = DateTime.utc(2026, 10, 2, 6);

  /// A 600 s free run with HR from [hrAt] (null = no reading).
  engine.RunFile runWith(int? Function(int sec) hrAt, {List<engine.Span>? p}) {
    final base = freeRunFile(n: 70, start: start, seconds: 600);
    return base.copyWith(
      pauses: p,
      samples: [
        for (final s in base.samples) s.copyWith(hr: hrAt(s.tMs ~/ 1000)),
      ],
    );
  }

  group('zoneSecondsOf', () {
    test('buckets by share of max HR', () {
      final z = zoneSecondsOf(runWith((s) => s < 300 ? 100 : 140), 190);
      expect(z[1], closeTo(300, 3)); // 100/190 = 53 %
      expect(z[3], closeTo(300, 3)); // 140/190 = 74 %
      expect(z[0], 0);
    });

    test('paused time counts in no zone', () {
      final all = zoneSecondsOf(runWith((_) => 140), 190);
      final paused = zoneSecondsOf(
        runWith((_) => 140, p: [const engine.Span(100000, 220000)]),
        190,
      );
      expect(all[3] - paused[3], closeTo(120, 2));
    });

    test('overlapping pauses are not subtracted twice', () {
      final z = zoneSecondsOf(
        runWith(
          (_) => 140,
          p: [
            const engine.Span(100000, 200000),
            const engine.Span(150000, 250000),
          ],
        ),
        190,
      );
      final all = zoneSecondsOf(runWith((_) => 140), 190);
      expect(all[3] - z[3], closeTo(150, 2));
    });

    test('moving time with no reading lands in slot 0', () {
      final z = zoneSecondsOf(runWith((s) => s < 100 ? null : 140), 190);
      expect(z[0], closeTo(100, 3));
    });
  });

  group('ZoneShares', () {
    test('percents sum to 100 whatever the split', () {
      for (final secs in [
        [1.0, 1.0, 1.0, 0.0, 0.0],
        [100.0, 100.0, 100.0, 100.0, 100.0],
        [333.0, 333.0, 334.0, 0.0, 0.0],
        [1.0, 2.0, 3.0, 5.0, 7.0],
        [0.0, 27.0, 2858.0, 0.0, 0.0],
        [0.5, 0.0, 0.0, 0.0, 999.0],
      ]) {
        final s = ZoneShares.from([0, ...secs])!;
        expect(s.percents.reduce((a, b) => a + b), 100, reason: '$secs');
        for (var i = 0; i < 5; i++) {
          if (secs[i] == 0) expect(s.percents[i], 0);
        }
      }
    });

    test('rounding is fixed: largest remainder, ties to the lower zone', () {
      final s = ZoneShares.from([0, 1, 1, 1, 0, 0])!;
      expect(s.percents, [34, 33, 33, 0, 0]);
    });

    test('founder run: 0:27 in Z2, 47:38 in Z3', () {
      final s = ZoneShares.from([0, 0, 27, 2858, 0, 0])!;
      expect(s.percents, [0, 1, 99, 0, 0]);
      expect(s.partialNote, isNull);
    });

    test('partial HR says how much of the run has it', () {
      final s = ZoneShares.from([180, 0, 0, 820, 0, 0])!;
      expect(s.hrCoverage, closeTo(0.82, 1e-9));
      expect(s.partialNote, 'Heart rate for 82% of the run');
    });

    test('no HR at all gives nothing to draw', () {
      expect(ZoneShares.from([600, 0, 0, 0, 0, 0]), isNull);
    });
  });
}
