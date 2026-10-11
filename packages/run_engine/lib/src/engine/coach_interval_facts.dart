/// The interval-session facts the coach upload carries, from the same numbers
/// the verdict reads ("4:17/km work pace. Reps within 6 s of each other.
/// Recovery 7:41."): the work pace is the verdict's headline,
/// [RunAnalysis.trueWorkPaceSecPerKm] (hills and heat taken out; the raw
/// [IntervalMetrics.avgWorkPaceSecPerKm] when there is none), the spread is
/// the clean reps' slowest minus fastest and the recovery is
/// [IntervalMetrics.recoveryPaceSecPerKm].
///
/// Pure, so the app (which holds index-row numbers on a device) and the replay
/// tool (which holds a fresh [IntervalMetrics]) build the same payload keys.
library;

/// Keys for the upload, all optional. Empty when there is no work pace.
Map<String, Object?> coachIntervalFacts({
  required String? sessionName,
  required double? workPaceSecPerKm,
  required int? repsDone,
  required Iterable<double> cleanRepPacesSecPerKm,
  required double? recoveryPaceSecPerKm,
}) {
  if (workPaceSecPerKm == null || !workPaceSecPerKm.isFinite) return const {};
  double r1(double v) => (v * 10).roundToDouble() / 10;
  final paces = cleanRepPacesSecPerKm.where((p) => p.isFinite).toList();
  double? spread;
  if (paces.length > 1) {
    spread =
        paces.reduce((a, b) => a > b ? a : b) -
        paces.reduce((a, b) => a < b ? a : b);
  }
  var name = sessionName?.trim();
  if (name != null && name.length > 40) {
    name = name.substring(0, 40).trimRight();
  }
  final recovery = recoveryPaceSecPerKm;
  return {
    if (name != null && name.isNotEmpty) 'session_name': name,
    'work_pace_s_per_km': r1(workPaceSecPerKm),
    'reps_done': ?repsDone,
    'rep_spread_s': ?(spread == null ? null : r1(spread)),
    'recovery_pace_s_per_km': ?(recovery == null || !recovery.isFinite
        ? null
        : r1(recovery)),
  };
}
