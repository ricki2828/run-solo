import 'session_spec.dart';

/// The eight Intervals presets, in picker order (Phase 3 plan §3.1, D1). The
/// app expands a preset here and hands Kotlin the expanded [SessionSpec];
/// Kotlin never expands. Editable fields are only the ones the plan table
/// lists (D2); anything else is "Save as custom".
class PresetDef {
  const PresetDef({
    required this.id,
    required this.name,
    required this.purpose,
    required this.defaultReps,
    this.minReps,
    this.maxReps,
    required this.work,
    this.workRange,
    required this.recovery,
    this.recoveryRange,
    this.recoveryDistanceRange,
    this.ladder,
    this.cueProfile = CueProfile.standard,
    this.hrBandLow,
    this.hrBandHigh,
  });

  final String id;
  final String name;

  /// One line for the picker card.
  final String purpose;
  final int defaultReps;

  /// Rep range when reps are editable; null = fixed.
  final int? minReps;
  final int? maxReps;

  /// The default work step (rep 1); [ladder] overrides per rep.
  final SessionStep work;

  /// Editable work value range (seconds or metres, same target as [work]).
  final (int, int)? workRange;

  /// The default recovery step (rep 1).
  final SessionStep recovery;

  /// Editable recovery ranges: seconds (time) and/or metres (distance).
  final (int, int)? recoveryRange;
  final (int, int)? recoveryDistanceRange;

  /// Pyramid: fixed work seconds per rep.
  final List<int>? ladder;
  final CueProfile cueProfile;
  final double? hrBandLow;
  final double? hrBandHigh;

  bool get repsEditable => minReps != null;
  bool get workEditable => workRange != null;
  bool get recoveryEditable =>
      recoveryRange != null || recoveryDistanceRange != null;

  /// The expanded session at the defaults.
  SessionSpec get defaults => expand();

  /// Expand with the runner's edits. [recovery] is a whole recovery step
  /// (time or distance) so the 400s can switch between metres and minutes.
  /// Throws [ArgumentError] for a field that is not editable or out of range.
  SessionSpec expand({int? reps, int? workValue, SessionStep? recovery}) {
    final n = reps ?? defaultReps;
    if (reps != null && reps != defaultReps) {
      if (!repsEditable || reps < minReps! || reps > maxReps!) {
        throw ArgumentError.value(
          reps,
          'reps',
          '$id: not editable or out of range',
        );
      }
    }
    final w = workValue ?? work.value;
    if (workValue != null && workValue != work.value) {
      final r = workRange;
      if (r == null || workValue < r.$1 || workValue > r.$2) {
        throw ArgumentError.value(workValue, 'workValue', '$id: out of range');
      }
    }
    final rec = recovery ?? this.recovery;
    if (recovery != null && recovery != this.recovery) {
      final range = switch (rec.target) {
        TargetKind.time => recoveryRange,
        TargetKind.distance => recoveryDistanceRange,
        TargetKind.equalToPreviousWork => null,
      };
      if (range == null ||
          rec.value < range.$1 ||
          rec.value > range.$2 ||
          rec.kind != StepKind.recovery) {
        throw ArgumentError.value(rec, 'recovery', '$id: out of range');
      }
    }
    final ladder = this.ladder;
    final steps = ladder != null
        ? [
            for (var i = 0; i < ladder.length; i++) ...[
              SessionStep.work(ladder[i], rep: i + 1),
              if (i < ladder.length - 1) _recoveryFor(rec, i + 1),
            ],
          ]
        : SessionSpec.uniform(
            reps: n,
            work: (r) => SessionStep(
              kind: StepKind.work,
              target: work.target,
              value: w,
              style: RecoveryStyle.run,
              rep: r,
            ),
            recovery: (r) => _recoveryFor(rec, r),
          );
    return SessionSpec(
      templateId: id,
      templateVersion: 1,
      name: id == '400s' ? '$n × 400 m' : name,
      cueProfile: cueProfile,
      hrBandLow: hrBandLow,
      hrBandHigh: hrBandHigh,
      steps: steps,
    );
  }

  static SessionStep _recoveryFor(SessionStep template, int rep) => SessionStep(
    kind: StepKind.recovery,
    target: template.target,
    value: template.value,
    style: template.style,
    rep: rep,
  );
}

