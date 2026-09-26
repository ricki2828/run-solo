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
    this.goalRun = false,
    this.goalId = GoalChoice.eventId,
    this.goalCustomMetres = GoalChoice.defaultCustomMetres,
    this.goalCustomSeconds = GoalChoice.defaultCustomSeconds,
    this.profileSex = ProfileSex.notSet,
    this.tryNextDismissed,
    this.cues = true,
    this.kmSplits = true,
    this.haptics = true,
    this.volumeKeyLap,
    this.keepScreenOn = true,
    this.weatherPerRun = true,
    this.compareHeatAdjusted = false,
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

  /// GOAL is the picked run type (founder 26-Sep, plan §G): a goal run
  /// records as Intervals carrying one work step; [lastMode] keeps the other
  /// chips' choice.
  final bool goalRun;

  /// The picked goal ([GoalChoice] id): the Saturday 5 km event, `d<m>` or
  /// `t<s>`.
  final String goalId;

  /// GOAL > Distance > Custom: whole metres within the engine's goal
  /// limits, entered in the runner's units (0.1 km or 0.1 mi).
  final int goalCustomMetres;

  /// GOAL > Time > Custom: whole minutes, within the engine's limits.
  final int goalCustomSeconds;

  /// Settings → Profile → "Sex (for fitness norms)" (CR2, A10.7). Only the
  /// VO2 research-norm line reads it; it stays on this phone.
  final ProfileSex profileSex;

  /// The run whose Home "try next" card the runner dismissed (A10.4).
  final String? tryNextDismissed;

  /// The event (K1) is the picked goal.
  bool get eventRun => goalRun && goalId == GoalChoice.eventId;

  /// The picked goal's step: (distance?, metres or seconds); null for the
  /// event, which runs its own spec.
  ({bool distance, int value})? get goalStep {
    final g = GoalChoice.byId(goalId);
    if (g == null || g.id == GoalChoice.eventId) return null;
    final v = g.value ?? (g.distance ? goalCustomMetres : goalCustomSeconds);
    return (distance: g.distance, value: v);
  }

  /// The picked goal's shown and spoken name: G1's catalogue names ("10K",
  /// "45 min"); a custom distance in the runner's units ("12.3 km",
  /// "7.5 mi"). Null for the event and when nothing is picked.
  String? get goalName {
    final g = GoalChoice.byId(goalId);
    final step = goalStep;
    if (g == null || step == null) return null;
    if (g.id == GoalChoice.customDistanceId && units == Units.mi) {
      final mi = step.value / GoalChoice.metresPerMile;
      return '${mi.toStringAsFixed(1)} mi';
    }
    return engine.GoalCatalogue.nameFor(
      step.distance ? engine.TargetKind.distance : engine.TargetKind.time,
      step.value,
    );
  }

  /// The spec a goal run records (plan §G, G1's specs and names); the
  /// event's is `SessionSpec.parkrun(eventName)`. Null when GOAL is not
  /// the picked run type.
  engine.SessionSpec? goalSpec(String eventName) {
    if (!goalRun) return null;
    final step = goalStep;
    if (step == null) return engine.SessionSpec.parkrun(eventName);
    final name = goalName!;
    final miles =
        GoalChoice.byId(goalId)?.id == GoalChoice.customDistanceId &&
        units == Units.mi;
    return step.distance
        ? engine.SessionSpec.goalDistance(
            step.value,
            name,
            // "7.5 miles", not the km default (the voice says spokenName).
            spokenName: miles
                ? engine.GoalCatalogue.spokenNameFor(
                    engine.TargetKind.distance,
                    step.value,
                    miles: true,
                  )
                : null,
          )
        : engine.SessionSpec.goalTime(step.value, name);
  }

  final bool cues;

  /// Voice → "Km splits": a Free run says each km (Phase 4 LV1). Default on.
  final bool kmSplits;
  final bool haptics;

  /// Null = the run type's default (plan §18.2: on for Laps, off for 4x4,
  /// never for Free). See [volumeKeyLapFor].
  final bool? volumeKeyLap;
  final bool keepScreenOn;

  /// "Weather for each run" (v1 plan §18.6, default on): fetch the
  /// temperature and dew point for each finished run from Open-Meteo with
  /// the location rounded to about 10 km. Off = nothing is sent.
  final bool weatherPerRun;

  /// "Compare heat-adjusted paces" (W2, v1 plan §18.5, default off):
  /// verdicts compare heat-adjusted headlines; flipping it recomputes every
  /// verdict, like an engine bump, keeping history. The trend chart leads
  /// with the adjusted series.
  final bool compareHeatAdjusted;
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
  RecordMode get recordMode => goalRun
      ? RecordMode.intervals
      : lastMode == RecordMode.intervals && SessionChoice.isFartlek(sessionId)
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
    bool? goalRun,
    String? goalId,
    int? goalCustomMetres,
    int? goalCustomSeconds,
    ProfileSex? profileSex,
    String? tryNextDismissed,
    bool? cues,
    bool? kmSplits,
    bool? haptics,
    bool? volumeKeyLap,
    bool? keepScreenOn,
    bool? weatherPerRun,
    bool? compareHeatAdjusted,
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
    goalRun: goalRun ?? this.goalRun,
    goalId: goalId ?? this.goalId,
    goalCustomMetres: goalCustomMetres ?? this.goalCustomMetres,
    goalCustomSeconds: goalCustomSeconds ?? this.goalCustomSeconds,
    profileSex: profileSex ?? this.profileSex,
    tryNextDismissed: tryNextDismissed ?? this.tryNextDismissed,
    cues: cues ?? this.cues,
    kmSplits: kmSplits ?? this.kmSplits,
    haptics: haptics ?? this.haptics,
    volumeKeyLap: volumeKeyLap ?? this.volumeKeyLap,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    weatherPerRun: weatherPerRun ?? this.weatherPerRun,
    compareHeatAdjusted: compareHeatAdjusted ?? this.compareHeatAdjusted,
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
    'goalRun': goalRun,
    'goalId': goalId,
    'goalCustomMetres': goalCustomMetres,
    'goalCustomSeconds': goalCustomSeconds,
    'profileSex': profileSex.name,
    'tryNextDismissed': tryNextDismissed,
    'cues': cues,
    'kmSplits': kmSplits,
    'haptics': haptics,
    'volumeKeyLap': volumeKeyLap,
    'keepScreenOn': keepScreenOn,
    'weatherPerRun': weatherPerRun,
    'compareHeatAdjusted': compareHeatAdjusted,
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
      goalRun: pick('goalRun', d.goalRun),
      goalId: GoalChoice.byId(pick('goalId', d.goalId)) == null
          ? d.goalId
          : pick('goalId', d.goalId),
      goalCustomMetres: GoalChoice.clampMetres(
        pick('goalCustomMetres', d.goalCustomMetres),
      ),
      goalCustomSeconds: GoalChoice.clampSeconds(
        pick('goalCustomSeconds', d.goalCustomSeconds),
      ),
      profileSex:
          ProfileSex.values.asNameMap()[pick('profileSex', '')] ?? d.profileSex,
      tryNextDismissed: j['tryNextDismissed'] is String
          ? j['tryNextDismissed'] as String
          : null,
      cues: pick('cues', d.cues),
      kmSplits: pick('kmSplits', d.kmSplits),
      haptics: pick('haptics', d.haptics),
      volumeKeyLap: j['volumeKeyLap'] is bool
          ? j['volumeKeyLap'] as bool
          : null,
      keepScreenOn: pick('keepScreenOn', d.keepScreenOn),
      weatherPerRun: pick('weatherPerRun', d.weatherPerRun),
      compareHeatAdjusted: pick('compareHeatAdjusted', d.compareHeatAdjusted),
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

