/// Session target paces on the phone: the paces the runner accepted from a
/// nudge (`files/state/target_paces.json`), and the evidence the nudges are
/// judged on. The rules live in the engine (`target_paces.dart`); nothing
/// here decides when to nudge, and nothing here moves a target except
/// [TargetPaceController.accept], which only a tap calls.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import 'history_store.dart';

/// The runner's answer to the last nudge for one intensity.
class PaceAnswer {
  const PaceAnswer({
    required this.at,
    required this.accepted,
    required this.quicker,
  });

  final DateTime at;
  final bool accepted;

  /// The direction that was offered.
  final bool quicker;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'accepted': accepted,
    'quicker': quicker,
  };

  static PaceAnswer? tryParse(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    final accepted = j['accepted'], quicker = j['quicker'];
    if (at == null || accepted is! bool || quicker is! bool) return null;
    return PaceAnswer(at: at.toLocal(), accepted: accepted, quicker: quicker);
  }
}

class TargetPaceState {
  const TargetPaceState({
    this.adopted = const {},
    this.adoptedFrom = const {},
    this.answers = const {},
  });

  /// True Pace s/km the runner said yes to, per intensity.
  final Map<engine.PaceIntensity, double> adopted;

  /// What the tables said when they said yes: the accepted pace lapses once
  /// the tables pass it.
  final Map<engine.PaceIntensity, double> adoptedFrom;
  final Map<engine.PaceIntensity, PaceAnswer> answers;

  static const TargetPaceState empty = TargetPaceState();

  Map<String, Object?> toJson() => {
    'v': 1,
    'adopted': {for (final e in adopted.entries) e.key.name: e.value},
    'adopted_from': {for (final e in adoptedFrom.entries) e.key.name: e.value},
    'answers': {for (final e in answers.entries) e.key.name: e.value.toJson()},
  };

  /// Damaged or unreadable JSON reads as nothing adopted.
  static TargetPaceState tryParse(Object? j) {
    if (j is! Map) return empty;
    final adopted = <engine.PaceIntensity, double>{};
    final adoptedFrom = <engine.PaceIntensity, double>{};
    final answers = <engine.PaceIntensity, PaceAnswer>{};
    final a = j['adopted'];
    if (a is Map) {
      for (final e in a.entries) {
        final i = engine.PaceIntensity.byName('${e.key}');
        final v = e.value;
        if (i != null && v is num && v.isFinite && v > 0) {
          adopted[i] = v.toDouble();
        }
      }
    }
    final f = j['adopted_from'];
    if (f is Map) {
      for (final e in f.entries) {
        final i = engine.PaceIntensity.byName('${e.key}');
        final v = e.value;
        if (i != null && v is num && v.isFinite && v > 0) {
          adoptedFrom[i] = v.toDouble();
        }
      }
    }
    final r = j['answers'];
    if (r is Map) {
      for (final e in r.entries) {
        final i = engine.PaceIntensity.byName('${e.key}');
        final v = PaceAnswer.tryParse(e.value);
        if (i != null && v != null) answers[i] = v;
      }
    }
    return TargetPaceState(
      adopted: adopted,
      adoptedFrom: adoptedFrom,
      answers: answers,
    );
  }
}

abstract class TargetPaceStore {
  Future<TargetPaceState> load();
  Future<void> save(TargetPaceState state);
}

class MemoryTargetPaceStore implements TargetPaceStore {
  MemoryTargetPaceStore([this.state = TargetPaceState.empty]);
  TargetPaceState state;

  @override
  Future<TargetPaceState> load() async => state;

  @override
  Future<void> save(TargetPaceState state) async => this.state = state;
}

class FileTargetPaceStore implements TargetPaceStore {
  FileTargetPaceStore(this.stateDir);
  final Directory stateDir;

  File get file => File('${stateDir.path}/target_paces.json');

  @override
  Future<TargetPaceState> load() async {
    try {
      if (!await file.exists()) return TargetPaceState.empty;
      return TargetPaceState.tryParse(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('target paces: damaged file, nothing adopted ($e)');
      return TargetPaceState.empty;
    }
  }

  @override
  Future<void> save(TargetPaceState state) async {
    await stateDir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()));
    await tmp.rename(file.path);
  }
}

class TargetPaceController extends ChangeNotifier {
  TargetPaceController(this.store);
  final TargetPaceStore store;

  TargetPaceState _state = TargetPaceState.empty;
  TargetPaceState get state => _state;

  /// What [engine.TargetPaces.of] takes as `adopted`.
  Map<engine.PaceIntensity, double> get adopted => _state.adopted;

  /// And its `adoptedFrom`.
  Map<engine.PaceIntensity, double> get adoptedFrom => _state.adoptedFrom;

  Future<void> load() async {
    _state = await store.load();
    notifyListeners();
  }

  /// The runner tapped Yes: the target becomes the nudge's pace.
  /// [modelSecPerKm] is what the tables say now, so the move can lapse once
  /// they catch up.
  Future<void> accept(
    engine.PaceNudge n, {
    required DateTime now,
    double? modelSecPerKm,
  }) => _answer(n, now, accepted: true, model: modelSecPerKm);

  /// The runner tapped Keep: the target stays and the nudge goes quiet.
  Future<void> keep(engine.PaceNudge n, {required DateTime now}) =>
      _answer(n, now, accepted: false);

  Future<void> _answer(
    engine.PaceNudge n,
    DateTime now, {
    required bool accepted,
    double? model,
  }) async {
    final before = _state;
    _state = TargetPaceState(
      adopted: {..._state.adopted, if (accepted) n.intensity: n.toSecPerKm},
      adoptedFrom: {
        ..._state.adoptedFrom,
        if (accepted && model != null) n.intensity: model,
      },
      answers: {
        ..._state.answers,
        n.intensity: PaceAnswer(
          at: now,
          accepted: accepted,
          quicker: n.quicker,
        ),
      },
    );
    notifyListeners();
    await _persist(before);
  }

