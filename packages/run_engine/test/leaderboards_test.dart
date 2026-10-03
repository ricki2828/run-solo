import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 4 LB2 (plan §3.1): boards, membership, rank, PB, last 5, trend,
/// heat column, the reserved `be:` prefix, and the per-run live figures
/// (BLOCK-2) with the shared Dart/Kotlin fixture.
void main() {
  final day0 = DateTime.utc(2026, 7, 1, 7);
  DateTime day(int n) => day0.add(Duration(days: n));

  BestEffort be(BestEffortDistance d, int seconds) => BestEffort(
    distance: d,
    elapsedMs: seconds * 1000,
    startMs: 0,
    startOffsetM: 0,
    splitsMs: const [],
  );

  BoardInput free(
    String id,
    int n,
    int fiveK, {
    double? heat,
    double grade = 1,
  }) => BoardInput(
    runId: id,
    date: day(n),
    mode: RunMode.free,
    efforts: {
      BestEffortDistance.k5: BestEffort(
        distance: BestEffortDistance.k5,
        elapsedMs: fiveK * 1000,
        startMs: 0,
        startOffsetM: 0,
        splitsMs: const [],
        gradeFactor: grade,
      ),
    },
    heatFraction: heat,
  );

  group('rank, PB, ties, last 5', () {
    final boards = Leaderboards.fold([
      free('a', 0, 1500),
      free('b', 10, 1480),
      free('c', 20, 1480),
      free('d', 30, 1520),
      free('e', 40, 1470),
      free('f', 50, 1490),
    ]);
    final b = boards['be:5000']!;

    test('lower time ranks higher; ties go to the earlier date', () {
      expect(b.ranked.map((r) => r.runId), ['e', 'b', 'c', 'f', 'a', 'd']);
      expect(b.rankOf('c'), 3);
      expect(b.rankOf('zz'), isNull);
      expect(b.pb!.runId, 'e');
      expect(b.length, 6);
    });

    test('last 5 newest first', () {
      expect(b.last5.map((r) => r.runId), ['f', 'e', 'd', 'c', 'b']);
    });
  });

  group('trend', () {
    test('Theil–Sen over the last 8, per month, as pace', () {
      // 5K 10 s faster every 30 days = 2 s/km per month faster.
      final runs = [
        for (var i = 0; i < 5; i++) free('r$i', i * 15, 1500 - i * 5),
      ];
      final t = Leaderboards.fold(runs)['be:5000']!.trend(day(60))!;
      expect(t.perMonth, closeTo(-2, 1e-9));
      expect(t.entries, 5);
    });

    test('an outlier barely moves it', () {
      final runs = [
        for (var i = 0; i < 6; i++) free('r$i', i * 10, 1500 - i * 5),
        free('bad', 65, 1800),
      ];
      final t = Leaderboards.fold(runs)['be:5000']!.trend(day(70))!;
      expect(t.perMonth, lessThan(0));
    });

    test('fewer than 4 entries in 90 days → no trend', () {
      final runs = [
        free('old1', 0, 1500),
        free('old2', 5, 1490),
        free('new1', 100, 1480),
        free('new2', 110, 1470),
        free('new3', 120, 1460),
      ];
      expect(Leaderboards.fold(runs)['be:5000']!.trend(day(125)), isNull);
    });

    test('Cooper trends in VO2 per month, higher is better', () {
      final runs = [
        for (var i = 0; i < 4; i++)
          BoardInput(
            runId: 'c$i',
            date: day(i * 30),
            mode: RunMode.cooper,
            comparisonKey: ComparisonKey.cooper,
            cooperVo2: 45.0 + i,
          ),
      ];
      final b = Leaderboards.fold(runs)['cooper']!;
      expect(b.kind, BoardKind.cooper);
      expect(b.pb!.runId, 'c3');
      expect(b.trend(day(90))!.perMonth, closeTo(1, 1e-9));
    });
  });

  group('membership (WARN-8)', () {
    test('a parkrun counts on be:* and its course board; official time '
        'wins on the course board', () {
      final m = Leaderboards.membership(
        BoardInput(
          runId: 'p',
          date: day(0),
          mode: RunMode.intervals,
          comparisonKey: ComparisonKey.parkrunOf(courseId: 'albert'),
          efforts: {
            BestEffortDistance.k5: be(BestEffortDistance.k5, 1470),
            BestEffortDistance.km1: be(BestEffortDistance.km1, 280),
          },
          officialTimeMs: 1466000,
        ),
      );
      expect(m.keys.toSet(), {'be:5000', 'be:1000', 'parkrun:albert'});
      expect(m['parkrun:albert']!.metric, 1466);
      expect(m['be:5000']!.metric, 1470);
      // The 'official' tag on the board card and table (LB3c/d).
      expect(m['parkrun:albert']!.official, isTrue);
      expect(m['be:5000']!.official, isFalse);
    });

    test('a parkrun with no course (before K1) is on be:* only', () {
      final m = Leaderboards.membership(
        BoardInput(
          runId: 'p',
          date: day(0),
          mode: RunMode.intervals,
          comparisonKey: ComparisonKey.parkrun,
          efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, 1470)},
        ),
      );
      expect(m.keys, ['be:5000']);
    });

    test('interval boards take verdict-grade sets only', () {
      BoardInput s({required bool grade}) => BoardInput(
        runId: 's',
        date: day(0),
        mode: RunMode.intervals,
        comparisonKey: 't240x*',
        headlineSecPerKm: 262,
        verdictGrade: grade,
      );
      expect(Leaderboards.membership(s(grade: true)).keys, ['t240x*']);
      expect(Leaderboards.membership(s(grade: false)), isEmpty);
    });

    test('the twin is t x hills x (1 - heat); the actual time stays', () {
      final boards = Leaderboards.fold([
        free('hot', 0, 1500, heat: 0.05),
        free('cool', 1, 1490),
      ]);
      final b = boards['be:5000']!;
      // Ranked by true time: the hot 1500 s is 1425 s once the heat is out.
      expect(b.pb!.runId, 'hot');
      expect(b.pb!.metric, 1500);
      expect(b.pb!.adjMetric, closeTo(1425, 1e-9));
      // No weather: the twin is the actual time, never missing.
      expect(b.ranked.last.adjMetric, 1490);
    });

    test('a flat, cool run: the twin is exactly the actual time', () {
      final b = Leaderboards.fold([free('flat', 0, 1490, heat: 0)])['be:5000']!;
      expect(b.pb!.adjMetric, b.pb!.metric);
      expect(b.onRawValue(b.pb!), isFalse);
    });

    test('a comparison key on the reserved be: prefix is refused', () {
      expect(
        () => Leaderboards.membership(
          BoardInput(
            runId: 'x',
            date: day(0),
            mode: RunMode.intervals,
            comparisonKey: 'be:5000',
          ),
        ),
        throwsStateError,
      );
      expect(ComparisonKey.reservedBoardPrefix, BestEffortDistance.keyPrefix);
      for (final spec in [
        SessionSpec.norwegian4x4(),
        SessionSpec.cooper,
        SessionSpec.fartlek,
      ]) {
        expect(ComparisonKey.of(spec).startsWith('be:'), isFalse);
      }
    });
  });

  group('true pace boards', () {
    test('rank by the twin; the actual time stays alongside', () {
      final runs = [
        free('hot', 0, 1500, heat: 0.05), // 1425 true
        free('cool', 1, 1490, heat: 0), // 1490
        free('none', 2, 1450), // no weather: neutral, 1450
      ];
      final b = Leaderboards.fold(runs)['be:5000']!;
      expect(b.trueRanked, isTrue);
      expect(b.ranked.map((r) => r.runId), ['hot', 'none', 'cool']);
      expect(b.pb!.metric, 1500);
      expect(b.rankValue(b.pb!), closeTo(1425, 1e-9));
      // The actual-time board is still one flag away.
      final raw = Leaderboards.fold(runs, trueRanked: false)['be:5000']!;
      expect(raw.ranked.map((r) => r.runId), ['none', 'cool', 'hot']);
    });

    test('hills count: a 5K up a hill outranks a faster flat one', () {
      final b = Leaderboards.fold([
        free('flat', 0, 1450),
        free('hilly', 1, 1550, grade: 0.88), // 1364 true
      ])['be:5000']!;
      expect(b.pb!.runId, 'hilly');
      expect(b.pb!.adjMetric, closeTo(1364, 1e-9));
      // Hills and heat multiply.
      final both = Leaderboards.fold([
        free('x', 0, 1500, heat: 0.05, grade: 0.9),
      ])['be:5000']!;
      expect(both.pb!.adjMetric, closeTo(1500 * 0.95 * 0.9, 1e-9));
    });

    test('a PB never drops off a board: it just ranks on what it was', () {
      final b = Leaderboards.fold([
        free('pb', 0, 1400), // no weather, flat: the actual PB
        free('hot', 1, 1500, heat: 0.05),
      ])['be:5000']!;
      expect(b.length, 2);
      expect(b.pb!.runId, 'pb');
    });

    test('course boards rank the true official time', () {
      BoardInput course(String id, int n, int ms, double? heat) => BoardInput(
        runId: id,
        date: day(n),
        mode: RunMode.intervals,
        comparisonKey: ComparisonKey.parkrunOf(courseId: 'c1'),
        officialTimeMs: ms,
        heatFraction: heat,
      );
      final key = ComparisonKey.parkrunOf(courseId: 'c1');
      final b = Leaderboards.fold([
        course('a', 0, 1500000, 0.06), // 1410
        course('b', 1, 1440000, 0),
      ])[key]!;
      expect(b.pb!.runId, 'a');
    });

    test('interval boards: the work pace with its own hills and the heat', () {
      final m = Leaderboards.membership(
        BoardInput(
          runId: 's',
          date: day(0),
          mode: RunMode.intervals,
          comparisonKey: 't240x*',
          headlineSecPerKm: 300,
          verdictGrade: true,
          heatFraction: 0.05,
          headlineGradeFactor: 0.9,
        ),
      );
      expect(m['t240x*']!.metric, 300);
      expect(m['t240x*']!.adjMetric, closeTo(300 * 0.9 * 0.95, 1e-9));
    });

    test('distance in time: hills and heat make the twin longer', () {
      final m = Leaderboards.membership(
        BoardInput(
          runId: 'd',
          date: day(0),
          mode: RunMode.free,
          distances: {
            BestTimeWindow.min30: BestDistance(
              window: BestTimeWindow.min30,
              metres: 5000,
              startMs: 0,
              startOffsetM: 0,
              gradeFactor: 0.9,
            ),
          },
          heatFraction: 0.05,
        ),
      );
      expect(m['be:t1800']!.adjMetric, closeTo(5000 / (0.9 * 0.95), 1e-6));
    });

    test('Cooper ranks the adjusted VO2, higher is better', () {
      BoardInput test(String id, int n, double vo2, double? adj) => BoardInput(
        runId: id,
        date: day(n),
        mode: RunMode.cooper,
        comparisonKey: ComparisonKey.cooper,
        cooperVo2: vo2,
        cooperVo2Adj: adj,
      );
      final b = Leaderboards.fold([
        test('hot', 0, 47, 50),
        test('cool', 1, 48, 48),
      ])['cooper']!;
      expect(b.pb!.runId, 'hot');
      // A run with no usable weather keeps its raw value.
      final c = Leaderboards.fold([
        test('dry', 2, 49, null),
        test('hot2', 3, 47, 50),
      ])['cooper']!;
      expect(c.pb!.runId, 'hot2');
      expect(
        c.onRawValue(c.ranked.firstWhere((r) => r.runId == 'dry')),
        isTrue,
      );
      expect(c.rankValue(c.ranked.firstWhere((r) => r.runId == 'dry')), 49);
    });

    test('the trend reads the twin', () {
      // Actual 5K flat at 1500; heat falls away, so true gets slower.
      final runs = [
        for (var i = 0; i < 5; i++)
          free('r$i', i * 15, 1500, heat: 0.04 - i * 0.01),
      ];
      final actual = Leaderboards.fold(
        runs,
        trueRanked: false,
      )['be:5000']!.trend(day(60))!;
      final truePace = Leaderboards.fold(runs)['be:5000']!.trend(day(60))!;
      expect(actual.perMonth, closeTo(0, 1e-9));
      expect(truePace.perMonth, greaterThan(0));
    });

    test('a custom goal board carries a twin from the whole run', () {
      BoardInput goal(double heat) => BoardInput(
        runId: 'g',
        date: day(0),
        mode: RunMode.intervals,
        comparisonKey: '${ComparisonKey.goalPrefix}d3000',
        goalBoardKey: '${ComparisonKey.goalPrefix}d3000',
        goal: const GoalResult(
          kind: GoalKind.distance,
          target: 3000,
          name: '3 km',
          reached: true,
          goalMs: 900000,
          stoppedAtM: 3000,
        ),
        heatFraction: heat,
        gradeFactor: 0.95,
      );
      final m = Leaderboards.membership(goal(0.05))['goal:d3000']!;
      expect(m.metric, 900);
      expect(m.adjMetric, closeTo(900 * 0.95 * 0.95, 1e-9));
    });
  });

  group('live figures (BLOCK-2)', () {
    final fx = jsonDecode(
      File('test/fixtures/phase4/live_rep_paces.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final expected = fx['expected']! as Map<String, Object?>;
    final paces = [
      for (final p in expected['rep_paces_s_per_km']! as List)
        (p as num).toDouble(),
    ];

    for (final which in ['run', 'run_pre_lv0']) {
      test('shared fixture $which: untrimmed rep paces from the stream at '
          'lap time', () {
        final run = RunFile.fromJson(fx[which]! as Map<String, Object?>);
        final a = engine.analyze(run, now: fixedNow);
        expect(a.intervals!.reps, hasLength(3));
        final live = LiveFigures.of(run, a);
        expect(live.repPacesSecPerKm, hasLength(3));
        for (var i = 0; i < 3; i++) {
          expect(live.repPacesSecPerKm[i], closeTo(paces[i], 0.1));
        }
      });
    }

    test('an unclean rep is null', () {
      final f = fixture('gps_dropout_rep2');
      final a = engine.analyze(f.run, now: fixedNow);
      final live = LiveFigures.of(f.run, a);
      final reps = a.intervals!.reps;
      for (var i = 0; i < reps.length; i++) {
        expect(live.repPacesSecPerKm[i] == null, !reps[i].clean);
      }
      expect(live.repPacesSecPerKm.whereType<double>(), isNotEmpty);
    });

    test('Cooper minute marks from the Kotlin contract run', () {
      final run = RunFile.fromJson(
        jsonDecode(
          File('test/fixtures/contract/cooper_12min.json').readAsStringSync(),
        ) as Map<String, Object?>,
      );
      final a = engine.analyze(run, now: fixedNow);
      final live = LiveFigures.of(run, a);
      expect(live.cooperMinuteM, hasLength(12));
      expect(live.cooperMinuteM.last, closeTo(run.distanceM, 0.01));
      for (var i = 1; i < 12; i++) {
        expect(live.cooperMinuteM[i], greaterThan(live.cooperMinuteM[i - 1]));
      }
      expect(live.repPacesSecPerKm, isEmpty);
    });

    test('a paused Cooper gives no minute marks, never a partial list', () {
      final raw = jsonDecode(
        File('test/fixtures/contract/cooper_12min.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final run = RunFile.fromJson(raw)
          .copyWith(pauses: const [Span(300000, 330000)]);
      final live = LiveFigures.of(run, engine.analyze(run, now: fixedNow));
      expect(live.cooperMinuteM, isEmpty);
    });

    test('RunDerived JSON round trip', () {
      final f = fixture('preset_4x4_auto_standard');
      final a = engine.analyze(f.run, now: fixedNow);
      final d = RunDerived.of(
        f.run,
        a,
        nudgesFired: const [FiredNudge('rep_fade', 3)],
      );
      final back = RunDerived.fromJson(
        jsonDecode(jsonEncode(d.toJson())) as Map<String, Object?>,
      );
      expect(jsonEncode(back.toJson()), jsonEncode(d.toJson()));
      expect(back.nudgesFired.single.rule, 'rep_fade');
      expect(back.live.repPacesSecPerKm, hasLength(4));
    });
  });
}
