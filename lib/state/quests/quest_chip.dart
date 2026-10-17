/// The chip a result screen shows when a run completes or advances the quest (quests spec §4): one chip in
/// the existing board-chip row, never a card of its own.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'quest_build.dart';
import 'quest_store.dart';

class QuestChip {
  const QuestChip({required this.label, required this.done});

  /// "QUEST 3 OF 5", "QUEST 640 OF 1,000 M", "QUEST 84 OF 120 KM", or "QUEST DONE".
  final String label;

  /// The run finished the quest: shown in the PB colour (cyan is for a best).
  final bool done;
}

/// The chip for [runId], or null when the run did nothing for the quest.
/// - the run that crossed the line, while the quest is still active or after it was closed as done: QUEST DONE;
/// - a run that counted toward an active counter quest (trail visits, climb, distance): its progress.
/// A best-time quest has no running count, so it only ever shows DONE.
QuestChip? questChipFor(QuestState state, QuestInputs inputs, String runId) {
  const done = QuestChip(label: 'QUEST DONE', done: true);
  for (final h in state.history.reversed) {
    if (h.result == 'done' && h.doneRunId == runId) return done;
  }
  final a = state.active;
  if (a == null) return null;
  final p = engine.Quests.progress(a, inputs.runs);
  if (p.complete && p.completedByRunId == runId) return done;
  if (p.complete || !p.contributingRunIds.contains(runId)) return null;
  final target = engine.Quests.fmtInt(a.target);
  return switch (a.kind) {
    engine.QuestKind.trailVisits => QuestChip(
      label: 'QUEST ${p.value.floor()} OF $target',
      done: false,
    ),
    engine.QuestKind.climbMonth => QuestChip(
      label: 'QUEST ${engine.Quests.fmtInt(p.value)} OF $target M',
      done: false,
    ),
    engine.QuestKind.distanceMonth => QuestChip(
      label: 'QUEST ${p.value.floor()} OF $target KM',
      done: false,
    ),
    engine.QuestKind.trailBest || engine.QuestKind.climbBest => null,
  };
}
