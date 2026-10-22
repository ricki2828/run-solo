import '../model/run_file.dart' show Units;
import '../model/session_spec.dart';
import '../run_mode.dart';
import 'best_efforts.dart';
import 'live_plan.dart';
import 'run_identity.dart';

/// Why the runner's latest run of 5 km or more did not count for MID and
/// ESTIMATED TIMES, in runner language ("Your 5K on 20 Oct didn't count:
/// paused at 3.2 km"). Replaces the generic "needs a 5K or 10K run" hint
/// when there is a real reason; null when the latest long run counted, or
/// the cause is not in the trace.
class EffortNote {
  const EffortNote({
    required this.runId,
    required this.date,
    required this.subject,
    required this.reason,
  });

  final String runId;

  /// The run's local start.
  final DateTime date;

  /// "5K", "10K", "run", "trail run", "Cooper test".
  final String subject;

  /// "paused at 3.2 km".
  final String reason;

  /// A run older than this is not "recent": no note.
  static const int recentDays = 14;

  /// A run must go at least this far to be expected to count.
  static const double minRunM = 5000;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "Your 5K on 20 Oct didn't count: paused at 3.2 km"
  String get line =>
      "Your $subject on ${date.day} ${_months[date.month - 1]} didn't count: "
      '$reason';

  /// The note for the newest run of 5 km or more, or null.
  static EffortNote? latest(
    Iterable<LiveCandidate> runs, {
    required DateTime now,
    Units units = Units.km,
  }) {
    LiveCandidate? newest;
    for (final c in runs) {
      final i = c.input;
      if (i.date.isAfter(now) || i.runDistanceM < minRunM) continue;
      // A non-goal interval session is judged by its reps, not as a 5K.
      if (i.mode == RunMode.intervals &&
          !ComparisonKey.isGoal(i.comparisonKey ?? '')) {
        continue;
      }
      if (newest == null || i.date.isAfter(newest.input.date)) newest = c;
    }
    if (newest == null) return null;
    final i = newest.input;
    if (now.difference(i.date).inDays > recentDays) return null;
    return forRun(newest, units: units);
  }

  /// The note for one run, whatever its age or length, or null when it
  /// counted or the cause is not in the trace. [latest] and the Counted runs
  /// list share it.
  static EffortNote? forRun(LiveCandidate newest, {Units units = Units.km}) {
    final i = newest.input;
    final efforts = newest.derived.bestEfforts;
    final date = RunIdentity.localStart(i.date, i.utcOffsetMin);
    EffortNote note(String subject, String reason) => EffortNote(
      runId: i.runId,
      date: date,
      subject: subject,
      reason: reason,
    );
    if (i.mode == RunMode.cooper) {
      return note('Cooper test', "it's a 12-minute test");
    }
    final counts =
        efforts.efforts.containsKey(BestEffortDistance.k5) ||
        efforts.efforts.containsKey(BestEffortDistance.k10);
    // A trail run counts at hill-adjusted pace, which needs the barometer's
    // elevation; with it, it is explained like any other run.
    if (i.mode == RunMode.trail && i.trailMovingMs == null) {
      return note('trail run', 'no elevation data to adjust for hills');
    }
    if (counts) return null;
    final miss = efforts.miss;
    if (miss == null) return null;
    final goal = miss.goalM;
    final subject = i.mode == RunMode.trail
        ? 'trail run'
        : goal == null
        ? 'run'
        : goal == BestEffortDistance.k5.metres
        ? '5K'
        : '10K';
    return note(subject, miss.reasonIn(units));
  }
}
