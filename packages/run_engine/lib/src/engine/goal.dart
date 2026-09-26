import '../model/run_file.dart';
import '../model/session_spec.dart';
import 'format.dart';
import 'trace.dart';

/// What a GOAL run is after (Phase 4 plan §G).
enum GoalKind { distance, time }

/// The locked-in goal result, computed from the run file (never from the
/// live event, which a shared fixture pins against this). Pauses are
/// excluded from goal time; the distance stream is the recorder's own,
/// interpolated at the crossing (the P2-a rule).
class GoalResult {
  const GoalResult({
    required this.kind,
    required this.target,
    required this.name,
    required this.reached,
    this.goalMs,
    this.goalDistanceM,
    this.atRunMs,
    required this.stoppedAtM,
  });

  final GoalKind kind;

  /// Metres (distance goals) or seconds (time goals).
  final int target;

  /// The goal's shown name ("10K", "Half", "30 min"), from the spec.
  final String name;
  final bool reached;

  /// Distance goal: moving time from Start to the goal distance.
  final int? goalMs;

  /// Time goal: distance covered in the goal's moving time.
  final double? goalDistanceM;

  /// Run time (ms since Start, pauses included) the goal was reached; the
  /// cool-down starts here.
  final int? atRunMs;

  /// Distance at Stop, from Start.
  final double stoppedAtM;

  /// "10K in 49:12" / "30 min: 6.21 km" / "Stopped at 8.4 km of 10K".
  String get resultLine {
    if (!reached) {
      return 'Stopped at ${_km(stoppedAtM)} km of $name';
    }
    return switch (kind) {
      GoalKind.distance => '$name in ${_clock(goalMs! / 1000)}',
      GoalKind.time =>
        '$name: ${(goalDistanceM! / 1000).toStringAsFixed(2)} km',
    };
  }

  static String _km(double m) => (m / 1000).toStringAsFixed(1);

  static String _clock(double seconds) {
    final t = seconds.round();
    final h = t ~/ 3600;
    if (h == 0) return PaceFormat.mmss(seconds);
    final m = (t % 3600) ~/ 60;
    return '$h:${m.toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';
  }

  /// The result of [run] against its goal [spec] (a `goal` template with
  /// one work step), or null for any other spec.
  static GoalResult? of(RunFile run, SessionSpec spec) {
    if (!spec.isGoal || spec.workSteps.length != 1 || run.samples.isEmpty) {
      return null;
    }
    final step = spec.workSteps.single;
    final trace = Trace(run.samples);
    final d0 = run.samples.first.distM;
    final stopped = run.samples.last.distM - d0;
    final pauses = [...run.pauses]..sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
    int pausedBefore(int t) {
      var p = 0;
      for (final s in pauses) {
        if (s.t0Ms >= t) break;
        p += (s.t1Ms < t ? s.t1Ms : t) - s.t0Ms;
      }
      return p;
    }

    if (step.target == TargetKind.distance) {
      final at = _timeAtDistance(run.samples, d0 + step.value);
      return GoalResult(
        kind: GoalKind.distance,
        target: step.value,
        name: spec.name,
        reached: at != null,
        goalMs: at == null ? null : at - pausedBefore(at),
        atRunMs: at,
        stoppedAtM: stopped,
      );
    }
    // Time goal: the run time at which moving time reaches the target.
    var t = step.value * 1000;
    for (final s in pauses) {
      if (s.t0Ms >= t) break;
      t += s.durationMs;
    }
    final reached = run.elapsedMs >= t;
    return GoalResult(
      kind: GoalKind.time,
      target: step.value,
      name: spec.name,
      reached: reached,
      goalDistanceM: reached ? trace.distAt(t) - d0 : null,
      atRunMs: reached ? t : null,
      stoppedAtM: stopped,
    );
  }

  /// First run time the distance stream reaches [d], interpolated; null if
  /// it never does.
  static int? _timeAtDistance(List<Sample> s, double d) {
    for (var i = 0; i < s.length; i++) {
      if (s[i].distM < d) continue;
      if (i == 0 || s[i].distM == d) return s[i].tMs;
      final a = s[i - 1];
      final b = s[i];
      return (a.tMs + (d - a.distM) / (b.distM - a.distM) * (b.tMs - a.tMs))
          .round();
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'target': target,
    'name': name,
    'reached': reached,
    'goal_ms': goalMs,
    'goal_distance_m': goalDistanceM == null
        ? null
        : double.parse(goalDistanceM!.toStringAsFixed(1)),
    'at_run_ms': atRunMs,
    'stopped_at_m': double.parse(stoppedAtM.toStringAsFixed(1)),
  };
}
