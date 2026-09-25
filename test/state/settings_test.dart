import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/settings.dart';

void main() {
  test('round-trips through JSON', () {
    final s = AppSettings(
      units: Units.mi,
      reps: 5,
      recoverySeconds: 165,
      lastMode: RecordMode.laps,
      cues: false,
      volumeKeyLap: true,
      typedMaxHr: 185,
      birthYear: 1986,
      observedMaxHr: 192,
      observedMaxHrAt: DateTime.utc(2026, 9, 3, 6),
      pendingObservedMaxHr: 205,
      onboardingDone: true,
      strap: const SavedStrap(address: 'AA:BB', name: 'WHOOP 1234'),
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.units, Units.mi);
    expect(back.reps, 5);
    expect(back.recoverySeconds, 165);
    expect(back.lastMode, RecordMode.laps);
    expect(back.cues, isFalse);
    expect(back.volumeKeyLap, isTrue);
    expect(back.typedMaxHr, 185);
    expect(back.birthYear, 1986);
    expect(back.observedMaxHr, 192);
    expect(back.observedMaxHrAt, DateTime.utc(2026, 9, 3, 6));
    expect(back.pendingObservedMaxHr, 205);
    expect(back.onboardingDone, isTrue);
    expect(back.strap?.address, 'AA:BB');
    expect(back.strap?.isWhoop, isTrue);
    expect(back.strap?.label, 'Whoop');
  });

  test('Phase 1 maxHr migrates: 190 → not entered, other → typed (N1)', () {
    expect(AppSettings.fromJson({'maxHr': 190}).typedMaxHr, isNull);
    expect(AppSettings.fromJson({'maxHr': 185}).typedMaxHr, 185);
    expect(AppSettings.fromJson({'maxHr': 40}).typedMaxHr, isNull);
    expect(
      AppSettings.fromJson({'typedMaxHr': 178, 'maxHr': 185}).typedMaxHr,
      178,
    );
  });

  test('malformed values fall back to defaults and clamp', () {
    final s = AppSettings.fromJson({
      'units': 'furlongs',
      'reps': 9,
      'recoverySeconds': 37,
      'cues': 'yes',
      'volumeKeyLap': 'maybe',
      'observedMaxHrAt': 'not a date',
      'strap': {'name': 'no address'},
    });
    expect(s.units, Units.km);
    expect(s.reps, PresetRules.maxReps);
    expect(s.recoverySeconds, PresetRules.minRecovery);
    expect(s.cues, isTrue);
    expect(s.volumeKeyLap, isNull);
    expect(s.observedMaxHrAt, isNull);
    expect(s.strap, isNull);
  });

  test('volume-key lap default follows the run type (plan §18.2)', () {
    const d = AppSettings();
    expect(d.volumeKeyLapFor(RecordMode.laps), isTrue);
    expect(d.volumeKeyLapFor(RecordMode.intervals), isFalse);
    expect(d.volumeKeyLapFor(RecordMode.free), isFalse);
    const off = AppSettings(volumeKeyLap: false);
    expect(off.volumeKeyLapFor(RecordMode.laps), isFalse);
    const on = AppSettings(volumeKeyLap: true);
    expect(
      on.volumeKeyLapFor(RecordMode.free),
      isFalse,
      reason: 'never in Free',
    );
  });

  test('preset rules: work locked, recovery snaps to 15 s', () {
    expect(PresetRules.clampRecovery(172), 165);
    expect(PresetRules.clampRecovery(173), 180);
    expect(PresetRules.clampRecovery(600), 300);
    expect(PresetRules.clampReps(2), 3);
    // The saved 4x4 expands through the engine catalogue: work stays 4:00.
    final spec = const AppSettings(reps: 5, recoverySeconds: 195).spec;
    expect(spec.templateId, 'norwegian-4x4');
    expect(spec.repCount, 5);
    expect(spec.timedSeconds(StepKind.work, 3), 240);
    expect(spec.timedSeconds(StepKind.recovery, 4), 195);
    expect(spec.timedSeconds(StepKind.recovery, 5), isNull, reason: 'N − 1');
  });

  test('controller saves on update', () async {
    final store = MemorySettingsStore();
    final c = SettingsController(store);
    await c.update((s) => s.copyWith(reps: 6));
    expect(store.settings.reps, 6);
    expect(store.saves, 1);
    await c.update((s) => s.copyWith(clearStrap: true));
    expect(c.settings.strap, isNull);
  });
}
