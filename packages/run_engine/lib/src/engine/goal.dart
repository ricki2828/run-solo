import '../model/run_file.dart';
import '../model/session_spec.dart';
import 'best_efforts.dart';
import 'format.dart';
import 'leaderboards.dart';
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
    this.interrupted = false,
  });

  /// A kill→resume gap before the goal: the runner kept moving while the
  /// recorder was dead, so the goal time counts time with no distance
  /// behind it (plan §G, WARN-G2). The card says so.
  final bool interrupted;

  /// Shown under [resultLine] when [interrupted].
  static const String interruptedNote =
      'The recording stopped for a while before the goal, so this may be off.';

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

    bool gapBefore(int t) => run.gaps.any((g) => g.t0Ms < t);

    if (step.target == TargetKind.distance) {
      final at = _timeAtDistance(run.samples, d0 + step.value);
      return GoalResult(
        interrupted: gapBefore(at ?? run.elapsedMs),
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
      interrupted: gapBefore(reached ? t : run.elapsedMs),
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
    'interrupted': interrupted,
  };
}

/// The standard GOAL choices and which board each ranks on (plan §G).
abstract final class GoalCatalogue {
  /// Standard distance goals (step metres) ride the best-effort boards.
  static const Map<int, BestEffortDistance> distances = {
    5000: BestEffortDistance.k5,
    10000: BestEffortDistance.k10,
    21098: BestEffortDistance.half,
    42195: BestEffortDistance.marathon,
  };

  /// Standard time goals ride the distance-in-time boards.
  static const Map<int, BestTimeWindow> times = {
    1800: BestTimeWindow.min30,
    3600: BestTimeWindow.min60,
  };

  /// The board a goal [spec] ranks on: `be:*` for a standard goal, its own
  /// goal key for a custom one (founder, 26-Sep: every custom distance and
  /// time gets a board; distances by their exact metres, which the app
  /// takes to 0.1 of the runner's unit).
  static String boardKeyOf(SessionSpec spec) {
    final w = spec.workSteps.single;
    final std = w.target == TargetKind.time
        ? times[w.value]?.key
        : distances[w.value]?.key;
    return std ?? ComparisonKey.of(spec);
  }

  /// The shown and spoken goal name ("10K done, 49:12"): the standard
  /// names, else "12.3 km" (nearest 0.1 km) or "45 min" /
  /// "1 h 15 min".
  static String nameFor(TargetKind kind, int value) {
    if (kind == TargetKind.distance) {
      return switch (value) {
        5000 => '5K',
        10000 => '10K',
        21098 => 'Half',
        42195 => 'Marathon',
        _ => '${((value / 100).round() / 10).toStringAsFixed(1)} km',
      };
    }
    if (value == 1800) return '30 min';
    if (value == 3600) return '1 hour';
    final m = (value / 60).round();
    return m < 60
        ? '$m min'
        : '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}';
  }

  static bool isStandard(SessionSpec spec) =>
      boardKeyOf(spec) != ComparisonKey.of(spec);
}

/// The goal result headline (founder, 26-Sep: result, rank, gap to best;
/// no verdict word): "10K in 49:12 · #2 of 7 · 38 s off your best",
/// "30 min: 7.21 km · #1 of 4 · new best, 120 m further", or the bare
/// result on a board with no other runs.
String goalHeadline(GoalResult g, Leaderboard? board, String runId) {
  if (!g.reached || board == null) return g.resultLine;
  final mine = g.kind == GoalKind.distance
      ? g.goalMs! / 1000
      : g.goalDistanceM!;
  final others = [
    for (final r in board.ranked)
      if (r.runId != runId) r.metric,
  ];
  if (others.isEmpty) return g.resultLine;
  final higherBetter = g.kind == GoalKind.time;
  final better = others.where((m) => higherBetter ? m > mine : m < mine).length;
  final rank = better + 1;
  final best = higherBetter
      ? others.reduce((a, b) => a > b ? a : b)
      : others.reduce((a, b) => a < b ? a : b);
  final of = others.length + 1;
  final gap = (mine - best).abs();
  final String tail;
  if (g.kind == GoalKind.distance) {
    final s = gap.round();
    tail = rank == 1
        ? (s == 0 ? 'equals your best' : 'new best, $s s faster')
        : '$s s off your best';
  } else {
    final m = gap.round();
    tail = rank == 1
        ? (m == 0 ? 'equals your best' : 'new best, $m m further')
        : '$m m short of your best';
  }
  return '${g.resultLine} · #$rank of $of · $tail';
}
