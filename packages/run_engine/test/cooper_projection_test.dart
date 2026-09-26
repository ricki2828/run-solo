import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Phase 4 CO1 (plan §3.3): Cooper fade curve, personal curve from test 3,
/// projection, range. Expected values come from the shared fixture table,
/// computed outside the engine; Kotlin `CooperProjection.kt` reads the same
/// file.
void main() {
  final fx = jsonDecode(
    File('test/fixtures/cooper/cooper_projection.json').readAsStringSync(),
  ) as Map<String, Object?>;
  List<double> doubles(Object? l) => [
    for (final v in l! as List) (v as num).toDouble(),
  ];

  group('default curve (tests 1 and 2)', () {
    final f = CooperCurve.defaultCurve.fractions;

    test('matches the shared table', () {
      final want = doubles(fx['default_curve']);
      for (var i = 0; i < 12; i++) {
        expect(f[i], closeTo(want[i], 1e-12), reason: 'F(${i + 1})');
      }
    });

    test('plan §3.3 values: F(1) 0.0884, F(6) 0.5032, F(11) 0.9133', () {
      expect(f[0], closeTo(0.0884, 0.00005));
      expect(f[5], closeTo(0.5032, 0.00005));
      expect(f[10], closeTo(0.9133, 0.00005));
      expect(f[11], 1);
      // Normalised speeds 1.061 / 1.000 … 0.980 / 1.040.
      expect(f[0] * 12, closeTo(1.061, 0.0005));
      expect((f[11] - f[10]) * 12, closeTo(1.040, 0.0005));
      expect((f[1] - f[0]) * 12, closeTo(1.000, 0.0005));
      expect((f[10] - f[9]) * 12, closeTo(0.980, 0.0005));
    });

    test('asymmetric U: fast first minute, easing middle, kick at 12', () {
      final speeds = [
        for (var i = 0; i < 12; i++) f[i] - (i == 0 ? 0 : f[i - 1]),
      ];
      for (var i = 2; i < 11; i++) {
        expect(speeds[i], lessThan(speeds[i - 1]), reason: 'minute ${i + 1}');
      }
      expect(speeds[0], greaterThan(speeds[11]));
      expect(speeds[11], greaterThan(speeds[1]));
    });

    test('fraction between whole minutes is linear from F(0) = 0', () {
      final c = CooperCurve.defaultCurve;
      expect(c.fractionAt(0), 0);
      expect(c.fractionAt(0.5), closeTo(f[0] / 2, 1e-12));
      expect(c.fractionAt(5.5), closeTo((f[4] + f[5]) / 2, 1e-12));
      expect(c.fractionAt(12), 1);
      expect(c.fractionAt(13), 1);
    });
  });

  group('projection', () {
    for (final c
        in (fx['default_projections']! as List).cast<Map<String, Object?>>()) {
      final t = (c['elapsed_s']! as num).toDouble();
      final d = (c['distance_m']! as num).toDouble();
      test('${t.toInt()} s, ${d.toStringAsFixed(1)} m', () {
        final p = CooperProjection.project(
          CooperCurve.defaultCurve,
          elapsedSeconds: t,
          distanceM: d,
        );
        if (c.containsKey('projection') && c['projection'] == null) {
          expect(p, isNull);
          return;
        }
        expect(
          p!.distanceM,
          closeTo((c['projected_m']! as num).toDouble(), 1e-3),
        );
        expect(p.vo2, closeTo((c['vo2']! as num).toDouble(), 1e-6));
        if (c['cue'] != null) {
          expect(p.cue(t ~/ 60), c['cue']);
        }
      });
    }

    test('a runner on the default curve projects the same all test', () {
      for (var m = 2; m <= 11; m++) {
        final p = CooperProjection.project(
          CooperCurve.defaultCurve,
          elapsedSeconds: m * 60,
          distanceM: 2800 * CooperCurve.defaultCurve.fractions[m - 1],
        )!;
        expect(p.distanceM, closeTo(2800, 1e-6), reason: 'minute $m');
      }
    });

    test('a fast start projects lower than the old linear rule', () {
      // 1:30 at 480 m: linear 480 / 90 × 720 = 3840 m.
      final p = CooperProjection.project(
        CooperCurve.defaultCurve,
        elapsedSeconds: 90,
        distanceM: 480,
      )!;
      expect(p.distanceM, lessThan(480 / 90 * 720));
    });

    test('voice: rounded to 10 m and a whole VO2, plan example', () {
      final f5 = CooperCurve.defaultCurve.fractions[4];
      final p = CooperProjection.project(
        CooperCurve.defaultCurve,
        elapsedSeconds: 300,
        distanceM: 2741 * f5,
      )!;
      expect(p.cue(5), '5 minutes. Heading for about 2,740. VO2 about 50.');
      expect(p.cue(5), contains('about'), reason: 'estimate marker');
    });

    test('nothing before a minute or without distance', () {
      final c = CooperCurve.defaultCurve;
      expect(
        CooperProjection.project(c, elapsedSeconds: 59, distanceM: 300),
        isNull,
      );
      expect(
        CooperProjection.project(c, elapsedSeconds: 300, distanceM: 0),
        isNull,
      );
    });
  });

  group('VO2 and range', () {
    test('2800 m → 51.3; ± 5 range text', () {
      const e = CooperEstimate(2800);
      expect(e.vo2, closeTo((fx['vo2']! as Map)['2800'] as num, 1e-12));
      expect(e.vo2, closeTo(51.3, 0.05));
      expect(fx['range_half_width'], CooperProjection.rangeHalfWidth);
      expect(e.vo2High - e.vo2Low, 10);
      expect(e.rangeText, '51 (46 to 56)');
      expect(e.rangeLine, 'VO2 estimate 51 (46 to 56)');
    });
  });

  group('personal curve', () {
    final p = fx['personal']! as Map<String, Object?>;
    final tests = [for (final t in p['tests_minute_m']! as List) doubles(t)];

    test('0 or 1 valid tests: the default curve', () {
      expect(
        CooperProjection.curveFor(const []),
        same(CooperCurve.defaultCurve),
      );
      expect(
        CooperProjection.curveFor(tests.sublist(0, 1)),
        same(CooperCurve.defaultCurve),
      );
    });

    test('2 valid tests: test 3 uses the mean of both', () {
      final c = CooperProjection.curveFor(tests.sublist(0, 2));
      expect(c, isNot(same(CooperCurve.defaultCurve)));
      for (var i = 0; i < 12; i++) {
        final want =
            (tests[0][i] / tests[0].last + tests[1][i] / tests[1].last) / 2;
        expect(c.fractions[i], closeTo(want, 1e-12));
      }
    });

    test('4 valid tests: the last 3 only, as the shared table', () {
      final c = CooperProjection.curveFor(tests);
      final want = doubles(p['curve_from_last3']);
      for (var i = 0; i < 12; i++) {
        expect(c.fractions[i], closeTo(want[i], 1e-12));
      }
      final pr = p['projection']! as Map<String, Object?>;
      final est = CooperProjection.project(
        c,
        elapsedSeconds: (pr['elapsed_s']! as num).toDouble(),
        distanceM: (pr['distance_m']! as num).toDouble(),
      )!;
      expect(
        est.distanceM,
        closeTo((pr['projected_m']! as num).toDouble(), 1e-6),
      );
      expect(est.vo2, closeTo((pr['vo2']! as num).toDouble(), 1e-9));
    });

    test('an unusable test is skipped, not averaged', () {
      final flat = [...tests[0]]..[5] = tests[0][4];
      final c = CooperProjection.curveFor([tests[1], flat]);
      expect(c, same(CooperCurve.defaultCurve), reason: 'one usable test');
    });

    test('JSON round trip; junk rejected', () {
      final c = CooperProjection.curveFor(tests);
      final back = CooperCurve.fromJson(jsonDecode(jsonEncode(c.toJson())))!;
      expect(back.fractions, c.fractions);
      expect(CooperCurve.fromJson([0.1, 0.2]), isNull);
      expect(
        CooperCurve.fromJson([for (var i = 1; i <= 12; i++) i / 13]),
        isNull,
        reason: 'F(12) must be 1',
      );
      expect(CooperCurve.fromJson('x'), isNull);
    });
  });

  group('minute distances from a run file', () {
    RunFile cooperRun({
      int warmupS = 0,
      int testS = 720,
      List<Span> pauses = const [],
      bool laps = true,
    }) {
      // Warm-up at 2 m/s, then the test at 4 m/s.
      final samples = <Sample>[];
      final total = warmupS + testS;
      for (var s = 0; s <= total; s++) {
        final d = s <= warmupS ? 2.0 * s : 2.0 * warmupS + 4.0 * (s - warmupS);
        samples.add(Sample(tMs: s * 1000, lat: -33.9, lon: 151.2, distM: d));
      }
      final start = DateTime.utc(2026, 9, 20, 6);
      return RunFile(
        id: 'cooper-$warmupS-$testS',
        device: 'test',
        app: 'test',
        start: start,
        end: start.add(Duration(seconds: total)),
        tz: 'UTC',
        mode: RunMode.cooper,
        session: SessionSpec.cooper,
        units: Units.km,
        laps: [
          if (laps && warmupS > 0) ...[
            Lap(
              index: 0,
              t0Ms: 0,
              t1Ms: warmupS * 1000,
              d0M: 0,
              d1M: 2.0 * warmupS,
              kind: LapKind.manual,
            ),
            Lap(
              index: 1,
              t0Ms: warmupS * 1000,
              t1Ms: total * 1000,
              d0M: 2.0 * warmupS,
              d1M: samples.last.distM,
              kind: LapKind.auto,
            ),
          ],
        ],
        pauses: pauses,
        samples: samples,
      );
    }

    test('measured from "Start reps", not the warm-up', () {
      final run = cooperRun(warmupS: 300);
      expect(CooperProjection.testStartMs(run), 300000);
      final m = CooperProjection.minuteDistances(run)!;
      expect(m, [for (var i = 1; i <= 12; i++) 240.0 * i]);
    });

    test('a warm-up that itself lasted 12:02 is not the test', () {
      final base = cooperRun(warmupS: 722, testS: 780);
      Lap lap(int i, int t0, int t1, LapKind k) => Lap(
        index: i,
        t0Ms: t0 * 1000,
        t1Ms: t1 * 1000,
        d0M: Trace(base.samples).distAt(t0 * 1000),
        d1M: Trace(base.samples).distAt(t1 * 1000),
        kind: k,
      );
      final run = base.copyWith(
        laps: [
          lap(0, 0, 722, LapKind.manual),
          lap(1, 722, 1442, LapKind.auto),
          lap(2, 1442, 1502, LapKind.manual),
        ],
      );
      expect(CooperProjection.testStartMs(run), 722000);
      expect(CooperProjection.minuteDistances(run)!.first, 240);
      // Same when the warm-up lap is the recorder's own (no LAP pressed).
      final autoWarmup = run.copyWith(
        laps: [
          lap(0, 0, 722, LapKind.auto),
          lap(1, 722, 1442, LapKind.auto),
          lap(2, 1442, 1502, LapKind.manual),
        ],
      );
      expect(CooperProjection.testStartMs(autoWarmup), 722000);
    });

    test('no warm-up, then a 12:00 cool-down: the test, not the cool-down', () {
      final base = cooperRun(testS: 1440);
      final d = Trace(base.samples).distAt(720000);
      final run = base.copyWith(
        laps: [
          Lap(
            index: 0,
            t0Ms: 0,
            t1Ms: 720000,
            d0M: 0,
            d1M: d,
            kind: LapKind.auto,
          ),
          Lap(
            index: 1,
            t0Ms: 720000,
            t1Ms: 1440000,
            d0M: d,
            d1M: base.distanceM,
            kind: LapKind.manual,
          ),
        ],
      );
      expect(CooperProjection.testStartMs(run), 0);
    });

    test('the I5 replay (warm-up LAP, START REPS at 1:00, cool-down)', () {
      final run = RunFile.fromJson(
        jsonDecode(
          File('test/fixtures/contract/replay_cooper.json').readAsStringSync(),
        ) as Map<String, Object?>,
      );
      expect(CooperProjection.testStartMs(run), 60000);
      final m = CooperProjection.minuteDistances(run)!;
      expect(m.last, closeTo(run.laps[1].distanceM, 0.5));
      expect(CooperCurve.fromMinuteDistances(m), isNotNull);
    });

    test('the I2 contract Cooper (one 12:00 lap) starts at 0', () {
      final raw = jsonDecode(
        File('test/fixtures/contract/cooper_12min.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final run = RunFile.fromJson(raw);
      expect(CooperProjection.testStartMs(run), 0);
      final m = CooperProjection.minuteDistances(run)!;
      expect(m.last, closeTo(run.distanceM, 1e-6));
    });

    test('no warm-up, then a cool-down lap: the 12:00 lap, not its end', () {
      final base = cooperRun(testS: 900);
      final run = base.copyWith(
        laps: [
          Lap(
            index: 0,
            t0Ms: 0,
            t1Ms: 720000,
            d0M: 0,
            d1M: 2880,
            kind: LapKind.manual,
          ),
          Lap(
            index: 1,
            t0Ms: 720000,
            t1Ms: 900000,
            d0M: 2880,
            d1M: base.distanceM,
            kind: LapKind.auto,
          ),
        ],
      );
      expect(CooperProjection.testStartMs(run), 0);
      expect(CooperProjection.minuteDistances(run)!.last, 2880);
    });

    test('a pre-I2 file with no lap boundary starts at 0', () {
      final run = cooperRun();
      expect(CooperProjection.testStartMs(run), 0);
      expect(CooperProjection.minuteDistances(run)!.last, 2880);
    });

    test('paused inside the test or stopped early: no minute distances', () {
      expect(
        CooperProjection.minuteDistances(
          cooperRun(warmupS: 60, pauses: [const Span(400000, 420000)]),
        ),
        isNull,
      );
      expect(CooperProjection.minuteDistances(cooperRun(testS: 600)), isNull);
      // A pause in the warm-up does not count.
      expect(
        CooperProjection.minuteDistances(
          cooperRun(warmupS: 120, pauses: [const Span(10000, 20000)]),
        ),
        isNotNull,
      );
    });
  });
}
