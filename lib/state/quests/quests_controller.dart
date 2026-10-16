import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../history_store.dart';
import 'quest_build.dart';
import 'quest_store.dart';

/// The quests the runner holds on this device: loads `quests.json`, closes
/// and offers quests as runs land, and carries the runner's actions (take it,
/// another, not this month, drop, pause a week). One per app.
class QuestsController extends ChangeNotifier {
  QuestsController(this._store);

  final QuestStore _store;

  QuestState _state = QuestState.empty;
  bool _loaded = false;

  QuestState get state => _state;

  /// Monday-start week indices the runner paused.
  Set<int> get pausedWeeks => _state.pausedWeeks;

  Future<QuestState> load() async {
    if (!_loaded) {
      _state = await _store.load();
      _loaded = true;
    }
    return _state;
  }

  /// Closes a quest that ended, rolls this month's offer, adopts a quest the
  /// coach accepted in Telegram ([coachQuest]: its offer id and accept time),
  /// saves when something changed, and returns the state.
  Future<QuestState> refresh(
    Iterable<RunSummary> runs,
    DateTime now, {
    ({String id, DateTime? acceptedAt})? coachQuest,
  }) async {
    await load();
    final inputs = questInputsOf(runs);
    var next = reconcileQuests(
      _state,
      inputs,
      now,
      exposed: questsExposed(inputs.runs, now),
    );
    final c = coachQuest;
    final offer = next.offer;
    if (c != null && next.active == null && offer != null && offer.open) {
      for (final d in offer.candidates) {
        if (d.id == c.id) {
          next = next.copyWith(
            active: d.accept(c.acceptedAt ?? now, source: 'coach'),
            offer: offer.copyWith(state: 'taken'),
          );
          break;
        }
      }
    }
    await _commit(next);
    return _state;
  }

  Future<void> _commit(QuestState next) async {
    if (jsonEncode(next.toJson()) == jsonEncode(_state.toJson())) return;
    _state = next;
    notifyListeners();
    try {
      await _store.save(next);
    } catch (e) {
      debugPrint('quests: could not save ($e)');
    }
  }

  /// TAKE IT: the shown candidate becomes the active quest from [now].
  Future<void> accept(DateTime now) async {
    await load();
    final offer = _state.offer, d = offer?.current;
    if (d == null || _state.active != null) return;
    await _commit(
      _state.copyWith(
        active: d.accept(now),
        offer: offer!.copyWith(state: 'taken'),
      ),
    );
  }

  /// ANOTHER: the next of the (up to three) candidates.
  Future<void> another() async {
    await load();
    final offer = _state.offer;
    if (offer == null || !offer.open) return;
    await _commit(
      _state.copyWith(
        offer: offer.copyWith(
          shown: (offer.shown + 1) % offer.candidates.length,
        ),
      ),
    );
  }

  /// NOT THIS MONTH: nothing more is offered until next month.
  Future<void> skip() async {
    await load();
    final offer = _state.offer;
    if (offer == null || !offer.open) return;
    await _commit(_state.copyWith(offer: offer.copyWith(state: 'skipped')));
  }

  /// The runner gives the active quest up.
  Future<void> drop(DateTime now) async {
    await load();
    final a = _state.active;
    if (a == null) return;
    await _commit(
      _state.copyWith(
        active: null,
        history: [
          ..._state.history,
          QuestHistoryEntry(
            def: a,
            result: 'dropped',
            closedOn: engine.Quests.isoDay(now),
          ),
        ],
      ),
    );
  }

  /// "Pause this week": the week neither counts nor breaks the streak.
  Future<void> pauseWeek(int week) async {
    await load();
    if (_state.pausedWeeks.contains(week)) return;
    await _commit(_state.copyWith(pausedWeeks: {..._state.pausedWeeks, week}));
  }

  Future<void> unpauseWeek(int week) async {
    await load();
    if (!_state.pausedWeeks.contains(week)) return;
    await _commit(
      _state.copyWith(pausedWeeks: {..._state.pausedWeeks}..remove(week)),
    );
  }
}
