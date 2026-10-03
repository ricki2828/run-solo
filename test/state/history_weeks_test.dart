import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/history_weeks.dart';
import 'package:run_solo/state/run_index.dart';

// Thursday 24 Sep 2026: this week is Mon 21 to Sun 27 Sep.
final _now = DateTime(2026, 9, 24, 10);

RunSummary _run(
  String id,
  DateTime start, {
  int? offset,
  double distanceM = 5000,
  int durationMs = 1800000,
  int? movingMs,
  double? climbM,
}) => RunSummary(
  id: id,
  mode: RecordMode.free,
  start: start,
  durationMs: durationMs,
  distanceM: distanceM,
  laps: 1,
  utcOffsetMin: offset,
  row: IndexRow(lapCount: 1, movingMs: movingMs, climbM: climbM),
);

Map<String, List<String>> _ids(List<HistoryGroup> gs) => {
  for (final g in gs) g.header: [for (final r in g.runs) r.id],
};

void main() {
  test('this week, last week, then date ranges, then months', () {
    final gs = groupByWeek([
      _run('thu', DateTime.utc(2026, 9, 24, 6), offset: 0),
      _run('mon', DateTime.utc(2026, 9, 21, 6), offset: 0),
      _run('last', DateTime.utc(2026, 9, 16, 6), offset: 0),
      _run('wk3', DateTime.utc(2026, 9, 10, 6), offset: 0),
      _run('wk3b', DateTime.utc(2026, 9, 8, 6), offset: 0),
      _run('cross', DateTime.utc(2026, 7, 30, 6), offset: 0),
      _run('aug', DateTime.utc(2026, 8, 3, 6), offset: 0),
      _run('mar25', DateTime.utc(2025, 3, 3, 6), offset: 0),
    ], _now);
    expect(_ids(gs), {
      'THIS WEEK': ['thu', 'mon'],
      'LAST WEEK': ['last'],
      '7 TO 13 SEP': ['wk3', 'wk3b'],
      // 3 Aug is 7 weeks back: still a range, across no month boundary.
      '3 TO 9 AUG': ['aug'],
      // 27 Jul to 2 Aug straddles two months.
      '27 JUL TO 2 AUG': ['cross'],
      'MARCH 2025': ['mar25'],
    });
    expect(gs.map((g) => g.header).first, 'THIS WEEK');
  });

  test('beyond eight weeks the current year falls back to month headers', () {
    final gs = groupByWeek([
      _run('a', DateTime.utc(2026, 7, 20, 6), offset: 0), // 9 weeks back
      _run('b', DateTime.utc(2026, 7, 6, 6), offset: 0),
      _run('c', DateTime.utc(2026, 2, 1, 6), offset: 0),
    ], _now);
    expect(_ids(gs), {
      'THIS WEEK': [],
      'JULY 2026': ['a', 'b'],
      'FEBRUARY 2026': ['c'],
    });
  });

  test('Sunday night is the old week, Monday morning the new one', () {
    // Local Sun 13 Sep 23:30 and Mon 14 Sep 00:30 (UTC+0 for both).
    final gs = groupByWeek([
      _run('sun', DateTime.utc(2026, 9, 13, 23, 30), offset: 0),
      _run('mon', DateTime.utc(2026, 9, 14, 0, 30), offset: 0),
    ], _now);
    expect(_ids(gs), {
      'THIS WEEK': [],
      'LAST WEEK': ['mon'],
      '7 TO 13 SEP': ['sun'],
    });
  });

  test('a run abroad is grouped by its own local date', () {
    final gs = groupByWeek([
      // Auckland (+12h): local Mon 14 Sep 06:00 = UTC Sun 13 Sep 18:00.
      _run('akl', DateTime.utc(2026, 9, 13, 18), offset: 720),
      // Los Angeles (-7h): local Sun 13 Sep 22:00 = UTC Mon 14 Sep 05:00.
      _run('lax', DateTime.utc(2026, 9, 14, 5), offset: -420),
    ], _now);
    expect(_ids(gs), {
      'THIS WEEK': [],
      'LAST WEEK': ['akl'],
      '7 TO 13 SEP': ['lax'],
    });
  });

  test('a run dated ahead of the phone clock stays in this week', () {
    final gs = groupByWeek([
      _run('ahead', DateTime.utc(2026, 9, 28, 0, 30), offset: 720),
    ], _now);
    expect(_ids(gs), {
      'THIS WEEK': ['ahead'],
    });
  });

  test('empty this week is kept as the first group; other empties skipped', () {
    final gs = groupByWeek([
      _run('old', DateTime.utc(2026, 8, 12, 6), offset: 0),
    ], _now);
    expect(gs.first.header, 'THIS WEEK');
    expect(gs.first.runs, isEmpty);
    expect(gs.map((g) => g.header), ['THIS WEEK', '10 TO 16 AUG']);
    expect(groupByWeek(const [], _now).map((g) => g.header), ['THIS WEEK']);
  });

  group('totals', () {
    final g = HistoryGroup(
      header: 'THIS WEEK',
      runs: [
        _run(
          'a',
          DateTime.utc(2026, 9, 21),
          distanceM: 10000,
          durationMs: 3000000,
          movingMs: 2900000,
          climbM: 200,
        ),
        _run(
          'b',
          DateTime.utc(2026, 9, 22),
          distanceM: 12000,
          durationMs: 4000000,
          movingMs: 3900000,
          climbM: 210.4,
        ),
        // No moving time or climb on the row: elapsed time, no climb.
        _run(
          'c',
          DateTime.utc(2026, 9, 23),
          distanceM: 10400,
          durationMs: 4300000,
        ),
        _run(
          'd',
          DateTime.utc(2026, 9, 24),
          distanceM: 0,
          durationMs: 0,
          movingMs: 0,
        ),
      ],
    );

    test('count, distance, moving time and climb', () {
      // 2900 + 3900 + 4300 s = 11100 s = 3:05; 32.4 km; +410 m.
      expect(g.totals(Units.km), '4 runs · 32.4 km · 3:05 · +410 m');
    });

    test('miles and feet', () {
      expect(g.totals(Units.mi), '4 runs · 20.1 mi · 3:05 · +1346 ft');
    });

    test('no climb leaves it out; one run is singular; minutes pad', () {
      final one = HistoryGroup(
        header: 'X',
        runs: [_run('a', DateTime.utc(2026, 9, 21), movingMs: 1500000)],
      );
      expect(one.totals(Units.km), '1 run · 5.0 km · 0:25');
    });
  });
}
