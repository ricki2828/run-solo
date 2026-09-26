import '../model/session_spec.dart';
import '../run_mode.dart';
import 'best_efforts.dart';
import 'coaching_rules.dart';
import 'cooper_projection.dart';
import 'event_names.dart';
import 'leaderboards.dart';
import 'live_figures.dart';

/// One earlier run the live compare may race (Phase 4 §3.2, LC1): its
/// board input and its derived data (from-start splits, live rep paces,
/// Cooper minutes). Built by the app from its index entry.
class LiveCandidate {
  const LiveCandidate(this.input, this.derived, {this.durationMs = 0});

  final BoardInput input;
  final RunDerived derived;

  /// Whole-run duration (the coaching rules' history input).
  final int durationMs;

  CoachRun get coachRun => CoachRun(
    runId: input.runId,
    date: input.date,
    mode: input.mode,
    derived: derived,
    durationMs: durationMs,
    comparisonKey: input.comparisonKey,
    cooperVo2: input.cooperVo2,
  );
}

enum LiveBoardPlanKind { distance, intervals, cooper }

/// One board the recorder ranks against, as the engine picked it.
class LiveBoardPlan {
  const LiveBoardPlan({
    required this.key,
    required this.label,
    required this.kind,
    this.targetM,
    required this.entries,
  });

  final String key;
  final String label;
  final LiveBoardPlanKind kind;
  final double? targetM;
  final List<LiveEntryPlan> entries;
}

/// One prior run on a live board: the series matching the board's kind.
class LiveEntryPlan {
  const LiveEntryPlan({
    required this.runId,
    required this.date,
    this.fromStartSplitsMs,
    this.liveRepPacesSecPerKm,
    this.cooperMinuteM,
    required this.finalMetric,
  });

  final String runId;
  final DateTime date;
  final List<int>? fromStartSplitsMs;
  final List<double?>? liveRepPacesSecPerKm;
  final List<double>? cooperMinuteM;
  final double finalMetric;
}

/// Everything the recorder needs for the live compare of one Start.
class LivePlan {
  const LivePlan({
    required this.boards,
    this.nudges,
    this.cooperCurve,
    this.cooperHistory,
  });

  final List<LiveBoardPlan> boards;

  /// CR1's nudge plan for the first board (never for a Cooper); null when
  /// no rule has enough history.
  final NudgePlanSpec? nudges;

  /// Cooper: the fade curve for this test (default, or personal from test 3).
  final List<double>? cooperCurve;

  /// Cooper: past raw VO2 estimates, oldest first.
  final List<double>? cooperHistory;

  bool get isEmpty => boards.isEmpty && cooperCurve == null;
}

/// Which boards a run races live and what each carries (Phase 4 §3.2):
/// - the Saturday 5 km: its course board when the course is known, else
///   the 5K board;
/// - Free / Laps: the 5K board (km 1 to 5), then the 10K board (km 6 to 10);
/// - Intervals: the session's comparison-key board;
/// - Cooper: the Cooper board, plus the fade curve and past VO2s.
/// A board needs [minEntries]; it carries at most [maxEntries] (the top 10
/// and the newest 10, deduped), and only entries that have the series the
/// live compare reads (a 5K entry needs 5 from-start splits). Pure.
abstract final class LivePlanner {
  static const int maxBoards = 3;
  static const int maxEntries = 20;
  static const int topN = 10;
  static const int newestN = 10;
  static const int minEntries = 2;

