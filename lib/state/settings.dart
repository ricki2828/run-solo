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

abstract final class HrZoneRules {
  static const int minResting = 30;
  static const int maxResting = 120;

  static bool validResting(int v) => v >= minResting && v <= maxResting;

  /// Five ascending bottoms (Z1..Z5) or null. Anything else is dropped.
  static List<int>? parseCustom(Object? raw) {
    if (raw is! List || raw.length != 5 || raw.any((e) => e is! int)) {
      return null;
    }
    final v = raw.cast<int>();
    return engine.HrZones.validate(v.sublist(1), z1Floor: v[0]) == null
        ? v
        : null;
  }
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

/// A finished "Send all past runs" pass: [count] runs, at [at] (UTC).
@immutable
class PastRunsSent {
  const PastRunsSent({required this.count, required this.at});
  final int count;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'count': count,
    'at': at.toUtc().toIso8601String(),
  };

  static PastRunsSent? tryParse(Object? v) {
    if (v is! Map || v['count'] is! int || v['at'] is! String) return null;
    final at = DateTime.tryParse(v['at'] as String);
    return at == null
        ? null
        : PastRunsSent(count: v['count'] as int, at: at.toUtc());
  }
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
    this.loadDismissedWeek,
    this.cues = true,
    this.kmSplits = true,
    this.checkInMetrics = CheckInMetric.defaults,
    this.spokenSummary = true,
    this.voiceCoaching = true,
    this.coachingDetail = CoachingDetail.full,
    this.autoPause = true,
    this.countdownSeconds = defaultCountdownSeconds,
    this.coachingTips = true,
    this.showWhileRunning = true,
    this.haptics = true,
    this.volumeKeyLap,
    this.keepScreenOn = true,
    this.weatherPerRun = true,
    this.reducedMotion = false,
    this.typedMaxHr,
    this.hrZoneMethod = engine.HrZoneMethod.percentMax,
    this.restingHr,
    this.customZones,
    this.birthYear,
    this.observedMaxHr,
    this.observedMaxHrAt,
    this.pendingObservedMaxHr,
    this.onboardingDone = false,
    this.strap,
    this.introSeenVersion,
    this.sessionId = engine.SessionSpec.norwegian4x4Id,
    this.presetEdits = const {},
    this.pbSeen = const {},
    this.autoSend = const {},
    this.autoSendSince = const {},
    this.pastRunsSent = const {},
    this.liveMapTypes = const {},
    this.topoMap = true,
    this.liveTopoMap = false,
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

  /// The week (its Monday, `2026-10-12`) whose "don't overdo it" warning
  /// the runner dismissed; a new week shows it again.
  final String? loadDismissedWeek;

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

  /// Voice → "Check-in": what each km line says besides the split, for Free
  /// and Trail runs. Order is fixed by importance natively; a metric with no
  /// data (no strap, no barometer, flat run) is skipped when it comes up.
  final List<CheckInMetric> checkInMetrics;

  /// Voice → "Spoken summary": a line as a run starts and one when it ends
  /// (trail, 4x4 and free runs say what they are and how they went). Needs
  /// [cues]. Default on.
  final bool spokenSummary;

  /// Voice → "Voice coaching": lines said during a run, from the next step
  /// to target status and zone drift. Needs [cues]. Default on.
  final bool voiceCoaching;

  /// Voice → "Coaching detail": [CoachingDetail.minimal] says the next step
  /// only; [CoachingDetail.full] adds target status and zone drift.
  final CoachingDetail coachingDetail;

  /// Recording → "Auto-pause": the recorder pauses itself when you stop and
  /// resumes when you move. Default on.
  final bool autoPause;

  /// Recording -> "Countdown": the 3-2-1-GO between tapping START on the
  /// Ready screen and the recorder starting. One of [countdownChoices];
  /// 0 = off (recording starts on the tap). Default 3 s.
  final int countdownSeconds;
  static const int defaultCountdownSeconds = 3;
  static const List<int> countdownChoices = [0, 3, 5, 10];

  /// Voice → "Coaching tips" (LV2, A10.7): where you stand and short tips,
  /// spoken at your splits. Off = no compare speech and no nudges. Needs
  /// [cues]. Default on.
  final bool coachingTips;

