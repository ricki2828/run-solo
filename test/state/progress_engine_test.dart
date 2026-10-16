import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/progress/seen_moments_store.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// Direction B engine: level, pack, streak, firsts, ghost, story, moments.
void main() {
  // A Monday, local time.
  final now = DateTime(2026, 10, 12, 9);

  var n = 0;
  RunSummary run(
    DateTime start, {
    double km = 5,
    int minutes = 30,
    RecordMode mode = RecordMode.free,
  }) => summary(
    id: 'r${n++}',
    start: start,
    mode: mode,
    fourByFour: false,
    durationMs: minutes * 60000,
    distanceM: km * 1000,
  );

  ProgressSnapshot build(
    List<RunSummary> runs, {
    ProfileSex sex = ProfileSex.male,
    int? birthYear = 1980,
    Set<String> seen = const {},
    DateTime? at,
    Map<String, engine.Leaderboard> boards = const {},
  }) => buildProgressSnapshot(
    runs,
    now: at ?? now,
    sex: sex,
    birthYear: birthYear,
    seenMoments: seen,
    leaderboards: boards,
  );

  FirstMilestone first(ProgressSnapshot s, String id) =>
      s.firsts.firstWhere((f) => f.id == id);

  group('basics', () {
    test('no runs is the empty snapshot', () {
      final s = build(const []);
      expect(s.runCount, 0);
      expect(s.firsts, isEmpty);
      expect(s.pending, isEmpty);
    });

    test('is deterministic', () {
      final runs = [
        run(DateTime(2026, 10, 1, 7)),
        run(DateTime(2026, 10, 8, 7)),
      ];
      final a = build(runs), b = build(runs);
      expect(a.level.level, b.level.level);
      expect(a.pending.map((m) => m.id), b.pending.map((m) => m.id));
    });
  });

  group('null profile', () {
    final runs = [run(DateTime(2026, 10, 8, 7))];

    test('no sex: no pack, no age grade, level still moves', () {
      final s = build(runs, sex: ProfileSex.notSet);
      expect(s.pack, isNull);
      expect(s.level.ageGradePct, isNull);
      expect(s.level.level, greaterThan(0));
    });

    test('no birth year: no pack, no age grade', () {
      final s = build(runs, birthYear: null);
      expect(s.pack, isNull);
      expect(s.level.ageGradePct, isNull);
    });

    test('prefer not to say behaves as not set', () {
      expect(build(runs, sex: ProfileSex.preferNot).pack, isNull);
    });
  });

  group('level', () {
    test('calibrating until 5 runs or a hard effort', () {
      final runs = [
        for (var i = 0; i < 4; i++) run(DateTime(2026, 10, 1 + i * 2, 7)),
      ];
      final s = build(runs);
      expect(s.level.calibrating, isTrue);
      expect(s.level.runsToSettle, 1);
      final more = build([...runs, run(DateTime(2026, 10, 10, 7))]);
      expect(more.level.calibrating, isFalse);
      expect(more.level.runsToSettle, 0);
    });

    test('a Cooper test settles it at once', () {
      final s = build([
        run(
          DateTime(2026, 10, 8, 7),
          km: 2.7,
          minutes: 12,
          mode: RecordMode.cooper,
        ),
      ]);
      expect(s.level.calibrating, isFalse);
    });

    test('rises with runs 1 to 5', () {
      var prev = 0;
      for (var i = 1; i <= 5; i++) {
        final runs = [
          for (var j = 0; j < i; j++) run(DateTime(2026, 10, 1 + j, 7)),
        ];
        final l = build(runs).level.level;
        expect(l, greaterThan(prev));
        prev = l;
      }
    });

    test('never drops more than one level a month', () {
      final runs = [
        for (var i = 0; i < 12; i++)
          run(DateTime(2026, 8, 1 + i * 2, 7), km: 5, minutes: 24),
      ];
      final peak = build(runs, at: DateTime(2026, 9, 1, 9)).level.level;
      // Five weeks of nothing: the fitness window empties, level eases only.
      final later = build(runs, at: DateTime(2026, 9, 29, 9));
      expect(later.level.level, greaterThanOrEqualTo(peak - 1));
      expect(later.level.levelMonthAgo, isNotNull);
    });

    test('month-ago figures come from the snapshot 28 days back', () {
      final runs = [
        run(DateTime(2026, 9, 1, 7)),
        run(DateTime(2026, 9, 3, 7)),
        run(DateTime(2026, 10, 10, 7)),
      ];
      final s = build(runs);
      expect(s.level.levelMonthAgo, isNotNull);
      expect(s.level.ageGradeMonthAgo, isNotNull);
      expect(
        build([run(DateTime(2026, 10, 10, 7))]).level.levelMonthAgo,
        isNull,
      );
    });
  });

  group('pack', () {
    test('band, percentile and histogram', () {
      final s = build([run(DateTime(2026, 10, 8, 7), km: 5, minutes: 25)]);
      final p = s.pack!;
      expect(p.band, 'M40-49');
      expect(p.percentile, inInclusiveRange(1, 99));
      expect(p.histogram.length, 20);
      expect(p.histogram.every((h) => h >= 0 && h <= 1), isTrue);
      expect(p.youBin, inInclusiveRange(0, 19));
    });

    test('female band, faster means higher percentile', () {
      final slow = build(
        [run(DateTime(2026, 10, 8, 7), km: 5, minutes: 40)],
        sex: ProfileSex.female,
        birthYear: 1991,
      );
      final fast = build(
        [run(DateTime(2026, 10, 8, 7), km: 5, minutes: 24)],
        sex: ProfileSex.female,
        birthYear: 1991,
      );
      expect(slow.pack!.band, 'F30-39');
      expect(fast.pack!.percentile, greaterThan(slow.pack!.percentile));
      expect(fast.pack!.youBin, greaterThan(slow.pack!.youBin));
    });

    test('outside 20 to 89 there is no pack', () {
      expect(
        build([run(DateTime(2026, 10, 8, 7))], birthYear: 2012).pack,
        isNull,
      );
    });
  });

  group('streak', () {
    test('Sunday night and Monday morning are different weeks', () {
      final s = build([
        run(DateTime(2026, 10, 4, 23, 30)),
        run(DateTime(2026, 10, 5, 0, 30)),
      ]);
      expect(s.streak.weeks, 2);
      expect(s.streak.thisWeekDone, isFalse);
    });

    test('two runs in one week count once', () {
      final s = build([
        run(DateTime(2026, 10, 5, 7)),
        run(DateTime(2026, 10, 11, 20)),
      ]);
      expect(s.streak.weeks, 1);
    });

    test('this week done, recent has 8 weeks', () {
      final s = build([run(DateTime(2026, 10, 12, 7))]);
      expect(s.streak.thisWeekDone, isTrue);
      expect(s.streak.recent.length, 8);
      expect(s.streak.recent.last, engine.StreakWeek.ran);
    });

    test('a freeze covers one missed week', () {
      // Four weeks in a row (Sep 7 to Sep 28) earn one; Oct 5 missed.
      final s = build([
        for (var w = 0; w < 4; w++) run(DateTime(2026, 9, 7 + w * 7, 7)),
        run(DateTime(2026, 10, 12, 7)),
      ]);
      expect(s.streak.weeks, 5);
      expect(s.streak.freezesReady, 0);
      expect(s.streak.recent[6], engine.StreakWeek.frozen);
    });
  });

  group('firsts', () {
    test('15 stable ids in landing order', () {
      final s = build([run(DateTime(2026, 10, 8, 7))]);
      expect(s.firsts.length, kFirstsTotal);
      expect(s.firsts.map((f) => f.id).toList(), [
        'first-run',
        'first-1k',
        'first-3k',
        'first-5k',
        'first-10k',
        'first-half',
        'first-30min',
        'first-60min',
        'first-week',
        'two-weeks',
        'first-month',
        'first-intervals',
        'first-test',
        'first-trail',
        'first-sub30-5k',
      ]);
    });

    test('achievedAt is the run that did it', () {
      final r1 = run(DateTime(2026, 10, 1, 7), km: 2, minutes: 15);
      final r2 = run(DateTime(2026, 10, 3, 7), km: 5.2, minutes: 28);
      final r3 = run(DateTime(2026, 10, 6, 7), km: 5, minutes: 31);
      final s = build([r3, r1, r2]);
      expect(first(s, 'first-run').achievedAt, r1.start);
      expect(first(s, 'first-1k').achievedAt, r1.start);
      expect(first(s, 'first-3k').achievedAt, r2.start);
      expect(first(s, 'first-5k').achievedAt, r2.start);
      expect(first(s, 'first-sub30-5k').achievedAt, r2.start);
      expect(first(s, 'first-30min').achievedAt, r3.start);
      expect(first(s, 'first-10k').done, isFalse);
      expect(first(s, 'first-5k').detail, '28:00 on Sat 3 Oct, run 2');
      expect(first(s, 'first-10k').detail, '');
    });

    test('week firsts wait for the week to finish', () {
      final one = build([run(DateTime(2026, 10, 12, 7))]);
      expect(first(one, 'first-week').done, isFalse);
      final done = build([run(DateTime(2026, 10, 7, 7))]);
      expect(first(done, 'first-week').done, isTrue);
    });

    test('weeks in a row and the first month', () {
      final s = build([
        for (var w = 0; w < 4; w++) run(DateTime(2026, 9, 14 + w * 7, 7)),
      ]);
      expect(first(s, 'two-weeks').achievedAt, DateTime(2026, 9, 21, 7));
      expect(first(s, 'first-month').achievedAt, DateTime(2026, 10, 5, 7));
      final gap = build([
        run(DateTime(2026, 9, 14, 7)),
        run(DateTime(2026, 9, 28, 7)),
      ]);
      expect(first(gap, 'two-weeks').done, isFalse);
    });

    test('mode firsts', () {
      final s = build([
        run(DateTime(2026, 10, 1, 7), mode: RecordMode.trail),
        run(
          DateTime(2026, 10, 2, 7),
          mode: RecordMode.cooper,
          km: 2.5,
          minutes: 12,
        ),
        run(
          DateTime(2026, 10, 3, 7),
          mode: RecordMode.intervals,
          km: 6,
          minutes: 32,
        ),
      ]);
      expect(first(s, 'first-trail').done, isTrue);
      expect(first(s, 'first-test').done, isTrue);
      expect(first(s, 'first-intervals').done, isTrue);
    });
  });

  group('local calendar', () {
    // 1 Oct 07:00 in NZ (+13) and 1 Oct 06:00 in SGT (+8) are still 30 Sep
    // in UTC; the run must read as the 1st of October where it was run.
    for (final (name, offsetMin, hour) in [
      ('NZ', 13 * 60, 7),
      ('SGT', 8 * 60, 6),
    ]) {
      test('first-run on the 1st in $name is labelled with the local date', () {
        final startUtc = DateTime.utc(
          2026,
          10,
          1,
          hour,
        ).subtract(Duration(minutes: offsetMin));
        expect(startUtc.month, 9);
        final s = build([
          RunSummary(
            id: 'tz-$name',
            mode: RecordMode.free,
            start: startUtc,
            durationMs: 30 * 60000,
            distanceM: 5000,
            laps: 0,
            utcOffsetMin: offsetMin,
          ),
        ]);
        expect(first(s, 'first-run').detail, contains('1 Oct'));
        expect(first(s, 'first-run').detail, isNot(contains('Sep')));
      });
    }
  });

  group('ghost', () {
    test('5K this month against a month earlier', () {
      final s = build([
        run(DateTime(2026, 9, 5, 7), km: 5, minutes: 28),
        run(DateTime(2026, 10, 5, 7), km: 5, minutes: 26),
      ]);
      final g = s.ghost!;
      expect(g.label, '5K');
      expect(g.now, const Duration(minutes: 26));
      expect(g.then, const Duration(minutes: 28));
      expect(g.nowLabel, 'Last 4 weeks');
      expect(g.thenLabel, 'The 4 weeks before');
    });

    test('names the span, never a month, even when both runs share one', () {
      final at = DateTime(2026, 10, 30, 9);
      final s = build([
        run(DateTime(2026, 10, 1, 7), km: 5, minutes: 28),
        run(DateTime(2026, 10, 29, 7), km: 5, minutes: 26),
      ], at: at);
      final g = s.ghost!;
      expect(g.nowLabel, isNot(g.thenLabel));
      for (final m in ['Sept', 'Oct']) {
        expect(g.nowLabel, isNot(contains(m)));
        expect(g.thenLabel, isNot(contains(m)));
      }
    });

    test('falls back to 3K, then null without a pair', () {
      final s = build([
        run(DateTime(2026, 9, 5, 7), km: 3.2, minutes: 20),
        run(DateTime(2026, 10, 5, 7), km: 3, minutes: 18),
      ]);
      expect(s.ghost!.label, '3K');
      expect(build([run(DateTime(2026, 10, 5, 7))]).ghost, isNull);
    });
  });

  group('story', () {
    test('null without a run in the last complete week', () {
      expect(build([run(DateTime(2026, 10, 12, 7))]).story, isNull);
    });

    test('biggest week headline and daily breakdown', () {
      final s = build([
        run(DateTime(2026, 9, 29, 7), km: 5, minutes: 30),
        run(DateTime(2026, 10, 5, 7), km: 5, minutes: 30),
        run(DateTime(2026, 10, 7, 7), km: 8, minutes: 48),
        run(DateTime(2026, 10, 11, 7), km: 16, minutes: 100),
      ]);
      final st = s.story!;
      expect(st.weekStart, DateTime(2026, 10, 5));
      expect(st.runs, 3);
      expect(st.km, closeTo(29, 1e-9));
      expect(st.headline, 'Your biggest week yet. 3 runs, 29.0 km.');
      expect(st.dailyKm, [5, 0, 8, 0, 0, 0, 16]);
      expect(st.dailyLane[6], engine.IdentityLane.long);
      expect(st.dailyLane[1], isNull);
      expect(st.laneOfWeek, engine.IdentityLane.long);
    });

    test('plain tally when nothing stands out', () {
      final s = build([
        run(DateTime(2026, 9, 29, 7), km: 10, minutes: 60),
        run(DateTime(2026, 10, 6, 7), km: 5, minutes: 30),
      ]);
      expect(s.story!.headline, '1 run, 5.0 km.');
    });
  });

  group('moments', () {
    final runs = [
      run(DateTime(2026, 10, 1, 7), km: 5, minutes: 28),
      run(DateTime(2026, 10, 5, 7), km: 5, minutes: 27),
    ];

    test('firsts, then story; ids are stable', () {
      final s = build(runs);
      final ids = s.pending.map((m) => m.id).toList();
      expect(ids.first, startsWith('first:'));
      expect(ids, contains('first:first-5k'));
      expect(ids.last, 'story:2026-10-05');
      expect(
        s.pending.map((m) => m.kind).toList(),
        orderedEquals(
          [...s.pending.map((m) => m.kind)]..sort((a, b) => a.index - b.index),
        ),
      );
      expect(build(runs).pending.map((m) => m.id), ids);
    });

    test('seen moments drop out', () {
      final all = build(runs).pending.map((m) => m.id).toSet();
      final left = build(runs, seen: {'first:first-5k', 'story:2026-10-05'});
      expect(
        left.pending.map((m) => m.id).toSet(),
        all.difference({'first:first-5k', 'story:2026-10-05'}),
      );
    });

    test('old firsts do not flood a new install', () {
      final old = [
        for (var i = 0; i < 6; i++) run(DateTime(2026, 6, 1 + i * 3, 7)),
      ];
      final ids = build(old).pending.map((m) => m.id);
      expect(ids.where((i) => i.startsWith('first:')), isEmpty);
    });

    test('a fresh PB on the boards becomes a moment', () {
      final r1 = run(DateTime(2026, 10, 1, 7));
      final r2 = run(DateTime(2026, 10, 9, 7));
      final board = engine.Leaderboard.of(
        'be:5000',
        engine.BoardKind.bestEffort,
        [
          engine.BoardRun(runId: r1.id, date: r1.start, metric: 1650),
          engine.BoardRun(runId: r2.id, date: r2.start, metric: 1590),
        ],
        metres: 5000,
      );
      final s = build([r1, r2], boards: {'be:5000': board});
      final pb = s.pending.firstWhere((m) => m.kind == MomentKind.pb);
      expect(pb.id, 'pb:be:5000:${r2.id}');
      expect(pb.big, '5K');
      expect(pb.detail, contains('26:30'));
    });

    test('a level-up appears once settled', () {
      final many = [
        for (var i = 0; i < 8; i++)
          run(DateTime(2026, 10, 1 + i, 7), minutes: 25),
      ];
      final s = build(many);
      expect(s.pending.any((m) => m.kind == MomentKind.levelUp), isTrue);
      expect(
        s.pending.firstWhere((m) => m.kind == MomentKind.levelUp).id,
        'level:${s.level.level}',
      );
    });
  });

  group('seen store', () {
    test('memory store accumulates', () async {
      final store = MemorySeenMomentsStore({'a'});
      expect(await store.markSeen(['b']), {'a', 'b'});
      expect(await store.load(), {'a', 'b'});
    });

    test('file store round-trips and survives garbage', () async {
      final dir = await Directory.systemTemp.createTemp('seen_moments');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSeenMomentsStore(dir);
      expect(await store.load(), isEmpty);
      await store.markSeen(['x', 'y']);
      expect(await FileSeenMomentsStore(dir).load(), {'x', 'y'});
      await File('${dir.path}/seen_moments.json').writeAsString('not json');
      expect(await store.load(), isEmpty);
    });
  });
}
