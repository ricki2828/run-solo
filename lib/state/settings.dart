/// User settings mirrored to `files/state/settings.json` (plan §2: sidecars
/// are the source of truth, the index is a cache). Kept tiny for Phase 1;
/// Settings screen proper is Phase 3.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/gateway.dart';

/// 4x4 editor bounds (plan §6): reps 3–6, work locked 4:00, recovery
/// 2:00–5:00 in 15 s steps.
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

  static Preset normalise(Preset p) => Preset(
    reps: clampReps(p.reps),
    workSeconds: workSeconds,
    recoverySeconds: clampRecovery(p.recoverySeconds),
  );
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
    this.lastMode = RecordMode.fourByFour,
    this.cues = true,
    this.haptics = true,
    this.volumeKeyLap = false,
    this.keepScreenOn = true,
    this.reducedMotion = false,
    this.maxHr = 190,
    this.onboardingDone = false,
    this.strap,
  });

  final Units units;
  final int reps;
  final int recoverySeconds;
  final RecordMode lastMode;
  final bool cues;
  final bool haptics;
  final bool volumeKeyLap;
  final bool keepScreenOn;
  final bool reducedMotion;
  final int maxHr;
  final bool onboardingDone;
  final SavedStrap? strap;

  Preset get preset => Preset(
    reps: reps,
    workSeconds: PresetRules.workSeconds,
    recoverySeconds: recoverySeconds,
  );

  AppSettings copyWith({
    Units? units,
    int? reps,
    int? recoverySeconds,
    RecordMode? lastMode,
    bool? cues,
    bool? haptics,
    bool? volumeKeyLap,
    bool? keepScreenOn,
    bool? reducedMotion,
    int? maxHr,
    bool? onboardingDone,
    SavedStrap? strap,
    bool clearStrap = false,
  }) => AppSettings(
    units: units ?? this.units,
    reps: reps ?? this.reps,
    recoverySeconds: recoverySeconds ?? this.recoverySeconds,
    lastMode: lastMode ?? this.lastMode,
    cues: cues ?? this.cues,
    haptics: haptics ?? this.haptics,
    volumeKeyLap: volumeKeyLap ?? this.volumeKeyLap,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    reducedMotion: reducedMotion ?? this.reducedMotion,
    maxHr: maxHr ?? this.maxHr,
    onboardingDone: onboardingDone ?? this.onboardingDone,
    strap: clearStrap ? null : (strap ?? this.strap),
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
    'reducedMotion': reducedMotion,
    'maxHr': maxHr,
    'onboardingDone': onboardingDone,
    'strap': strap?.toJson(),
  };

  /// Lenient: unknown or malformed keys fall back to defaults, never throw.
  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    T pick<T>(String key, T fallback) {
      final v = j[key];
      return v is T ? v : fallback;
    }

    final strapJson = j['strap'];
    return AppSettings(
      units: Units.values.asNameMap()[pick('units', '')] ?? d.units,
      reps: PresetRules.clampReps(pick('reps', d.reps)),
      recoverySeconds: PresetRules.clampRecovery(
        pick('recoverySeconds', d.recoverySeconds),
      ),
      lastMode:
          RecordMode.values.asNameMap()[pick('lastMode', '')] ?? d.lastMode,
      cues: pick('cues', d.cues),
      haptics: pick('haptics', d.haptics),
      volumeKeyLap: pick('volumeKeyLap', d.volumeKeyLap),
      keepScreenOn: pick('keepScreenOn', d.keepScreenOn),
      reducedMotion: pick('reducedMotion', d.reducedMotion),
      maxHr: pick('maxHr', d.maxHr),
      onboardingDone: pick('onboardingDone', d.onboardingDone),
      strap: strapJson is Map<String, Object?> && strapJson['address'] is String
          ? SavedStrap.fromJson(strapJson)
          : null,
    );
  }
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
