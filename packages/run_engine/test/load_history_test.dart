import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

// Monday 26 Oct 2026, a Wednesday is the 28th.
final now = DateTime(2026, 10, 28, 9);
final thisMonday = DateTime(2026, 10, 26);

/// A 40 minute, assumed-weight (2.5) run: load 100.
LoadRun run(DateTime start, {double min = 40, double km = 6.5}) =>
    LoadRun(start: start, movingMin: min, distanceM: km * 1000);

/// [n] runs of load 100 each on the Monday of [weeksAgo] weeks before this one.
List<LoadRun> week(int weeksAgo, int n) => [
  for (var i = 0; i < n; i++) run(DateTime(2026, 10, 26 - 7 * weeksAgo, 7 + i)),
];

/// A history where each of the 4 weeks before [last] has load 100 x [usualN],
/// and the week [lastWeeksAgo] has [n] runs. `now` is in the week after.
LoadCompare compareFor(int n, {int usualN = 4}) {
  final runs = [for (var k = 2; k <= 5; k++) ...week(k, usualN), ...week(1, n)];
  // Drop the current part week: judge the last complete one.
  final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
  return LoadCompare.of(ws.sublist(0, ws.length - 1));
}

void main() {
  group('bands', () {
    // usual 400 (4 runs x 100). ratio = load / 400.
    LoadBand? band(int n) => compareFor(n).band;
    test('0.79 is lighter, 0.8 is usual', () {
      // load 316 / 320 via minutes instead of run counts
      final runs = [
        for (var k = 2; k <= 5; k++) ...week(k, 4),
        run(DateTime(2026, 10, 19, 7), min: 126.4), // 316 = 0.79
      ];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(LoadCompare.of(ws.sublist(0, 5)).band, LoadBand.lighter);
      final runs2 = [
        for (var k = 2; k <= 5; k++) ...week(k, 4),
        run(DateTime(2026, 10, 19, 7), min: 128), // 320 = 0.8
      ];
      final ws2 = LoadHistory.weeks(runs2, now: now, weeks: 6);
      expect(LoadCompare.of(ws2.sublist(0, 5)).band, LoadBand.usual);
    });
    test('1.1 is usual, above is stepUp', () {
      expect(LoadCompare.bandOf(1.1), LoadBand.usual);
      expect(LoadCompare.bandOf(1.11), LoadBand.stepUp);
    });
    test('1.3 is stepUp, 1.31 is bigJump, like the guard', () {
      expect(LoadCompare.bandOf(1.3), LoadBand.stepUp);
      expect(LoadCompare.bandOf(1.31), LoadBand.bigJump);
      expect(LoadCompare.bandOf(LoadGuard.loadRatio + 0.001), LoadBand.bigJump);
    });
    test('whole run counts', () {
      expect(band(4), LoadBand.usual);
      expect(band(2), LoadBand.lighter);
      expect(band(5), LoadBand.stepUp);
      expect(band(6), LoadBand.bigJump);
    });
    test('1.9 reads as double, not 190% more', () {
      final c = compareFor(8, usualN: 4); // ratio 2.0
      final w = LoadHistory.weeks(
        [for (var k = 2; k <= 5; k++) ...week(k, 4), ...week(1, 8)],
        now: now,
        weeks: 6,
      );
      expect(
        LoadWords.headline(w[4], c),
        '800 load, about double your usual week (400).',
      );
      expect(
        loadVsUsualPhrase(1.89, 'your usual week', 'your usual week'),
        '89% more than your usual week',
      );
      expect(
        loadVsUsualPhrase(1.9, 'your usual week', 'your usual week'),
        'about double your usual week',
      );
    });
  });

  group('usual week rules', () {
    test('a paused week is skipped, not counted as 0', () {
      final runs = [
        ...week(2, 4),
        ...week(4, 4),
        ...week(5, 4),
        ...week(1, 4),
      ]; // week 3 has no runs but is paused
      final paused = {ProgressMath.weekIndex(DateTime(2026, 10, 5))};
      final ws = LoadHistory.weeks(
        runs,
        now: now,
        weeks: 6,
        pausedWeeks: paused,
      );
      final c = LoadCompare.of(ws.sublist(0, 5));
      expect(ws[2].paused, isTrue);
      expect(c.usual, 400);
      expect(c.band, LoadBand.usual);
    });
    test('an empty unpaused week is left out, not counted as 0', () {
      final runs = [...week(2, 4), ...week(4, 4), ...week(5, 4), ...week(1, 4)];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      final c = LoadCompare.of(ws.sublist(0, 5));
      expect(c.usual, 400);
      expect(c.band, LoadBand.usual);
    });
    test('weeks before the first run are skipped', () {
      final runs = [...week(2, 4), ...week(3, 4), ...week(4, 4), ...week(1, 4)];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(ws[0].beforeStart, isTrue);
      expect(ws[1].beforeStart, isFalse);
      final c = LoadCompare.of(ws.sublist(0, 5));
      expect(c.state, LoadCompareState.ok);
      expect(c.usual, 400);
    });
    test('under 3 counted weeks with runs is firstWeeks', () {
      final runs = [...week(2, 4), ...week(1, 4)];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(
        LoadCompare.of(ws.sublist(0, 5)).state,
        LoadCompareState.firstWeeks,
      );
    });
    test('a first run on a Sunday: the part week is left out of usual', () {
      final sunday = run(DateTime(2026, 9, 27, 7)); // week of 21 Sep
      final runs = [
        sunday,
        ...week(4, 4),
        ...week(3, 4),
        ...week(2, 4),
        ...week(1, 4),
      ];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(ws[0].partialStart, isTrue);
      final c = LoadCompare.of(ws.sublist(0, 5));
      expect(c.state, LoadCompareState.ok);
      expect(c.usual, 400);
      expect(c.band, LoadBand.usual);
    });
    test('a part first week plus 2 full weeks is still firstWeeks', () {
      final runs = [
        run(DateTime(2026, 9, 27, 7)),
        ...week(4, 4),
        ...week(3, 4),
        ...week(1, 4),
      ];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(
        LoadCompare.of(ws.sublist(0, 5)).state,
        LoadCompareState.firstWeeks,
      );
    });
    test('usual under 60 is firstWeeks', () {
      final runs = [
        for (var k = 1; k <= 5; k++)
          run(DateTime(2026, 10, 26 - 7 * k, 7), min: 10),
      ];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(
        LoadCompare.of(ws.sublist(0, 5)).state,
        LoadCompareState.firstWeeks,
      );
    });
    test('2 empty unpaused weeks before is returning, no band', () {
      final runs = [...week(4, 4), ...week(5, 4), ...week(1, 3)];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      final c = LoadCompare.of(ws.sublist(0, 5));
      expect(c.state, LoadCompareState.returning);
      expect(c.band, isNull);
    });
    test('2 paused weeks before is not returning', () {
      final runs = [...week(4, 4), ...week(5, 4), ...week(1, 3)];
      final paused = {
        ProgressMath.weekIndex(DateTime(2026, 10, 12)),
        ProgressMath.weekIndex(DateTime(2026, 10, 19)),
      };
      // weeks(1) is 19 Oct which has runs; pause 12 Oct and 5 Oct instead.
      final p2 = {
        ProgressMath.weekIndex(DateTime(2026, 10, 12)),
        ProgressMath.weekIndex(DateTime(2026, 10, 5)),
      };
      final ws = LoadHistory.weeks(
        runs,
        now: now,
        weeks: 6,
        pausedWeeks: paused.union(p2),
      );
      expect(
        LoadCompare.of(ws.sublist(0, 5)).state,
        isNot(LoadCompareState.returning),
      );
    });
  });

  group('the summary and the in-week warning agree', () {
    // The guard flags a week on the load trigger; the summary says big jump
    // only then. Run both over the same fixtures.
    bool guardUp(List<LoadRun> runs, DateTime monday) {
      for (var d = 0; d < 7; d++) {
        final day = DateTime(monday.year, monday.month, monday.day + d, 23, 59);
        if (LoadGuard.check(runs, now: day).flag?.trigger == LoadTrigger.load) {
          return true;
        }
      }
      return false;
    }

    LoadCompare judge(List<LoadRun> runs) {
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      return LoadCompare.of(ws.sublist(0, 5));
    }

    test('a normal week after one rest week is not a jump', () {
      final runs = [...week(5, 4), ...week(4, 4), ...week(2, 4), ...week(1, 4)];
      final c = judge(runs);
      expect(c.band, LoadBand.usual);
      expect(guardUp(runs, DateTime(2026, 10, 19)), isFalse);
    });

    test('1.31-1.44x usual is a step up: the warning never fired', () {
      // usual 400; this week 1.375x = 550 over 5 runs of 110.
      final runs = [
        for (var k = 2; k <= 5; k++) ...week(k, 4),
        for (var i = 0; i < 5; i++) run(DateTime(2026, 10, 19, 7 + i), min: 44),
      ];
      final c = judge(runs);
      expect(c.ratio, closeTo(1.375, 1e-9));
      expect(guardUp(runs, DateTime(2026, 10, 19)), isFalse);
      expect(c.band, LoadBand.stepUp);
    });

    test('a week the warning flagged is a big jump', () {
      final runs = [for (var k = 2; k <= 5; k++) ...week(k, 4), ...week(1, 6)];
      expect(guardUp(runs, DateTime(2026, 10, 19)), isTrue);
      expect(judge(runs).band, LoadBand.bigJump);
    });

    test('big jump implies the warning was up, on every fixture', () {
      for (final n in [3, 4, 5, 6, 7, 9]) {
        for (final usualN in [3, 4]) {
          final runs = [
            for (var k = 2; k <= 5; k++) ...week(k, usualN),
            ...week(1, n),
          ];
          final c = judge(runs);
          if (c.band == LoadBand.bigJump) {
            expect(
              guardUp(runs, DateTime(2026, 10, 19)),
              isTrue,
              reason: '$n/$usualN',
            );
          }
        }
      }
    });

    test('a list ending in the current part week is never banded', () {
      final runs = [for (var k = 2; k <= 5; k++) ...week(k, 4), ...week(0, 4)];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 6);
      expect(ws.last.current, isTrue);
      expect(LoadCompare.of(ws).state, LoadCompareState.firstWeeks);
      expect(LoadCompare.of(ws).band, isNull);
    });
  });

  group('local-date week edges', () {
    test('Sunday 23:59 is that week, Monday 00:00 the next', () {
      final runs = [
        run(DateTime(2026, 10, 25, 23, 59)),
        run(DateTime(2026, 10, 26, 0, 0)),
      ];
      final ws = LoadHistory.weeks(runs, now: now, weeks: 2);
      expect(ws[0].monday, DateTime(2026, 10, 19));
      expect(ws[0].runs, 1);
      expect(ws[1].runs, 1);
      expect(ws[1].current, isTrue);
    });
  });

  group('one number with the guard', () {
    test('a week of one run is LoadGuard.load of that run', () {
      final r = LoadRun(
        start: DateTime(2026, 10, 27, 7),
        movingMin: 52,
        distanceM: 9000,
        avgHr: 150,
        hrCoverage: 0.95,
        zoneSec: [0, 100, 1800, 900, 300, 20],
      );
      final ws = LoadHistory.weeks([r], now: now, weeks: 1, maxHr: 190);
      expect(ws.single.load, LoadGuard.load(r, maxHr: 190));
      expect(ws.single.basisShare[LoadBasis.heartRate], 1);
      expect(ws.single.hrRuns, 1);
    });
    test('the history week sum matches the guard acute window', () {
      final runs = [
        for (var d = 20; d <= 28; d += 2) run(DateTime(2026, 10, d, 7)),
      ];
      final ws = LoadHistory.weeks(
        runs,
        now: DateTime(2026, 11, 1, 9),
        weeks: 2,
      );
      final sum = [
        for (final r in runs)
          if (!r.start.isBefore(DateTime(2026, 10, 26))) LoadGuard.load(r),
      ].fold(0.0, (a, b) => a + b);
      expect(ws.last.load, sum);
    });
  });

  group('hard minutes and shares', () {
    test('hr run uses z4+z5, non-hr intervals half, other non-hr 0', () {
      final hr = LoadRun(
        start: DateTime(2026, 10, 27, 7),
        movingMin: 50,
        distanceM: 8000,
        avgHr: 150,
        hrCoverage: 1,
        zoneSec: [0, 0, 1800, 600, 300, 300],
      );
      final iv = LoadRun(
        start: DateTime(2026, 10, 28, 7),
        movingMin: 40,
        distanceM: 6000,
        isIntervals: true,
      );
      final easy = run(DateTime(2026, 10, 29, 7));
      final w = LoadHistory.weeks(
        [hr, iv, easy],
        now: DateTime(2026, 10, 30),
        weeks: 1,
        maxHr: 190,
      ).single;
      expect(w.hardMinutes, 10 + 20);
      expect(w.zoneShare[1] > 0, isTrue);
      expect(
        w.zoneShare.fold(0.0, (a, b) => a + b) + w.noHrShare,
        closeTo(1, 1e-9),
      );
    });
    test('mostlyAssumed when the weight is a guess', () {
      final w = LoadHistory.weeks(
        [run(DateTime(2026, 10, 27, 7))],
        now: now,
        weeks: 1,
      ).single;
      expect(w.mostlyAssumed, isTrue);
      expect(w.basisShare[LoadBasis.assumed], 1);
    });
  });

  group('month and year', () {
    test('months bucket by local date and flag current', () {
      final runs = [
        run(DateTime(2026, 9, 30, 23, 59)),
        run(DateTime(2026, 10, 1, 0, 0)),
      ];
      final m = LoadHistory.months(runs, now: now, months: 3);
      expect(m.map((p) => p.runs), [0, 1, 1]);
      expect(m.last.current, isTrue);
      expect(m.first.beforeStart, isTrue);
    });
    test('year has 12 months, future flagged, last-year km to date', () {
      final runs = [
        run(DateTime(2025, 3, 1, 7), km: 10),
        run(DateTime(2025, 10, 28, 7), km: 5),
        run(DateTime(2025, 10, 29, 7), km: 50), // after the same date
        run(DateTime(2026, 3, 1, 7), km: 20),
      ];
      final y = LoadHistory.year(runs, now: now);
      expect(y.months, hasLength(12));
      expect(y.months[10].future, isTrue);
      expect(y.months[9].current, isTrue);
      expect(y.km, 20);
      expect(y.lastYearKm, 15);
      expect(y.kmVsLastYear, 5);
      expect(LoadWords.yearLine(y), '5 km more than this time last year');
    });
    test('no line with no run last year', () {
      final y = LoadHistory.year([run(DateTime(2026, 3, 1))], now: now);
      expect(LoadWords.yearLine(y), isNull);
    });
    test('a usual month needs 3 prior months with runs', () {
      PeriodLoad m(int i, {int runs = 5, bool partial = false}) => PeriodLoad(
        start: DateTime(2026, 5 + i),
        load: runs * 100.0,
        runs: runs,
        partialStart: partial,
      );
      expect(
        LoadCompare.months([m(0), m(1), m(2)]).state,
        LoadCompareState.firstWeeks,
      );
      expect(
        LoadCompare.months([m(0), m(1), m(2), m(3)]).state,
        LoadCompare.months([m(0), m(1), m(2), m(3)]).state,
      );
      final ok = LoadCompare.months([m(0), m(1), m(2), m(3)]);
      expect(ok.state, LoadCompareState.ok);
      expect(ok.band, LoadBand.usual);
      // A part first month is left out: only 2 full months before.
      expect(
        LoadCompare.months([m(0, partial: true), m(1), m(2), m(3)]).state,
        LoadCompareState.firstWeeks,
      );
    });
    test('a single first month is still drawn', () {
      final m = LoadHistory.months(
        [run(DateTime(2026, 10, 3))],
        now: now,
        months: 6,
      );
      expect(m.where((p) => p.runs > 0), hasLength(1));
    });
  });

  group('copy', () {
    test('samples land in the state their name says', () {
      LoadCompare c(LoadSample s) => LoadCompare.of(WeekLoad.sample(s));
      expect(c(LoadSample.usual).band, LoadBand.usual);
      expect(c(LoadSample.stepup).band, LoadBand.stepUp);
      expect(c(LoadSample.bigjump).band, LoadBand.bigJump);
      expect(c(LoadSample.lighter).band, LoadBand.lighter);
      expect(c(LoadSample.first).state, LoadCompareState.firstWeeks);
      expect(c(LoadSample.returning).state, LoadCompareState.returning);
      expect(c(LoadSample.paused).band, LoadBand.usual);
      expect(WeekLoad.sample(LoadSample.paused)[3].paused, isTrue);
      expect(WeekLoad.sample(LoadSample.nohr).last.mostlyAssumed, isTrue);
    });
    test('headline, changed and suggest by band', () {
      String h(LoadSample s) {
        final ws = WeekLoad.sample(s);
        return LoadWords.headline(ws.last, LoadCompare.of(ws));
      }

      expect(h(LoadSample.usual), '352 load, about your usual week (349).');
      expect(
        h(LoadSample.stepup),
        '420 load, 20% more than your usual week (349).',
      );
      expect(
        h(LoadSample.lighter),
        '240 load, 31% less than your usual week (349).',
      );
      expect(
        h(LoadSample.first),
        '300 load. Your usual week takes shape after 3 weeks of running.',
      );
      expect(
        h(LoadSample.returning),
        "200 load, your first week back. We'll compare from next week.",
      );
      final big = WeekLoad.sample(LoadSample.bigjump);
      final c = LoadCompare.of(big);
      expect(
        LoadWords.suggest(big.last, c),
        'Keep next week near 380 and the easy runs easy.',
      );
      expect(LoadWords.changed(big.last, c), 'Hard minutes: 80, usual 40.');
      final first = WeekLoad.sample(LoadSample.first);
      expect(
        LoadWords.changed(first.last, LoadCompare.of(first)),
        '3 runs, 136 minutes, 25.0 km.',
      );
    });
    test('changed rules fall through in order', () {
      WeekLoad w({
        double hard = 40,
        double longest = 12,
        int runs = 4,
        double min = 160,
      }) => WeekLoad(
        monday: thisMonday,
        load: 400,
        minutes: min,
        hardMinutes: hard,
        longestKm: longest,
        runs: runs,
      );
      const c = LoadCompare(
        state: LoadCompareState.ok,
        band: LoadBand.stepUp,
        ratio: 1.2,
        usual: 350,
        usualHard: 40,
        usualLongestKm: 10,
        usualRuns: 4,
        usualMin: 150,
      );
      expect(
        LoadWords.changed(w(hard: 49), c),
        '160 minutes running, usual 150.',
      );
      expect(
        LoadWords.changed(w(hard: 55), c),
        '160 minutes running, usual 150.',
      );
      expect(LoadWords.changed(w(hard: 60), c), 'Hard minutes: 60, usual 40.');
      expect(
        LoadWords.changed(w(longest: 13.5), c),
        'Longest run 13.5 km, usual 10.0 km.',
      );
      expect(
        LoadWords.changed(w(longest: 12.5), c),
        '160 minutes running, usual 150.',
      );
      expect(LoadWords.changed(w(runs: 5), c), '5 runs, usual 4.');
    });
    test('why adds the heart rate sentence only with HR runs', () {
      final a = WeekLoad(monday: DateTime(2026, 10, 19));
      expect(LoadWords.why(a), isNot(contains('used your heart rate')));
      final b = WeekLoad(monday: DateTime(2026, 10, 19), runs: 4, hrRuns: 3);
      expect(
        LoadWords.why(b),
        contains('3 of 4 runs this week used your heart rate.'),
      );
    });
  });

  group('LoadFlag wording is unchanged', () {
    test('delegates to loadVsUsualPhrase', () {
      const f = LoadFlag(
        trigger: LoadTrigger.load,
        loadRatio: 2.0,
        distanceRatio: 1,
      );
      expect(f.message, startsWith('This week is about double your usual.'));
    });
  });
}
