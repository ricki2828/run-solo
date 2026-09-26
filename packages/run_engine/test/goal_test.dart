import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 4 §G: GOAL runs. Spec shape, keys, the locked-in goal result,
/// half/marathon best efforts, distance-in-time boards, from-Start ghosts
/// to 42 km.
void main() {
  /// [pieces] of (seconds, m/s) at 1 Hz from Start; a pause of
  /// [pauseSeconds] after [pauseAfterS] (no samples, distance frozen).
  RunFile run(
    List<(int, double)> pieces, {
    SessionSpec? session,
    RunMode mode = RunMode.intervals,
    int? pauseAfterS,
    int pauseSeconds = 0,
  }) {
    final samples = <Sample>[];
    final pauses = <Span>[];
    var t = 0;
    var d = 0.0;
    var s = 0;
    void add() => samples.add(
      Sample(tMs: t, lat: -33.87, lon: 151.21, accM: 5, distM: d),
    );
    add();
    for (final (secs, mps) in pieces) {
      for (var i = 0; i < secs; i++) {
        t += 1000;
        d += mps;
        s++;
        add();
        if (pauseAfterS == s) {
          pauses.add(Span(t + 1, t + pauseSeconds * 1000));
          t += pauseSeconds * 1000;
        }
      }
    }
    return RunFile(
      id: '00000000-0000-4000-8000-00000000g0a1'.replaceAll('g', '0'),
      device: 'test',
      app: 'test',
      start: fixedNow,
      end: fixedNow.add(Duration(milliseconds: t)),
      tz: 'UTC',
      mode: mode,
      session: session,
      units: Units.km,
      laps: const [],
      pauses: pauses,
      samples: samples,
    );
  }

  final tenK = SessionSpec.goalDistance(10000, '10K');
  final thirty = SessionSpec.goalTime(1800, '30 min');

  group('spec and keys', () {
    test('one step, no auto-stop, open cool-down, no warm-up', () {
      expect(tenK.steps, hasLength(1));
      expect(tenK.autoStop, isFalse);
      expect(tenK.cooldownSeconds, isNull);
      expect(tenK.warmupSeconds, 0);
      expect(tenK.isGoal, isTrue);
      expect(ComparisonKey.of(tenK), 'goal:d10000');
      expect(ComparisonKey.of(thirty), 'goal:t1800');
      expect(ComparisonKey.isDistance('goal:d10000'), isTrue);
      expect(ComparisonKey.isTime('goal:t1800'), isTrue);
    });

    test('a 10 km goal never shares the 1 × 10 km interval key', () {
      final interval = SessionSpec(
        templateId: 'custom:x',
        templateVersion: 1,
        name: '1 x 10 km',
        steps: const [SessionStep.workDistance(10000, rep: 1)],
      );
      expect(ComparisonKey.of(interval), 'd10000x*');
      expect(ComparisonKey.of(tenK), isNot(ComparisonKey.of(interval)));
    });

    test('spec JSON round trip', () {
      final back = SessionSpec.fromJson(
        jsonDecode(jsonEncode(tenK.toJson())) as Map<String, Object?>,
      );
      expect(back, tenK);
    });
  });

  group('goal result (locked in from the file)', () {
    test('10K reached, then a cool-down: time at 10 km, no verdict', () {
      final r = run([(2500, 4.0), (600, 2.0)], session: tenK);
      final a = engine.analyze(r, now: fixedNow);
      expect(a.comparisonKey, 'goal:d10000');
      expect(a.verdict, isNull);
      final g = a.goal!;
      expect(g.reached, isTrue);
      expect(g.goalMs, 2500000);
      expect(g.atRunMs, 2500000);
      expect(g.resultLine, '10K in 41:40');
      expect(g.stoppedAtM, 11200);
    });

    test('a pause before the goal is not goal time', () {
      final r = run(
        [(2500, 4.0)],
        session: tenK,
        pauseAfterS: 1000,
        pauseSeconds: 60,
      );
      final g = engine.analyze(r, now: fixedNow).goal!;
      expect(g.goalMs, closeTo(2500000, 2));
      expect(g.atRunMs, closeTo(2560000, 2));
    });

    test('stopped short', () {
      final g = engine
          .analyze(run([(2000, 4.0)], session: tenK), now: fixedNow)
          .goal!;
      expect(g.reached, isFalse);
      expect(g.goalMs, isNull);
      expect(g.resultLine, 'Stopped at 8.0 km of 10K');
    });

    test('time goal: distance at 30 min of moving time', () {
      final g = engine
          .analyze(
            run(
              [(2000, 4.0)],
              session: thirty,
              pauseAfterS: 600,
              pauseSeconds: 60,
            ),
            now: fixedNow,
          )
          .goal!;
      expect(g.reached, isTrue);
      expect(g.goalDistanceM, closeTo(7200, 0.5));
      expect(g.atRunMs, closeTo(1860000, 2));
      expect(g.resultLine, '30 min: 7.20 km');
    });

    test('a half marathon result shows hours', () {
      final half = SessionSpec.goalDistance(21098, 'Half');
      final g = engine
          .analyze(run([(5300, 4.0)], session: half), now: fixedNow)
          .goal!;
      expect(g.resultLine, 'Half in 1:27:55');
    });
  });

  test('a kill gap before the goal marks the result interrupted '
      '(WARN-G2)', () {
    final r = run([(2500, 4.0)], session: tenK);
    final gapped = r.copyWith(gaps: const [Span(1000000, 1030000)]);
    final g = engine.analyze(gapped, now: fixedNow).goal!;
    expect(g.interrupted, isTrue);
    expect(engine.analyze(r, now: fixedNow).goal!.interrupted, isFalse);
    // A gap in the cool-down, after the goal, does not count.
    final late = run([
      (2500, 4.0),
      (600, 2.0),
    ], session: tenK).copyWith(gaps: const [Span(2800000, 2830000)]);
    expect(engine.analyze(late, now: fixedNow).goal!.interrupted, isFalse);
    expect(
      carriesEstimateMarker(GoalResult.interruptedNote),
      isFalse,
      reason: 'no research number in it; plain copy',
    );
  });

  test('derived data is versioned: old index data refills once (WARN-G1)', () {
    final r = run([(2500, 4.0)], mode: RunMode.free);
    final d = RunDerived.of(r, engine.analyze(r, now: fixedNow));
    expect(d.version, RunDerived.currentVersion);
    expect(d.isCurrent, isTrue);
    final old = Map<String, Object?>.of(d.toJson())..remove('v');
    final back = RunDerived.fromJson(old);
    expect(back.version, 1);
    expect(back.isCurrent, isFalse);
  });

  group('best efforts and boards', () {
    test('a goal run is searched whole; half and marathon windows', () {
      final r = run([
        (10600, 4.0),
      ], session: SessionSpec.goalDistance(42195, 'Marathon'));
      final a = engine.analyze(r, now: fixedNow);
      final be = const BestEffortFinder().find(r, a);
      expect(be.efforts[BestEffortDistance.half]!.elapsedMs, 5274375);
      expect(be.efforts[BestEffortDistance.marathon]!.elapsedMs, 10548750);
      expect(be.fromStartSplitsMs, hasLength(42), reason: 'a marathon ghost');
    });

    test('most distance in 30 and 60 minutes', () {
      // 10 min easy, 30 min hard, 30 min easy.
      final r = run([(600, 3.0), (1800, 4.0), (1800, 3.0)], mode: RunMode.free);
      final be = const BestEffortFinder().find(
        r,
        engine.analyze(r, now: fixedNow),
      );
      expect(be.distances[BestTimeWindow.min30]!.metres, closeTo(7200, 0.01));
      expect(be.distances[BestTimeWindow.min30]!.startMs, 600000);
      // Best hour holds all 30 hard minutes: 7200 + 1800 × 3.
      expect(be.distances[BestTimeWindow.min60]!.metres, closeTo(12600, 0.01));
      final back = RunBestEfforts.fromJson(
        jsonDecode(jsonEncode(be.toJson())) as Map<String, Object?>,
      );
      expect(back.distances[BestTimeWindow.min60]!.metres, closeTo(12600, 0.1));
    });

    test('a run under 30 min has no time board entry', () {
      final r = run([(1700, 4.0)], mode: RunMode.free);
      final be = const BestEffortFinder().find(
        r,
        engine.analyze(r, now: fixedNow),
      );
      expect(be.distances, isEmpty);
    });

    test(
      'boards: time boards rank higher-is-better; a goal key is no board',
      () {
        final day = DateTime.utc(2026, 9, 1);
        BoardInput input(String id, double m30) => BoardInput(
          runId: id,
          date: day,
          mode: RunMode.intervals,
          comparisonKey: 'goal:t1800',
          distances: {
            BestTimeWindow.min30: BestDistance(
              window: BestTimeWindow.min30,
              metres: m30,
              startMs: 0,
              startOffsetM: 0,
            ),
          },
        );
        final boards = Leaderboards.fold([input('a', 6800), input('b', 7200)]);
        expect(boards.keys, ['be:t1800']);
        final b = boards['be:t1800']!;
        expect(b.kind, BoardKind.distanceInTime);
        expect(b.pb!.runId, 'b');
      },
    );

    test('goal runs seed predictions from their 5K and 10K, never the whole '
        'run (it has a cool-down)', () {
      final r = run([(2500, 4.0), (600, 2.0)], session: tenK);
      final a = engine.analyze(r, now: fixedNow);
      final inputs = PredictionInput.ofRun(
        r,
        a,
        const BestEffortFinder().find(r, a),
        localDate: DateTime(2026, 9, 26),
      );
      expect(inputs.map((i) => i.kind), [
        PredictionSourceKind.bestEffort5k,
        PredictionSourceKind.bestEffort10k,
      ]);
    });
  });

  group('founder answers 26-Sep: targets, headline, custom boards', () {
    final now = DateTime(2026, 9, 26, 9);
    const predictor = Predictor(names: EventNames(parkrun: 'parkrun'));
    PredictionInput input(double m, int s, PredictionSourceKind k) =>
        PredictionInput(
          runId: 'i$m',
          date: DateTime(2026, 9, 12),
          distanceM: m,
          elapsedMs: s * 1000,
          kind: k,
        );
    final fiveK = input(5000, 1500, PredictionSourceKind.bestEffort5k);
    final tenKIn = input(10000, 2700, PredictionSourceKind.bestEffort10k);
    final halfIn = input(21097.5, 6000, PredictionSourceKind.bestEffortHalf);

    test('up to 10 km: the §3.4 prediction', () {
      final t = predictor.goalTarget(tenK, [fiveK], now: now)!;
      expect(t.long, isFalse);
      expect(t.line, 'Target 52:07 (predicted)');
    });

    test('half: a wider-band estimate from a 10 km+ effort', () {
      final half = SessionSpec.goalDistance(21098, 'Half');
      final t = predictor.goalTarget(half, [fiveK, tenKIn], now: now)!;
      expect(t.long, isTrue);
      expect(t.line, 'Target about 1:39:17 (1:38:33 to 1:40:47), estimate');
      expect(carriesEstimateMarker(t.line), isTrue);
    });

    test('marathon: Vickers average 1.07, band 1.05 to 1.12', () {
      final m = SessionSpec.goalDistance(42195, 'Marathon');
      final t = predictor.goalTarget(m, [halfIn], now: now)!;
      expect(t.line, 'Target about 3:29:57 (3:27:03 to 3:37:21), estimate');
    });

    test('no target beyond 10 km without a 10 km+ run in 6 weeks', () {
      final half = SessionSpec.goalDistance(21098, 'Half');
      expect(predictor.goalTarget(half, [fiveK], now: now), isNull);
      final old = PredictionInput(
        runId: 'old',
        date: DateTime(2026, 7, 1),
        distanceM: 10000,
        elapsedMs: 2700000,
        kind: PredictionSourceKind.bestEffort10k,
      );
      expect(predictor.goalTarget(half, [fiveK, old], now: now), isNull);
    });

    test('time goals: predicted distance; an hour is a long estimate', () {
      expect(
        predictor.goalTarget(thirty, [fiveK], now: now)!.line,
        'Target 5.94 km (predicted)',
      );
      final hour = SessionSpec.goalTime(3600, '1 hour');
      final t = predictor.goalTarget(hour, [tenKIn], now: now)!;
      expect(t.long, isTrue);
      expect(t.line, 'Target about 13.1 km (13.1 to 13.2 km), estimate');
      expect(predictor.goalTarget(hour, [fiveK], now: now), isNull);
    });

    test('headline: result, rank, gap to best; no verdict word', () {
      final g = engine
          .analyze(run([(2952, 3.3898)], session: tenK), now: fixedNow)
          .goal!;
      final day = DateTime.utc(2026, 9, 1);
      Leaderboard board(List<(String, double)> rows) =>
          Leaderboard.of('be:10000', BoardKind.bestEffort, [
            for (final (id, sec) in rows)
              BoardRun(runId: id, date: day, metric: sec),
          ], metres: 10000);
      final secs = g.goalMs! / 1000;
      expect(
        goalHeadline(
          g,
          board([('a', secs - 38), ('b', secs + 10), ('c', secs + 20)]),
          'me',
        ),
        '${g.resultLine} · #2 of 4 · 38 s off your best',
      );
      expect(
        goalHeadline(g, board([('a', secs + 12)]), 'me'),
        '${g.resultLine} · #1 of 2 · new best, 12 s faster',
      );
      expect(goalHeadline(g, board(const []), 'me'), g.resultLine);
    });

    test('custom goals get their own board, keyed to 0.1 km', () {
      final custom = SessionSpec.goalDistance(12345, '12.3 km');
      expect(ComparisonKey.of(custom), 'goal:d12300');
      expect(GoalCatalogue.boardKeyOf(custom), 'goal:d12300');
      expect(GoalCatalogue.boardKeyOf(tenK), 'be:10000');
      expect(GoalCatalogue.boardKeyOf(thirty), 'be:t1800');
      expect(
        GoalCatalogue.boardKeyOf(SessionSpec.goalTime(2700, '45 min')),
        'goal:t2700',
      );
      final day = DateTime.utc(2026, 9, 1);
      GoalResult result(int ms) => GoalResult(
        kind: GoalKind.distance,
        target: 12345,
        name: '12.3 km',
        reached: true,
        goalMs: ms,
        stoppedAtM: 12400,
      );
      final boards = Leaderboards.fold([
        for (final (id, ms) in [('a', 3700000), ('b', 3650000)])
          BoardInput(
            runId: id,
            date: day,
            mode: RunMode.intervals,
            comparisonKey: 'goal:d12300',
            goal: result(ms),
            goalBoardKey: 'goal:d12300',
          ),
      ]);
      final b = boards['goal:d12300']!;
      expect(b.kind, BoardKind.goalDistance);
      expect(b.pb!.runId, 'b');
      expect(Leaderboards.metresOf('goal:d12300'), 12300);
    });
  });
}
