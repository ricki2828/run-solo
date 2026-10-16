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
  Future<QuestState>? _loading;

  // The trail grouping is the costly part of reading the history, and a
  // Progress open reads it several times: keep the last one per history.
  int? _inputsSig;
  QuestInputs? _inputs;

  QuestState get state => _state;

  /// Monday-start week indices the runner paused.
  Set<int> get pausedWeeks => _state.pausedWeeks;

  /// Loads once, however many callers ask at the same time.
  Future<QuestState> load() => _loading ??= _store.load().then((s) {
    _state = s;
    return s;
  });

  /// [questInputsOf] for [runs], grouped once per history revision.
  QuestInputs inputsFor(Iterable<RunSummary> runs) {
    final list = runs is List<RunSummary> ? runs : runs.toList();
    final sig = Object.hashAll([
      list.length,
      for (final r in list)
        Object.hash(
          r.id,
          r.missing,
          r.durationMs,
          r.distanceM,
          r.mode,
          r.trailOverride,
          r.row,
        ),
    ]);
    if (sig != _inputsSig || _inputs == null) {
      _inputs = questInputsOf(list);
      _inputsSig = sig;
    }
    return _inputs!;
  }

  /// Closes a quest that ended, rolls this month's offer, adopts a quest the
  /// coach accepted in Telegram ([coachQuest]: its offer id and accept time),
  /// saves when something changed, and returns the state.
  Future<QuestState> refresh(
    Iterable<RunSummary> runs,
    DateTime now, {
    ({String id, DateTime? acceptedAt})? coachQuest,
    int? offsetMin,
  }) async {
    await load();
    final inputs = inputsFor(runs);
    var next = reconcileQuests(
      _state,
      inputs,
      now,
      exposed: questsExposed(inputs.runs, now, offsetMin: offsetMin),
      offsetMin: offsetMin,
    );
    final c = coachQuest;
    final offer = next.offer;
    if (c != null && next.active == null && offer != null && offer.open) {
      for (final d in offer.candidates) {
        if (d.id == c.id) {
          next = next.copyWith(
            // The coach's accept time is a real instant; the quest runs on
            // the wall clock.
            active: d.accept(
              questWall(
                c.acceptedAt ?? now,
                offsetMin: offsetMin ?? now.timeZoneOffset.inMinutes,
              ),
              source: 'coach',
            ),
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
  Future<void> accept(DateTime now, {int? offsetMin}) async {
    await load();
    final offer = _state.offer, d = offer?.current;
    if (d == null || _state.active != null) return;
    await _commit(
      _state.copyWith(
        active: d.accept(questWall(now, offsetMin: offsetMin)),
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
  Future<void> drop(DateTime now, {int? offsetMin}) async {
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
            closedOn: engine.Quests.isoDay(
              questWall(now, offsetMin: offsetMin),
            ),
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