  /// Voice → "Show while running" (LV2, A10.7): the 2 s card on the record
  /// screen when a rank is spoken. Independent of [coachingTips].
  final bool showWhileRunning;

  /// Tips are spoken this run: voice cues and coaching tips both on.
  bool get tipsSpoken => cues && coachingTips;
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

  /// Settings → Heart rate zones → Method. Default share of max HR, which
  /// is what every run used before the choice existed.
  final engine.HrZoneMethod hrZoneMethod;

  /// Resting HR typed for the reserve method; null = not entered.
  final int? restingHr;

  /// The custom table: bottoms of Z1..Z5 in bpm (five values, ascending);
  /// null = not edited yet.
  final List<int>? customZones;

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

  /// LB3d "PB seen" (A11.6): board key to the run id of the best the
  /// runner last opened on that board. Drives the overview's NEW tag and
  /// the board detail's one quiet PB replay (A11.4). App state, not an
  /// index field.
  final Map<String, String> pbSeen;

  /// Settings → Send runs to: ids of the export targets switched on for
  /// automatic sending after each run. All off by default; a run is sent
  /// only to services the runner switched on (or by the Send button).
  final Set<String> autoSend;

  /// When each [autoSend] target was switched on. Only runs that finished
  /// after it are sent automatically; older runs go only via the Send
  /// button. A target with no entry sends nothing automatically.
  final Map<String, DateTime> autoSendSince;

  /// Per target id: the last "Send all past runs" pass that finished with no
  /// failures (how many runs, and when), so Settings can say so after a
  /// restart.
  final Map<String, PastRunsSent> pastRunsSent;

  /// Switch [id] on (at [now]) or off.
  AppSettings withAutoSend(String id, bool on, DateTime now) => copyWith(
    autoSend: {
      for (final x in autoSend)
        if (x != id) x,
      if (on) id,
    },
    autoSendSince: {
      for (final e in autoSendSince.entries)
        if (e.key != id) e.key: e.value,
      if (on) id: now.toUtc(),
    },
  );

  /// Run types (`free`, `laps`, `intervals`, `goal`, `tests`) whose record
  /// screen last showed the MAP view; every other type shows NUMBERS, the
  /// default. Remembered per type so a long easy run can keep the map while
  /// intervals keep the big numbers.
  final Set<String> liveMapTypes;

  /// Free and Trail maps: the offline Topo map (true) or Google's terrain
  /// map (false). Topo only draws where an installed offline pack covers the
  /// run; everywhere else Google stays.
  final bool topoMap;

