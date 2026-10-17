/// The `quest` block of `POST /v1/runs` (companion-server README, "Quest block"). Built by hand, key by
/// key: never [engine.QuestDef.toJson], which carries `trailRunIds` (run ids) and other fields the
/// server must never get. Every number is a whole number; no run ids, no coordinates, no dates but `ends_on`.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'quest_build.dart';
import 'quest_store.dart';

final RegExp _idPattern = RegExp(r'^q_[a-z0-9_-]{1,48}$');

/// How long after it ended a finished quest is still named in `closed`, so a run uploaded late (an
/// offline queue) still tells the server.
const int kQuestClosedDays = 14;

const int _big = 1000000;

/// The unit the server derives for each kind.
String questUnit(engine.QuestKind k) => switch (k) {
  engine.QuestKind.trailVisits => 'runs',
  engine.QuestKind.trailBest || engine.QuestKind.climbBest => 's',
  engine.QuestKind.climbMonth => 'm',
  engine.QuestKind.distanceMonth => 'km',
};

/// The block for the run [runId], or null when there is nothing to say. [now] is the real clock; [names]
/// says trail names may go out (the place opt-in), and a name over 30 characters is left out.
///
/// - `offers`: the open offer's candidates (up to 3), offer 0 first as the app shows it.
/// - `active`: the quest taken, with its progress; the source of truth.
/// - `done_now` (with `active.value == target`): the run that finished a quest, whether it is still active
///   or was already closed as done.
/// - `closed`: the most recent quest the app closed within [kQuestClosedDays].
/// - `month_skipped`: the offer month the runner passed on ("YYYY-MM").
Map<String, Object?>? questWire(
  QuestState state,
  QuestInputs inputs,
  DateTime now, {
  required String runId,
  required bool names,
  int? offsetMin,
}) {
  final wall = questWall(now, offsetMin: offsetMin);
  final month = engine.Quests.monthOf(wall);

  int? whole(num v, {int min = 0}) {
    final n = v.floor();
    return n >= min && n <= _big ? n : null;
  }

  String? name(engine.QuestDef d) {
    final n = d.trailName?.trim();
    return !names || n == null || n.isEmpty || n.length > 30 ? null : n;
  }

  Map<String, Object?>? offer(engine.QuestDef d) {
    final target = whole(d.target, min: 1);
    final baseline = whole(d.baseline);
    if (target == null || !_idPattern.hasMatch(d.id)) return null;
    return {
      'id': d.id,
      'kind': d.kind.wire,
      'target': target,
      'baseline': ?baseline,
      'unit': questUnit(d.kind),
      'trail_name': ?name(d),
    };
  }

  Map<String, Object?>? active(engine.QuestDef d, {required bool finished}) {
    final target = whole(d.target, min: 1);
    final ends = d.endsOn;
    if (target == null || ends == null || !_idPattern.hasMatch(d.id)) {
      return null;
    }
    int? value;
    if (finished) {
      value = target;
    } else {
      final p = engine.Quests.progress(d, inputs.runs);
      value = switch (d.kind) {
        engine.QuestKind.trailBest ||
        engine.QuestKind.climbBest => p.complete ? target : 0,
        _ => whole(p.value),
      };
    }
    if (value == null) return null;
    return {
      'id': d.id,
      'kind': d.kind.wire,
      'target': target,
      'value': value,
      'ends_on': ends,
      'trail_name': ?name(d),
    };
  }

  Map<String, Object?>? activeWire;
  String? doneNow;
  final a = state.active;
  if (a != null) {
    final p = engine.Quests.progress(a, inputs.runs);
    final finishedHere = p.complete && p.completedByRunId == runId;
    activeWire = active(a, finished: finishedHere);
    if (finishedHere && activeWire != null) doneNow = a.id;
  } else {
    // Closed as done before this upload ran: the server still needs its row and the run that finished it.
    for (final h in state.history.reversed) {
      if (h.result == 'done' && h.doneRunId == runId) {
        activeWire = active(h.def, finished: true);
        if (activeWire != null) doneNow = h.def.id;
        break;
      }
    }
  }

  final offers = <Map<String, Object?>>[];
  final o = state.offer;
  if (o != null && o.open) {
    for (final d in o.candidates.take(3)) {
      final w = offer(d);
      if (w != null) offers.add(w);
    }
  }

  Map<String, Object?>? closed;
  for (final h in state.history.reversed) {
    final day = engine.Quests.parseDay(h.closedOn);
    if (day == null ||
        engine.Quests.daysBetween(day, wall) > kQuestClosedDays) {
      continue;
    }
    if (!_idPattern.hasMatch(h.def.id) || h.def.id == doneNow) continue;
    closed = {'id': h.def.id, 'result': h.result};
    break;
  }

  final skipped = o != null && o.state == 'skipped' && o.month == month
      ? month
      : null;

  if (offers.isEmpty &&
      activeWire == null &&
      closed == null &&
      skipped == null) {
    return null;
  }
  return {
    if (offers.isNotEmpty) 'offers': offers,
    'active': ?activeWire,
    'done_now': ?doneNow,
    'closed': ?closed,
    'month_skipped': ?skipped,
  };
}
