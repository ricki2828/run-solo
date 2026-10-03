import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// TRUE PACE: moving pace x hills x heat. Factor maths against the cited
/// references (Minetti 2002, the Hadley table), then whole runs.

/// A run at a steady 3 m/s (5:33/km) for [seconds]; elevation from [elev]
/// (metres at second i).
RunFile _run(
  int seconds,
  double? Function(int i) elev, {
  ElevSource? src = ElevSource.baro,
}) {
  final samples = [
    for (var i = 1; i <= seconds; i++)
      Sample(tMs: i * 1000, distM: i * 3.0, elevM: elev(i)),
  ];
  return RunFile(
    id: 'true-pace-test',
    device: 'test',
    app: 'test',
    start: DateTime.utc(2026, 10, 3),
    end: DateTime.utc(2026, 10, 3).add(Duration(seconds: seconds)),
    tz: 'UTC',
    mode: RunMode.free,
    units: Units.km,
    laps: [
      Lap(
        index: 0,
        t0Ms: 0,
        t1Ms: seconds * 1000,
        d0M: 0,
        d1M: seconds * 3.0,
        kind: LapKind.manual,
      ),
    ],
    samples: samples,
    elevSrc: src,
  );
}

double _slowdown(double tempC, double dewC) =>
    HeatModel.of(tempC: tempC, dewPointC: dewC).fraction!;

