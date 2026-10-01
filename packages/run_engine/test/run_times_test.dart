import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  // A 30 minute free run to hang laps and pauses on.
  final base = fixture('easy_free_run').run;
  final totalMs = base.end.difference(base.start).inMilliseconds;

  /// A lap from [t0] to [t1] ms covering [m] metres.
  Lap lap(int i, int t0, int t1, double m, [LapKind kind = LapKind.manual]) =>
      Lap(
        index: i,
        t0Ms: t0,
        t1Ms: t1,
        d0M: i * 1000.0,
        d1M: i * 1000.0 + m,
        kind: kind,
      );

  RunFile with_({
    List<Lap>? laps,
    List<Span> pauses = const [],
    List<Span> gaps = const [],
    Object? session = 'keep',
  }) => base.copyWith(
    laps: laps ?? base.laps,
    pauses: pauses,
    gaps: gaps,
    session: session == 'keep' ? base.session : session as SessionSpec?,
  );

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

  group('movingMs (more)', () {
    test('a run from before pause events existed is its elapsed time', () {
      expect(RunTimes.movingMs(with_()), totalMs);
    });

    test('a crash gap comes out too, and a gap inside a pause once', () {
      final r = with_(
        pauses: [Span(100000, 200000)],
        gaps: [Span(300000, 330000), Span(150000, 180000)],
      );
      expect(RunTimes.movingMs(r), totalMs - 100000 - 30000);
    });
  });

  group('medianLapSec', () {
    test('no laps: null', () {
      expect(RunTimes.medianLapSec(with_(laps: const [])), isNull);
    });

    test('median of complete 1 km laps', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000, 1000),
          lap(1, 300000, 620000, 1000),
          lap(2, 620000, 900000, 1000),
          lap(3, 900000, 1200000, 1000),
        ],
      );
      expect(RunTimes.medianLapSec(r), 300); // 280 300 300 320
    });

    test('a manual-LAP run with pressed-by-feel laps (within 25%)', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000, 980),
          lap(1, 300000, 610000, 1130),
          lap(2, 610000, 900000, 940),
          lap(3, 900000, 1210000, 1010),
        ],
      );
      expect(RunTimes.medianLapSec(r), 305); // 300 310 290 310
    });

    test('a slow partial final lap is dropped (by distance, not time)', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000, 1000),
          lap(1, 300000, 600000, 1000),
          lap(2, 600000, 900000, 1000),
          lap(3, 900000, 1500000, 300), // 10 min, only 300 m
        ],
      );
      expect(RunTimes.medianLapSec(r), 300);
    });

    test('a fast complete final lap is kept', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000, 1000),
          lap(1, 300000, 640000, 1000),
          lap(2, 640000, 900000, 1000),
          lap(3, 900000, 1150000, 1000), // 250 s, a full km
        ],
      );
      // 300 340 260 250 -> 280 (dropping the last would give 300)
      expect(RunTimes.medianLapSec(r), 280);
    });

    test('a 4 s tail after the last press is left out', () {
      final r = with_(
        laps: [
          lap(0, 0, 400000, 1000),
          lap(1, 400000, 790000, 1000),
          lap(2, 790000, 794000, 12),
        ],
      );
      expect(RunTimes.medianLapSec(r), 395);
    });

    test('variable-length laps: null', () {
      final r = with_(
        laps: [
          lap(0, 0, 100000, 400),
          lap(1, 100000, 400000, 1000),
          lap(2, 400000, 600000, 600),
        ],
      );
      expect(RunTimes.medianLapSec(r), isNull);
    });

    test('a fartlek: null', () {
      final r = with_(
        laps: [lap(0, 0, 300000, 1000), lap(1, 300000, 600000, 1000)],
        session: SessionSpec.fartlek,
      );
      expect(RunTimes.medianLapSec(r), isNull);
    });

    test('no GPS distance (indoor): null', () {
      final r = with_(laps: [lap(0, 0, 300000, 0), lap(1, 300000, 600000, 0)]);
      expect(RunTimes.medianLapSec(r), isNull);
    });

    test('paused or gap time inside a lap is taken out of it', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000, 1000),
          lap(1, 300000, 700000, 1000),
          lap(2, 700000, 1030000, 1000),
        ],
        pauses: [Span(400000, 500000)],
        gaps: [Span(900000, 930000)],
      );
      expect(RunTimes.medianLapSec(r), 300); // 300, 300, 300
    });

    test('pause laps are not laps', () {
      final r = with_(
        laps: [
          lap(0, 0, 300000, 1000),
          lap(1, 300000, 360000, 0, LapKind.pause),
          lap(2, 360000, 660000, 1000),
        ],
      );
      expect(RunTimes.medianLapSec(r), 300);
    });

    test('a single lap is kept', () {
      expect(RunTimes.medianLapSec(with_(laps: [lap(0, 0, 100000, 400)])), 100);
    });
  });
}
