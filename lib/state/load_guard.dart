/// "Don't overdo it" on the phone: History's index rows in, the engine's
/// check out, plus the per-week dismissal. The maths and the words live in
/// the engine (`load_guard.dart`).
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'block_plan.dart';
import 'history_store.dart';
import 'settings.dart';

abstract final class LoadInputs {
  /// Index-row figures only: moving time, distance, True Pace, average HR.
  static List<engine.LoadRun> runs(List<RunSummary> all) => [
    for (final r in all)
      if (!r.missing)
        engine.LoadRun(
          start: PlanInputs.wallClock(r),
          movingMin: (r.row?.movingMs ?? r.durationMs) / 60000.0,
          distanceM: r.distanceM,
          truePaceSecPerKm: r.truePaceSecPerKm,
          workTruePaceSecPerKm: r.trueWorkPaceSecPerKm,
          isIntervals: r.mode == RecordMode.intervals && r.spec?.isGoal != true,
          avgHr: r.row?.avgHr,
          hrCoverage: r.row?.hrCoverage,
        ),
  ];

  static engine.LoadCheck check(
    List<RunSummary> runs, {
    required DateTime now,
    required int maxHr,
    required double? vdot,
  }) => engine.LoadGuard.check(
    LoadInputs.runs(runs),
    now: now,
    maxHr: maxHr.toDouble(),
    vdot: vdot,
  );
}

abstract final class LoadDismissal {
  static bool dismissed(AppSettings s, DateTime now) =>
      s.loadDismissedWeek == engine.LoadGuard.weekKey(now);

  static AppSettings Function(AppSettings) dismiss(DateTime now) =>
      (s) => s.copyWith(loadDismissedWeek: engine.LoadGuard.weekKey(now));
}
