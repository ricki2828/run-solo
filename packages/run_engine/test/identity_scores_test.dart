import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime(2026, 9, 29, 12);
  BestEffort best(BestEffortDistance d, int seconds) => BestEffort(
    distance: d,
    elapsedMs: seconds * 1000,
    startMs: 0,
    startOffsetM: 0,
    splitsMs: const [],
  );
  LiveCandidate run(
    String id, {
    RunMode mode = RunMode.free,
    String? key,
    bool clean = false,
    double? pace,
    double? vo2,
    double? heat,
    int daysAgo = 1,
    Map<BestEffortDistance, BestEffort> bests = const {},
    double? wholeM,
    int? wholeMs,
  }) {
    final efforts = RunBestEfforts(
      efforts: bests,
      fromStartSplitsMs: const [],
      wholeRunM: wholeM,
      wholeRunMs: wholeMs,
    );
    return LiveCandidate(
      BoardInput(
        runId: id,
        date: now.subtract(Duration(days: daysAgo)),
        mode: mode,
        comparisonKey: key,
        verdictGrade: clean,
        headlineSecPerKm: pace,
        cooperVo2: vo2,
        heatFraction: heat,
        efforts: efforts.efforts,
      ),
      RunDerived(bestEfforts: efforts),
    );
  }

  test('all lanes locked with no run evidence', () {
    expect(IdentityScores.of([], now: now), isEmpty);
    expect(IdentityScores.displayScore(-100), 0);
    expect(IdentityScores.displayScore(500), 99);
  });

  test('aerobic uses the very same hero observation and run', () {
    final cooper = run(
      'cooper',
      mode: RunMode.cooper,
      key: ComparisonKey.cooper,
      vo2: 51.5,
    );
    final hero = FitnessHero.of([cooper], now: now)!;
    final score = IdentityScores.of([cooper], now: now, hero: hero);
    expect(score[IdentityLane.aerobic]!.runId, hero.runId);
    expect(
      score[IdentityLane.aerobic]!.score,
      IdentityScores.displayScore(hero.vo2),
    );
    expect(score[IdentityLane.speed], isNull);
  });

  test('speed requires clean intervals; best 1K and 4x4 are scored', () {
    final noisy = run(
      'noisy',
      mode: RunMode.intervals,
      key: ComparisonKey.norwegian4x4,
      pace: 220,
      bests: {BestEffortDistance.km1: best(BestEffortDistance.km1, 220)},
    );
    final clean = run(
      'clean',
      mode: RunMode.intervals,
      key: ComparisonKey.norwegian4x4,
      clean: true,
      pace: 280,
      bests: {BestEffortDistance.km1: best(BestEffortDistance.km1, 275)},
    );
    final scores = IdentityScores.of([noisy, clean], now: now);
    expect(scores[IdentityLane.speed]!.runId, 'clean');
    expect(scores[IdentityLane.speed]!.score, inInclusiveRange(0, 99));
  });

  test('mid unlocks on 5K, not a 1K, and heat improves its evidence', () {
    final short = run(
      'short',
      bests: {BestEffortDistance.km1: best(BestEffortDistance.km1, 240)},
    );
    expect(IdentityScores.of([short], now: now)[IdentityLane.mid], isNull);
    final five = run(
      'five',
      heat: 0.04,
      bests: {BestEffortDistance.k5: best(BestEffortDistance.k5, 1500)},
    );
    final cool = run(
      'cool',
      bests: {BestEffortDistance.k5: best(BestEffortDistance.k5, 1500)},
    );
    final score = IdentityScores.of([five, cool], now: now)[IdentityLane.mid]!;
    expect(score.runId, 'five');
    expect(score.boardKey, BestEffortDistance.k5.key);
  });

  test('long stays locked until a continuous 15K+ free run', () {
    final short = run('short', wholeM: 14999, wholeMs: 70 * 60000);
    expect(IdentityScores.of([short], now: now)[IdentityLane.long], isNull);
    final long = run('long', wholeM: 16000, wholeMs: 80 * 60000);
    final score = IdentityScores.of([long], now: now)[IdentityLane.long]!;
    expect(score.runId, 'long');
    expect(score.source, '15K+ run');
  });

  test('six-week comparison uses prior-window best and ignores stale runs', () {
    final prior = run(
      'prior',
      daysAgo: 50,
      bests: {BestEffortDistance.k5: best(BestEffortDistance.k5, 1600)},
    );
    final current = run(
      'current',
      daysAgo: 2,
      bests: {BestEffortDistance.k5: best(BestEffortDistance.k5, 1500)},
    );
    final score = IdentityScores.of([
      prior,
      current,
    ], now: now)[IdentityLane.mid]!;
    expect(score.changeVs6Weeks, greaterThan(0));
    expect(IdentityScores.of([prior], now: now)[IdentityLane.mid], isNull);
  });
}
