import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime(2026, 10, 20, 18);

  BestEffort k5(int seconds) => BestEffort(
    distance: BestEffortDistance.k5,
    elapsedMs: seconds * 1000,
    startMs: 0,
    startOffsetM: 0,
    splitsMs: const [],
  );

  LiveCandidate run(
    String id, {
    RunMode mode = RunMode.free,
    String? key,
    double distanceM = 5015,
    int daysAgo = 0,
    EffortMiss? miss,
    bool counts = false,
    int? trailMs,
  }) {
    final efforts = RunBestEfforts(
      efforts: {if (counts) BestEffortDistance.k5: k5(1618)},
      fromStartSplitsMs: const [],
      miss: miss,
    );
    return LiveCandidate(
      BoardInput(
        runId: id,
        date: now.subtract(Duration(days: daysAgo, hours: 1)),
        mode: mode,
        comparisonKey: key,
        efforts: efforts.efforts,
        runDistanceM: distanceM,
        trailMovingMs: trailMs,
      ),
      RunDerived(bestEfforts: efforts),
    );
  }

  String? line(Iterable<LiveCandidate> runs) =>
      EffortNote.latest(runs, now: now)?.line;

  test('a goal run split by a pause says where', () {
    final c = run(
      'goal',
      mode: RunMode.intervals,
      key: 'goal:d5000',
      miss: const EffortMiss(EffortMissKind.pause, atM: 3200, goalM: 5000),
    );
    expect(line([c]), "Your 5K on 20 Oct didn't count: paused at 3.2 km");
  });

  test('a GPS drop, a jump, a stop and a noisy track each have words', () {
    for (final (miss, words) in [
      (
        const EffortMiss(EffortMissKind.gpsDropped, atM: 4100, goalM: 5000),
        'GPS dropped at 4.1 km',
      ),
      (
        const EffortMiss(EffortMissKind.gpsJump, atM: 2500, goalM: 5000),
        'GPS jumped at 2.5 km',
      ),
      (
        const EffortMiss(EffortMissKind.recordingStopped, atM: 900),
        'recording stopped at 0.9 km',
      ),
      (
        const EffortMiss(EffortMissKind.noisy, goalM: 5000),
        'GPS was too noisy',
      ),
    ]) {
      final text = line([run('r', miss: miss)]);
      expect(text, endsWith("didn't count: $words"));
    }
    expect(
      line([run('r', miss: const EffortMiss(EffortMissKind.pause, atM: 3200))]),
      "Your run on 20 Oct didn't count: paused at 3.2 km",
    );
  });

  test('a trail run without elevation says so; with elevation it counts', () {
    expect(
      line([run('t', mode: RunMode.trail, counts: true)]),
      "Your trail run on 20 Oct didn't count: no elevation data to adjust for "
      'hills',
    );
    expect(
      line([run('t', mode: RunMode.trail, counts: true, trailMs: 1900000)]),
      isNull,
    );
  });

  test('a trail run with elevation but no window is explained like a road '
      'run', () {
    final c = run(
      't',
      mode: RunMode.trail,
      trailMs: 1900000,
      miss: const EffortMiss(EffortMissKind.pause, atM: 3200),
    );
    expect(
      line([c]),
      "Your trail run on 20 Oct didn't count: paused at 3.2 km",
    );
  });

  test("distances follow the runner's units; a long pause has none", () {
    final c = run('r', miss: const EffortMiss(EffortMissKind.pause, atM: 3200));
    expect(
      EffortNote.latest([c], now: now, units: Units.mi)!.line,
      "Your run on 20 Oct didn't count: paused at 2.0 mi",
    );
    final long = run(
      'l',
      miss: const EffortMiss(EffortMissKind.pausedLong, goalM: 5000),
    );
    expect(
      line([long]),
      "Your 5K on 20 Oct didn't count: paused for over a minute",
    );
  });

  test('a Cooper test says what it is', () {
    expect(
      line([run('c', mode: RunMode.cooper, distanceM: 5200)]),
      "Your Cooper test on 20 Oct didn't count: it's a 12-minute test",
    );
  });

  test('no note when the run counted, was short, old, or has no cause', () {
    expect(line([run('ok', counts: true)]), isNull);
    expect(line([run('short', distanceM: 4000)]), isNull);
    expect(
      line([
        run(
          'old',
          daysAgo: 20,
          miss: const EffortMiss(EffortMissKind.pause, atM: 3200),
        ),
      ]),
      isNull,
    );
    expect(line([run('plain')]), isNull);
  });

  test('only the newest long run is explained', () {
    final older = run(
      'older',
      daysAgo: 3,
      miss: const EffortMiss(EffortMissKind.pause, atM: 3200),
    );
    expect(line([older, run('newer', counts: true)]), isNull);
  });

  test('Home ESTIMATED TIMES says why a newer run did not update it', () {
    final good = run('good', daysAgo: 22, counts: true);
    final bad = run(
      'bad',
      mode: RunMode.intervals,
      key: 'goal:d5000',
      miss: const EffortMiss(EffortMissKind.pause, atM: 3200, goalM: 5000),
    );
    final h = HomeEstimates.of(
      [good, bad],
      now: now,
      names: const EventNames(parkrun: 'parkrun'),
    );
    expect(h.rows, isNotEmpty);
    expect(
      h.sourceLines.last,
      "Your 5K on 20 Oct didn't count: paused at 3.2 km.",
    );
    final stale = HomeEstimates.of(
      [run('old-ok', daysAgo: 60, counts: true), bad],
      now: now,
      names: const EventNames(parkrun: 'parkrun'),
    );
    expect(stale.message, startsWith("Your 5K on 20 Oct didn't count: "));
  });
}
