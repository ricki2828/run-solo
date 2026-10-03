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
    double? trailM,
    int? trailMs,
    double grade = 1,
    double effortGrade = 1,
  }) {
    final efforts = RunBestEfforts(
      efforts: {
        for (final e in bests.entries) e.key: e.value.withGrade(effortGrade),
      },
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
        trailDistanceM: trailM,
        trailMovingMs: trailMs,
        gradeFactor: grade,
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

  test('a clean 5K inside an INT run without eligible reps unlocks MID', () {
    final candidate = run(
      'int-8k',
      mode: RunMode.intervals,
      bests: {BestEffortDistance.k5: best(BestEffortDistance.k5, 1720)},
    );
    final score = IdentityScores.of([candidate], now: now);
    expect(score[IdentityLane.mid]?.runId, 'int-8k');
    expect(score[IdentityLane.speed], isNull);
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

  group('scores move with true pace, not with flat cool runs', () {
    LiveCandidate fiveK({double? heat, double hills = 1}) => run(
      'five',
      heat: heat,
      effortGrade: hills,
      bests: {BestEffortDistance.k5: best(BestEffortDistance.k5, 1500)},
    );
    double mid(LiveCandidate c) =>
        IdentityScores.of([c], now: now)[IdentityLane.mid]!.vdot;

    test('a flat, cool 5K scores exactly its clock time', () {
      expect(mid(fiveK(heat: 0)), FitnessHero.vdot(5000, 1500000));
      expect(mid(fiveK()), FitnessHero.vdot(5000, 1500000));
    });

    test('a hot 5K scores better than the same time on a cool day', () {
      final hot = mid(fiveK(heat: 0.06));
      expect(hot, greaterThan(mid(fiveK(heat: 0))));
      expect(
        hot,
        closeTo(FitnessHero.vdot(5000, (1500000 * 0.94).round()), 1e-9),
      );
    });

    test('a hilly 5K scores better than the same time on the flat', () {
      final hilly = mid(fiveK(hills: 0.9));
      expect(hilly, greaterThan(mid(fiveK())));
      expect(
        hilly,
        closeTo(FitnessHero.vdot(5000, (1500000 * 0.9).round()), 1e-9),
      );
    });

    test('hills and heat multiply, and SPEED reads the work pace hills', () {
      final both = mid(fiveK(heat: 0.05, hills: 0.9));
      expect(
        both,
        closeTo(FitnessHero.vdot(5000, (1500000 * 0.95 * 0.9).round()), 1e-9),
      );
      final session = LiveCandidate(
        BoardInput(
          runId: 'x',
          date: now.subtract(const Duration(days: 1)),
          mode: RunMode.intervals,
          comparisonKey: ComparisonKey.norwegian4x4,
          verdictGrade: true,
          headlineSecPerKm: 280,
          heatFraction: 0.04,
          headlineGradeFactor: 0.9,
        ),
        const RunDerived(bestEfforts: RunBestEfforts.none),
      );
      final speed = IdentityScores.of([session], now: now)[IdentityLane.speed]!;
      expect(
        speed.vdot,
        closeTo(FitnessHero.vdot(1000, (280000 * 0.96 * 0.9).round()), 1e-9),
      );
    });
  });

  group('trail runs count at their true pace', () {
    // A flat road 16 km at 6:00/km: the LONG reading before trail existed.
    final road = run(
      'road',
      wholeM: 16000,
      wholeMs: 16 * 360 * 1000,
      daysAgo: 3,
    );
    // A slow, hilly 15.5 km: 7:20/km on the clock, hills worth 25% (the
    // clamp), so 5:30/km true pace.
    final hilly = run(
      'hilly',
      mode: RunMode.trail,
      trailM: 15500,
      trailMs: (15.5 * 440 * 1000).round(),
      grade: 0.7,
      daysAgo: 1,
    );

    test('a slow hilly 15K lifts LONG fairly, at its true pace', () {
      final withoutTrail = IdentityScores.of([road], now: now);
      final withTrail = IdentityScores.of([road, hilly], now: now);
      expect(withoutTrail[IdentityLane.long]!.source, '15K+ run');
      expect(withTrail[IdentityLane.long]!.runId, 'hilly');
      expect(withTrail[IdentityLane.long]!.source, TrailScore.longSource);
      expect(
        withTrail[IdentityLane.long]!.vdot,
        closeTo(FitnessHero.vdot(15500, (15.5 * 330 * 1000).round()), 1e-9),
      );
      expect(
        withTrail[IdentityLane.long]!.score,
        greaterThan(withoutTrail[IdentityLane.long]!.score),
      );
      // The clock pace alone (7:20/km) would have scored far lower.
      expect(
        FitnessHero.vdot(15500, (15.5 * 440 * 1000).round()),
        lessThan(withoutTrail[IdentityLane.long]!.vdot),
      );
    });

    test('a flat road run is unchanged by trail runs that do not count', () {
      // No scoring time: a trail run too short to count.
      final nothing = run('flat-trail', mode: RunMode.trail, daysAgo: 1);
      final alone = IdentityScores.of([road], now: now);
      final mixed = IdentityScores.of([road, nothing], now: now);
      for (final lane in IdentityLane.values) {
        expect(mixed[lane]?.score, alone[lane]?.score, reason: '$lane');
        expect(mixed[lane]?.runId, alone[lane]?.runId, reason: '$lane');
      }
    });

    test(
      'a trail run lifts AEROBIC only through the hero, never SPEED or MID',
      () {
        final scores = IdentityScores.of([hilly], now: now);
        expect(scores[IdentityLane.speed], isNull);
        expect(scores[IdentityLane.mid], isNull);
        expect(scores[IdentityLane.aerobic]!.source, 'trail run');
        expect(scores[IdentityLane.long]!.source, TrailScore.longSource);
      },
    );

    test('under 15 km feeds AEROBIC but not LONG', () {
      final short = run(
        'short',
        mode: RunMode.trail,
        trailM: 9000,
        trailMs: 9 * 340 * 1000,
      );
      final scores = IdentityScores.of([short], now: now);
      expect(scores[IdentityLane.aerobic], isNotNull);
      expect(scores[IdentityLane.long], isNull);
    });
  });
}