abstract final class SessionCatalogue {
  static const PresetDef norwegian4x4 = PresetDef(
    id: SessionSpec.norwegian4x4Id,
    name: 'Norwegian 4x4',
    purpose: 'VO2 max, the flagship',
    defaultReps: 4,
    minReps: 3,
    maxReps: 6,
    work: SessionStep.work(240, rep: 1),
    recovery: SessionStep.recovery(180, rep: 1),
    recoveryRange: (120, 300),
    hrBandLow: 0.85,
    hrBandHigh: 0.95,
  );

  static const PresetDef thirtyThirty = PresetDef(
    id: '30-30s',
    name: '30/30s',
    purpose: 'Speed and VO2 with short efforts',
    defaultReps: 20,
    minReps: 10,
    maxReps: 30,
    work: SessionStep.work(30, rep: 1),
    recovery: SessionStep.recovery(30, rep: 1),
    cueProfile: CueProfile.short,
  );

  static const PresetDef oneMinute = PresetDef(
    id: '1-min-reps',
    name: '1-minute reps',
    purpose: 'Classic starter interval session',
    defaultReps: 10,
    minReps: 6,
    maxReps: 15,
    work: SessionStep.work(60, rep: 1),
    recovery: SessionStep.recovery(60, rep: 1),
  );

  static const PresetDef pyramid = PresetDef(
    id: 'pyramid',
    name: 'Pyramid',
    purpose: 'Mixed-length VO2 session, keeps it interesting',
    defaultReps: 7,
    work: SessionStep.work(60, rep: 1),
    recovery: SessionStep.recoveryEqualTime(rep: 1),
    ladder: [60, 120, 180, 240, 180, 120, 60],
  );

  static const PresetDef tempo = PresetDef(
    id: 'tempo',
    name: 'Tempo intervals',
    purpose: 'Threshold ("cruise") work',
    defaultReps: 3,
    minReps: 2,
    maxReps: 5,
    work: SessionStep.work(480, rep: 1),
    workRange: (300, 720),
    recovery: SessionStep.recovery(120, rep: 1),
    hrBandLow: 0.80,
    hrBandHigh: 0.90,
  );

  static const PresetDef fourHundreds = PresetDef(
    id: '400s',
    name: '8 × 400 m',
    purpose: 'Track speed, 5k sharpening',
    defaultReps: 8,
    minReps: 4,
    maxReps: 12,
    work: SessionStep.workDistance(400, rep: 1),
    recovery: SessionStep.recoveryDistance(200, rep: 1),
    recoveryRange: (60, 120),
    recoveryDistanceRange: (100, 400),
  );

  static const PresetDef yasso = PresetDef(
    id: 'yasso-800s',
    name: 'Yasso 800s',
    purpose: 'Marathon-block staple',
    defaultReps: 6,
    minReps: 4,
    maxReps: 10,
    work: SessionStep.workDistance(800, rep: 1),
    recovery: SessionStep.recoveryEqualTime(rep: 1),
  );

  static const PresetDef kmRepeats = PresetDef(
    id: '1km-repeats',
    name: '1 km repeats',
    purpose: '5k to 10k pace work',
    defaultReps: 5,
    minReps: 3,
    maxReps: 8,
    work: SessionStep.workDistance(1000, rep: 1),
    recovery: SessionStep.recovery(120, rep: 1),
    recoveryRange: (60, 180),
  );

  /// Picker order (plan §3.1 table).
  static const List<PresetDef> presets = [
    norwegian4x4,
    thirtyThirty,
    oneMinute,
    pyramid,
    tempo,
    fourHundreds,
    yasso,
    kmRepeats,
  ];

  static PresetDef? byId(String id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Expand preset [id] with the runner's edits (see [PresetDef.expand]).
  static SessionSpec expand(
    String id, {
    int? reps,
    int? workValue,
    SessionStep? recovery,
  }) {
    final p = byId(id);
    if (p == null) throw ArgumentError.value(id, 'id', 'no such preset');
    return p.expand(reps: reps, workValue: workValue, recovery: recovery);
  }

  /// The preset whose DEFAULT expansion has comparison key [key], if any
  /// (the nominal session behind a key's noise floor, plan §3.7 W1).
  static PresetDef? ownerOfKey(String key) {
    for (final p in presets) {
      if (p.defaults.comparisonKey == key) return p;
    }
    return null;
  }
}
