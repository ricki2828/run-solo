/// The next-step line on the run screen ("212 m left · then 200 m jog"). A
/// Dart port of Kotlin `CueWords.nextStep` (what the voice says at ten
/// seconds to go): same rules on the same spec, written instead of spoken
/// ("200 m jog" for "200 metres jog", "1:30 jog" for "1 minute 30 jog").
/// `test/state/next_step_test.dart` runs the cases of `CueWordsNextStepTest`
/// so the screen and the voice cannot drift apart.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';

/// What follows the current part, or null when nothing is said: goals,
/// events, Cooper, Free runs, the last part of a run. A zero-second recovery
/// is skipped.
String? nextStepText(SessionSpec? spec, Phase phase, int? stepIndex) {
  if (spec == null) return null;
  if (spec.templateId == engine.SessionSpec.goalId ||
      spec.templateId == engine.SessionSpec.parkrunId ||
      spec.cueProfile == CueProfile.cooper) {
    return null;
  }
  final int from;
  switch (phase) {
    case Phase.warmup:
      from = 0;
    case Phase.work || Phase.recovery:
      if (stepIndex == null) return null;
      from = stepIndex + 1;
    default:
      return null;
  }
  final steps = spec.steps;
  final reps = steps.where((s) => s.kind == StepKind.work).length;
  var i = from;
  while (true) {
    if (i >= steps.length) {
      return phase == Phase.cooldown || spec.cooldownSeconds == 0
          ? null
          : 'cool down';
    }
    final next = steps[i];
    if (next.kind == StepKind.recovery &&
        next.target == TargetKind.time &&
        next.value == 0) {
      i++;
      continue;
    }
    if (next.kind == StepKind.work) {
      if (reps > 1 && next.repIndex == reps) return 'last rep';
      return reps > 1 ? 'rep ${next.repIndex}' : null;
    }
    final String len;
    switch (next.target) {
      case TargetKind.time:
        len = _gap(next.value);
      case TargetKind.distance:
        len = _metres(next.value);
      case TargetKind.equalToPreviousWork:
        if (i == 0) return null;
        final w = steps[i - 1];
        len = w.target == TargetKind.distance
            ? _metres(w.value)
            : _gap(w.value);
    }
    final style = next.style == RecoveryStyle.stand ? 'stand' : next.style.name;
    return '$len $style';
  }
}

String _metres(int m) =>
    m >= 1000 && m % 1000 == 0 ? '${m ~/ 1000} km' : '$m m';

/// Under a minute "30 s", from a minute on "1:30" / "4:00".
String _gap(int seconds) {
  final s = seconds.abs();
  if (s < 60) return '$s s';
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
