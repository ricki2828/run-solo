import 'dart:math' as math;

import '../model/session_spec.dart';
import '../run_mode.dart';
import 'best_efforts.dart';
import 'coaching_rules.dart';
import 'cooper_projection.dart';
import 'event_names.dart';
import 'goal.dart';
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

/// [distanceInTime] (§G): most distance in a fixed time (`be:t1800`, a
/// custom time goal's `goal:t2700`); metres, higher is better.
enum LiveBoardPlanKind { distance, intervals, cooper, distanceInTime }

/// One board the recorder ranks against, as the engine picked it.
class LiveBoardPlan {
  const LiveBoardPlan({
    required this.key,
    required this.label,
    required this.kind,
    this.targetM,
    required this.entries,
    this.pbSplitsMs,
    this.pbSplitsLabel,
  });

  /// A distance board's PB window (the run behind the board's best, the
  /// number the runner's PB shows): its cumulative time at each whole km of
  /// the window, km 1 up to the board's distance. These are the window's own
  /// splits (dropout-bridged), so the base is exactly the PB wherever in its
  /// run it sat; "chase your best" races it. Null off the standard 5K/10K/
  /// half/marathon boards, or when the PB's splits are missing or disagree
  /// with its finish.
  final List<int>? pbSplitsMs;

  /// Set when [pbSplitsMs] are a nearby standard board's PB (a custom 8 km
  /// goal races the 10K PB's km splits pro-rata): that board's spoken name,
  /// so the voice says "vs your 10K pace" and never calls it a best 8 km.
  final String? pbSplitsLabel;

  final String key;
  final String label;
  final LiveBoardPlanKind kind;
  final double? targetM;
  final List<LiveEntryPlan> entries;
}