  Future<void> _saving = Future<void>.value();

  /// Saves [_state], one save at a time and in order. A failed save puts
  /// [before] back and rethrows, but only if nothing newer has happened since
  /// (a later Undo is never rolled back by an earlier failure).
  Future<void> _persist(TargetPaceState before) {
    final mine = _state;
    final run = _saving.then((_) => store.save(mine));
    _saving = run.then((_) {}, onError: (Object _) {});
    return run.catchError((Object e) {
      if (identical(_state, mine)) {
        _state = before;
        notifyListeners();
      }
      throw e;
    });
  }

  /// Forgets accepted paces the tables have since caught up with (they no
  /// longer apply: [paces] shows them as not adopted), so a later dip in the
  /// tables cannot bring them back. Changes nothing the runner sees, so it
  /// does not notify; safe to call while building.
  void prune(engine.TargetPaces paces) {
    final lapsed = [
      for (final i in _state.adopted.keys)
        if (paces[i] != null && !paces[i]!.adopted) i,
    ];
    if (lapsed.isEmpty) return;
    final before = _state;
    _state = TargetPaceState(
      adopted: {..._state.adopted}..removeWhere((k, _) => lapsed.contains(k)),
      adoptedFrom: {..._state.adoptedFrom}
        ..removeWhere((k, _) => lapsed.contains(k)),
      answers: _state.answers,
    );
    _persist(before).catchError((Object _) {});
  }

  /// Back to the tables for one intensity (a nudge's undo).
  Future<void> reset(engine.PaceIntensity i) async {
    final before = _state;
    _state = TargetPaceState(
      adopted: {..._state.adopted}..remove(i),
      adoptedFrom: {..._state.adoptedFrom}..remove(i),
      answers: _state.answers,
    );
    notifyListeners();
    await _persist(before);
  }

  /// The one nudge to show, or null. Pure over the state: calling it moves
  /// nothing.
  engine.PaceNudge? nudge(
    engine.TargetPaces paces,
    Map<engine.PaceIntensity, List<engine.PaceObservation>> evidence, {
    required DateTime now,
  }) {
    for (final i in engine.PaceIntensity.values) {
      final target = paces[i];
      final obs = evidence[i];
      if (target == null || obs == null) continue;
      final last = _state.answers[i];
      final n = engine.PaceNudges.evaluate(
        i,
        current: target.trueSecPerKm,
        observations: obs,
        now: now,
        lastAnswerAt: last?.at,
        lastAcceptedQuicker: last != null && last.accepted
            ? last.quicker
            : null,
      );
      if (n != null) return n;
    }
    return null;
  }
}

/// How the runner really ran each effort lately, from the history index
/// (row fields only, no run files): a structured set's True work pace, and
/// an easy run's True Pace. Hills and heat are already out of both, so trail
/// runs count. An easy run is a Free or Trail run of 3 km or more with most
/// of its heart-rate time in zones 1 and 2; without a strap there is none.
Map<engine.PaceIntensity, List<engine.PaceObservation>> paceEvidence(
  Iterable<RunSummary> runs, {
  required engine.HrZones zones,
}) {
  const vo2Sets = {
    engine.SessionSpec.norwegian4x4Id,
    '30-30s',
    '1-min-reps',
    'pyramid',
  };
  final out = <engine.PaceIntensity, List<engine.PaceObservation>>{
    for (final i in engine.PaceIntensity.values) i: [],
  };
  for (final r in runs) {
    if (r.missing) continue;
    final id = r.spec?.templateId;
    final work = r.trueWorkPaceSecPerKm;
    if (id != null && work != null && work > 0) {
      final i = vo2Sets.contains(id)
          ? engine.PaceIntensity.vo2max
          : id == 'tempo'
          ? engine.PaceIntensity.tempo
          : null;
      if (i != null) {
        out[i]!.add(
          engine.PaceObservation(
            runId: r.id,
            date: r.start,
            trueSecPerKm: work,
          ),
        );
      }
      continue;
    }
    if ((r.mode == RecordMode.free || r.mode == RecordMode.trail) &&
        r.distanceM >= 3000) {
      final pace = r.truePaceSecPerKm, hist = r.hrHist;
      if (pace == null || hist == null) continue;
      final z = hist.zoneSeconds(zones);
      final total = z.fold<double>(0, (a, b) => a + b);
      if (total > 0 && (z[1] + z[2]) / total >= 0.75) {
        out[engine.PaceIntensity.easy]!.add(
          engine.PaceObservation(
            runId: r.id,
            date: r.start,
            trueSecPerKm: pace,
          ),
        );
      }
    }
  }
  return out;
}

/// The words for targets and nudges.
abstract final class TargetPaceText {
  /// "Work reps at 4:17/km · VO2 max, Daniels VDOT, from your 5K on Sat 12
  /// Sep". Heat and grade notes ride on the end.
  static String sessionLine(
    engine.AdjustedPace a,
    Units units, {
    required String verb,
    String? source,
  }) {
    final t = a.target;
    final head = a.isEffort
        ? '${a.effort}'
        : '$verb ${Fmt.paceUnit(a.secPerKm!, units)}';
    final why = [
      t.intensity.label,
      if (t.adopted) 'moved by you' else 'Daniels VDOT',
      if (source != null && source.isNotEmpty)
        '${source[0].toLowerCase()}${source.substring(1)}',
    ].join(', ');
    final notes = a.notes.isEmpty ? '' : ' (${a.notes.join(', ')})';
    return '$head$notes · $why';
  }
}