/// The GOAL picker's choices (plan §G): Distance or Time. The engine's
/// goal specs (G1, #63) run everything but the event; until they land only
/// the event can be picked.
class GoalChoice {
  const GoalChoice(this.id, this.label, {required this.distance, this.value});
  final String id;
  final String label;
  final bool distance;

  /// Step metres or seconds; null for Custom (the settings hold it) and for
  /// the event (its own spec).
  final int? value;

  bool get custom => id == customDistanceId || id == customTimeId;

  /// The Saturday 5 km event (K1), labelled from `kEventNames` by the UI.
  static const String eventId = 'parkrun'; // event-name-ok: data key
  static const String customDistanceId = 'dcustom';
  static const String customTimeId = 'tcustom';

  static const int defaultCustomMetres = 12000;
  static const int defaultCustomSeconds = 2700;

  static const double metresPerMile = 1609.344;

  /// Whole metres within the engine's goal limits.
  static int clampMetres(int m) => m.clamp(
    engine.SessionSpec.goalMinMetres,
    engine.SessionSpec.goalMaxMetres,
  );

  /// Whole minutes within the engine's goal limits.
  static int clampSeconds(int s) => ((s / 60).round() * 60).clamp(
    engine.SessionSpec.goalMinSeconds,
    engine.SessionSpec.goalMaxSeconds,
  );

  /// Standard names and values are G1's (`GoalCatalogue`).
  static const List<GoalChoice> distances = [
    GoalChoice('d5000', '5K', distance: true, value: 5000),
    GoalChoice(eventId, '', distance: true),
    GoalChoice('d10000', '10K', distance: true, value: 10000),
    GoalChoice('d21098', 'Half', distance: true, value: 21098),
    GoalChoice('d42195', 'Marathon', distance: true, value: 42195),
    GoalChoice(customDistanceId, 'Custom', distance: true),
  ];
  static const List<GoalChoice> times = [
    GoalChoice('t1800', '30 min', distance: false, value: 1800),
    GoalChoice('t3600', '1 hour', distance: false, value: 3600),
    GoalChoice(customTimeId, 'Custom', distance: false),
  ];

  static GoalChoice? byId(String id) {
    for (final g in [...distances, ...times]) {
      if (g.id == id) return g;
    }
    return null;
  }
}

/// Settings → Profile (A10.7): "Not set" / "Male" / "Female" / "Prefer not
/// to say".
enum ProfileSex {
  notSet('Not set'),
  male('Male'),
  female('Female'),
  preferNot('Prefer not to say');

  const ProfileSex(this.label);
  final String label;

  /// For the research norms: null unless male or female.
  engine.NormsSex? get norms => switch (this) {
    ProfileSex.male => engine.NormsSex.male,
    ProfileSex.female => engine.NormsSex.female,
    ProfileSex.notSet || ProfileSex.preferNot => null,
  };
}
