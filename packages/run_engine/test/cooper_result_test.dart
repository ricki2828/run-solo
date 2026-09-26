import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// C1 (v1 plan §18.4, Phase 4 §3.3): the 12-minute test's result block.
void main() {
  final start = DateTime.utc(2026, 9, 20, 6);

  /// Warm-up at 2 m/s, then the test at [mps]; "Start reps" ends the
  /// warm-up and the recorder's own 12:00 lap ends the test.
  RunFile cooperRun({
    int warmupS = 300,
    int testS = 720,
    int cooldownS = 0,
    double mps = 4,
    List<Span> pauses = const [],
    bool fix = true,
  }) {
    final total = warmupS + testS + cooldownS;
    double dAt(int s) => s <= warmupS
        ? 2.0 * s
        : s <= warmupS + testS
        ? 2.0 * warmupS + mps * (s - warmupS)
        : 2.0 * warmupS + mps * testS + 2.0 * (s - warmupS - testS);
    final samples = [
      for (var s = 0; s <= total; s++)
        Sample(
          tMs: s * 1000,
          lat: fix ? -33.9 + s * 1e-5 : null,
          lon: fix ? 151.2 : null,
          accM: fix ? 5 : null,
          distM: dAt(s),
        ),
    ];
    final testEnd = (warmupS + (testS < 720 ? testS : 720)) * 1000;
    return RunFile(
      id: 'cooper-result-$warmupS-$testS-${mps.toStringAsFixed(2)}',
      device: 'test',
      app: 'test',
      start: start,
      end: start.add(Duration(seconds: total)),
      tz: 'UTC',
      mode: RunMode.cooper,
      session: SessionSpec.cooper,
      units: Units.km,
      laps: [
        Lap(
          index: 0,
          t0Ms: 0,
          t1Ms: warmupS * 1000,
          d0M: 0,
          d1M: dAt(warmupS),
          kind: LapKind.manual,
        ),
        Lap(
          index: 1,
          t0Ms: warmupS * 1000,
          t1Ms: testEnd,
          d0M: dAt(warmupS),
          d1M: dAt(testEnd ~/ 1000),
          kind: LapKind.auto,
        ),
      ],
      pauses: pauses,
      samples: samples,
    );
  }

  test('Cooper 1968 fixtures: 2800 m -> 51.31, 2000 m -> 33.42', () {
    expect(CooperProjection.vo2(2800), closeTo(51.31, 0.005));
    expect(CooperProjection.vo2(2000), closeTo(33.42, 0.005));
  });

  test('a clean test: 12:00 at 4 m/s is 2880 m, VO2 est. 53 (48 to 58)', () {
    final a = engine.analyze(cooperRun(cooldownS: 120), now: start);
    final c = a.cooper!;
    expect(c.valid, isTrue);
    expect(c.testDistanceM, closeTo(2880, 1e-6));
    expect(c.minuteM, [for (var i = 1; i <= 12; i++) 240.0 * i]);
    expect(c.estimate!.vo2, closeTo((2880 - 504.9) / 44.73, 1e-9));
    expect(c.estimate!.rangeLine, 'VO2 estimate 53 (48 to 58)');
    expect(c.invalidLine, isNull);
    expect(a.verdict, isNull, reason: 'a test is a measurement');
  });

  test('paused, stopped early, no GPS: distance shown, no estimate', () {
    final paused = CooperResult.of(
      cooperRun(pauses: [const Span(400000, 420000)]),
      indoor: false,
      noisy: false,
    );
    expect(paused.invalid, CooperInvalid.paused);
    expect(paused.estimate, isNull);
    expect(paused.invalidLine, contains('Paused'));

    final short = CooperResult.of(
      cooperRun(testS: 600),
      indoor: false,
      noisy: false,
    );
    expect(short.invalid, CooperInvalid.short);
    expect(short.testDistanceM, closeTo(2400, 1e-6));
    expect(short.estimate, isNull);

    final indoor = engine.analyze(cooperRun(fix: false), now: start).cooper!;
    expect(indoor.invalid, CooperInvalid.indoor);
    expect(indoor.estimate, isNull);

    final noisy = CooperResult.of(cooperRun(), indoor: false, noisy: true);
    expect(noisy.invalid, CooperInvalid.noisy);
  });

  test('heat: HV1 twin as its own line; too hot says so; none when cool', () {
    WeatherRecord w(double t, double dew, {double? sun, double? wind}) =>
        WeatherRecord(
          status: WeatherStatus.ok,
          tempC: t,
          rh: 60,
          dewPointC: dew,
          shortwaveWm2: sun,
          windMs: wind,
        );
    final run = cooperRun();
    final warm = CooperResult.of(
      run,
      indoor: false,
      noisy: false,
      weather: w(28, 21),
    );
    final f = CooperHeat.of(w(28, 21))!.fraction!;
    expect(
      warm.vo2Adjusted,
      closeTo(CooperProjection.vo2(2880 / (1 - f)), 1e-9),
    );
    expect(warm.vo2Adjusted! > warm.estimate!.vo2, isTrue);
    expect(warm.heatLine, startsWith('Heat-adjusted estimate '));
    expect(carriesEstimateMarker(warm.heatLine!), isTrue);

    final cool = CooperResult.of(
      run,
      indoor: false,
      noisy: false,
      weather: w(10, 2),
    );
    expect(cool.heatLine, isNull);
    expect(cool.vo2Adjusted, isNull);

    final hot = CooperResult.of(
      run,
      indoor: false,
      noisy: false,
      weather: w(38, 28),
    );
    expect(hot.heatLine, CooperHeat.tooHotLine);
    expect(hot.vo2Adjusted, isNull);

    // An invalid test has no heat line either.
    final paused = CooperResult.of(
      cooperRun(pauses: [const Span(400000, 420000)]),
      indoor: false,
      noisy: false,
      weather: w(28, 21),
    );
    expect(paused.heatLine, isNull);
  });

  test('change line only with two prior tests; month or day', () {
    final d = DateTime.utc(2026, 9, 24);
    expect(
      CooperResult.changeLine(52, d, [(DateTime.utc(2026, 6, 1), 50)]),
      isNull,
    );
    expect(
      CooperResult.changeLine(52.4, d, [
        (DateTime.utc(2026, 3, 1), 49),
        (DateTime.utc(2026, 6, 10), 51),
      ]),
      'VO2 est. +1.4 since June',
    );
    expect(
      CooperResult.changeLine(50, d, [
        (DateTime.utc(2026, 8, 1), 49),
        (DateTime.utc(2026, 9, 3), 51),
      ]),
      'VO2 est. -1.0 since 3 Sep',
    );
  });

  test('change line rounds before the sign: no "-0.0"', () {
    final d = DateTime.utc(2026, 9, 24);
    final prior = [
      (DateTime.utc(2026, 3, 1), 49.0),
      (DateTime.utc(2026, 6, 10), 51.0),
    ];
    expect(
      CooperResult.changeLine(50.96, d, prior),
      'VO2 est. no change since June',
    );
    expect(
      CooperResult.changeLine(51.04, d, prior),
      'VO2 est. no change since June',
    );
    expect(
      CooperResult.changeLine(50.94, d, prior),
      'VO2 est. -0.1 since June',
    );
    expect(carriesEstimateMarker('VO2 est. no change since June'), isTrue);
  });

  test('change line adds the year when the earlier test is another year', () {
    final d = DateTime.utc(2026, 2, 14);
    expect(
      CooperResult.changeLine(52.4, d, [
        (DateTime.utc(2025, 3, 1), 49),
        (DateTime.utc(2025, 6, 10), 51),
      ]),
      'VO2 est. +1.4 since June 2025',
    );
    // Same month number, different year: still the year, not the day.
    expect(
      CooperResult.changeLine(52.4, d, [
        (DateTime.utc(2025, 1, 1), 49),
        (DateTime.utc(2025, 2, 3), 51),
      ]),
      'VO2 est. +1.4 since February 2025',
    );
  });

  test('copy: every number carries an estimate marker; no em dashes', () {
    final c = CooperResult.of(cooperRun(), indoor: false, noisy: false);
    final strings = [
      c.estimate!.rangeLine,
      CooperResult.disclaimer,
      ...CooperResult.method,
      CooperResult.changeLine(52, start, [
        (DateTime.utc(2026, 3, 1), 49),
        (DateTime.utc(2026, 6, 1), 51),
      ])!,
    ];
    for (final s in strings) {
      expect(s.contains('—'), isFalse, reason: s);
    }
    for (final s in [
      c.estimate!.rangeLine,
      CooperResult.disclaimer,
      CooperResult.method[1],
      CooperResult.changeLine(52, start, [
        (DateTime.utc(2026, 3, 1), 49),
        (DateTime.utc(2026, 6, 1), 51),
      ])!,
    ]) {
      expect(carriesEstimateMarker(s), isTrue, reason: s);
    }
  });
}
