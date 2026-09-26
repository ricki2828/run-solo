import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Phase 4 PD2: the Home ESTIMATED TIMES card and the Start target, both
/// from what the index holds (never a run file).
void main() {
  const names = EventNames(parkrun: 'parkrun');
  final now = DateTime(2026, 9, 26, 9);
  // Local noon on Sat 12 Sep, so toLocal() keeps the day in any zone the
  // test host uses.
  final sat12 = DateTime(2026, 9, 12, 12);

  BestEffort be(BestEffortDistance d, int seconds) => BestEffort(
    distance: d,
    elapsedMs: seconds * 1000,
    startMs: 0,
    startOffsetM: 0,
    splitsMs: const [],
  );

  LiveCandidate run(
    String id, {
    DateTime? date,
    RunMode mode = RunMode.free,
    String? key,
    Map<BestEffortDistance, BestEffort> efforts = const {},
    double? wholeM,
    int? wholeMs,
    double? heat,
    int? officialMs,
  }) {
    final e = RunBestEfforts(
      efforts: efforts,
      fromStartSplitsMs: const [],
      wholeRunM: wholeM,
      wholeRunMs: wholeMs,
    );
    return LiveCandidate(
      BoardInput(
        runId: id,
        date: (date ?? sat12).toUtc(),
        mode: mode,
        comparisonKey: key,
        efforts: e.efforts,
        heatFraction: heat,
        officialTimeMs: officialMs,
      ),
      RunDerived(bestEfforts: e),
    );
  }

  group('Home ESTIMATED TIMES', () {
    test('nothing yet: the empty line', () {
      final h = HomeEstimates.of(const [], now: now, names: names);
      expect(h.rows, isEmpty);
      expect(h.message, 'Run 3 km or more to see your estimated times.');
    });

    test('nothing in 6 weeks: the stale line, never a stale number', () {
      final h = HomeEstimates.of(
        [
          run(
            'old',
            date: now.subtract(const Duration(days: 57)),
            efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1500)},
          ),
        ],
        now: now,
        names: names,
      );
      expect(h.rows, isEmpty);
      expect(
        h.message,
        'Run 3 km or more to refresh your estimated times. The last one was '
        '8 weeks ago.',
      );
    });

    test('5K and 10K rows from a 5K; source with the day; cool conditions', () {
      final h = HomeEstimates.of(
        [
          run(
            'a',
            efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1470)},
            heat: 0,
          ),
        ],
        now: now,
        names: names,
      );
      expect(h.message, isNull);
      expect(h.rows.map((r) => r.label), ['5K', '10K']);
      expect(h.rows.first.time, '24:30');
      expect(h.rows.first.semantics, 'Estimated 5K 24:30');
      expect(h.rows.first.band, isNotEmpty);
      expect(h.sourceLines, [
        'From your 5K on Sat 12 Sep · in cool conditions',
      ]);
      expect(carriesEstimateMarker(h.rows.first.semantics), isTrue);
    });

    test(
      'a continuous 4 km Free run counts (the whole run, from the index)',
      () {
        final h = HomeEstimates.of(
          [run('w', wholeM: 4000, wholeMs: 1200000)],
          now: now,
          names: names,
        );
        expect(h.rows, hasLength(2));
        expect(h.sourceLines.single, 'From your 4.0 km run on Sat 12 Sep');
      },
    );

    test('the event row once a course exists, with the injected name', () {
      final h = HomeEstimates.of(
        [
          run(
            'p',
            mode: RunMode.intervals,
            key: 'parkrun:albert',
            efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1470)},
          ),
        ],
        now: now,
        names: const EventNames(parkrun: '5K time trial'),
        includeEvent: true,
      );
      expect(h.rows.last.label, 'Your 5K time trial');
    });
  });

  group('Start target', () {
    final event = SessionSpec.parkrun('parkrun');

    test('the event: a fresh faster course PB leads; predicted is the '
        'switch', () {
      final t = StartTarget.forSession(
        event,
        runs: [
          run(
            'pb',
            date: DateTime(2026, 9, 19, 8),
            mode: RunMode.intervals,
            key: 'parkrun:albert',
            efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1500)},
            officialMs: 1452000,
          ),
        ],
        now: now,
        names: names,
        courseKey: 'parkrun:albert',
      )!;
      expect(t.line, 'Target 24:12 (your PB)');
      expect(t.predicted, isFalse);
      expect(t.liveDistanceM, 5000);
      expect(t.liveTargetMs, 1452000);
      expect(t.alternativeLine, 'Target 25:00 (predicted)');
      expect(t.alternative!.liveTargetMs, 1500000);
    });

    test('the event with no course: predicted only', () {
      final t = StartTarget.forSession(
        event,
        runs: [
          run(
            'a',
            efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1470)},
          ),
        ],
        now: now,
        names: names,
      )!;
      expect(t.line, 'Target 24:30 (predicted)');
      expect(t.alternativeLine, isNull);
    });

    test('a half goal: the wide-band estimate, a live target', () {
      final t = StartTarget.forSession(
        SessionSpec.goalDistance(21098, 'Half'),
        runs: [
          run(
            'a',
            efforts: {BestEffortDistance.k10: be(BestEffortDistance.k10, 2700)},
          ),
        ],
        now: now,
        names: names,
      )!;
      expect(t.line, 'Target about 1:39:17 (1:38:33 to 1:40:47), estimate');
      expect(t.liveDistanceM, 21098);
      expect(t.liveTargetMs, closeTo(5957000, 1000));
    });

    test('a time goal: a line, no live target', () {
      final t = StartTarget.forSession(
        SessionSpec.goalTime(1800, '30 min'),
        runs: [
          run(
            'a',
            efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1500)},
          ),
        ],
        now: now,
        names: names,
      )!;
      expect(t.line, 'Target 5.94 km (predicted)');
      expect(t.liveDistanceM, isNull);
      expect(t.liveTargetMs, isNull);
    });

    test('other sessions, or nothing to go on: no target', () {
      expect(
        StartTarget.forSession(
          SessionSpec.norwegian4x4(),
          runs: const [],
          now: now,
          names: names,
        ),
        isNull,
      );
      expect(
        StartTarget.forSession(event, runs: const [], now: now, names: names),
        isNull,
      );
    });
  });
}
