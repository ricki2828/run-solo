/// User settings mirrored to `files/state/settings.json` (plan §2: sidecars
/// are the source of truth, the index is a cache).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import '../platform/session_codec.dart';
import 'sessions.dart';

/// 4x4 editor bounds (plan §6): reps 3–6, work locked 4:00, recovery
/// 2:00–5:00 in 15 s steps. Match `SessionCatalogue.norwegian4x4`.
abstract final class PresetRules {
  static const int minReps = 3;
  static const int maxReps = 6;
  static const int workSeconds = 240;
  static const int minRecovery = 120;
  static const int maxRecovery = 300;
  static const int recoveryStep = 15;

  static int clampReps(int reps) => reps.clamp(minReps, maxReps);

  static int clampRecovery(int seconds) {
    final snapped = (seconds / recoveryStep).round() * recoveryStep;
    return snapped.clamp(minRecovery, maxRecovery);
  }
}

/// Max HR entry bounds (plan D3). Typed values outside these are rejected at
/// the field, never clamped silently.
abstract final class MaxHrRules {
  static const int min = 120;
  static const int max = 220;
  static const int fallback = 190;

  /// An observed 30 s value more than this above the typed max is offered as
  /// a confirm sheet, not applied (artefact guard, D3 rule 5).
  static const int artefactMargin = 15;

  static bool validTyped(int v) => v >= min && v <= max;
  static bool validBirthYear(int y, int nowYear) =>
      y >= nowYear - 100 && y <= nowYear - 10;
}

@immutable
class SavedStrap {
  const SavedStrap({required this.address, this.name});
  final String address;
  final String? name;

  /// Whoop advertises as "WHOOP xxxx"; the pairing list names it plainly.
  bool get isWhoop => (name ?? '').toUpperCase().startsWith('WHOOP');
  String get label => isWhoop ? 'Whoop' : (name ?? 'Strap');

  Map<String, Object?> toJson() => {'address': address, 'name': name};
  factory SavedStrap.fromJson(Map<String, Object?> j) =>
      SavedStrap(address: j['address'] as String, name: j['name'] as String?);
}

@immutable
class AppSettings {
  const AppSettings({
    this.units = Units.km,
    this.reps = 4,
    this.recoverySeconds = 180,
    this.lastMode = RecordMode.intervals,
    this.cues = true,
    this.haptics = true,
    this.volumeKeyLap,
    this.keepScreenOn = true,
    this.weatherPerRun = true,
    this.reducedMotion = false,
    this.typedMaxHr,
    this.birthYear,
    this.observedMaxHr,
    this.observedMaxHrAt,
    this.pendingObservedMaxHr,
    this.onboardingDone = false,
    this.strap,
    this.introSeenVersion,
    this.sessionId = engine.SessionSpec.norwegian4x4Id,
    this.presetEdits = const {},
  });

  final Units units;
  final int reps;
  final int recoverySeconds;
  final RecordMode lastMode;
  final bool cues;
  final bool haptics;

  /// Null = the run type's default (plan §18.2: on for Laps, off for 4x4,
  /// never for Free). See [volumeKeyLapFor].
  final bool? volumeKeyLap;
  final bool keepScreenOn;

  /// "Weather for each run" (v1 plan §18.6, default on): fetch the
  /// temperature and dew point for each finished run from Open-Meteo with
  /// the location rounded to about 10 km. Off = nothing is sent.
  final bool weatherPerRun;
  final bool reducedMotion;

  /// Max HR typed in Settings; null = not entered (plan D3, N1: the old
  /// constant 190 migrates to null so the age / observed sources can win).
  final int? typedMaxHr;

  /// Asked once in onboarding, skippable; drives the 220 − age fallback.
  final int? birthYear;

  /// Highest sustained 30 s strap reading accepted so far, and when.
  final int? observedMaxHr;
  final DateTime? observedMaxHrAt;

  /// An observed value the artefact guard held back (> typed + 15 or > 220);
  /// offered once as a confirm sheet, then applied or discarded.
  final int? pendingObservedMaxHr;
  final bool onboardingDone;
  final SavedStrap? strap;

  /// App version that last played the full Lap Draw intro (plan §4, D8):
  /// null or older than the running version = full intro, else 0.6 s.
  final String? introSeenVersion;
  /// The Intervals session picked in the sheet (A8): a catalogue id,
  /// `custom:<id>` or `fartlek`. The Norwegian 4x4's edits stay in [reps] /
  /// [recoverySeconds] (the Phase 2 fields, already on phones).
  final String sessionId;

  /// Edits to the other presets (D2: reps and recovery only), by preset id.
  final Map<String, PresetEdit> presetEdits;

