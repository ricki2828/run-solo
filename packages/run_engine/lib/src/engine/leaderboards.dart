import 'dart:math' as math;

import '../model/session_spec.dart';
import '../run_mode.dart';
import 'best_efforts.dart';

/// What a board fold needs to know about one run (Phase 4 plan §3.1, LB2).
/// Built by the app from its index entry; the engine never reads files.
class BoardInput {
  const BoardInput({
    required this.runId,
    required this.date,
    required this.mode,
    this.comparisonKey,
    this.efforts = const {},
    this.distances = const {},
    this.headlineSecPerKm,
    this.verdictGrade = false,
    this.officialTimeMs,
    this.cooperVo2,
    this.cooperVo2Adj,
    this.heatFraction,
  });

  final String runId;
  final DateTime date;
  final RunMode mode;
  final String? comparisonKey;
  final Map<BestEffortDistance, BestEffort> efforts;

  /// Most distance per time window (§G time boards).
  final Map<BestTimeWindow, BestDistance> distances;

  /// I3's headline metric (avg work pace, s/km) for a structured session.
  final double? headlineSecPerKm;

  /// The session has a verdict-grade set (it may serve as a prior).
  final bool verdictGrade;

  /// K1's official parkrun time from the sidecar; wins over the GPS time.
  final int? officialTimeMs;

  /// A valid Cooper test's raw VO2 estimate, and its heat-adjusted twin.
  final double? cooperVo2;
  final double? cooperVo2Adj;

  /// Steady-effort heat slowdown (§18.5; 0.047 = 4.7%); null without
  /// weather or when too hot to compare. Only for the heat column.
  final double? heatFraction;
}

/// One run's value on one board.
class BoardRun {
  const BoardRun({
    required this.runId,
    required this.date,
    required this.metric,
    this.adjMetric,
  });

  final String runId;
  final DateTime date;

  /// Seconds (time boards), s/km (interval boards) or VO2 (Cooper).
  final double metric;

  /// The heat-adjusted twin for the heat column; never used for rank.
  final double? adjMetric;
}

/// How a board's metric reads.
enum BoardKind {
  /// Best-effort time in seconds; lower is better.
  bestEffort,

  /// Course time in seconds (official if entered, else GPS); lower better.
  course,

  /// I3 headline pace, s/km; lower is better.
  interval,

  /// Cooper VO2 estimate; higher is better.
  cooper,

  /// Most distance in 30 / 60 min (GOAL time boards, §G), metres; higher is
  /// better. Trend in metres per month.
  distanceInTime,
}

/// A trend over a board's recent entries.
class BoardTrend {
  const BoardTrend(this.perMonth, this.entries);

  /// Theil–Sen slope per 30 days: s/km for time and interval boards (the
  /// pace the time implies), VO2 for Cooper. Negative pace = faster.
  final double perMonth;
  final int entries;
}

/// One personal leaderboard: a fold over the index (plan §3.1).
class Leaderboard {
  Leaderboard._(this.key, this.kind, this.metres, this.ranked);

  /// Rank [runs] on [key]. Ties: the earlier date ranks higher.
  factory Leaderboard.of(
    String key,
    BoardKind kind,
    List<BoardRun> runs, {
    double? metres,
  }) {
    final higher = kind == BoardKind.cooper || kind == BoardKind.distanceInTime;
    final ranked = [...runs]
      ..sort((a, b) {
        final c = higher
            ? b.metric.compareTo(a.metric)
            : a.metric.compareTo(b.metric);
        return c != 0 ? c : a.date.compareTo(b.date);
      });
    return Leaderboard._(key, kind, metres, List.unmodifiable(ranked));
  }

  final String key;
  final BoardKind kind;

  /// The board's distance for time boards (pace for the trend).
  final double? metres;

  /// Best first.
  final List<BoardRun> ranked;

  int get length => ranked.length;

  BoardRun? get pb => ranked.isEmpty ? null : ranked.first;

  /// 1-based rank of [runId], or null when it is not on the board.
  int? rankOf(String runId) {
    final i = ranked.indexWhere((r) => r.runId == runId);
    return i < 0 ? null : i + 1;
  }

  /// The five newest entries, newest first.
  List<BoardRun> get last5 {
    final byDate = [...ranked]..sort((a, b) => b.date.compareTo(a.date));
    return byDate.take(5).toList();
  }

  /// Minimum entries in the last [trendWindow] for a trend line.
  static const int trendMinEntries = 4;
  static const Duration trendWindow = Duration(days: 90);

  /// How many of the newest entries the slope uses.
  static const int trendSpan = 8;

