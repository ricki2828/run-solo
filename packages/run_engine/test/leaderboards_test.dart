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

  BoardInput free(String id, int n, int fiveK, {double? heat}) => BoardInput(
    runId: id,
    date: day(n),
    mode: RunMode.free,
    efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, fiveK)},
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

    test('the heat column is t × (1 − adj) and never ranks (setting off)', () {
      final boards = Leaderboards.fold([
        free('hot', 0, 1500, heat: 0.05),
        free('cool', 1, 1490),
      ]);
      final b = boards['be:5000']!;
      expect(b.pb!.runId, 'cool');
      expect(b.ranked.last.adjMetric, closeTo(1425, 1e-9));
      expect(b.pb!.adjMetric, isNull);
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

  group('heat-adjusted boards (W2 setting on)', () {
    test('rank by the twin; the raw time stays alongside; a run without '
        'weather stays ranked on its raw time', () {
      final runs = [
        free('hot', 0, 1500, heat: 0.05), // 1425 adjusted
        free('cool', 1, 1490, heat: 0), // 1490
        free('none', 2, 1450), // no weather: ranks on raw 1450
      ];
      final off = Leaderboards.fold(runs)['be:5000']!;
      expect(off.heatAdjusted, isFalse);
      expect(off.ranked.map((r) => r.runId), ['none', 'cool', 'hot']);
      expect(off.ranked.any(off.onRawValue), isFalse);

      final on = Leaderboards.fold(runs, heatAdjusted: true)['be:5000']!;
      expect(on.heatAdjusted, isTrue);
      expect(on.ranked.map((r) => r.runId), ['hot', 'none', 'cool']);
      expect(on.pb!.metric, 1500);
      expect(on.rankValue(on.pb!), closeTo(1425, 1e-9));
      final none = on.ranked[1];
      expect(on.onRawValue(none), isTrue);
      expect(on.rankValue(none), 1450);
      expect(on.onRawValue(on.pb!), isFalse);
    });

    test('a no-weather PB never drops off because of the setting', () {
      final on = Leaderboards.fold([
        free('pb', 0, 1400), // no weather, the raw PB
        free('hot', 1, 1500, heat: 0.05),
      ], heatAdjusted: true)['be:5000']!;
      expect(on.length, 2);
      expect(on.pb!.runId, 'pb');
      expect(on.onRawValue(on.pb!), isTrue);
    });

    test('course boards rank the adjusted official time', () {
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
      ], heatAdjusted: true)[key]!;
      expect(b.pb!.runId, 'a');
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
      ], heatAdjusted: true)['cooper']!;
      expect(b.pb!.runId, 'hot');
    });

    test('the trend reads the twin', () {
      // Raw 5K flat at 1500; heat falls away, so adjusted gets slower.
      final runs = [
        for (var i = 0; i < 5; i++)
          free('r$i', i * 15, 1500, heat: 0.04 - i * 0.01),
      ];
      final raw = Leaderboards.fold(runs)['be:5000']!.trend(day(60))!;
      final adj = Leaderboards.fold(
        runs,
        heatAdjusted: true,
      )['be:5000']!.trend(day(60))!;
      expect(raw.perMonth, closeTo(0, 1e-9));
      expect(adj.perMonth, greaterThan(0));
    });

    test('a custom goal board has no twin and stays raw', () {
      expect(Leaderboards.hasHeatTwin('goal:d3000'), isFalse);
      expect(Leaderboards.hasHeatTwin('be:5000'), isTrue);
      final b = Leaderboard.of(
        'goal:d3000',
        BoardKind.goalDistance,
        [BoardRun(runId: 'g', date: day(0), metric: 900)],
        metres: 3000,
        heatAdjusted: true,
      );
      expect(b.heatAdjusted, isFalse);
      expect(b.ranked, hasLength(1));
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