void main() {
  group('factor maths', () {
    test('hills follow Minetti: 1 / cost ratio, clamped', () {
      // 3 m/s up a steady 5% (Minetti ratio 1.303): factor 0.767.
      final up = _run(600, (i) => i * 3.0 * 0.05);
      final f = RunElevation.of(up)!.gradeFactor;
      expect(f, closeTo(1 / Gap.ratio(0.05), 0.01));
      // 10% would be 0.603: the clamp stops a wild estimate at 0.75.
      final steep = RunElevation.of(_run(600, (i) => i * 3.0 * 0.10))!;
      expect(steep.gradeFactor, TruePace.minGrade);
      // A long descent is slower than flat, never more than the clamp.
      final down = RunElevation.of(_run(600, (i) => 500 - i * 3.0 * 0.05))!;
      expect(down.gradeFactor, greaterThan(1));
      expect(down.gradeFactor, lessThanOrEqualTo(TruePace.maxGrade));
    });

    test('heat follows the Hadley table: 28 C / dew 21 is 4.7%', () {
      expect(_slowdown(28, 21), closeTo(0.047, 0.001));
      expect(TruePace.heatFactor(_slowdown(28, 21)), closeTo(0.953, 0.001));
      expect(TruePace.heatFactor(_slowdown(12, 5)), 1);
      // The model's own ceiling is 10%, never a cold bonus, none when null.
      expect(TruePace.heatFactor(0.5), TruePace.minHeat);
      expect(TruePace.heatFactor(null), 1);
    });

    test('a split inside a run gets the distance ramp of the heat only', () {
      final slow = _slowdown(34, 27);
      final early = TruePace.factors(
        slowdown: slow,
        midpointM: 1000,
        ramp: HeatModel.distanceRamp,
      );
      final late = TruePace.factors(
        slowdown: slow,
        midpointM: 12000,
        ramp: HeatModel.distanceRamp,
      );
      expect(early.heat, 1); // no accumulation in the first 3 km
      expect(late.heat, closeTo(1 - slow, 1e-9));
    });

    test('the factors multiply; no factors change nothing', () {
      const f = TruePaceFactors(grade: 0.9, heat: 0.95);
      expect(f.combined, closeTo(0.855, 1e-12));
      expect(f.apply(300), closeTo(256.5, 1e-9));
      expect(TruePaceFactors.none.neutral, isTrue);
      expect(TruePaceFactors.none.apply(300), 300);
    });
  });

  group('whole runs', () {
    test('a flat cool run: true pace is the actual pace', () {
      final tp = RunTruePace.of(
        _run(900, (_) => 20.0),
        elevation: RunElevation.of(_run(900, (_) => 20.0)),
        slowdown: _slowdown(12, 5),
      )!;
      expect(tp.factors.neutral, isTrue);
      expect(tp.trueSecPerKm, closeTo(tp.rawSecPerKm, 1e-9));
      expect(tp.rawSecPerKm, closeTo(1000 / 3, 0.01));
      expect(
        TruePaceText.breakdown(tp.rawSecPerKm, tp.factors, Units.km),
        isNull,
      );
    });

    test('a hot flat run is faster than its actual pace', () {
      final run = _run(900, (_) => 20.0);
      final tp = RunTruePace.of(
        run,
        elevation: RunElevation.of(run),
        slowdown: _slowdown(34, 27),
      )!;
      expect(tp.factors.grade, 1);
      expect(tp.trueSecPerKm, lessThan(tp.rawSecPerKm));
      expect(tp.trueSecPerKm, closeTo(tp.rawSecPerKm * (1 - 0.0862), 0.5));
    });

    test('a hilly cool run is faster than its actual pace', () {
      final run = _run(900, (i) => i * 3.0 * 0.04);
      final tp = RunTruePace.of(
        run,
        elevation: RunElevation.of(run),
        slowdown: 0,
      )!;
      expect(tp.factors.heat, 1);
      expect(tp.factors.grade, closeTo(1 / Gap.ratio(0.04), 0.01));
      expect(tp.trueSecPerKm, lessThan(tp.rawSecPerKm));
    });

    test('a noisy flat barometer road run keeps true == actual', () {
      // 1.2 m of barometer wobble on a flat road: no hills to speak of.
      for (final wobble in [0.6, 1.2]) {
        final run = _run(1800, (i) => 80 + wobble * math.sin(i * 0.63));
        final e = RunElevation.of(run)!;
        expect(e.gradeFactor, 1, reason: 'wobble $wobble');
        final tp = RunTruePace.of(run, elevation: e, slowdown: 0)!;
        expect(tp.trueSecPerKm, tp.rawSecPerKm);
      }
      // The deadband is exactly the noise floor, not a hill.
      expect(TruePace.clampGrade(1.004), 1);
      expect(TruePace.clampGrade(0.996), 1);
      expect(TruePace.clampGrade(0.99), 0.99);
    });

    test('GPS-only elevation is too noisy for the grade model: hills = 1', () {
      final run = _run(900, (i) => i * 3.0 * 0.05, src: ElevSource.gps);
      expect(RunElevation.of(run)!.gradeFactor, 1);
    });

    test('no elevation: grade 1; too hot or no weather: heat 1', () {
      final run = _run(900, (_) => null, src: null);
      final tp = RunTruePace.of(run, elevation: RunElevation.of(run))!;
      expect(tp.factors.neutral, isTrue);
      // Too hot for the model: fraction null, the heat stays in.
      expect(HeatModel.of(tempC: 38, dewPointC: 28).fraction, isNull);
      expect(TruePace.heatFactor(null), 1);
    });

    test('under 500 m has no true pace', () {
      expect(RunTruePace.of(_run(100, (_) => 0.0)), isNull);
    });

    test('a stretch reads its own hills: the climb half vs the flat half', () {
      // Climb at 5% for the first 300 s, flat for the next 300 s.
      final run = _run(600, (i) => i <= 300 ? i * 3.0 * 0.05 : 45.0);
      final e = RunElevation.of(run)!;
      expect(
        e.gradeFactorBetweenMs(0, 300000),
        closeTo(1 / Gap.ratio(0.05), 0.02),
      );
      expect(e.gradeFactorBetweenMs(310000, 600000), closeTo(1, 0.003));
      // Too little distance for a factor: neutral, never noise.
      expect(e.gradeFactorBetweenMs(10000, 20000), 1);
    });
  });

  group('live', () {
    test('grade only: the pace as it would run on the flat', () {
      // 5% up at 6:00/km: Minetti ratio 1.303, so 4:36 on the flat.
      expect(
        RunTruePace.live(paceSecPerKm: 360, gradePct: 5)!,
        closeTo(360 / Gap.ratio(0.05), 1e-9),
      );
      expect(RunTruePace.live(paceSecPerKm: 360, gradePct: 0), 360);
      // The clamp holds on a wall: 25% off at most.
      expect(
        RunTruePace.live(paceSecPerKm: 360, gradePct: 30)!,
        closeTo(360 * TruePace.minGrade, 1e-9),
      );
    });

    test('heat ramps in over the distance so far', () {
      final slow = _slowdown(34, 27);
      // Early on the heat has no say; from 9 km it has all of it.
      expect(
        RunTruePace.live(paceSecPerKm: 330, slowdown: slow, distanceM: 1000),
        330,
      );
      expect(
        RunTruePace.live(paceSecPerKm: 330, slowdown: slow, distanceM: 12000)!,
        closeTo(330 * (1 - slow), 1e-9),
      );
    });

    test('no pace, no figure; no grade yet, heat only', () {
      expect(RunTruePace.live(paceSecPerKm: null, gradePct: 4), isNull);
      expect(
        RunTruePace.live(paceSecPerKm: 330, slowdown: 0.05, distanceM: 20000),
        closeTo(330 * 0.95, 1e-9),
      );
    });
  });

  group('words', () {
    test('headline reads true first, actual and the reason beside it', () {
      // 4:31 actual, 4:22 true, a hot day.
      final f = TruePaceFactors(heat: 262 / 271);
      expect(
        TruePaceText.headline(271, f, Units.km),
        '4:22 true pace (4:31 actual, hot day)',
      );
      expect(
        TruePaceText.headline(
          271,
          const TruePaceFactors(grade: 0.95),
          Units.km,
        ),
        '4:17 true pace (4:31 actual, hilly)',
      );
      expect(
        TruePaceText.headline(
          271,
          const TruePaceFactors(grade: 0.9, heat: 0.95),
          Units.km,
        ),
        '3:52 true pace (4:31 actual, hilly, hot day)',
      );
      expect(
        TruePaceText.headline(271, TruePaceFactors.none, Units.km),
        '4:31 true pace',
      );
      // A rep-time session reads as the time for the rep.
      expect(
        TruePaceText.headline(
          300,
          const TruePaceFactors(heat: 0.95),
          Units.km,
          repMetres: 400,
        ),
        '1:54 true time (2:00 actual, hot day)',
      );
    });

    test('the breakdown adds up on the seconds shown', () {
      // 5:21 actual, hills -0:18, heat -0:05 = 4:58.
      const f = TruePaceFactors(grade: 0.9439, heat: 0.9835);
      expect(
        TruePaceText.breakdown(321, f, Units.km),
        'True pace 4:58/km = actual 5:21, hills -0:18, heat -0:05',
      );
      // Downhill reads plus, a missing part is left out.
      expect(
        TruePaceText.breakdown(
          321,
          const TruePaceFactors(grade: 1.05),
          Units.km,
        ),
        'True pace 5:37/km = actual 5:21, downhill +0:16',
      );
      expect(
        TruePaceText.breakdown(
          321,
          const TruePaceFactors(heat: 0.95),
          Units.mi,
          label: 'True work pace',
        ),
        startsWith('True work pace 8:'),
      );
    });
  });
}
