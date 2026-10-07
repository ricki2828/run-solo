import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/next_step.dart';

/// The cases of Kotlin `CueWordsNextStepTest`, so the line on the screen and
/// the voice's "ten seconds, then ..." name the same step (written form:
/// "200 m jog" for "200 metres jog", "1:30 jog" for "1 minute 30 jog").
SessionSpec eight400() => engine.SessionSpec(
  templateId: '400s',
  templateVersion: 1,
  name: '8 × 400 m',
  steps: [
    for (var r = 1; r <= 8; r++) ...[
      engine.SessionStep.work(60, rep: r),
      if (r < 8) engine.SessionStep.recoveryDistance(200, rep: r),
    ],
  ],
).toPigeon();

SessionSpec withRecovery(
  engine.SessionSpec base, {
  engine.RecoveryStyle? style,
  int? seconds,
  bool equal = false,
}) => engine.SessionSpec(
  templateId: base.templateId,
  templateVersion: 1,
  name: base.name,
  steps: [
    for (final s in base.steps)
      if (s.isWork)
        s
      else if (equal)
        engine.SessionStep.recoveryEqualTime(rep: s.rep)
      else
        engine.SessionStep.recovery(
          seconds ?? s.value,
          rep: s.rep,
          style: style ?? s.style,
        ),
  ],
).toPigeon();

void main() {
  test('work into a distance jog recovery', () {
    expect(nextStepText(eight400(), Phase.work, 0), '200 m jog');
  });

  test('recovery into the next rep, and into the last rep', () {
    expect(nextStepText(eight400(), Phase.recovery, 1), 'rep 2');
    expect(nextStepText(eight400(), Phase.recovery, 13), 'last rep');
  });

  test('time recoveries by style; equal-time follows the work step', () {
    final s = engine.SessionSpec.norwegian4x4(reps: 3, recoverySeconds: 90);
    expect(nextStepText(s.toPigeon(), Phase.work, 0), '1:30 jog');
    expect(
      nextStepText(
        withRecovery(s, style: engine.RecoveryStyle.walk, seconds: 30),
        Phase.work,
        0,
      ),
      '30 s walk',
    );
    expect(
      nextStepText(
        withRecovery(s, style: engine.RecoveryStyle.stand, seconds: 45),
        Phase.work,
        0,
      ),
      '45 s stand',
    );
    expect(
      nextStepText(withRecovery(s, equal: true), Phase.work, 0),
      '4:00 jog',
    );
  });

  test('warm-up into the first rep, the last rep into the cool-down', () {
    final s = engine.SessionSpec.norwegian4x4().toPigeon();
    expect(nextStepText(s, Phase.warmup, null), 'rep 1');
    expect(nextStepText(s, Phase.work, 6), 'cool down');
  });

  test('goals, Cooper and Free runs say nothing', () {
    expect(
      nextStepText(
        engine.SessionSpec.goalTime(1800, '30 min').toPigeon(),
        Phase.work,
        0,
      ),
      isNull,
    );
    expect(
      nextStepText(engine.SessionSpec.cooper.toPigeon(), Phase.work, 0),
      isNull,
    );
    expect(nextStepText(null, Phase.none, null), isNull);
  });
}
