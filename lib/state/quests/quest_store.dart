import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

/// A finished quest, kept for the History list and the Moment.
class QuestHistoryEntry {
  const QuestHistoryEntry({
    required this.def,
    required this.result,
    required this.closedOn,
    this.doneRunId,
  });

  final engine.QuestDef def;

  /// `done`, `expired` or `dropped`.
  final String result;

  /// `yyyy-mm-dd`.
  final String closedOn;
  final String? doneRunId;

  bool get done => result == 'done';

  Map<String, Object?> toJson() => {
    ...def.toJson(),
    'result': result,
    'closedOn': closedOn,
    'doneRunId': ?doneRunId,
  };

  static QuestHistoryEntry? fromJson(Object? j) {
    final def = engine.QuestDef.fromJson(j);
    if (def == null || j is! Map) return null;
    final result = j['result'], closed = j['closedOn'];
    if (result is! String || closed is! String) return null;
    return QuestHistoryEntry(
      def: def,
      result: result,
      closedOn: closed,
      doneRunId: j['doneRunId'] is String ? j['doneRunId']! as String : null,
    );
  }
}

/// This month's offer: up to three candidates, the one on show, and what the
/// runner did with it.
class QuestOffer {
  const QuestOffer({
    required this.month,
    required this.candidates,
    this.shown = 0,
    this.state = 'open',
  });

  /// `yyyy-mm`.
  final String month;
  final List<engine.QuestDef> candidates;

  /// Index into [candidates] of the one on the card (ANOTHER cycles it).
  final int shown;

  /// `open`, `taken` or `skipped`.
  final String state;

  bool get open => state == 'open' && candidates.isNotEmpty;
  engine.QuestDef? get current =>
      open ? candidates[shown % candidates.length] : null;

  QuestOffer copyWith({int? shown, String? state}) => QuestOffer(
    month: month,
    candidates: candidates,
    shown: shown ?? this.shown,
    state: state ?? this.state,
  );

  Map<String, Object?> toJson() => {
    'month': month,
    'candidates': [for (final c in candidates) c.toJson()],
    'shown': shown,
    'state': state,
  };

  static QuestOffer? fromJson(Object? j) {
    if (j is! Map || j['month'] is! String) return null;
    final raw = j['candidates'];
    return QuestOffer(
      month: j['month']! as String,
      candidates: [
        if (raw is List)
          for (final c in raw) ?engine.QuestDef.fromJson(c),
      ],
      shown: j['shown'] is int ? j['shown']! as int : 0,
      state: switch (j['state']) {
        'taken' => 'taken',
        'skipped' => 'skipped',
        _ => 'open',
      },
    );
  }
}

/// Everything quests keep on the device (`state/quests.json`). Progress is
/// never stored: it is folded from the run history every time.
class QuestState {
  const QuestState({
    this.active,
    this.offer,
    this.history = const [],
    this.pausedWeeks = const {},
    this.climbCache = const {},
  });

  static const empty = QuestState();

  final engine.QuestDef? active;
  final QuestOffer? offer;

  /// Oldest first.
  final List<QuestHistoryEntry> history;

  /// Monday-start week indices the runner paused herself or himself.
  final Set<int> pausedWeeks;

  /// Per trail key: the climbs on it and the runs they were timed from.
  /// Written by the climb pass; opaque here.
  final Map<String, Object?> climbCache;

  QuestState copyWith({
    Object? active = _keep,
    Object? offer = _keep,
    List<QuestHistoryEntry>? history,
    Set<int>? pausedWeeks,
    Map<String, Object?>? climbCache,
  }) => QuestState(
    active: identical(active, _keep) ? this.active : active as engine.QuestDef?,
    offer: identical(offer, _keep) ? this.offer : offer as QuestOffer?,
    history: history ?? this.history,
    pausedWeeks: pausedWeeks ?? this.pausedWeeks,
    climbCache: climbCache ?? this.climbCache,
  );

  static const Object _keep = Object();

  Map<String, Object?> toJson() => {
    'v': 1,
    'active': active?.toJson(),
    'offer': offer?.toJson(),
    'history': [for (final h in history) h.toJson()],
    'pausedWeeks': (pausedWeeks.toList()..sort()),
    'climbCache': climbCache,
  };

  static QuestState fromJson(Object? j) {
    if (j is! Map || j['v'] != 1) return empty;
    final hist = j['history'],
        paused = j['pausedWeeks'],
        cache = j['climbCache'];
    return QuestState(
      active: engine.QuestDef.fromJson(j['active']),
      offer: QuestOffer.fromJson(j['offer']),
      history: [
        if (hist is List)
          for (final h in hist) ?QuestHistoryEntry.fromJson(h),
      ],
      pausedWeeks: {
        if (paused is List)
          for (final w in paused)
            if (w is int) w,
      },
      climbCache: cache is Map<String, Object?> ? cache : const {},
    );
  }
}

/// Where [QuestState] lives. Same pattern as `SeenMomentsStore`.
abstract class QuestStore {
  Future<QuestState> load();
  Future<void> save(QuestState state);
}

class MemoryQuestStore implements QuestStore {
  MemoryQuestStore([this._state = QuestState.empty]);
  QuestState _state;

  @override
  Future<QuestState> load() async => _state;

  @override
  Future<void> save(QuestState state) async => _state = state;
}

/// `files/state/quests.json`, written atomically (tmp + rename).
class FileQuestStore implements QuestStore {
  FileQuestStore(this.stateDir);
  final Directory stateDir;

  File get _file => File('${stateDir.path}/quests.json');

  @override
  Future<QuestState> load() async {
    try {
      if (!await _file.exists()) return QuestState.empty;
      return QuestState.fromJson(jsonDecode(await _file.readAsString()));
    } catch (e) {
      debugPrint('quests: unreadable, starting empty ($e)');
      return QuestState.empty;
    }
  }

  @override
  Future<void> save(QuestState state) async {
    await stateDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(_file.path);
  }
}
