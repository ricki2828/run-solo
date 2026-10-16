import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/history_store.dart';
import '../state/quests/quest_store.dart';
import 'services.dart';

/// What the progress snapshot needs from quests: the weeks the streak
/// ignores, and the finished quests (for the QUEST DONE moment).
class QuestSync {
  const QuestSync({
    this.pausedWeeks = const {},
    this.localPaused = const {},
    this.history = const [],
  });

  /// Runner pauses plus the coach's care weeks (Monday-start indices).
  final Set<int> pausedWeeks;

  /// Only the runner's own pauses: the ones the Undo button can lift.
  final Set<int> localPaused;
  final List<QuestHistoryEntry> history;

  static const none = QuestSync();
}

/// The Monday-start week indices of [care] Mondays, merged with [local].
Set<int> mergePausedWeeks(Set<int> local, Iterable<DateTime> care) => {
  ...local,
  for (final d in care) engine.ProgressMath.weekIndex(d),
};

/// Closes and offers quests for [runs], adopts a quest accepted in Telegram,
/// and returns what the snapshot needs. Never throws: a failure here must not
/// take a screen with it.
Future<QuestSync> syncQuests(AppServices s, List<RunSummary> runs) async {
  try {
    final c = s.companion;
    final cq = c?.coachQuest;
    final st = await s.quests.refresh(
      runs,
      s.now(),
      coachQuest: cq == null ? null : (id: cq.id, acceptedAt: cq.acceptedAt),
    );
    return QuestSync(
      pausedWeeks: mergePausedWeeks(st.pausedWeeks, c?.careWeeks ?? const []),
      localPaused: st.pausedWeeks,
      history: st.history,
    );
  } catch (e) {
    debugPrint('quests: sync failed ($e)');
    return QuestSync.none;
  }
}