  /// Every preset's edits, the 4x4 included.
  Map<String, PresetEdit> get allPresetEdits => {
    ...presetEdits,
    engine.SessionSpec.norwegian4x4Id: PresetEdit(
      reps: reps,
      recovery: engine.SessionStep.recovery(recoverySeconds, rep: 1),
    ),
  };

  /// The picked session, expanded; falls back to the 4x4 when a custom
  /// template was deleted. Fartlek expands to its empty spec.
  engine.SessionSpec session(List<CustomSession> customs) =>
      SessionChoice.resolve(
        sessionId,
        edits: allPresetEdits,
        customs: customs,
      ) ??
      SessionChoice.resolve(
        engine.SessionSpec.norwegian4x4Id,
        edits: allPresetEdits,
      )!;

  /// Fartlek records as a Laps run with the fartlek session (plan §3.5).
  RecordMode get recordMode =>
      lastMode == RecordMode.intervals && SessionChoice.isFartlek(sessionId)
      ? RecordMode.laps
      : lastMode;

  /// The 4x4 session to record, expanded by the engine catalogue from the
  /// saved reps and recovery (CONTRACT.md I1: Kotlin never expands).
  SessionSpec get spec => engine.SessionCatalogue.expand(
    engine.SessionSpec.norwegian4x4Id,
    reps: reps,
    recovery: engine.SessionStep.recovery(recoverySeconds, rep: 1),
  ).toPigeon();

  /// Effective volume-key lap for a run type (plan §18.2 defaults).
  bool volumeKeyLapFor(RecordMode mode) => switch (mode) {
    RecordMode.free || RecordMode.cooper => false,
    RecordMode.laps => volumeKeyLap ?? true,
    RecordMode.intervals => volumeKeyLap ?? false,
  };

  AppSettings copyWith({
    Units? units,
    int? reps,
    int? recoverySeconds,
    RecordMode? lastMode,
    bool? cues,
    bool? haptics,
    bool? volumeKeyLap,
    bool? keepScreenOn,
    bool? weatherPerRun,
    bool? reducedMotion,
    int? typedMaxHr,
    bool clearTypedMaxHr = false,
    int? birthYear,
    bool clearBirthYear = false,
    int? observedMaxHr,
    DateTime? observedMaxHrAt,
    bool clearObservedMaxHr = false,
    int? pendingObservedMaxHr,
    bool clearPendingObservedMaxHr = false,
    bool? onboardingDone,
    SavedStrap? strap,
    bool clearStrap = false,
    String? introSeenVersion,
    String? sessionId,
    Map<String, PresetEdit>? presetEdits,
  }) => AppSettings(
    units: units ?? this.units,
    reps: reps ?? this.reps,
    recoverySeconds: recoverySeconds ?? this.recoverySeconds,
    lastMode: lastMode ?? this.lastMode,
    cues: cues ?? this.cues,
    haptics: haptics ?? this.haptics,
    volumeKeyLap: volumeKeyLap ?? this.volumeKeyLap,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    weatherPerRun: weatherPerRun ?? this.weatherPerRun,
    reducedMotion: reducedMotion ?? this.reducedMotion,
    typedMaxHr: clearTypedMaxHr ? null : (typedMaxHr ?? this.typedMaxHr),
    birthYear: clearBirthYear ? null : (birthYear ?? this.birthYear),
    observedMaxHr: clearObservedMaxHr
        ? null
        : (observedMaxHr ?? this.observedMaxHr),
    observedMaxHrAt: clearObservedMaxHr
        ? null
        : (observedMaxHrAt ?? this.observedMaxHrAt),
    pendingObservedMaxHr: clearPendingObservedMaxHr
        ? null
        : (pendingObservedMaxHr ?? this.pendingObservedMaxHr),
    onboardingDone: onboardingDone ?? this.onboardingDone,
    strap: clearStrap ? null : (strap ?? this.strap),
    introSeenVersion: introSeenVersion ?? this.introSeenVersion,
    sessionId: sessionId ?? this.sessionId,
    presetEdits: presetEdits ?? this.presetEdits,
  );

  Map<String, Object?> toJson() => {
    'units': units.name,
    'reps': reps,
    'recoverySeconds': recoverySeconds,
    'lastMode': lastMode.name,
    'cues': cues,
    'haptics': haptics,
    'volumeKeyLap': volumeKeyLap,
    'keepScreenOn': keepScreenOn,
    'weatherPerRun': weatherPerRun,
    'reducedMotion': reducedMotion,
    'typedMaxHr': typedMaxHr,
    'birthYear': birthYear,
    'observedMaxHr': observedMaxHr,
    'observedMaxHrAt': observedMaxHrAt?.toUtc().toIso8601String(),
    'pendingObservedMaxHr': pendingObservedMaxHr,
    'onboardingDone': onboardingDone,
    'strap': strap?.toJson(),
    'introSeenVersion': introSeenVersion,
    'sessionId': sessionId,
    'presetEdits': {
      for (final e in presetEdits.entries) e.key: e.value.toJson(),
    },
  };

