/// The app's bridge between the engine's `SessionSpec` (history, catalogue,
/// validation) and the Pigeon `SessionSpec` the recorder takes (CONTRACT.md
/// I1: the same shape, flat so it maps 1:1). Kotlin never expands a preset;
/// the app expands it with `SessionCatalogue` and sends the result.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'platform_api.g.dart' as p;

extension EngineSessionToPigeon on engine.SessionSpec {
  p.SessionSpec toPigeon() => p.SessionSpec(
    templateId: templateId,
    templateVersion: templateVersion,
    name: name,
    warmupSeconds: warmupSeconds,
    cooldownSeconds: cooldownSeconds,
    lapLockout: lapLockout,
    autoStop: autoStop,
    cueProfile: p.CueProfile.values.byName(cueProfile.name),
    hrBandLow: hrBandLow,
    hrBandHigh: hrBandHigh,
    steps: [
      for (final s in steps)
        p.SessionStep(
          kind: p.StepKind.values.byName(s.kind.name),
          target: p.TargetKind.values.byName(s.target.name),
          value: s.value,
          style: p.RecoveryStyle.values.byName(s.style.name),
          repIndex: s.rep,
        ),
    ],
  );
}

extension PigeonSessionToEngine on p.SessionSpec {
  engine.SessionSpec toEngine() => engine.SessionSpec(
    templateId: templateId,
    templateVersion: templateVersion,
    name: name,
    warmupSeconds: warmupSeconds,
    cooldownSeconds: cooldownSeconds,
    lapLockout: lapLockout,
    // Null from an older recorder = off, as the engine's JSON default.
    autoStop: autoStop ?? false,
    cueProfile: engine.CueProfile.values.byName(cueProfile.name),
    hrBandLow: hrBandLow,
    hrBandHigh: hrBandHigh,
    steps: [
      for (final s in steps)
        engine.SessionStep(
          kind: engine.StepKind.values.byName(s.kind.name),
          target: engine.TargetKind.values.byName(s.target.name),
          value: s.value,
          style: engine.RecoveryStyle.values.byName(s.style.name),
          rep: s.repIndex,
        ),
    ],
  );

  /// Work steps (reps); N reps carry N − 1 recoveries.
  int get repCount => steps.where((s) => s.kind == p.StepKind.work).length;

  /// The time-based step of [kind] for 1-based [rep], or null when the step
  /// is missing or not timed (distance / equal-to-previous steps are I2).
  int? timedSeconds(p.StepKind kind, int rep) {
    for (final s in steps) {
      if (s.kind == kind && s.repIndex == rep) {
        return s.target == p.TargetKind.time ? s.value : null;
      }
    }
    return null;
  }
}
