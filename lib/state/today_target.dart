/// "Today's target" on Start: the heat-adjusted aim for a Free, Trail or Goal
/// run, from the weather now at the runner's usual coarse location and the
/// pace they have been running lately. Pure helpers; the fetch lives in
/// [WeatherQueue.currentAt] and the widget in `today_target_line.dart`.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import 'history_store.dart';

/// The runner's recent steady-run pace (median True Pace of up to the last
/// [take] Free and Trail runs of 2 km or more in the past [days] days), s/km;
/// null with fewer than [minRuns]. History-fed, so it reads index-row fields
/// only ([RunSummary.truePaceSecPerKm]).
double? typicalTruePace(
  Iterable<RunSummary> runs, {
  required DateTime now,
  int take = 8,
  int minRuns = 2,
  int days = 90,
}) {
  final cutoff = now.subtract(Duration(days: days));
  final steady = [
    for (final r in runs)
      if ((r.mode == RecordMode.free || r.mode == RecordMode.trail) &&
          !r.missing &&
          r.distanceM >= 2000 &&
          r.start.isAfter(cutoff) &&
          r.truePaceSecPerKm != null)
        r,
  ]..sort((a, b) => b.start.compareTo(a.start));
  final paces = [for (final r in steady.take(take)) r.truePaceSecPerKm!]
    ..sort();
  if (paces.length < minRuns) return null;
  final mid = paces.length ~/ 2;
  return paces.length.isOdd ? paces[mid] : (paces[mid - 1] + paces[mid]) / 2;
}

/// Where the runner last started a run (the newest run with a fix), for the
/// coarse weather request; null for a runner with no outdoor run yet.
({double lat, double lon})? lastRunLocation(Iterable<RunSummary> runs) {
  RunSummary? best;
  for (final r in runs) {
    if (r.startPoint == null) continue;
    if (best == null || r.start.isAfter(best.start)) best = r;
  }
  return best?.startPoint;
}

/// "Warm today (31°C). Aim for 5:10/km true pace, about 5:25/km actual."
String todayTargetLine(engine.TodayTarget t, Units units) {
  final head = '${t.word} today (${t.tempC.round()}°C)';
  final actual = t.actualSecPerKm;
  if (actual == null) {
    return '$head. Too hot to compare, so run by feel and keep it easy.';
  }
  return '$head. Aim for ${Fmt.paceUnit(t.trueSecPerKm, units)} true pace, '
      'about ${Fmt.paceUnit(actual, units)} actual.';
}
