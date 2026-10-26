/// What the load screens need from the app, read once: the run history, the
/// heart rate setup, the pace estimate and the paused weeks. The maths lives
/// in `load_history.dart`; this only gathers its inputs.
library;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/quest_sync.dart';
import '../app/services.dart';
import 'history_store.dart';
import 'load_history.dart';

class LoadSource {
  const LoadSource({
    required this.runs,
    required this.now,
    required this.zones,
    required this.maxHr,
    required this.vdot,
    required this.pausedWeeks,
  });

  final List<RunSummary> runs;
  final DateTime now;
  final engine.HrZones zones;
  final int maxHr;
  final double? vdot;
  final Set<int> pausedWeeks;

  /// Never throws for a missing piece: no pace estimate or no quest file just
  /// leaves that input empty.
  static Future<LoadSource> read(AppServices s) async {
    final runs = await s.history.list();
    double? vdot;
    try {
      final live = s.live;
      if (live != null) {
        await live.prepare();
        vdot = engine.BlockPaces.medianVdot([
          for (final v in live.identityScores().values) v.vdot,
        ]);
      }
    } catch (e) {
      debugPrint('load: no pace estimate ($e)');
    }
    var paused = <int>{};
    try {
      final st = await s.quests.load();
      paused = mergePausedWeeks(
        st.pausedWeeks,
        s.companion?.careWeeks ?? const [],
      );
    } catch (e) {
      debugPrint('load: no paused weeks ($e)');
    }
    return LoadSource(
      runs: runs,
      now: s.now(),
      zones: s.hrZones,
      maxHr: s.maxHr.maxHr,
      vdot: vdot,
      pausedWeeks: paused,
    );
  }

  List<engine.WeekLoad> weeks(int n) => LoadHistoryInputs.weeks(
    runs,
    now: now,
    zones: zones,
    maxHr: maxHr,
    vdot: vdot,
    weeks: n,
    pausedWeeks: pausedWeeks,
  );

  List<engine.PeriodLoad> months(int n) => LoadHistoryInputs.months(
    runs,
    now: now,
    maxHr: maxHr,
    vdot: vdot,
    months: n,
  );

  engine.YearLoad year() =>
      LoadHistoryInputs.year(runs, now: now, maxHr: maxHr, vdot: vdot);

  /// The weeks ending with the Monday-start week [weekStart], oldest first
  /// (the story's week and the nine before it at most); null when that week
  /// holds no run.
  List<engine.WeekLoad>? weeksEnding(DateTime weekStart) {
    final end = DateTime(weekStart.year, weekStart.month, weekStart.day);
    final all = weeks(10);
    final cut = [
      for (final w in all)
        if (!w.monday.isAfter(end)) w,
    ];
    if (cut.isEmpty || cut.last.monday != end || cut.last.runs == 0) {
      return null;
    }
    return cut;
  }
}
