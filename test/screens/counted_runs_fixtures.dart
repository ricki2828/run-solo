import 'package:run_engine/run_engine.dart' as engine;

import '../helpers.dart';

engine.BestEffort _k5(int seconds, {int gpsGapMs = 0, double grade = 1}) =>
    engine.BestEffort(
      distance: engine.BestEffortDistance.k5,
      elapsedMs: seconds * 1000,
      startMs: 0,
      startOffsetM: 0,
      splitsMs: const [],
      gpsGapMs: gpsGapMs,
      gradeFactor: grade,
    );

engine.LiveCandidate countedRun(
  String id,
  int daysAgo, {
  int seconds = 1500,
  int gpsGapMs = 0,
  double distanceM = 5200,
  engine.RunMode mode = engine.RunMode.free,
  double grade = 1,
  int? trailMovingMs,
  engine.EffortMiss? miss,
  bool counts = true,
}) => engine.LiveCandidate(
  engine.BoardInput(
    runId: id,
    date: testNow.subtract(Duration(days: daysAgo)).toUtc(),
    mode: mode,
    runDistanceM: distanceM,
    trailMovingMs: trailMovingMs,
    trailDistanceM: trailMovingMs == null ? null : distanceM,
    gradeFactor: grade,
  ),
  engine.RunDerived(
    bestEfforts: engine.RunBestEfforts(
      efforts: counts
          ? {
              engine.BestEffortDistance.k5: _k5(
                seconds,
                gpsGapMs: gpsGapMs,
                grade: grade,
              ),
            }
          : const {},
      fromStartSplitsMs: const [],
      miss: miss,
    ),
  ),
);

/// Six runs covering every row kind.
List<engine.LiveCandidate> countedFixtures() => [
  countedRun('r-ok', 1, seconds: 1488),
  countedRun('r-bridged', 3, seconds: 1530, gpsGapMs: 45000),
  countedRun('r-short', 5, distanceM: 3200, counts: false),
  countedRun(
    'r-paused',
    8,
    distanceM: 8000,
    counts: false,
    miss: const engine.EffortMiss(engine.EffortMissKind.pausedLong),
  ),
  countedRun(
    'r-dropped',
    11,
    distanceM: 7000,
    counts: false,
    miss: const engine.EffortMiss(
      engine.EffortMissKind.gpsDropped,
      durationMs: 180000,
      drops: 4,
    ),
  ),
  countedRun(
    'r-trail',
    14,
    seconds: 1800,
    mode: engine.RunMode.trail,
    distanceM: 6000,
    grade: 0.9,
    trailMovingMs: 2000000,
  ),
];
