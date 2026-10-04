import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime(2026, 10, 4, 9);
  DateTime daysAgo(int d) => now.subtract(Duration(days: d)).toLocal();

  BestEffort be(BestEffortDistance d, int seconds) => BestEffort(
    distance: d,
    elapsedMs: seconds * 1000,
    startMs: 0,
    startOffsetM: 0,
    splitsMs: const [],
  );

  LiveCandidate run(
    String id, {
    int days = 3,
    Map<BestEffortDistance, BestEffort> efforts = const {},
    double? wholeM,
    int? wholeMs,
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
        date: daysAgo(days).toUtc(),
        mode: RunMode.free,
        efforts: e.efforts,
      ),
      RunDerived(bestEfforts: e),
    );
  }

  final fiveK = run(
    'a',
    efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1470)},
  );

  test('no runs: no times, a reason on every row, no VO2, nothing to show', () {
    final r = RaceEstimates.of(const [], now: now);
    expect(r.isEmpty, isTrue);
    expect(r.rows.map((x) => x.label), ['5K', '10K', 'Half', 'Marathon']);
    expect(r.rows.every((x) => x.whyNot == RaceEstimates.shortWhyNot), isTrue);
    expect(r.homeLine, isNull);
  });

  test('a 5K gives 5K and 10K, says why there is no half or marathon', () {
    final r = RaceEstimates.of([fiveK], now: now);
    expect(r.row('5K').time, '24:30');
    expect(r.row('10K').hasTime, isTrue);
    expect(r.row('Half').whyNot, RaceEstimates.longWhyNot);
    expect(r.row('Marathon').whyNot, RaceEstimates.longWhyNot);
    expect(r.vo2, isNotNull);
    expect(r.homeLine, startsWith('VO2 '));
    expect(r.homeLine, isNot(contains('Half')));
  });

  test('a 12 km run unlocks half and marathon, on the goal exponents', () {
    final long = run('l', wholeM: 12000, wholeMs: 3600 * 1000);
    final r = RaceEstimates.of([long], now: now);
    final half = r.row('Half'), full = r.row('Marathon');
    expect(half.hasTime && full.hasTime, isTrue);
    final (e, _, _) = GoalTarget.exponentsFor(21097.5);
    expect(
      half.seconds,
      closeTo(Predictor.riegel(3600, 12000, 21097.5, e), 1e-6),
    );
    expect(full.seconds!, greaterThan(half.seconds! * 2));
    expect(half.range, contains(' to '));
    expect(r.homeLine, startsWith('Half '));
    expect(r.homeLine, contains('Marathon '));
  });

  test('a stale long run does not count', () {
    final old = run('o', days: 60, wholeM: 15000, wholeMs: 4500 * 1000);
    final r = RaceEstimates.of([fiveK, old], now: now);
    expect(r.row('Half').whyNot, RaceEstimates.longWhyNot);
  });

  test('the method is in the detail view and says it is an estimate', () {
    expect(RaceEstimates.method.any(carriesEstimateMarker), isTrue);
  });
}
