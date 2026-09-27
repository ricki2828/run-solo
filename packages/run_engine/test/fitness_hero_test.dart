import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The Home fitness hero (product call 27-Sep): VO2 as the headline,
/// Cooper the gold standard, other run types updating the estimate.
void main() {
  final now = DateTime(2026, 9, 26, 9);
  // Local noon, so toLocal() keeps the day in any zone the test host uses.
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
    DateTime? date,
    RunMode mode = RunMode.free,
    String? key,
    Map<BestEffortDistance, BestEffort> efforts = const {},
    double? cooperVo2,
    double? cooperVo2Adj,
    double? heat,
  }) {
    final e = RunBestEfforts(efforts: efforts, fromStartSplitsMs: const []);
    return LiveCandidate(
      BoardInput(
        runId: id,
        date: (date ?? daysAgo(3)).toUtc(),
        mode: mode,
        comparisonKey: key,
        efforts: e.efforts,
        cooperVo2: cooperVo2,
        cooperVo2Adj: cooperVo2Adj,
        heatFraction: heat ?? 0,
      ),
      RunDerived(bestEfforts: e),
    );
  }

  test('VDOT conversion: a 24:30 5K effort reads about 39', () {
    expect(FitnessHero.vdot(5000, 24 * 60 * 1000 + 30000), closeTo(39.2, 0.3));
  });

  test('no observations, or none inside the window, gives no hero', () {
    expect(FitnessHero.of(const [], now: now), isNull);
    final stale = run('s', date: daysAgo(60), cooperVo2: 50);
    expect(FitnessHero.of([stale], now: now), isNull);
  });

  test('a Cooper test sets the headline at its prime figure', () {
    final test = run(
      't',
      key: ComparisonKey.cooper,
      mode: RunMode.cooper,
      cooperVo2: 50.0,
      cooperVo2Adj: 51.5,
    );
    final hero = FitnessHero.of([test], now: now)!;
    expect(hero.vo2, 51.5);
    expect(hero.sourceLabel, 'Cooper test');
  });

  test('a strong run raises the headline between tests', () {
    final test = run(
      't',
      date: daysAgo(6),
      key: ComparisonKey.cooper,
      mode: RunMode.cooper,
      cooperVo2: 38.0,
    );
    final fast = run(
      'f',
      date: daysAgo(2),
      efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 24 * 60 + 30)},
    );
    final hero = FitnessHero.of([test, fast], now: now)!;
    expect(hero.sourceLabel, '5K');
    expect(hero.vo2, greaterThan(38.0));
  });

  test('the delta compares with the same reading six weeks ago', () {
    final oldTest = run(
      'old',
      date: daysAgo(50),
      key: ComparisonKey.cooper,
      mode: RunMode.cooper,
      cooperVo2: 50.0,
    );
    final newTest = run(
      'new',
      key: ComparisonKey.cooper,
      mode: RunMode.cooper,
      cooperVo2: 51.5,
    );
    final hero = FitnessHero.of([oldTest, newTest], now: now)!;
    expect(hero.deltaVs6wks, closeTo(1.5, 0.001));
    // Without a prior-window observation there is no delta.
    expect(FitnessHero.of([newTest], now: now)!.deltaVs6wks, isNull);
  });

  test('the spark lists the trailing twelve weeks, oldest first', () {
    LiveCandidate t(String id, int days, double vo2) => run(
      id,
      date: daysAgo(days),
      key: ComparisonKey.cooper,
      mode: RunMode.cooper,
      cooperVo2: vo2,
    );
    final a = t('a', 70, 48.0);
    final b = t('b', 30, 49.0);
    final c = t('c', 2, 51.5);
    final outside = t('z', 100, 60.0);
    final hero = FitnessHero.of([a, b, c, outside], now: now)!;
    expect(hero.spark, [48.0, 49.0, 51.5]);
  });
}