/// One prior run on a live board: the series matching the board's kind.
/// [finalMetric] is in the Pigeon `LiveEntry` units: finish ms (distance),
/// mean rep pace s/km (intervals), raw VO2 (Cooper), metres (distance in
/// time).
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

  /// CR1's nudge plan for the first board (never for a Cooper); a Free /
  /// Laps run switches to the 10K board's plan past 5 km (#70 review P3).
  /// Null when no rule has enough history.
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
/// - Cooper: the Cooper board, plus the fade curve and past VO2s;
/// - a GOAL (§G): only its own board, [GoalCatalogue.boardKeyOf] (a
///   standard distance its best-effort board, a standard time its
///   distance-in-time board, a custom goal its `goal:` board). A distance
///   goal races it at each km (native `LiveCoach`: the entries' from-start
///   splits, an entry short of that km sits it out) and it decides "new
///   best" at the goal (`GoalCoach`, matched by key), so every entry
///   counts, series or not, and one earlier run is enough.
/// A board needs [minEntries] (a goal board 1); it carries at most [maxEntries] (the top 10
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
    // Live racing is against the clock: boards ranked by actual time, so the
    // ghosts are the fastest real runs (true pace is for comparing days, not
    // for racing one).
    final boards = Leaderboards.fold(
      byId.values.map((r) => r.input),
      trueRanked: false,
    );
    final out = <LiveBoardPlan>[];

    void add(
      String key,
      String label,
      LiveBoardPlanKind kind,
      double? m, {
      bool goal = false,
    }) {
      final board = boards[key];
      if (board == null || out.length >= maxBoards) return;
      final entries = _entries(board, byId, kind, m, goal: goal);
      // A goal board needs one entry: GoalCoach only checks "beats every
      // entry" and nothing races it, so a second Half can hear "new best".
      if (entries.length < (goal ? 1 : minEntries)) return;
      final own = kind == LiveBoardPlanKind.distance
          ? _pbSplits(board, byId)
          : null;
      // A custom distance goal has no best effort of its own: race the
      // nearest standard PB at or past its distance, pro-rata.
      final proxy = own == null && kind == LiveBoardPlanKind.distance && goal
          ? _proxyPbSplits(boards, byId, m)
          : null;
      out.add(
        LiveBoardPlan(
          key: key,
          label: label,
          kind: kind,
          targetM: m,
          entries: entries,
          pbSplitsMs: own ?? proxy?.$2,
          pbSplitsLabel: own == null ? proxy?.$1 : null,
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
      case RunMode.trail:
        // No boards: a trail pace is not comparable with road bests.
        break;
      case RunMode.intervals when session != null && session.isGoal:
        final key = GoalCatalogue.boardKeyOf(session);
        final time = Leaderboards.kindOf(key) == BoardKind.distanceInTime;
        add(
          key,
          session.name,
          time ? LiveBoardPlanKind.distanceInTime : LiveBoardPlanKind.distance,
          time ? null : Leaderboards.metresOf(key),
          goal: true,
        );
        // A custom distance goal nobody has finished yet (or ever reached) has
        // no board of its own, but its chase base never needed one: it comes
        // straight from the standard PB boards. A runner with a 10K PB whose
        // last 8 km attempt stopped at 6.6 km still hears the 10K pace on the
        // next one. An empty board: nothing ranks, "new best" stays quiet.
        if (out.isEmpty && !time && key.startsWith('goal:d')) {
          final m = Leaderboards.metresOf(key);
          final proxy = _proxyPbSplits(boards, byId, m);
          if (proxy != null) {
            out.add(
              LiveBoardPlan(
                key: key,
                label: session.name,
                kind: LiveBoardPlanKind.distance,
                targetM: m,
                entries: const [],
                pbSplitsMs: proxy.$2,
                pbSplitsLabel: proxy.$1,
              ),
            );
          }
        }
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
    NudgePlanSpec? nudgesOf(LiveBoardPlan b) =>
        _nudges(b, boards[b.key]!, byId, session);
    return LivePlan(
      boards: out,
      nudges: mode == RunMode.cooper || out.isEmpty || session?.isGoal == true
          ? null
          : _handOver(nudgesOf(out.first), switch (out) {
              [LiveBoardPlan(key: final a), final b, ...]
                  when a == k5.key && b.key == k10.key =>
                nudgesOf(b),
              _ => null,
            }),
      cooperCurve: curve,
      cooperHistory: history == null || history.isEmpty ? null : history,
    );
  }

  /// Free / Laps race the 5K board to km 5, then the 10K board: km 1 to 5
  /// nudge off [k5]'s plan, km 6 on off [k10]'s. Only the HR drift rule
  /// reaches past km 5; fast start is km 1, so it stays the 5K's.
  static NudgePlanSpec? _handOver(NudgePlanSpec? k5, NudgePlanSpec? k10) {
    final hr10 = k10?.hrDrift;
    if (hr10 == null || hr10.kmSamples.length <= _handOverKm) return k5;
    final hr5 = k5?.hrDrift;
    final kms = [
      for (var k = 0; k < _handOverKm; k++)
        hr5 == null || k >= hr5.kmSamples.length
            ? const <(double, double)>[]
            : hr5.kmSamples[k],
      ...hr10.kmSamples.skip(_handOverKm),
    ];
    final plan = NudgePlanSpec(
      fastStart: k5?.fastStart,
      hrDrift: kms.every((p) => p.length < HrDriftRule.minSimilar)
          ? null
          : HrDriftRule(kmSamples: kms, text: hr10.text),
      // Each board blocks its own kms: the 5K's newest run to km 5, the
      // 10K's past it.
      blocked: [
        for (final b in k5?.blocked ?? const <String>[])
          if ((_blockedKm(b) ?? 0) <= _handOverKm) b,
        for (final b in k10!.blocked)
          if ((_blockedKm(b) ?? 0) > _handOverKm) b,
      ],
    );
    return plan.isEmpty ? null : plan;
  }

  static const int _handOverKm = 5;

  /// The km of a "hr_drift:k" blocked pair; null for any other rule.
  static int? _blockedKm(String pair) {
    const prefix = '${NudgeRule.hrDrift}:';
    return pair.startsWith(prefix)
        ? int.tryParse(pair.substring(prefix.length))
        : null;
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
      LiveBoardPlanKind.cooper || LiveBoardPlanKind.distanceInTime => null,
    };
  }

  /// The smallest standard board (5K, 10K, Half, Marathon) at or past [goalM]
  /// that has a PB with usable window splits, as (its spoken name, those
  /// splits): a custom 8 km goal races the 10K PB's first 8 km, worded "your
  /// 10K pace". Null when the goal is past the marathon or none has a PB.
  static (String, List<int>)? _proxyPbSplits(
    Map<String, Leaderboard> boards,
    Map<String, LiveCandidate> byId,
    double? goalM,
  ) {
    if (goalM == null) return null;
    const names = {
      BestEffortDistance.k5: '5K',
      BestEffortDistance.k10: '10K',
      BestEffortDistance.half: 'Half',
      BestEffortDistance.marathon: 'Marathon',
    };
    for (final d in names.keys) {
      if (d.metres + 1 < goalM) continue;
      final b = boards[d.key];
      final splits = b == null ? null : _pbSplits(b, byId);
      if (splits != null) return (names[d]!, splits);
      return null; // the nearest board has no usable PB: silent, not a farther one
    }
    return null;
  }

  /// Custom goals (an 8 km race) and course boards have no standard best
  /// effort of their own: course boards stay silent for "chase your best"
  /// (their last-2-km and furthest lines still say); a custom distance goal
  /// borrows the nearest standard PB, see [_proxyPbSplits].
  ///
  /// The PB window's cumulative km splits for a standard distance board: the
  /// effort's own `splitsMs` (every 1 km strictly inside the window) plus its
  /// finish when that is a whole km (5K, 10K). Null when the PB run has no
  /// such effort, the count is not the board's km, or the finish disagrees
  /// with the board's metric by over 1.5 s (a stale or mismatched effort).
  static List<int>? _pbSplits(
    Leaderboard board,
    Map<String, LiveCandidate> byId,
  ) {
    final d = BestEffortDistance.ofKey(board.key);
    final pb = board.pb;
    if (d == null || pb == null) return null;
    final e = byId[pb.runId]?.input.efforts[d];
    if (e == null) return null;
    final km = (d.metres / 1000).round();
    final out = [...e.splitsMs];
    if (out.length == km - 1) out.add(e.elapsedMs);
    if (out.length != km) return null;
    if ((e.elapsedMs - pb.metric * 1000).abs() > 1500) return null;
    for (var i = 0; i < out.length; i++) {
      if (out[i] <= 0 || (i > 0 && out[i] <= out[i - 1])) return null;
    }
    return out;
  }

  static List<LiveEntryPlan> _entries(
    Leaderboard board,
    Map<String, LiveCandidate> byId,
    LiveBoardPlanKind kind,
    double? metres, {
    bool goal = false,
  }) {
    LiveEntryPlan? entry(BoardRun r) {
      final c = byId[r.runId];
      if (c == null) return null;
      final live = c.derived.live;
      switch (kind) {
        case LiveBoardPlanKind.distance:
          final km = (metres! / 1000).round();
          final splits = c.derived.bestEfforts.fromStartSplitsMs;
          // A goal board keeps every entry (a short ghost is fine, nothing
          // races it): dropping the PB would let "new best" lie.
          if (splits.length < km && !goal) return null;
          return LiveEntryPlan(
            runId: r.runId,
            date: r.date,
            fromStartSplitsMs: splits.sublist(0, math.min(km, splits.length)),
            // Board seconds to finish ms. For a goal this is the windowed
            // best effort while the goal time runs from Start, so "new
            // best" is conservative (harder to beat), never a false claim.
            finalMetric: r.metric * 1000,
          );
        case LiveBoardPlanKind.distanceInTime:
          // No per-minute ghost for time goals yet (nothing races it); the
          // contract only needs the series present.
          return LiveEntryPlan(
            runId: r.runId,
            date: r.date,
            cooperMinuteM: const [],
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
