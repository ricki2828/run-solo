/// The active quest, packed for the recorder at Start (quests spec §5.3). Kotlin never reads history, so
/// everything it needs to say "quest done" is worked out here from the in-memory index rows: no file I/O.
library;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../../platform/gateway.dart';
import '../history_store.dart';
import 'quest_build.dart';
import 'quests_controller.dart';

/// Modes that can say "quest done" live. A structured session (intervals, Cooper) keeps its own cues; its
/// run still counts for the quest and completes on the result screen and the Moment.
const Set<RecordMode> kLiveQuestModes = {
  RecordMode.free,
  RecordMode.trail,
  RecordMode.laps,
};

/// [active] as a [LiveQuest], or null when there is no live beat for it: `trail_best` (its heat factor is only
/// final at finalise), `climb_best` (not offered yet, so its climb span is not kept), a quest already done,
/// and a trail visit that is not the last one.
LiveQuest? liveQuestOf(engine.QuestDef active, engine.QuestProgress p) {
  if (p.complete) return null;
  if (active.kind == engine.QuestKind.climbBest) return null;
  final remaining = engine.Quests.liveRemaining(active, p);
  if (remaining == null || !remaining.isFinite || remaining <= 0) return null;
  if (active.kind == engine.QuestKind.trailVisits && active.trailKey == null) {
    return null;
  }
  return LiveQuest(
    id: active.id,
    kind: active.kind.wire,
    title: active.title,
    line: active.liveLine,
    remaining: remaining,
    trailId: active.kind == engine.QuestKind.trailVisits
        ? active.trailKey
        : null,
  );
}

/// [ctx] with the active quest added for a run of [mode]: a context of the quest alone when there is none
/// (no boards, nothing said by the compare), as the known trails do. Never throws and never waits longer than
/// [budget]: a slow read means no quest beat for this run. Returns [ctx] as it was when there is nothing to add.
Future<LiveContext?> withLiveQuest(
  LiveContext? ctx, {
  required RecordMode mode,
  required QuestsController quests,
  required RunStore history,
  required DateTime now,
  Duration budget = const Duration(milliseconds: 120),
  int? offsetMin,
}) async {
  if (!kQuestsEnabled || !kLiveQuestModes.contains(mode)) return ctx;
  try {
    final q = await _pack(quests, history, now, offsetMin).timeout(budget);
    if (q == null) return ctx;
    if (ctx != null) return ctx..quest = q;
    return LiveContext(
      boards: const [],
      coachingMuted: true,
      builtAtMs: now.millisecondsSinceEpoch,
      engineVersion: engine.engineVersion,
      quest: q,
    );
  } catch (e) {
    debugPrint('quests: no live quest ($e)');
    return ctx;
  }
}

Future<LiveQuest?> _pack(
  QuestsController quests,
  RunStore history,
  DateTime now,
  int? offsetMin,
) async {
  final state = await quests.load();
  final active = state.active;
  if (active == null) return null;
  if (engine.Quests.expired(active, questWall(now, offsetMin: offsetMin))) {
    return null;
  }
  final inputs = quests.inputsFor(await history.list());
  return liveQuestOf(active, engine.Quests.progress(active, inputs.runs));
}
