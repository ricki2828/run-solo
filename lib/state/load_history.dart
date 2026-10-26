/// Load by week, month and year on the phone: History's index rows in, the
/// engine's `LoadHistory` out, plus the load facts a run upload carries. The
/// maths and the words live in the engine (`load_history.dart`); the weight of
/// each run is the guard's (`LoadGuard.weight`), so the warning, the weekly
/// summary and the Sunday recap show one number.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'block_plan.dart';
import 'history_store.dart';
import 'load_guard.dart';

abstract final class LoadHistoryInputs {
  /// The last [weeks] calendar weeks ending with the one holding [now], oldest
  /// first. [pausedWeeks] are `ProgressMath.weekIndex` values: the caller
  /// passes `QuestSync.pausedWeeks`, which is `mergePausedWeeks` of the
  /// runner's pauses and the coach's care weeks.
  static List<engine.WeekLoad> weeks(
    List<RunSummary> runs, {
    required DateTime now,
    required engine.HrZones zones,
    required int maxHr,
    required double? vdot,
    int weeks = 6,
    Set<int> pausedWeeks = const {},
  }) => engine.LoadHistory.weeks(
    LoadInputs.runs(runs, zones: zones),
    now: now,
    maxHr: maxHr.toDouble(),
    vdot: vdot,
    weeks: weeks,
    pausedWeeks: pausedWeeks,
  );

  static List<engine.PeriodLoad> months(
    List<RunSummary> runs, {
    required DateTime now,
    required int maxHr,
    required double? vdot,
    int months = 6,
  }) => engine.LoadHistory.months(
    LoadInputs.runs(runs),
    now: now,
    maxHr: maxHr.toDouble(),
    vdot: vdot,
    months: months,
  );

  static engine.YearLoad year(
    List<RunSummary> runs, {
    required DateTime now,
    required int maxHr,
    required double? vdot,
  }) => engine.LoadHistory.year(
    LoadInputs.runs(runs),
    now: now,
    maxHr: maxHr.toDouble(),
    vdot: vdot,
  );
}

/// The load facts of one uploaded run.
abstract final class LoadWire {
  /// This run's load (1 decimal) and where its weight came from, `hr`,
  /// `pace` or `assumed`. Null for a run the index cannot size.
  static ({double load, String basis})? of(
    RunSummary run, {
    required int maxHr,
    required double? vdot,
  }) {
    final runs = LoadInputs.runs([run]);
    if (runs.isEmpty) return null;
    final r = runs.single;
    final max = maxHr.toDouble();
    final basis = engine.LoadGuard.weight(r, maxHr: max, vdot: vdot).$2;
    final load = engine.LoadGuard.load(r, maxHr: max, vdot: vdot);
    return (
      load: (load * 10).roundToDouble() / 10,
      basis: switch (basis) {
        engine.LoadBasis.heartRate => 'hr',
        engine.LoadBasis.pace => 'pace',
        engine.LoadBasis.assumed => 'assumed',
      },
    );
  }

  /// The upload fields: `load_state` always (an older server already takes
  /// it), `load` and `load_basis` only with [withLoad] (a server that has said
  /// it takes them; an older one refuses any key it does not know).
  static Map<String, Object?> facts(
    List<RunSummary> history,
    RunSummary run, {
    required int maxHr,
    required double? vdot,
    required bool withLoad,
  }) {
    final state = stateAt(history, run, maxHr: maxHr, vdot: vdot);
    final l = withLoad ? of(run, maxHr: maxHr, vdot: vdot) : null;
    return {'load': ?l?.load, 'load_basis': ?l?.basis, 'load_state': ?state};
  }

  /// The guard's verdict as of this run, in the server's words: `steady`,
  /// `high` or `very_high` (the guard's high flag), the last two only for the
  /// load trigger. Null while there is not
  /// enough history to judge. [history] may or may not hold [run].
  static String? stateAt(
    List<RunSummary> history,
    RunSummary run, {
    required int maxHr,
    required double? vdot,
  }) {
    final at = PlanInputs.wallClock(run);
    final upTo = [
      for (final r in history)
        if (r.id != run.id &&
            !r.missing &&
            !PlanInputs.wallClock(r).isAfter(at))
          r,
      run,
    ];
    final c = engine.LoadGuard.check(
      LoadInputs.runs(upTo),
      now: at,
      maxHr: maxHr.toDouble(),
      vdot: vdot,
    );
    return switch (c.state) {
      engine.LoadState.notEnoughData => null,
      engine.LoadState.ok => 'steady',
      // A distance-only flag is not a load flag: the coach says "load is
      // high" only when load is (the in-app warning still shows distance).
      engine.LoadState.flagged =>
        c.flag!.trigger != engine.LoadTrigger.load
            ? 'steady'
            : c.flag!.high
            ? 'very_high'
            : 'high',
    };
  }
}
