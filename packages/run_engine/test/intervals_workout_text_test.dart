import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  test(
    '4x4 with HR band: open warm-up and cool-down left out, repeat block',
    () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4(), maxHr: 190)!;
      final text = IntervalsWorkoutText.fromWorkout(w, maxHr: 190)!;
      expect(
        text,
        '3x\n'
        '- Work 4m 85-95% HR\n'
        '- Recovery 3m\n'
        '\n'
        '- Work 4m 85-95% HR',
      );
    },
  );

  test('open warm-up and cool-down take the defaults when given', () {
    final w = FitWorkout.fromSession(SessionSpec.norwegian4x4(), maxHr: 190)!;
    final text = IntervalsWorkoutText.fromWorkout(
      w,
      maxHr: 190,
      openWarmupSeconds: 600,
      openCooldownSeconds: 300,
    )!;
    expect(text, startsWith('- Warm-up 10m\n\n3x'));
    expect(text, endsWith('- Cool-down 5m'));
    final none = IntervalsWorkoutText.fromWorkout(
      w,
      maxHr: 190,
      openWarmupSeconds: 0,
    )!;
    expect(none, isNot(contains('Warm-up')));
  });

  test('a fixed warm-up ignores the default', () {
    const spec = SessionSpec(
      templateId: 'x',
      templateVersion: 1,
      name: 'X',
      warmupSeconds: 300,
      steps: [SessionStep.work(60, rep: 1)],
    );
    final text = IntervalsWorkoutText.fromWorkout(
      FitWorkout.fromSession(spec)!,
      openWarmupSeconds: 900,
    )!;
    expect(text, contains('- Warm-up 5m'));
    expect(text, isNot(contains('15m')));
  });

  test('pace window is written slow-fast per km', () {
    final w = FitWorkout.fromSession(
      SessionSpec.norwegian4x4(reps: 2),
      workPace: FitTarget.pace(slowSecPerKm: 250, fastSecPerKm: 240),
    )!;
    final text = IntervalsWorkoutText.fromWorkout(w)!;
    expect(text, contains('- Work 4m 4:10-4:00/km Pace'));
    expect(text, contains('- Recovery 3m'));
  });

  test('fixed warm-up and cool-down, distance steps', () {
    const spec = SessionSpec(
      templateId: 'x',
      templateVersion: 1,
      name: 'X',
      warmupSeconds: 600,
      cooldownSeconds: 300,
      steps: [
        SessionStep.workDistance(800, rep: 1),
        SessionStep.recoveryDistance(1000, rep: 1),
        SessionStep.workDistance(800, rep: 2),
      ],
    );
    final text = IntervalsWorkoutText.fromWorkout(
      FitWorkout.fromSession(spec)!,
    )!;
    expect(text, contains('- Warm-up 10m'));
    expect(text, contains('- Work 800mtr'));
    expect(text, contains('- Recovery 1km'));
    expect(text, contains('- Cool-down 5m'));
  });

  test('HR targets are dropped without a max HR', () {
    final w = FitWorkout.fromSession(
      SessionSpec.norwegian4x4(reps: 2),
      maxHr: 190,
    )!;
    expect(IntervalsWorkoutText.fromWorkout(w), isNot(contains('HR')));
  });

  test('an open step that is not warm-up or cool-down cannot be written', () {
    const spec = SessionSpec(
      templateId: 'x',
      templateVersion: 1,
      name: 'Y',
      warmupSeconds: 0,
      cooldownSeconds: 0,
      steps: [
        SessionStep.workDistance(800, rep: 1),
        SessionStep.recoveryEqualTime(rep: 1),
        SessionStep.workDistance(800, rep: 2),
      ],
    );
    expect(
      IntervalsWorkoutText.fromWorkout(FitWorkout.fromSession(spec)!),
      isNull,
    );
  });

  test('time formats', () {
    final w = FitWorkout(
      name: 'T',
      steps: const [
        FitStep(
          name: 'A',
          duration: FitDuration.time,
          durationValue: 90000,
          intensity: FitIntensity.interval,
        ),
        FitStep(
          name: 'B',
          duration: FitDuration.time,
          durationValue: 3720000,
          intensity: FitIntensity.interval,
        ),
      ],
    );
    expect(IntervalsWorkoutText.fromWorkout(w), '- A 1m30s\n- B 1h2m');
  });
}
