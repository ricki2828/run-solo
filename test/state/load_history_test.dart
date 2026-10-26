import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/load_guard.dart';
import 'package:run_solo/state/load_history.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/platform/gateway.dart';

RunSummary run(
  String id,
  DateTime local, {
  int min = 40,
  double? avgHr,
  double? cov,
}) => RunSummary(
  id: id,
  mode: RecordMode.free,
  start: local.toUtc(),
  durationMs: min * 60000,
  distanceM: 6500,
  laps: 0,
  utcOffsetMin: local.timeZoneOffset.inMinutes,
  row: IndexRow(
    lapCount: 0,
    movingMs: min * 60000,
    avgHr: avgHr,
    hrCoverage: cov,
  ),
);

/// Three steady weeks of 3 runs (days 26..8 ago), then [extra] runs in the
/// last 7 days, the last of them (the target) today, 14 Oct at 18:00.
List<RunSummary> history({int extra = 3}) => [
  for (var w = 0; w < 3; w++)
    for (var d = 0; d < 3; d++)
      run('h$w$d', DateTime(2026, 10, 14 - (8 + 7 * w + 2 * d), 7)),
  for (var i = 0; i < extra - 1; i++)
    run('t$i', DateTime(2026, 10, 13 - i % 6, 7 + i ~/ 6)),
  run('target', DateTime(2026, 10, 14, 18)),
];

void main() {
  group('LoadWire.of', () {
    test('strap wins, else assumed', () {
      final hr = LoadWire.of(
        run('a', DateTime(2026, 10, 14, 7), avgHr: 150, cov: 0.95),
        maxHr: 190,
        vdot: null,
      )!;
      expect(hr.basis, 'hr');
      // weight = 2 + (150/190 - 0.65) x 10 = 3.39
      expect(hr.load, closeTo(40 * 3.3947, 0.1));
      final none = LoadWire.of(
        run('b', DateTime(2026, 10, 14, 7)),
        maxHr: 190,
        vdot: null,
      )!;
      expect(none.basis, 'assumed');
      expect(none.load, 100);
    });

    test('the same number the guard sums', () {
      final r = run('a', DateTime(2026, 10, 14, 7), avgHr: 150, cov: 0.95);
      final w = LoadWire.of(r, maxHr: 190, vdot: null)!;
      final g = engine.LoadGuard.load(LoadInputs.runs([r]).single, maxHr: 190);
      expect(w.load, closeTo(g, 0.05));
    });
  });

  group('LoadWire.stateAt', () {
    test('too little history is no state, not "steady"', () {
      final r = run('a', DateTime(2026, 10, 14, 7));
      expect(LoadWire.stateAt([r], r, maxHr: 190, vdot: null), isNull);
    });

    test('a usual week is steady', () {
      final h = history();
      expect(LoadWire.stateAt(h, h.last, maxHr: 190, vdot: null), 'steady');
    });

    test('a spike is high, a far bigger one very_high', () {
      final h = history(extra: 5);
      expect(LoadWire.stateAt(h, h.last, maxHr: 190, vdot: null), 'high');
      final big = history(extra: 9);
      expect(
        LoadWire.stateAt(big, big.last, maxHr: 190, vdot: null),
        'very_high',
      );
    });

    test('a distance-only flag is steady, not high', () {
      // Long slow runs: lots of km, little load (weight 1 at a slow pace).
      RunSummary slow(String id, DateTime t, {double km = 6.5}) => RunSummary(
        id: id,
        mode: RecordMode.free,
        start: t.toUtc(),
        durationMs: 40 * 60000,
        distanceM: km * 1000,
        laps: 0,
        utcOffsetMin: t.timeZoneOffset.inMinutes,
        row: const IndexRow(
          lapCount: 0,
          movingMs: 40 * 60000,
          avgHr: 100,
          hrCoverage: 1,
        ),
      );
      final h = [
        for (var w = 0; w < 3; w++)
          for (var d = 0; d < 3; d++)
            slow('h$w$d', DateTime(2026, 10, 14 - (8 + 7 * w + 2 * d), 7)),
        for (var i = 0; i < 3; i++)
          slow('t$i', DateTime(2026, 10, 12 + i, 7), km: 10),
      ];
      final c = engine.LoadGuard.check(
        LoadInputs.runs(h),
        now: h.last.start.toLocal(),
        maxHr: 190,
      );
      expect(c.flag?.trigger, engine.LoadTrigger.distance);
      expect(LoadWire.stateAt(h, h.last, maxHr: 190, vdot: null), 'steady');
    });

    test('runs after this one do not count', () {
      final h = history(extra: 3);
      final later = [
        ...h,
        for (var i = 0; i < 6; i++)
          run('later$i', DateTime(2026, 10, 15 + i, 18)),
      ];
      expect(LoadWire.stateAt(later, h.last, maxHr: 190, vdot: null), 'steady');
    });
  });

  group('LoadWire.facts', () {
    test('load and load_basis only for a server that takes them', () {
      final h = history(extra: 5);
      final off = LoadWire.facts(
        h,
        h.last,
        maxHr: 190,
        vdot: null,
        withLoad: false,
      );
      expect(off.keys, ['load_state']);
      final on = LoadWire.facts(
        h,
        h.last,
        maxHr: 190,
        vdot: null,
        withLoad: true,
      );
      expect(on.keys.toSet(), {'load', 'load_basis', 'load_state'});
    });
  });

  group('LoadHistoryInputs', () {
    test('weeks come from the index rows, the last one current', () {
      final h = history();
      final ws = LoadHistoryInputs.weeks(
        h,
        now: DateTime(2026, 10, 14, 9),
        zones: engine.HrZones.percentMax(190),
        maxHr: 190,
        vdot: null,
      );
      expect(ws, hasLength(6));
      expect(ws.last.current, isTrue);
      expect(ws.last.runs, 3);
    });
  });
}
