import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  // A 30 minute free run to hang laps and pauses on.
  final base = fixture('easy_free_run').run;
  final totalMs = base.end.difference(base.start).inMilliseconds;

  Lap lap(int i, int t0, int t1, [LapKind kind = LapKind.manual]) =>
      Lap(index: i, t0Ms: t0, t1Ms: t1, d0M: 0, d1M: 0, kind: kind);

  RunFile with_({List<Lap>? laps, List<Span>? pauses}) =>
      base.copyWith(laps: laps ?? base.laps, pauses: pauses ?? const []);

  group('movingMs', () {
    test('no pauses: the whole duration, warm-up included', () {
      expect(RunTimes.movingMs(with_()), totalMs);
    });

    test('pauses come out', () {
      final r = with_(pauses: [Span(60000, 90000), Span(120000, 125000)]);
      expect(RunTimes.movingMs(r), totalMs - 35000);
    });

    test('overlapping and out-of-range pauses are not counted twice', () {
      final r = with_(
        pauses: [
          Span(60000, 90000),
          Span(80000, 100000),
          Span(totalMs - 1000, totalMs + 9000),
        ],
      );
      expect(RunTimes.movingMs(r), totalMs - 40000 - 1000);
    });

    test('a run that was all pause is zero, never negative', () {
      expect(RunTimes.movingMs(with_(pauses: [Span(-5, totalMs + 5)])), 0);
    });
  });

  group('medianLapSec', () {
    test('no laps: null', () {
      expect(RunTimes.medianLapSec(with_(laps: const [])), isNull);
    });

    test('median of complete laps', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000),
          lap(1, 300000, 620000),
          lap(2, 620000, 900000),
          lap(3, 900000, 1200000),
        ],
      );
      // 300, 320, 280, 300 -> sorted 280 300 300 320 -> 300
      expect(RunTimes.medianLapSec(r), 300);
    });

    test('a partial final lap is left out', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000),
          lap(1, 300000, 600000),
          lap(2, 600000, 900000),
          lap(3, 900000, 960000), // stopped 60 s into the next lap
        ],
      );
      expect(RunTimes.medianLapSec(r), 300);
    });

    test('a 4 s tail after the last press is left out', () {
      final r = with_(
        laps: [
          lap(0, 0, 400000),
          lap(1, 400000, 790000),
          lap(2, 790000, 794000),
        ],
      );
      expect(RunTimes.medianLapSec(r), 395);
    });

    test('a full-length final lap stays in', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000),
          lap(1, 300000, 600000),
          lap(2, 600000, 880000), // 280 s, over 90% of 300
        ],
      );
      expect(RunTimes.medianLapSec(r), 300);
      expect(RunTimes.medianLapSec(with_(laps: [lap(0, 0, 100000)])), 100);
    });

    test('paused time inside a lap is taken out of it', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000),
          lap(1, 300000, 700000),
          lap(2, 700000, 1000000),
        ],
        pauses: [Span(400000, 500000)],
      );
      // 300, 400 - 100 paused = 300, 300
      expect(RunTimes.medianLapSec(r), 300);
    });

    test('pause laps are not laps', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000),
          lap(1, 300000, 360000, LapKind.pause),
          lap(2, 360000, 660000),
        ],
      );
      expect(RunTimes.medianLapSec(r), 300);
    });
  });
}