  static LivePlan plan({
    required RunMode mode,
    SessionSpec? session,
    String? courseKey,
    required Iterable<LiveCandidate> runs,
    EventNames names = EventNames.generic,
  }) {
    final byId = {for (final r in runs) r.input.runId: r};
    final boards = Leaderboards.fold(byId.values.map((r) => r.input));
    final out = <LiveBoardPlan>[];

    void add(String key, String label, LiveBoardPlanKind kind, double? m) {
      final board = boards[key];
      if (board == null || out.length >= maxBoards) return;
      final entries = _entries(board, byId, kind, m);
      if (entries.length < minEntries) return;
      out.add(
        LiveBoardPlan(
          key: key,
          label: label,
          kind: kind,
          targetM: m,
          entries: entries,
        ),
      );
    }

    final k5 = BestEffortDistance.k5;
    final k10 = BestEffortDistance.k10;
    List<double>? curve;
    List<double>? history;
    switch (mode) {
      case RunMode.free:
      case RunMode.laps:
        add(k5.key, '5K', LiveBoardPlanKind.distance, k5.metres);
        add(k10.key, '10K', LiveBoardPlanKind.distance, k10.metres);
      case RunMode.intervals:
        if (session?.templateId == SessionSpec.parkrunId) {
          final course = courseKey;
          final before = out.length;
          if (course != null) {
            add(course, names.parkrun, LiveBoardPlanKind.distance, 5000);
          }
          if (out.length == before) {
            add(k5.key, '5K', LiveBoardPlanKind.distance, k5.metres);
          }
        } else {
          final key = session?.comparisonKey;
          if (key != null) {
            add(key, session!.name, LiveBoardPlanKind.intervals, null);
          }
        }
      case RunMode.cooper:
        add(
          ComparisonKey.cooper,
          SessionSpec.cooper.name,
          LiveBoardPlanKind.cooper,
          null,
        );
        final tests = [
          for (final r
              in (byId.values.toList()
                ..sort((a, b) => a.input.date.compareTo(b.input.date))))
            if (r.input.comparisonKey == ComparisonKey.cooper &&
                r.derived.live.cooperMinuteM.length == CooperProjection.minutes)
              r,
        ];
        curve = CooperProjection.curveFor([
          for (final t in tests) t.derived.live.cooperMinuteM,
        ]).fractions;
        history = [for (final t in tests) ?t.input.cooperVo2];
    }
    return LivePlan(
      boards: out,
      nudges: mode == RunMode.cooper || out.isEmpty
          ? null
          : _nudges(out.first, boards[out.first.key]!, byId, session),
      cooperCurve: curve,
      cooperHistory: history == null || history.isEmpty ? null : history,
    );
  }

  /// CR1 (plan §3.5) over every earlier run on [plan]'s board, not just the
  /// 20 raced: a distance board by its km, an interval board by its key.
  static NudgePlanSpec? _nudges(
    LiveBoardPlan plan,
    Leaderboard board,
    Map<String, LiveCandidate> byId,
    SessionSpec? session,
  ) {
    final history = [for (final r in board.ranked) ?byId[r.runId]?.coachRun];
    const rules = CoachingRules();
    return switch (plan.kind) {
      LiveBoardPlanKind.distance => rules.forDistanceBoard(
        boardKm: (plan.targetM! / 1000).round(),
        boardLabel: plan.label,
        history: history,
      ),
      LiveBoardPlanKind.intervals => rules.forIntervalBoard(
        key: plan.key,
        history: history,
        templateDefault: session,
      ),
      LiveBoardPlanKind.cooper => null,
    };
  }

  static List<LiveEntryPlan> _entries(
    Leaderboard board,
    Map<String, LiveCandidate> byId,
    LiveBoardPlanKind kind,
    double? metres,
  ) {
    LiveEntryPlan? entry(BoardRun r) {
      final c = byId[r.runId];
      if (c == null) return null;
      final live = c.derived.live;
      switch (kind) {
        case LiveBoardPlanKind.distance:
          final km = (metres! / 1000).round();
          final splits = c.derived.bestEfforts.fromStartSplitsMs;
          if (splits.length < km) return null;
          return LiveEntryPlan(
            runId: r.runId,
            date: r.date,
            fromStartSplitsMs: splits.sublist(0, km),
            finalMetric: r.metric,
          );
        case LiveBoardPlanKind.intervals:
          if (live.repPacesSecPerKm.isEmpty) return null;
          return LiveEntryPlan(
            runId: r.runId,
            date: r.date,
            liveRepPacesSecPerKm: live.repPacesSecPerKm,
            finalMetric: r.metric,
          );
        case LiveBoardPlanKind.cooper:
          if (live.cooperMinuteM.length != CooperProjection.minutes) {
            return null;
          }
          return LiveEntryPlan(
            runId: r.runId,
            date: r.date,
            cooperMinuteM: live.cooperMinuteM,
            finalMetric: r.metric,
          );
      }
    }

    // Only entries the live compare can read; then the best and the newest.
    final usable = [
      for (final r in board.ranked)
        if (entry(r) case final e?) (r, e),
    ];
    final top = usable.take(topN);
    final newest = [...usable]..sort((a, b) => b.$1.date.compareTo(a.$1.date));
    final picked = <String, LiveEntryPlan>{};
    for (final (r, e) in [...top, ...newest.take(newestN)]) {
      picked.putIfAbsent(r.runId, () => e);
    }
    return picked.values.take(maxEntries).toList();
  }
}
