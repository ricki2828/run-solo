import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// A run at a steady 3 m/s (5:33/km) for [seconds], elevation from [elev]
/// (metres at second i; null = none at that tick).
RunFile _run(
  int seconds,
  double? Function(int i) elev, {
  ElevSource? src = ElevSource.baro,
  List<Span> pauses = const [],
  List<Lap>? laps,
}) {
  final samples = [
    for (var i = 1; i <= seconds; i++)
      Sample(tMs: i * 1000, distM: i * 3.0, elevM: elev(i)),
  ];
  return RunFile(
    id: 'elev-test',
    device: 'test',
    app: 'test',
    start: DateTime.utc(2026, 10, 2),
    end: DateTime.utc(2026, 10, 2).add(Duration(seconds: seconds)),
    tz: 'UTC',
    mode: RunMode.free,
    units: Units.km,
    laps:
        laps ??
        [
          Lap(
            index: 0,
            t0Ms: 0,
            t1Ms: seconds * 1000,
            d0M: 0,
            d1M: seconds * 3.0,
            kind: LapKind.manual,
          ),
        ],
    pauses: pauses,
    samples: samples,
    elevSrc: src,
  );
}

void main() {
  group('ClimbTracker', () {
    test('a noisy flat books nothing', () {
      final t = ClimbTracker(ClimbTracker.baroThresholdM);
      for (var i = 0; i < 3600; i++) {
        t.offer(80 + 1.2 * math.sin(i * 0.63));
      }
      expect(t.ascentM, 0);
      expect(t.descentM, 0);
    });

    test('books a step once it is past the threshold', () {
      final t = ClimbTracker(3);
      for (final e in [0.0, 1.0, 2.9, 3.0, 4.0, 6.5, 6.0, 3.4, 3.0]) {
        t.offer(e);
      }
      // The same sequence and totals as the Kotlin ClimbTracker test.
      expect(t.ascentM, closeTo(6.5, 1e-9));
      expect(t.descentM, closeTo(3.5, 1e-9));
    });

    test('a hill is booked right up to its top and its way down from it', () {
      final t = ClimbTracker(3);
      for (var i = 0; i <= 20; i++) {
        t.offer(i.toDouble());
      }
      for (var i = 0; i < 60; i++) {
        t.offer(20 + (i.isEven ? 0.8 : -0.8));
      }
      for (var i = 1; i <= 15; i++) {
        t.offer(20.0 - i);
      }
      // The plateau's own noise (0.8 m) may add to the top; nothing more.
      expect(t.ascentM, closeTo(20, 1));
      expect(t.descentM, closeTo(15, 1));
    });

    test('hold follows without booking', () {
      final t = ClimbTracker(3)..offer(10);
      t.hold(50);
      t.offer(51);
      expect(t.ascentM, 0);
    });

    test('GPS-only uses the larger threshold', () {
      expect(
        ClimbTracker.thresholdFor(ElevSource.gps),
        greaterThan(ClimbTracker.thresholdFor(ElevSource.baro)),
      );
    });
  });

  group('GradeWindow', () {
    test('null until a window, then the slope', () {
      final g = GradeWindow(50);
      double? last;
      double? firstAt;
      for (var d = 0.0; d <= 300; d += 5) {
        last = g.offer(d, 0.05 * d);
        if (last != null) firstAt ??= d;
      }
      expect(firstAt, 50);
      expect(last, closeTo(0.05, 1e-9));
    });

    test('negative downhill, clamped when absurd', () {
      final h = GradeWindow(50)..offer(0, 20);
      expect(h.offer(50, 15), closeTo(-0.1, 1e-9));
      final g = GradeWindow(10)..offer(0, 0);
      expect(g.offer(10, 100), GradeWindow.maxGrade);
    });
  });

  group('Gap (Minetti 2002 energy cost)', () {
    test('reference values of the published polynomial', () {
      expect(Gap.cost(0), 3.6);
      expect(Gap.ratio(0), 1);
      // +10%: 155.4e-5 - 30.4e-4 - 43.3e-3 + 46.3e-2 + 1.95 + 3.6 = 5.9682
      expect(Gap.cost(0.1), closeTo(5.968, 0.001));
      // -10%: 2.1519
      expect(Gap.cost(-0.1), closeTo(2.152, 0.001));
      expect(Gap.ratio(0.1), closeTo(1.658, 0.002));
      expect(Gap.ratio(-0.1), closeTo(0.598, 0.002));
    });

    test('cheapest near -20%, and the grade is clamped to +/-45%', () {
      expect(Gap.cost(-0.2), lessThan(Gap.cost(-0.1)));
      expect(Gap.cost(-0.2), lessThan(Gap.cost(-0.3)));
      expect(Gap.ratio(0.9), Gap.ratio(0.45));
    });

    test('live: a 5:00 pace up 10% is a faster flat pace', () {
      expect(Gap.paceSecPerKm(300, 10)!, closeTo(300 / 1.658, 0.5));
      expect(Gap.paceSecPerKm(300, 0), 300);
      expect(Gap.paceSecPerKm(null, 5), isNull);
      expect(Gap.paceSecPerKm(300, null), isNull);
    });
  });

  group('RunElevation', () {
    test('no source, no elevation', () {
      expect(RunElevation.of(_run(60, (i) => 10, src: null)), isNull);
    });

    test('a known climb: 5% for 600 s (1800 m) books about 90 m', () {
      final e = RunElevation.of(_run(600, (i) => 20 + 0.15 * i))!;
      expect(
        e.ascentM,
        closeTo(90, 3.1),
      ); // under one threshold lost to the dead band
      expect(e.descentM, 0);
      expect(e.points.length, 600);
      // GAP: 3 m/s is 333.3 s/km; a 5% grade costs Gap.ratio(0.05) more, so GAP is faster.
      final pace = 1000 / 3.0;
      expect(e.gapSecPerKm!, lessThan(pace));
      expect(e.gapSecPerKm!, closeTo(pace / Gap.ratio(0.05), pace * 0.03));
    });

    test('a noisy flat: no climb, GAP equals pace', () {
      final e = RunElevation.of(
        _run(900, (i) => 80 + 1.0 * math.sin(i * 0.9)),
      )!;
      expect(e.ascentM, 0);
      expect(e.descentM, 0);
      expect(e.gapSecPerKm!, closeTo(1000 / 3.0, 3));
    });

    test('downhill books descent and a slower-than-pace GAP', () {
      final e = RunElevation.of(_run(600, (i) => 200 - 0.15 * i))!;
      expect(e.descentM, closeTo(90, 1.5));
      expect(e.ascentM, 0);
      expect(e.gapSecPerKm!, greaterThan(1000 / 3.0));
    });

    test('a staircase walked while paused is not climb', () {
      final e = RunElevation.of(
        _run(
          300,
          (i) => i < 100 ? 20 : (i < 200 ? 20 + 0.5 * (i - 100) : 70),
          pauses: const [Span(100000, 200000)],
        ),
      )!;
      expect(e.ascentM, 0);
    });

    test('ticks with no elevation are skipped, not zeroed', () {
      final e = RunElevation.of(
        _run(400, (i) => i % 2 == 0 ? null : 20 + 0.1 * i),
      )!;
      expect(e.points.length, 200);
      expect(e.ascentM, closeTo(40, 1.5));
    });

    test('laps and units add up to the totals', () {
      final run = _run(
        900,
        (i) => 20 + 0.1 * i,
        laps: [
          for (var k = 0; k < 3; k++)
            Lap(
              index: k,
              t0Ms: k * 300000,
              t1Ms: (k + 1) * 300000,
              d0M: k * 900.0,
              d1M: (k + 1) * 900.0,
              kind: LapKind.manual,
            ),
        ],
      );
      final e = RunElevation.of(run)!;
      final laps = e.lapClimbs(run.laps);
      expect(laps.length, 3);
      expect(
        laps.fold<double>(0, (s, c) => s + c.ascentM),
        closeTo(e.ascentM, 1e-9),
      );
      expect(
        laps.fold<double>(0, (s, c) => s + c.descentM),
        closeTo(e.descentM, 1e-9),
      );
      // 2700 m: three full km minus nothing, the third partial (700 m).
      final km = e.unitClimbs(1000);
      expect(km.length, 3);
      expect(
        km.fold<double>(0, (s, c) => s + c.ascentM),
        closeTo(e.ascentM, 1e-9),
      );
      expect(
        km[0].ascentM,
        closeTo(33, 3.1),
      ); // 1000 m at 3 m/s is 333 s at 0.1 m/s
    });

    test('nearest finds the point under a scrub', () {
      final e = RunElevation.of(_run(100, (i) => 10.0 + i))!;
      expect(e.nearest(150).distM, 150);
      expect(e.nearest(151.4).distM, 150);
      expect(e.nearest(-5).distM, 3);
      expect(e.nearest(9999).distM, 300);
    });

    test('too short for a GAP', () {
      final e = RunElevation.of(_run(100, (i) => 10 + 0.15 * i))!;
      expect(e.gapSecPerKm, isNull); // 300 m
    });
  });

  group('run file', () {
    test('elevation and its source round trip', () {
      final run = _run(60, (i) => 10 + 0.5 * i);
      final text = RunFileCodec.encode(run);
      expect(text, contains('"elev_src":"baro"'));
      final back = RunFileCodec.decode(text);
      expect(back.elevSrc, ElevSource.baro);
      expect(back.samples.last.elevM, 40);
      expect(RunFileCodec.encode(back), text);
      // A sample with no elevation stays eight fields.
      final noElev = run.copyWith(
        samples: [run.samples.first.copyWith(elevM: null)],
      );
      expect(noElev.samples.single.toJson().length, 8);
      expect(run.samples.first.toJson().length, 9);
    });

    test('a run without elevation writes no elev_src', () {
      final run = _run(10, (i) => null, src: null);
      expect(RunFileCodec.encode(run), isNot(contains('elev_src')));
    });

    test('a bad elev_src is refused', () {
      final text = RunFileCodec.encode(_run(10, (i) => 1.0))
          .replaceFirst('"elev_src":"baro"', '"elev_src":"sonar"');
      expect(
        () => RunFileCodec.decode(text),
        throwsA(isA<RunFileFormatException>()),
      );
    });
  });

  group('RunMode', () {
    test('free and trail show live elevation, only trail shows live GAP', () {
      expect(RunMode.free.showsElevation, isTrue);
      expect(RunMode.trail.showsElevation, isTrue);
      for (final m in [RunMode.intervals, RunMode.laps, RunMode.cooper]) {
        expect(m.showsElevation, isFalse, reason: m.name);
      }
      for (final m in RunMode.values) {
        expect(m.showsLiveGap, m == RunMode.trail, reason: m.name);
      }
    });
  });
}