  /// Theil–Sen slope over the last [trendSpan] entries, or null (shown as
  /// "Not enough runs yet") with fewer than [trendMinEntries] in 90 days.
  BoardTrend? trend(DateTime now) {
    final since = now.subtract(trendWindow);
    final recent = ranked.where((r) => !r.date.isBefore(since)).length;
    if (recent < trendMinEntries) return null;
    final byDate = [...ranked]..sort((a, b) => a.date.compareTo(b.date));
    final pts = byDate.skip(math.max(0, byDate.length - trendSpan)).toList();
    final timeBoard = kind == BoardKind.bestEffort || kind == BoardKind.course;
    if (timeBoard && metres == null) {
      throw StateError('time board $key has no distance for its pace trend');
    }
    double y(BoardRun r) => timeBoard ? r.metric / (metres! / 1000) : r.metric;
    final slopes = <double>[];
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        final days =
            pts[j].date.difference(pts[i].date).inMilliseconds / 86400000;
        if (days <= 0) continue;
        slopes.add((y(pts[j]) - y(pts[i])) / days * 30);
      }
    }
    if (slopes.isEmpty) return null;
    slopes.sort();
    final m = slopes.length ~/ 2;
    final median = slopes.length.isOdd
        ? slopes[m]
        : (slopes[m - 1] + slopes[m]) / 2;
    return BoardTrend(median, pts.length);
  }
}

/// Board membership (plan §3.1, WARN-8) and the folds.
abstract final class Leaderboards {
  /// Board keys use this reserved prefix; no comparison key may.
  static const String reservedPrefix = BestEffortDistance.keyPrefix;

  /// Every board a run belongs to, with its value there:
  /// - `be:1000`, `be:1609`, `be:5000`, `be:10000`: its best efforts (a
  ///   parkrun counts here too);
  /// - `parkrun:<course>`: official time if entered, else its GPS 5K; runs
  ///   tagged parkrun with no course (before K1) sit on no course board;
  /// - an interval comparison key: I3's headline, verdict-grade sets only;
  /// - `cooper`: VO2 raw, higher is better.
  ///
  /// Throws [StateError] if a comparison key uses the reserved `be:` prefix
  /// (it would collide with a best-effort board).
  static Map<String, BoardRun> membership(BoardInput r) {
    final key = r.comparisonKey;
    if (key != null && key.startsWith(reservedPrefix)) {
      throw StateError(
        'comparison key "$key" uses the reserved "$reservedPrefix"',
      );
    }
    double? adj(double seconds) =>
        r.heatFraction == null ? null : seconds * (1 - r.heatFraction!);
    final out = <String, BoardRun>{
      for (final e in r.efforts.values)
        e.distance.key: BoardRun(
          runId: r.runId,
          date: r.date,
          metric: e.elapsedMs / 1000,
          adjMetric: adj(e.elapsedMs / 1000),
        ),
      // Distance in time: heat makes it shorter, so the cool twin is longer.
      for (final d in r.distances.values)
        d.window.key: BoardRun(
          runId: r.runId,
          date: r.date,
          metric: d.metres,
          adjMetric: r.heatFraction == null
              ? null
              : d.metres / (1 - r.heatFraction!),
        ),
    };
    // A GOAL run (§G) rides the be:* boards only; its own key is no board.
    if (key == null || ComparisonKey.isGoal(key)) return out;
    if (ComparisonKey.isParkrun(key)) {
      if (key == ComparisonKey.parkrun) return out;
      final gps = r.efforts[BestEffortDistance.k5];
      final ms = r.officialTimeMs ?? gps?.elapsedMs;
      if (ms != null) {
        out[key] = BoardRun(
          runId: r.runId,
          date: r.date,
          metric: ms / 1000,
          adjMetric: adj(ms / 1000),
        );
      }
      return out;
    }
    if (key == ComparisonKey.cooper) {
      if (r.cooperVo2 != null) {
        out[key] = BoardRun(
          runId: r.runId,
          date: r.date,
          metric: r.cooperVo2!,
          adjMetric: r.cooperVo2Adj,
        );
      }
      return out;
    }
    if (r.mode == RunMode.intervals &&
        r.verdictGrade &&
        r.headlineSecPerKm != null &&
        key != ComparisonKey.fartlek) {
      out[key] = BoardRun(
        runId: r.runId,
        date: r.date,
        metric: r.headlineSecPerKm!,
        adjMetric: r.heatFraction == null
            ? null
            : r.headlineSecPerKm! * (1 - r.heatFraction!),
      );
    }
    return out;
  }

  static BoardKind kindOf(String key) {
    if (BestTimeWindow.ofKey(key) != null) return BoardKind.distanceInTime;
    if (key.startsWith(reservedPrefix)) return BoardKind.bestEffort;
    if (ComparisonKey.isParkrun(key)) return BoardKind.course;
    if (key == ComparisonKey.cooper) return BoardKind.cooper;
    return BoardKind.interval;
  }

  static double? metresOf(String key) {
    final be = BestEffortDistance.ofKey(key);
    if (be != null) return be.metres;
    if (ComparisonKey.isParkrun(key)) return 5000;
    return null;
  }

  /// Every board across [runs], keyed by board key.
  static Map<String, Leaderboard> fold(Iterable<BoardInput> runs) {
    final byKey = <String, List<BoardRun>>{};
    for (final r in runs) {
      for (final e in membership(r).entries) {
        (byKey[e.key] ??= []).add(e.value);
      }
    }
    return {
      for (final e in byKey.entries)
        e.key: Leaderboard.of(
          e.key,
          kindOf(e.key),
          e.value,
          metres: metresOf(e.key),
        ),
    };
  }
}
