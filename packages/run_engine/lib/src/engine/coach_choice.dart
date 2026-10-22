import '../run_mode.dart';
import 'leaderboards.dart';
import 'run_identity.dart';

/// The pre-run choice at Start for a Free or goal run (founder 22-Oct,
/// "minimal first"): what the voice does for the whole run.
///
/// - [chase]: race your best. The voice says how you stand against your best
///   at the km marks, warns when you slip behind it, and says when this is
///   your furthest run of the month. On a distance goal it also calls the
///   last 2 km.
/// - [steady]: no comparisons. A distance goal still hears "2 k to go".
///
/// The [key] is the stable name: settings, the Pigeon `LiveContext
/// .coachChoice`, the run file's `coach.choice`. Mirrors core-jvm
/// `CoachChoice`.
enum CoachChoice {
  chase('chase'),
  steady('steady');

  const CoachChoice(this.key);
  final String key;

  /// The choice named [key]; null for none or a name this build does not know.
  static CoachChoice? parse(String? key) {
    for (final c in values) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// The base of the voice's "furthest run this month": the longest run in the
/// current calendar month, so the coach can say so at the first km past it.
abstract final class MonthFurthest {
  /// A month's best under this is not worth comparing with (the line would
  /// fall on km 1 or 2 and mean nothing).
  static const double minMetres = 2000;

  /// The furthest run (metres) of the calendar month [now] is in, among
  /// [runs] that started before [now]; null when there is none or it is under
  /// [minMetres] (no base: the line never fires). Cooper tests are not runs.
  /// A run's month is its own wall-clock one ([RunIdentity.localStart]), so a
  /// run in another time zone, or just after midnight, keeps its date. [now]
  /// is the runner's wall clock; pass it in, never read a clock here.
  static double? of(Iterable<BoardInput> runs, {required DateTime now}) {
    double? best;
    for (final r in runs) {
      if (r.mode == RunMode.cooper) continue;
      final d = r.runDistanceM;
      if (!d.isFinite || d <= 0) continue;
      final start = RunIdentity.localStart(r.date, r.utcOffsetMin);
      if (start.year != now.year || start.month != now.month) continue;
      if (r.date.isAfter(now)) continue;
      if (best == null || d > best) best = d;
    }
    return best != null && best >= minMetres ? best : null;
  }
}
