/// Intervals sessions (Phase 3 plan §3.1–§3.5, design brief A8): which
/// session is picked, the runner's edits to a preset (reps and recovery
/// only, D2), and saved custom templates in `files/state/sessions.json`.
///
/// The app expands every session here and hands Kotlin the expanded spec
/// (CONTRACT.md I1); Kotlin never expands.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

/// A preset's edits (D2): reps and the recovery step, nothing else.
@immutable
class PresetEdit {
  const PresetEdit({this.reps, this.recovery});

  final int? reps;

  /// A whole recovery step (rep 1), so the 400s can switch metres / time.
  final engine.SessionStep? recovery;

  Map<String, Object?> toJson() => {
    if (reps != null) 'reps': reps,
    if (recovery != null) 'recovery': recovery!.toJson(),
  };

  factory PresetEdit.fromJson(Map<String, Object?> j) {
    final r = j['recovery'];
    return PresetEdit(
      reps: j['reps'] is int ? j['reps'] as int : null,
      recovery: r is Map<String, Object?>
          ? engine.SessionStep.fromJson(r)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PresetEdit && other.reps == reps && other.recovery == recovery;

  @override
  int get hashCode => Object.hash(reps, recovery);
}

/// How a custom template's recovery ends (plan §3.4: Time / Distance / None).
enum RecoveryTarget { time, distance, none }

/// A saved custom session, stored compact and expanded on use. Editing it
/// bumps [version]; only a change to the work reps restarts the comparison
/// (D4), which the comparison key already encodes.
@immutable
class CustomSession {
  const CustomSession({
    required this.id,
    this.version = 1,
    required this.name,
    this.reps = 6,
    this.workTarget = engine.TargetKind.time,
    this.workValue = 180,
    this.recoveryTarget = RecoveryTarget.time,
    this.recoveryValue = 120,
    this.recoveryStyle = engine.RecoveryStyle.jog,
    this.warmupSeconds,
    this.cooldownSeconds,
    this.createdAt,
  });

  final String id;
  final int version;
  final String name;
  final int reps;

  /// [engine.TargetKind.time] (seconds) or [engine.TargetKind.distance] (m).
  final engine.TargetKind workTarget;
  final int workValue;
  final RecoveryTarget recoveryTarget;

  /// Seconds or metres; ignored for [RecoveryTarget.none].
  final int recoveryValue;

  /// Walk and stand recoveries are timed only (plan §3.3).
  final engine.RecoveryStyle recoveryStyle;

  /// null = open ("tap START REPS when ready" / "stop when done").
  final int? warmupSeconds;
  final int? cooldownSeconds;
  final DateTime? createdAt;

  String get templateId => '${engine.SessionSpec.customPrefix}$id';

  engine.SessionSpec expand() {
    engine.SessionStep work(int rep) => workTarget == engine.TargetKind.time
        ? engine.SessionStep.work(workValue, rep: rep)
        : engine.SessionStep.workDistance(workValue, rep: rep);
    engine.SessionStep recovery(int rep) => switch (recoveryTarget) {
      RecoveryTarget.time => engine.SessionStep.recovery(
        recoveryValue,
        rep: rep,
        style: recoveryStyle,
      ),
      RecoveryTarget.distance => engine.SessionStep.recoveryDistance(
        recoveryValue,
        rep: rep,
        style: recoveryStyle,
      ),
      // A 0:00 recovery means straight into the next rep (plan §3.3).
      RecoveryTarget.none => engine.SessionStep.recovery(
        0,
        rep: rep,
        style: engine.RecoveryStyle.run,
      ),
    };
    return engine.SessionSpec(
      templateId: templateId,
      templateVersion: version,
      name: name,
      warmupSeconds: warmupSeconds,
      cooldownSeconds: cooldownSeconds,
      cueProfile: workTarget == engine.TargetKind.time && workValue < 60
          ? engine.CueProfile.short
          : engine.CueProfile.standard,
      steps: engine.SessionSpec.uniform(
        reps: reps,
        work: work,
        recovery: recovery,
      ),
    );
  }

  /// Plan §3.4: "6 × 800 m · 2:00 jog".
  String get autoName => SessionText.structure(expand());

  /// Problems with this template (empty = valid): the engine's table.
  List<String> validate() => expand().validate();

  CustomSession copyWith({
    int? version,
    String? name,
    int? reps,
    engine.TargetKind? workTarget,
    int? workValue,
    RecoveryTarget? recoveryTarget,
    int? recoveryValue,
    engine.RecoveryStyle? recoveryStyle,
    int? warmupSeconds,
    bool openWarmup = false,
    int? cooldownSeconds,
    bool openCooldown = false,
  }) => CustomSession(
    id: id,
    version: version ?? this.version,
    name: name ?? this.name,
    reps: reps ?? this.reps,
    workTarget: workTarget ?? this.workTarget,
    workValue: workValue ?? this.workValue,
    recoveryTarget: recoveryTarget ?? this.recoveryTarget,
    recoveryValue: recoveryValue ?? this.recoveryValue,
    recoveryStyle: recoveryStyle ?? this.recoveryStyle,
    warmupSeconds: openWarmup ? null : (warmupSeconds ?? this.warmupSeconds),
    cooldownSeconds: openCooldown
        ? null
        : (cooldownSeconds ?? this.cooldownSeconds),
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'name': name,
    'reps': reps,
    'workTarget': workTarget.name,
    'workValue': workValue,
    'recoveryTarget': recoveryTarget.name,
    'recoveryValue': recoveryValue,
    'recoveryStyle': recoveryStyle.name,
    'warmupSeconds': warmupSeconds,
    'cooldownSeconds': cooldownSeconds,
    'createdAt': createdAt?.toUtc().toIso8601String(),
  };

  factory CustomSession.fromJson(Map<String, Object?> j) {
    T byName<T extends Enum>(List<T> values, Object? v, T fallback) =>
        values.asNameMap()[v] ?? fallback;
    final created = j['createdAt'];
    return CustomSession(
      id: j['id']! as String,
      version: j['version'] is int ? j['version']! as int : 1,
      name: j['name'] is String ? j['name']! as String : 'Custom',
      reps: j['reps']! as int,
      workTarget: byName(
        engine.TargetKind.values,
        j['workTarget'],
        engine.TargetKind.time,
      ),
      workValue: j['workValue']! as int,
      recoveryTarget: byName(
        RecoveryTarget.values,
        j['recoveryTarget'],
        RecoveryTarget.time,
      ),
      recoveryValue: j['recoveryValue'] is int ? j['recoveryValue']! as int : 0,
      recoveryStyle: byName(
        engine.RecoveryStyle.values,
        j['recoveryStyle'],
        engine.RecoveryStyle.jog,
      ),
      warmupSeconds: j['warmupSeconds'] is int
          ? j['warmupSeconds']! as int
          : null,
      cooldownSeconds: j['cooldownSeconds'] is int
          ? j['cooldownSeconds']! as int
          : null,
      createdAt: created is String ? DateTime.tryParse(created) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomSession &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Editing rules the builder and the session card share (plan §3.3, A8).
abstract final class SessionRules {
  static const int maxCustom = 20;
  static const int timeStep = 15;
  static const int distanceStep = 50;
  static const int minReps = 1;
  static const int maxReps = 40;
  static const (int, int) workTime = (15, 1200);
  static const (int, int) workDistance = (100, 10000);
  static const (int, int) recoveryTime = (0, 600);
  static const (int, int) recoveryDistance = (50, 2000);
  static const (int, int) warmup = (300, 1200);

  /// Custom distance step: 50 m up to 1600 m (track), then 100 m.
  static int distanceStepAt(int metres, {required bool up}) =>
      (up ? metres >= 1600 : metres > 1600) ? 100 : distanceStep;
}

/// Human text for a session (sheet cards, session card, builder).
abstract final class SessionText {
  static String clock(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String metres(int m) =>
      m >= 1000 && m % 1000 == 0 ? '${m ~/ 1000} km' : '$m m';

  static String target(engine.SessionStep s) => switch (s.target) {
    engine.TargetKind.time => clock(s.value),
    engine.TargetKind.distance => metres(s.value),
    engine.TargetKind.equalToPreviousWork => 'same time',
  };

  static String style(engine.RecoveryStyle s) => switch (s) {
    engine.RecoveryStyle.jog => 'jog',
    engine.RecoveryStyle.walk => 'walk',
    engine.RecoveryStyle.stand => 'stand',
    engine.RecoveryStyle.run => 'run',
  };

  /// "8 × 400 m · 200 m jog", "Pyramid 1-2-3-4-3-2-1 min · same-time jog".
  static String structure(engine.SessionSpec spec) {
    final work = spec.workSteps.toList();
    if (work.isEmpty) return 'By feel · you press LAP';
    final rec = spec.steps.where((s) => !s.isWork).toList();
    final uniform = work.every(
      (s) => s.target == work.first.target && s.value == work.first.value,
    );
    final head = uniform
        ? '${work.length} × ${target(work.first)}'
        : work.every(
            (s) => s.target == engine.TargetKind.time && s.value % 60 == 0,
          )
        ? '${work.map((s) => s.value ~/ 60).join('-')} min'
        : '${work.length} reps';
    if (rec.isEmpty) return head;
    final r = rec.first;
    final tail = switch (r.target) {
      engine.TargetKind.equalToPreviousWork => 'same-time ${style(r.style)}',
      _ when r.value == 0 => 'no recovery',
      _ => '${target(r)} ${style(r.style)}',
    };
    return '$head · $tail';
  }

  /// Estimated minutes: distance steps at 400 m 1:30, 800 m 3:30, 1 km 4:30
  /// (≈ 4:30/km), open warm-up and cool-down 10 min each (A8 glyph rule).
  static int estimateMinutes(engine.SessionSpec spec) {
    final secs = Glyph.durations(spec).fold<double>(0, (a, b) => a + b.$2);
    return (secs / 60).round();
  }
}

/// Structure-glyph geometry (A8): bar width = step time (distance steps
/// estimated), height = effort. Open warm-up / cool-down get 10 minutes.
abstract final class Glyph {
  static const double openMinutes = 10;

  static double estimateSeconds(engine.SessionStep s, double? previousWork) =>
      switch (s.target) {
        engine.TargetKind.time => s.value.toDouble(),
        // A8: 400 m 1:30, 800 m 3:30, 1 km and up 4:30/km; recoveries jog
        // at 6:00/km.
        engine.TargetKind.distance =>
          s.isWork
              ? s.value *
                    (s.value <= 400
                        ? 0.225
                        : s.value <= 800
                        ? 0.2625
                        : 0.27)
              : s.value * 0.36,
        engine.TargetKind.equalToPreviousWork => previousWork ?? 60,
      };

  /// (kind, seconds) per bar, warm-up and cool-down included.
  static List<(GlyphBar, double)> durations(engine.SessionSpec spec) {
    final out = <(GlyphBar, double)>[
      (GlyphBar.open, (spec.warmupSeconds ?? openMinutes * 60).toDouble()),
    ];
    double? prevWork;
    for (final s in spec.steps) {
      final d = estimateSeconds(s, prevWork);
      if (s.isWork) prevWork = d;
      if (!s.isWork && d == 0) continue;
      out.add((s.isWork ? GlyphBar.rep : GlyphBar.recovery, d));
    }
    out.add((
      GlyphBar.open,
      (spec.cooldownSeconds ?? openMinutes * 60).toDouble(),
    ));
    return out;
  }
}

enum GlyphBar { rep, recovery, open }

/// Which Intervals session is picked, resolved against the catalogue and
/// the saved templates. `fartlek` is recorded as a Laps run (plan §3.5).
abstract final class SessionChoice {
  static bool isFartlek(String id) => id == engine.SessionSpec.fartlekId;
  static bool isCustom(String id) =>
      id.startsWith(engine.SessionSpec.customPrefix);

  /// The expanded session for [id] with the runner's [edits]; null when the
  /// id no longer exists (a deleted template). Fartlek has no steps.
  static engine.SessionSpec? resolve(
    String id, {
    Map<String, PresetEdit> edits = const {},
    List<CustomSession> customs = const [],
  }) {
    if (isFartlek(id)) return engine.SessionSpec.fartlek;
    if (isCustom(id)) {
      for (final c in customs) {
        if (c.templateId == id) return c.expand();
      }
      return null;
    }
    final preset = engine.SessionCatalogue.byId(id);
    if (preset == null) return null;
    final e = edits[id];
    try {
      return preset.expand(reps: e?.reps, recovery: e?.recovery);
    } on ArgumentError {
      // An edit from an older catalogue that no longer fits: defaults.
      return preset.defaults;
    }
  }

  /// Any distance step (reps or recoveries): needs a GPS fix before reps
  /// (plan §3.6 W3).
  static bool needsGps(engine.SessionSpec spec) =>
      spec.steps.any((s) => s.target == engine.TargetKind.distance);

  /// A custom template pre-filled from [spec] ("Save as custom"): uniform
  /// sessions only; null for a ladder (pyramid) or fartlek.
  static CustomSession? asCustom(engine.SessionSpec spec, String id) {
    final work = spec.workSteps.toList();
    if (work.isEmpty) return null;
    if (work.any(
      (s) => s.target != work.first.target || s.value != work.first.value,
    )) {
      return null;
    }
    final rec = spec.steps.where((s) => !s.isWork).toList();
    final r = rec.isEmpty ? null : rec.first;
    final (target, value) = switch (r?.target) {
      null => (RecoveryTarget.none, 0),
      engine.TargetKind.time when r!.value == 0 => (RecoveryTarget.none, 0),
      engine.TargetKind.time => (RecoveryTarget.time, r!.value),
      engine.TargetKind.distance => (RecoveryTarget.distance, r!.value),
      // Equal-time has no builder control: the rep's own time, rounded.
      engine.TargetKind.equalToPreviousWork => (
        RecoveryTarget.time,
        work.first.target == engine.TargetKind.time ? work.first.value : 120,
      ),
    };
    final c = CustomSession(
      id: id,
      name: '',
      reps: work.length,
      workTarget: work.first.target,
      workValue: work.first.value,
      recoveryTarget: target,
      recoveryValue: value,
      recoveryStyle: r?.style ?? engine.RecoveryStyle.jog,
      warmupSeconds: spec.warmupSeconds,
      cooldownSeconds: spec.cooldownSeconds,
    );
    return c.copyWith(name: c.autoName);
  }
}

abstract class SessionsStore {
  Future<List<CustomSession>> load();
  Future<void> save(List<CustomSession> sessions);
}

class MemorySessionsStore implements SessionsStore {
  MemorySessionsStore([List<CustomSession> initial = const []])
    : sessions = List.of(initial);
  List<CustomSession> sessions;
  int saves = 0;

  @override
  Future<List<CustomSession>> load() async => List.of(sessions);

  @override
  Future<void> save(List<CustomSession> s) async {
    sessions = List.of(s);
    saves += 1;
  }
}

/// `files/state/sessions.json`, schema 1 (plan §3.4); backed up with the
/// rest of `state/`. A damaged file reads as no templates, never a crash.
class FileSessionsStore implements SessionsStore {
  FileSessionsStore(this.stateDir);
  final Directory stateDir;

  static const int schema = 1;

  File get file => File('${stateDir.path}/sessions.json');

  @override
  Future<List<CustomSession>> load() async {
    try {
      if (!await file.exists()) return const [];
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?> || json['schema'] != schema) {
        return const [];
      }
      final list = json['sessions'];
      if (list is! List) return const [];
      final out = <CustomSession>[];
      for (final e in list) {
        if (e is! Map<String, Object?>) continue;
        try {
          final c = CustomSession.fromJson(e);
          if (c.validate().isEmpty) out.add(c);
        } catch (err) {
          debugPrint('sessions: skipped a damaged template ($err)');
        }
      }
      return out;
    } catch (e) {
      debugPrint('sessions: unreadable, none loaded ($e)');
      return const [];
    }
  }

  @override
  Future<void> save(List<CustomSession> sessions) async {
    await stateDir.create(recursive: true);
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(
      jsonEncode({
        'schema': schema,
        'sessions': [for (final s in sessions) s.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

class SessionsController extends ChangeNotifier {
  SessionsController(this._store, {DateTime Function()? now, math.Random? rng})
    : _now = now ?? DateTime.now,
      _rng = rng ?? math.Random.secure();

  final SessionsStore _store;
  final DateTime Function() _now;
  final math.Random _rng;
  List<CustomSession> _sessions = const [];
  Future<void> _writes = Future.value();

  /// Newest first (A8 "My sessions").
  List<CustomSession> get sessions => _sessions;

  bool get full => _sessions.length >= SessionRules.maxCustom;

  Future<void> load() async {
    _sessions = _sorted(await _store.load());
    notifyListeners();
  }

  /// Synchronous seed for tests and the fake APK (no file behind it).
  void preload(List<CustomSession> sessions) =>
      _sessions = _sorted(List.of(sessions));

  CustomSession? byTemplateId(String templateId) {
    for (final s in _sessions) {
      if (s.templateId == templateId) return s;
    }
    return null;
  }

  /// A fresh id; 16 hex digits is plenty for ≤ 20 local templates.
  String newId() => [
    for (var i = 0; i < 4; i++)
      _rng.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'),
  ].join();

  /// Adds (new id) or replaces (same id, version bumped when the session
  /// itself changed). Returns the stored template. Throws [StateError] when
  /// a new one would exceed 20.
  Future<CustomSession> save(CustomSession s) async {
    final i = _sessions.indexWhere((x) => x.id == s.id);
    CustomSession stored;
    if (i < 0) {
      if (full) throw StateError('At most ${SessionRules.maxCustom} sessions');
      stored = CustomSession.fromJson({
        ...s.toJson(),
        'createdAt': _now().toUtc().toIso8601String(),
      });
      _sessions = _sorted([..._sessions, stored]);
    } else {
      final old = _sessions[i];
      final changed =
          old.expand().steps.toString() != s.expand().steps.toString() ||
          old.warmupSeconds != s.warmupSeconds ||
          old.cooldownSeconds != s.cooldownSeconds;
      stored = CustomSession.fromJson({
        ...s.toJson(),
        'version': changed ? old.version + 1 : old.version,
        'createdAt': old.createdAt?.toUtc().toIso8601String(),
      });
      _sessions = _sorted([..._sessions]..[i] = stored);
    }
    await _persist();
    return stored;
  }

  Future<void> rename(String id, String name) async {
    final i = _sessions.indexWhere((x) => x.id == id);
    if (i < 0 || name.trim().isEmpty) return;
    _sessions = _sorted(
      [..._sessions]..[i] = _sessions[i].copyWith(name: name.trim()),
    );
    await _persist();
  }

  Future<CustomSession?> duplicate(String id) async {
    final src = byTemplateId('${engine.SessionSpec.customPrefix}$id');
    if (src == null || full) return null;
    return save(
      CustomSession.fromJson({
        ...src.toJson(),
        'id': newId(),
        'version': 1,
        'name': '${src.name} (copy)',
      }),
    );
  }

  Future<void> delete(String id) async {
    _sessions = _sessions.where((x) => x.id != id).toList();
    await _persist();
  }

  List<CustomSession> _sorted(List<CustomSession> l) => l
    ..sort((a, b) {
      final ta = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });

  /// Writes are serialised so two quick edits never race on the file.
  Future<void> _persist() {
    notifyListeners();
    final snapshot = List.of(_sessions);
    return _writes = _writes.then((_) => _store.save(snapshot));
  }
}