  /// The live (in-run) map: Google (false, the default since 14-Oct) or the
  /// offline Topo map (true). Separate from [topoMap] so run detail and Home
  /// cards keep their own choice. A phone with no Google map at all uses Topo
  /// where a pack covers, whatever this says.
  final bool liveTopoMap;

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
    RecordMode.free || RecordMode.cooper || RecordMode.trail => false,
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
    String? loadDismissedWeek,
    bool? cues,
    bool? kmSplits,
    List<CheckInMetric>? checkInMetrics,
    bool? spokenSummary,
    bool? voiceCoaching,
    CoachingDetail? coachingDetail,
    bool? autoPause,
    int? countdownSeconds,
    bool? coachingTips,
    bool? showWhileRunning,
    bool? haptics,
    bool? volumeKeyLap,
    bool? keepScreenOn,
    bool? weatherPerRun,
    bool? reducedMotion,
    int? typedMaxHr,
    engine.HrZoneMethod? hrZoneMethod,
    int? restingHr,
    bool clearRestingHr = false,
    List<int>? customZones,
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
    Map<String, String>? pbSeen,
    Set<String>? autoSend,
    Map<String, DateTime>? autoSendSince,
    Map<String, PastRunsSent>? pastRunsSent,
    Set<String>? liveMapTypes,
    bool? topoMap,
    bool? liveTopoMap,
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
    loadDismissedWeek: loadDismissedWeek ?? this.loadDismissedWeek,
    cues: cues ?? this.cues,
    kmSplits: kmSplits ?? this.kmSplits,
    checkInMetrics: checkInMetrics ?? this.checkInMetrics,
    spokenSummary: spokenSummary ?? this.spokenSummary,
    voiceCoaching: voiceCoaching ?? this.voiceCoaching,
    coachingDetail: coachingDetail ?? this.coachingDetail,
    autoPause: autoPause ?? this.autoPause,
    countdownSeconds: countdownSeconds ?? this.countdownSeconds,
    coachingTips: coachingTips ?? this.coachingTips,
    showWhileRunning: showWhileRunning ?? this.showWhileRunning,
    haptics: haptics ?? this.haptics,
    volumeKeyLap: volumeKeyLap ?? this.volumeKeyLap,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    weatherPerRun: weatherPerRun ?? this.weatherPerRun,
    reducedMotion: reducedMotion ?? this.reducedMotion,
    typedMaxHr: clearTypedMaxHr ? null : (typedMaxHr ?? this.typedMaxHr),
    hrZoneMethod: hrZoneMethod ?? this.hrZoneMethod,
    restingHr: clearRestingHr ? null : (restingHr ?? this.restingHr),
    customZones: customZones ?? this.customZones,
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
    pbSeen: pbSeen ?? this.pbSeen,
    autoSend: autoSend ?? this.autoSend,
    autoSendSince: autoSendSince ?? this.autoSendSince,
    pastRunsSent: pastRunsSent ?? this.pastRunsSent,
    liveMapTypes: liveMapTypes ?? this.liveMapTypes,
    topoMap: topoMap ?? this.topoMap,
    liveTopoMap: liveTopoMap ?? this.liveTopoMap,
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
    'loadDismissedWeek': loadDismissedWeek,
    'cues': cues,
    'kmSplits': kmSplits,
    'checkInMetrics': [for (final m in checkInMetrics) m.name],
    'spokenSummary': spokenSummary,
    'voiceCoaching': voiceCoaching,
    'coachingDetail': coachingDetail.name,
    'autoPause': autoPause,
    'countdownSeconds': countdownSeconds,
    'coachingTips': coachingTips,
    'showWhileRunning': showWhileRunning,
    'haptics': haptics,
    'volumeKeyLap': volumeKeyLap,
    'keepScreenOn': keepScreenOn,
    'weatherPerRun': weatherPerRun,
    'reducedMotion': reducedMotion,
    'typedMaxHr': typedMaxHr,
    'hrZoneMethod': hrZoneMethod.name,
    'restingHr': restingHr,
    'customZones': customZones,
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
    'pbSeen': pbSeen,
    if (autoSend.isNotEmpty) 'autoSend': autoSend.toList()..sort(),
    if (autoSendSince.isNotEmpty)
      'autoSendSince': {
        for (final e in autoSendSince.entries)
          e.key: e.value.toUtc().toIso8601String(),
      },
    if (pastRunsSent.isNotEmpty)
      'pastRunsSent': {
        for (final e in pastRunsSent.entries) e.key: e.value.toJson(),
      },
    'liveMapTypes': liveMapTypes.toList()..sort(),
    'topoMap': topoMap,
    'liveTopoMap': liveTopoMap,
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
      loadDismissedWeek: j['loadDismissedWeek'] is String
          ? j['loadDismissedWeek'] as String
          : null,
      cues: pick('cues', d.cues),
      kmSplits: pick('kmSplits', d.kmSplits),
      checkInMetrics: j['checkInMetrics'] is List
          ? [
              for (final v in j['checkInMetrics'] as List)
                ?CheckInMetric.values.asNameMap()[v],
            ]
          : d.checkInMetrics,
      spokenSummary: pick('spokenSummary', d.spokenSummary),
      voiceCoaching: pick('voiceCoaching', d.voiceCoaching),
      coachingDetail:
          CoachingDetail.values.asNameMap()[pick('coachingDetail', '')] ??
          d.coachingDetail,
      autoPause: pick('autoPause', d.autoPause),
      countdownSeconds:
          countdownChoices.contains(
            pick('countdownSeconds', d.countdownSeconds),
          )
          ? pick('countdownSeconds', d.countdownSeconds)
          : d.countdownSeconds,
      coachingTips: pick('coachingTips', d.coachingTips),
      showWhileRunning: pick('showWhileRunning', d.showWhileRunning),
      haptics: pick('haptics', d.haptics),
      volumeKeyLap: j['volumeKeyLap'] is bool
          ? j['volumeKeyLap'] as bool
          : null,
      keepScreenOn: pick('keepScreenOn', d.keepScreenOn),
      weatherPerRun: pick('weatherPerRun', d.weatherPerRun),
      reducedMotion: pick('reducedMotion', d.reducedMotion),
      typedMaxHr: typed,
      // Unknown or malformed zone settings fall back to share of max.
      hrZoneMethod:
          engine.HrZoneMethod.values.asNameMap()[pick('hrZoneMethod', '')] ??
          d.hrZoneMethod,
      restingHr: switch (optInt('restingHr')) {
        final int v when HrZoneRules.validResting(v) => v,
        _ => null,
      },
      customZones: HrZoneRules.parseCustom(j['customZones']),
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
      pbSeen: _seen(j['pbSeen']),
      autoSend: j['autoSend'] is List
          ? {
              for (final v in j['autoSend'] as List)
                if (v is String) v,
            }
          : const {},
      autoSendSince: j['autoSendSince'] is Map
          ? {
              for (final e in (j['autoSendSince'] as Map).entries)
                if (e.key is String && e.value is String)
                  if (DateTime.tryParse(e.value as String) case final t?)
                    e.key as String: t.toUtc(),
            }
          : const {},
      pastRunsSent: j['pastRunsSent'] is Map
          ? {
              for (final e in (j['pastRunsSent'] as Map).entries)
                if (e.key is String)
                  e.key as String: ?PastRunsSent.tryParse(e.value),
            }
          : const {},
      liveMapTypes: {
        if (j['liveMapTypes'] case final List<Object?> l)
          for (final v in l)
            if (v is String) v,
      },
      topoMap: j['topoMap'] is bool ? j['topoMap'] as bool : true,
      liveTopoMap: j['liveTopoMap'] is bool ? j['liveTopoMap'] as bool : false,
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

Map<String, String> _seen(Object? raw) {
  if (raw is! Map) return const {};
  return {
    for (final e in raw.entries)
      if (e.key is String && e.value is String)
        e.key as String: e.value as String,
  };
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

/// Settings → Voice → "Check-in": the things a km check-in can say. [key] is
/// what Kotlin's `CheckInMetric` is told, in importance order (the spoken
/// order); [label] and [blurb] are the picker's.
enum CheckInMetric {
  distance('distance', 'Distance', 'The km you have reached.'),
  time('time', 'Elapsed time', 'Moving time so far.'),
  pace('pace', 'Pace', 'The pace of the km you just ran.'),
  retrace(
    'retrace',
    'Way back',
    'When you are doubling back: distance to the start and the climb ahead.',
  ),
  hrZone(
    'hrZone',
    'Heart rate zone',
    'Your zone and how long you have spent in it. Needs a strap.',
  ),
  heightVsStart(
    'heightVsStart',
    'Height vs start',
    'Metres above or below where you began. Needs a barometer.',
  ),
  climb('climb', 'Climb so far', 'Total climbed. Needs a barometer.'),
  truePace(
    'truePace',
    'True Pace',
    'Pace with hills and heat out, only when it differs from your pace.',
  ),
  avgPace('avgPace', 'Average pace', 'Your average pace for the run so far.');

  const CheckInMetric(this.key, this.label, this.blurb);
  final String key;
  final String label;
  final String blurb;

  /// Everything on: a metric with no data is skipped, and the line is cut to
  /// a short glance, so more on costs nothing on a flat road run.
  static const List<CheckInMetric> defaults = CheckInMetric.values;

  /// What the picker offers: every metric, "Way back" included. The recorder
  /// feeds it from the native retrace detector, so the runner can turn it off
  /// like the others.
  static List<CheckInMetric> get pickable => CheckInMetric.values;
}

/// Settings → Voice → "Coaching detail".
enum CoachingDetail {
  minimal('Minimal', 'Next step only.'),
  full('Full', 'Next step, target pace and heart rate zone.');

  const CoachingDetail(this.label, this.blurb);
  final String label;
  final String blurb;
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
