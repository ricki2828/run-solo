/// Builds the quest view from the run history. Pure: the same runs, clock and
/// state give the same board. Progress is folded from the runs every time and
/// never stored.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../../platform/gateway.dart' show RecordMode;
import '../history_store.dart';
import '../trails.dart';
import 'quest_store.dart';

/// Quests are on. `--dart-define=QUESTS=false` turns them off.
const bool kQuestsEnabled = bool.fromEnvironment('QUESTS', defaultValue: true);

/// Quests show from the runner's 2nd week: this many days after their first
/// run (testers get no quest on day one; no holdout).
const int kQuestsFromDays = int.fromEnvironment(
  'QUESTS_FROM_DAYS',
  defaultValue: 7,
);

/// The lane a quest is tinted with. Trail boards carry no lane of their own
/// (they use the run-type colour), so trail quests take LONG (ice), the lane
/// trail runs score into; climbs take MID (violet); distance takes AEROBIC.
engine.IdentityLane questLane(engine.QuestKind k) => switch (k) {
  engine.QuestKind.trailVisits ||
  engine.QuestKind.trailBest => engine.IdentityLane.long,
  engine.QuestKind.climbBest ||
  engine.QuestKind.climbMonth => engine.IdentityLane.mid,
  engine.QuestKind.distanceMonth => engine.IdentityLane.aerobic,
};

/// The runs as the engine reads them, plus the trail names and each run's
/// mode (for the segment colours).
class QuestInputs {
  const QuestInputs({
    required this.runs,
    required this.trailNames,
    required this.modes,
  });

  final List<engine.QuestRun> runs;
  final Map<String, String> trailNames;
  final Map<String, RecordMode> modes;

  static const empty = QuestInputs(runs: [], trailNames: {}, modes: {});
}

/// Index-row fields only. Trail grouping honours the runner's overrides
/// (`Trails.group`), the like-for-like time is `TrailGroup.normMs`.
QuestInputs questInputsOf(Iterable<RunSummary> all) {
  final usable = [
    for (final s in all)
      if (!s.missing && s.durationMs > 0 && s.distanceM > 0) s,
  ];
  final groups = engine.Trails.group(trailFactsOfAll(usable));
  final keyOf = <String, engine.TrailGroup>{};
  final facts = <String, engine.TrailRunFacts>{};
  for (final g in groups) {
    for (final r in g.runs) {
      keyOf[r.id] = g;
      facts[r.id] = r;
    }
  }
  return QuestInputs(
    runs: [
      for (final s in usable)
        engine.QuestRun(
          id: s.id,
          start: s.localStart,
          distanceM: s.distanceM,
          climbM: s.row?.climbM,
          baro: s.row?.elevSrc == engine.ElevSource.baro,
          trailKey: keyOf[s.id]?.key,
          normMs: keyOf[s.id]?.normMs(facts[s.id]!),
        ),
    ],
    trailNames: {for (final g in groups) g.key: g.name},
    modes: {for (final s in usable) s.id: s.mode},
  );
}

/// Quests show once the runner is in their 2nd week, and the flag is on.
bool questsExposed(List<engine.QuestRun> runs, DateTime now) {
  if (!kQuestsEnabled || runs.isEmpty) return false;
  final first = runs
      .map((r) => r.start)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  return now.difference(first) >= const Duration(days: kQuestsFromDays);
}

/// Closes a finished active quest (done, or expired) and rolls the monthly
/// offer. Returns [s] itself when nothing changed.
QuestState reconcileQuests(
  QuestState s,
  QuestInputs inputs,
  DateTime now, {
  bool exposed = true,
  List<engine.QuestClimb> climbs = const [],
}) {
  var out = s;
  final active = out.active;
  if (active != null) {
    final p = engine.Quests.progress(active, inputs.runs);
    final today = engine.Quests.isoDay(now);
    if (p.complete) {
      out = out.copyWith(
        active: null,
        history: [
          ...out.history,
          QuestHistoryEntry(
            def: active,
            result: 'done',
            closedOn: today,
            doneRunId: p.completedByRunId,
          ),
        ],
      );
    } else if (engine.Quests.expired(active, now)) {
      out = out.copyWith(
        active: null,
        history: [
          ...out.history,
          QuestHistoryEntry(def: active, result: 'expired', closedOn: today),
        ],
      );
    }
  }
  if (out.active == null && exposed) {
    final month = engine.Quests.monthOf(now);
    if (out.offer?.month != month) {
      final candidates = engine.Quests.candidates(
        inputs.runs,
        now,
        closed: [for (final h in out.history) h.def],
        climbs: climbs,
        trailNames: inputs.trailNames,
      );
      out = out.copyWith(
        offer: candidates.isEmpty
            ? null
            : QuestOffer(month: month, candidates: candidates),
      );
    }
  }
  return out;
}