  /// Lenient: unknown or malformed keys fall back to defaults, never throw.
  /// Phase 1's `maxHr` key migrates: its constant default 190 becomes
  /// "not entered" (null); any other value was typed by the user (N1).
  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    T pick<T>(String key, T fallback) {
      final v = j[key];
      return v is T ? v : fallback;
    }

    int? optInt(String key) {
      final v = j[key];
      return v is int ? v : null;
    }

    final strapJson = j['strap'];
    var typed = optInt('typedMaxHr');
    if (typed == null && j.containsKey('maxHr')) {
      final legacy = optInt('maxHr');
      if (legacy != null && legacy != MaxHrRules.fallback) typed = legacy;
    }
    if (typed != null && !MaxHrRules.validTyped(typed)) typed = null;
    final observedAtRaw = j['observedMaxHrAt'];
    return AppSettings(
      units: Units.values.asNameMap()[pick('units', '')] ?? d.units,
      reps: PresetRules.clampReps(pick('reps', d.reps)),
      recoverySeconds: PresetRules.clampRecovery(
        pick('recoverySeconds', d.recoverySeconds),
      ),
      // Schema <= 2 saved `fourByFour`; it is `intervals` now (I1).
      lastMode: switch (pick('lastMode', '')) {
        'fourByFour' => RecordMode.intervals,
        final String name => RecordMode.values.asNameMap()[name] ?? d.lastMode,
      },
      cues: pick('cues', d.cues),
      haptics: pick('haptics', d.haptics),
      volumeKeyLap: j['volumeKeyLap'] is bool
          ? j['volumeKeyLap'] as bool
          : null,
      keepScreenOn: pick('keepScreenOn', d.keepScreenOn),
      weatherPerRun: pick('weatherPerRun', d.weatherPerRun),
      reducedMotion: pick('reducedMotion', d.reducedMotion),
      typedMaxHr: typed,
      birthYear: optInt('birthYear'),
      observedMaxHr: optInt('observedMaxHr'),
      observedMaxHrAt: observedAtRaw is String
          ? DateTime.tryParse(observedAtRaw)
          : null,
      pendingObservedMaxHr: optInt('pendingObservedMaxHr'),
      onboardingDone: pick('onboardingDone', d.onboardingDone),
      strap: strapJson is Map<String, Object?> && strapJson['address'] is String
          ? SavedStrap.fromJson(strapJson)
          : null,
      introSeenVersion: j['introSeenVersion'] is String
          ? j['introSeenVersion'] as String
          : null,
      sessionId: pick('sessionId', d.sessionId),
      presetEdits: _edits(j['presetEdits']),
    );
  }
}

Map<String, PresetEdit> _edits(Object? raw) {
  if (raw is! Map<String, Object?>) return const {};
  final out = <String, PresetEdit>{};
  for (final e in raw.entries) {
    final v = e.value;
    if (v is! Map<String, Object?>) continue;
    try {
      out[e.key] = PresetEdit.fromJson(v);
    } catch (_) {
      // A damaged edit falls back to the preset's defaults.
    }
  }
  return out;
}

abstract class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.settings = const AppSettings()]);
  AppSettings settings;
  int saves = 0;

  @override
  Future<AppSettings> load() async => settings;

  @override
  Future<void> save(AppSettings s) async {
    settings = s;
    saves += 1;
  }
}

/// `files/state/settings.json`, written atomically (tmp + rename).
class FileSettingsStore implements SettingsStore {
  FileSettingsStore(this.stateDir);
  final Directory stateDir;

  File get _file => File('${stateDir.path}/settings.json');

  @override
  Future<AppSettings> load() async {
    try {
      if (!await _file.exists()) return const AppSettings();
      final json = jsonDecode(await _file.readAsString());
      if (json is Map<String, Object?>) return AppSettings.fromJson(json);
    } catch (e) {
      debugPrint('settings: unreadable, using defaults ($e)');
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) async {
    await stateDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await tmp.rename(_file.path);
  }
}

/// Owns the current settings; screens read it and call [update].
class SettingsController extends ChangeNotifier {
  SettingsController(this._store, [AppSettings initial = const AppSettings()])
    : _settings = initial;

  final SettingsStore _store;
  AppSettings _settings;
  AppSettings get settings => _settings;

  Future<void> load() async {
    _settings = await _store.load();
    notifyListeners();
  }

  Future<void> update(AppSettings Function(AppSettings) change) async {
    _settings = change(_settings);
    notifyListeners();
    await _store.save(_settings);
  }
}
