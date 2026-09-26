import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 4 PD1 (plan §3.4): Riegel predictions, candidate selection, heat
/// inputs, the parkrun target and "estimate" wording (WARN-4).
void main() {
  const predictor = Predictor();
  final now = DateTime(2026, 9, 26, 9);
  final sep12 = DateTime(2026, 9, 12);

  PredictionInput input(
    double metres,
    int seconds, {
    DateTime? date,
    PredictionSourceKind kind = PredictionSourceKind.bestEffort5k,
    int? adjSeconds,
  }) => PredictionInput(
    runId: 'r-$metres-$seconds',
    date: date ?? sep12,
    distanceM: metres,
    elapsedMs: seconds * 1000,
    kind: kind,
    adjElapsedMs: adjSeconds == null ? null : adjSeconds * 1000,
  );

  RunFile evenRun(
    int seconds,
    double mps, {
    RunMode mode = RunMode.free,
    List<Span> pauses = const [],
  }) => RunFile(
    id: '00000000-0000-4000-8000-0000000000d1',
    device: 'test',
    app: 'test',
    start: fixedNow,
    end: fixedNow.add(Duration(seconds: seconds)),
    tz: 'UTC',
    mode: mode,
    units: Units.km,
    laps: const [],
    pauses: pauses,
    samples: [
      for (var t = 0; t <= seconds; t++)
        Sample(
          tMs: t * 1000,
          lat: -33.87,
          lon: 151.21,
          accM: 5,
          distM: t * mps,
        ),
    ],
  );

  List<PredictionInput> inputsOf(RunFile run, {double? heat}) {
    final a = engine.analyze(run, now: fixedNow);
    return PredictionInput.ofRun(
      run,
      a,
      const BestEffortFinder().find(run, a),
      localDate: sep12,
      heatFraction: heat,
    );
  }

  group('Riegel', () {
    test('5K 25:00 → 10K with the 1.06 exponent and the 1.05–1.08 band', () {
      final p = predictor.predict(PredictionTarget.k10, [
        input(5000, 1500),
      ], now: now)!;
      expect(p.seconds, closeTo(3127.40, 0.01));
      expect(p.lowSeconds, closeTo(3105.79, 0.01));
      expect(p.highSeconds, closeTo(3171.05, 0.01));
      expect(
        p.cardLine,
        'Estimated 10K 52:07 (51:46 to 52:51) · from your 5K on 12 Sep',
      );
    });

    test('predicting down reverses the band order', () {
      final p = predictor.predict(PredictionTarget.k5, [
        input(10000, 3127, kind: PredictionSourceKind.bestEffort10k),
      ], now: now)!;
      expect(p.seconds, closeTo(1499.8, 0.1));
      expect(p.lowSeconds, lessThan(p.seconds));
      expect(p.highSeconds, greaterThan(p.seconds));
      expect(p.sourceLine, 'from your 10K on 12 Sep');
    });

    test('same distance predicts the same time', () {
      final p = predictor.predict(PredictionTarget.parkrun, [
        input(5000, 1470, kind: PredictionSourceKind.parkrun),
      ], now: now)!;
      expect(p.seconds, 1470);
      expect(p.headline, 'Estimated parkrun 24:30');
      expect(p.targetLine, 'Target 24:30 (predicted)');
    });

    test('a 3 km run seeds a 5K', () {
      final p = predictor.predict(PredictionTarget.k5, [
        input(3000, 720, kind: PredictionSourceKind.wholeRun),
      ], now: now)!;
      expect(p.seconds, closeTo(1237.35, 0.01));
      expect(p.sourceLine, 'from your 3.0 km run on 12 Sep');
    });

    test('past the hour the clock shows hours', () {
      expect(Prediction.clock(3725), '1:02:05');
      expect(Prediction.clock(1470), '24:30');
    });
  });

  group('candidate selection', () {
    test('the fastest predicted time wins, not the latest run', () {
      final p = predictor.predict(PredictionTarget.k10, [
        input(10000, 3600, kind: PredictionSourceKind.bestEffort10k),
        input(5000, 1500, date: DateTime(2026, 9, 1)),
        input(5000, 1560, date: DateTime(2026, 9, 20)),
      ], now: now)!;
      expect(p.source.elapsedMs, 1500000);
    });

    test('only the last 6 weeks and nothing under 3 km', () {
      expect(
        predictor.predict(PredictionTarget.k5, [
          input(5000, 1400, date: now.subtract(const Duration(days: 43))),
          input(2999, 600, kind: PredictionSourceKind.wholeRun),
        ], now: now),
        isNull,
      );
      expect(
        predictor.predict(PredictionTarget.k5, [
          input(5000, 1400, date: now.subtract(const Duration(days: 41))),
        ], now: now),
        isNotNull,
      );
    });

    test('no qualifying run → no prediction, empty-card copy', () {
      expect(predictor.predictAll(const [], now: now), isEmpty);
      expect(Predictor.emptyLine, 'Run 3 km or more to see your predictions');
    });

    test('heat-adjusted input is used and says so', () {
      final p = predictor.predict(PredictionTarget.k5, [
        input(5000, 1560, adjSeconds: 1500),
      ], now: now)!;
      expect(p.seconds, 1500);
      expect(p.conditionsNote, isNotNull);
      final raw = predictor.predict(PredictionTarget.k5, [
        input(5000, 1560),
      ], now: now)!;
      expect(raw.conditionsNote, isNull);
    });

    test('a hot fast run can still lose to a cool faster one', () {
      final p = predictor.predict(PredictionTarget.k5, [
        input(5000, 1560, adjSeconds: 1510),
        input(5000, 1490, date: DateTime(2026, 9, 5)),
      ], now: now)!;
      expect(p.seconds, 1490);
    });

    test('predictAll skips parkrun unless asked', () {
      final inputs = [input(5000, 1500)];
      expect(predictor.predictAll(inputs, now: now).keys, {
        PredictionTarget.k5,
        PredictionTarget.k10,
      });
      expect(
        predictor
            .predictAll(inputs, now: now, includeParkrun: true)
            .keys
            .length,
        3,
      );
    });
  });

  group('inputs from a run', () {
    test('a 6 km Free run offers its 5K and the whole run', () {
      final inputs = inputsOf(evenRun(1500, 4.0));
      expect(inputs.map((i) => i.kind), [
        PredictionSourceKind.bestEffort5k,
        PredictionSourceKind.wholeRun,
      ]);
      expect(inputs.first.elapsedMs, 1250000);
      expect(inputs.last.distanceM, 6000);
    });

    test('heat fraction gives t × (1 − adj)', () {
      final i = inputsOf(evenRun(1500, 4.0), heat: 0.04).first;
      expect(i.adjElapsedMs, 1200000);
    });

    test('a paused run offers its best efforts but not the whole run', () {
      final inputs = inputsOf(
        evenRun(3000, 4.0, pauses: const [Span(1600500, 1600900)]),
      );
      expect(
        inputs.map((i) => i.kind),
        isNot(contains(PredictionSourceKind.wholeRun)),
      );
    });

    test('interval sessions, Cooper and indoor runs offer nothing', () {
      final f = fixture('preset_4x4_auto_standard');
      final a = engine.analyze(f.run, now: fixedNow);
      expect(
        PredictionInput.ofRun(
          f.run,
          a,
          const BestEffortFinder().find(f.run, a),
          localDate: sep12,
        ),
        isEmpty,
      );
      expect(inputsOf(evenRun(720, 4.2, mode: RunMode.cooper)), isEmpty);
      final t = fixture('treadmill_indoor');
      final ta = engine.analyze(t.run, now: fixedNow);
      expect(
        PredictionInput.ofRun(
          t.run,
          ta,
          const BestEffortFinder().find(t.run, ta),
          localDate: sep12,
        ),
        isEmpty,
      );
    });
  });

  group('parkrun target', () {
    final pred = predictor.predict(PredictionTarget.parkrun, [
      input(5000, 1470, kind: PredictionSourceKind.parkrun),
    ], now: now);

    test('a fresh faster course PB wins', () {
      final t = ParkrunTarget.choose(
        prediction: pred,
        coursePbMs: 1452000,
        coursePbDate: DateTime(2026, 9, 1),
        now: now,
      )!;
      expect(t.fromPb, isTrue);
      expect(t.line, 'Target 24:12 (your PB)');
    });

    test('an old or slower PB loses to the prediction', () {
      for (final (ms, date) in [
        (1452000, DateTime(2026, 8, 1)),
        (1500000, DateTime(2026, 9, 1)),
      ]) {
        final t = ParkrunTarget.choose(
          prediction: pred,
          coursePbMs: ms,
          coursePbDate: date,
          now: now,
        )!;
        expect(t.fromPb, isFalse);
        expect(t.line, 'Target 24:30 (predicted)');
      }
    });

    test('nothing to go on → no target', () {
      expect(ParkrunTarget.choose(now: now), isNull);
    });
  });

  test('the marker check matches whole words only', () {
    for (final ok in [
      'Estimated 5K 24:30',
      'VO2 est. 50',
      'about 2,740',
      'Research-based norms',
      'Target 24:30 (predicted)',
      'Heat-adjusted estimate 52.8',
    ]) {
      expect(carriesEstimateMarker(ok), isTrue, reason: ok);
    }
    for (final bad in [
      'Your best.',
      'Your fastest.',
      'Take a rest.',
      'Roundabout 24:30',
      'Unpredicted 24:30',
    ]) {
      expect(carriesEstimateMarker(bad), isFalse, reason: bad);
    }
  });

  test('same distance: no collapsed band on the card', () {
    final p = predictor.predict(PredictionTarget.k5, [
      input(5000, 1470),
    ], now: now)!;
    expect(p.cardLine, 'Estimated 5K 24:30 · from your 5K on 12 Sep');
  });

  test('a run on day 42 counts all day', () {
    final early = DateTime(2026, 8, 15, 6);
    expect(
      predictor.predict(PredictionTarget.k5, [
        input(5000, 1470, date: early),
      ], now: DateTime(2026, 9, 26, 23)),
      isNotNull,
    );
  });

  test('string lint (WARN-4): every predicted-number string is labelled', () {
    final strings = <String>[];
    for (final kind in PredictionSourceKind.values) {
      for (final adj in [null, 1450]) {
        for (final units in Units.values) {
          final preds = predictor.predictAll(
            [input(6000, 1500, kind: kind, adjSeconds: adj)],
            now: now,
            units: units,
            includeParkrun: true,
          );
          for (final p in preds.values) {
            strings
              ..add(p.headline)
              ..add(p.cardLine)
              ..add(p.targetLine);
            if (p.conditionsNote case final n?) strings.add(n);
            // The band alone is shown only under the headline.
          }
        }
      }
    }
    final target = ParkrunTarget.choose(
      prediction: predictor.predict(PredictionTarget.parkrun, [
        input(5000, 1470),
      ], now: now),
      now: now,
    )!;
    strings.add(target.line);
    expect(strings, isNotEmpty);
    for (final s in strings) {
      expect(carriesEstimateMarker(s), isTrue, reason: s);
      expect(s.contains('—'), isFalse, reason: 'no em dashes: $s');
    }
  });
}