/// One run's share of a counter quest's bar.
class QuestSegment {
  const QuestSegment({
    required this.runId,
    required this.share,
    required this.mode,
  });
  final String runId;

  /// 0..1 of the target this run added.
  final double share;
  final RecordMode mode;
}

/// What the QUESTS section draws.
class QuestBoard {
  const QuestBoard({
    this.active,
    this.progress,
    this.daysLeft = 0,
    this.segments = const [],
    this.recentMs = const [],
    this.recentDates = const [],
    this.offer,
    this.offerCount = 0,
    this.history = const [],
  });

  final engine.QuestDef? active;
  final engine.QuestProgress? progress;
  final int daysLeft;

  /// Counter kinds: one segment per contributing run, oldest first.
  final List<QuestSegment> segments;

  /// Best-time kinds: the last up to 10 like-for-like times on the trail,
  /// oldest first, and their dates.
  final List<int> recentMs;
  final List<DateTime> recentDates;

  /// The open offer on show, if no quest is active.
  final engine.QuestDef? offer;
  final int offerCount;

  /// The last 6 finished quests, newest first.
  final List<QuestHistoryEntry> history;

  bool get isEmpty => active == null && offer == null && history.isEmpty;

  static const empty = QuestBoard();
}

QuestBoard buildQuestBoard(
  QuestState s,
  QuestInputs inputs,
  DateTime now, {
  bool exposed = true,
}) {
  if (!exposed) return QuestBoard.empty;
  final history = s.history.reversed.take(6).toList();
  final active = s.active;
  if (active == null) {
    final o = s.offer;
    return QuestBoard(
      offer: o?.current,
      offerCount: o?.open == true ? o!.candidates.length : 0,
      history: history,
    );
  }
  final p = engine.Quests.progress(active, inputs.runs);
  final byId = {for (final r in inputs.runs) r.id: r};
  final segments = <QuestSegment>[];
  final recentMs = <int>[];
  final recentDates = <DateTime>[];
  switch (active.kind) {
    case engine.QuestKind.trailVisits:
    case engine.QuestKind.climbMonth:
    case engine.QuestKind.distanceMonth:
      for (final id in p.contributingRunIds) {
        final r = byId[id];
        if (r == null) continue;
        final v = switch (active.kind) {
          engine.QuestKind.trailVisits => 1.0,
          engine.QuestKind.climbMonth => r.climbM ?? 0,
          _ => r.distanceM / 1000,
        };
        segments.add(
          QuestSegment(
            runId: id,
            share: active.target <= 0 ? 0 : v / active.target,
            mode: inputs.modes[id] ?? RecordMode.free,
          ),
        );
      }
    case engine.QuestKind.trailBest:
      final onTrail = [
        for (final r in inputs.runs)
          if (r.trailKey == active.trailKey && r.normMs != null) r,
      ]..sort((a, b) => a.start.compareTo(b.start));
      final last = onTrail.length > 10
          ? onTrail.sublist(onTrail.length - 10)
          : onTrail;
      for (final r in last) {
        recentMs.add(r.normMs!);
        recentDates.add(r.start);
      }
    case engine.QuestKind.climbBest:
      break;
  }
  return QuestBoard(
    active: active,
    progress: p,
    daysLeft: engine.Quests.daysLeft(active, now),
    segments: segments,
    recentMs: recentMs,
    recentDates: recentDates,
    history: history,
  );
}

/// "SADDLE ×5 · done 14 Nov".
String questHistoryLine(QuestHistoryEntry h) {
  final d = engine.Quests.parseDay(h.closedOn);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
    'Nov', 'Dec', //
  ];
  final when = d == null ? '' : ' ${d.day} ${months[d.month - 1]}';
  final word = switch (h.result) {
    'done' => 'done',
    'dropped' => 'dropped',
    _ => 'ran out',
  };
  return '${h.def.title} · $word$when';
}
