import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';

void main() {
  test('round-trips through JSON', () {
    const s = AppSettings(
      units: Units.mi,
      reps: 5,
      recoverySeconds: 165,
      lastMode: RecordMode.free,
      cues: false,
      volumeKeyLap: true,
      maxHr: 185,
      onboardingDone: true,
      strap: SavedStrap(address: 'AA:BB', name: 'WHOOP 1234'),
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.units, Units.mi);
    expect(back.reps, 5);
    expect(back.recoverySeconds, 165);
    expect(back.lastMode, RecordMode.free);
    expect(back.cues, isFalse);
    expect(back.volumeKeyLap, isTrue);
    expect(back.maxHr, 185);
    expect(back.onboardingDone, isTrue);
    expect(back.strap?.address, 'AA:BB');
    expect(back.strap?.isWhoop, isTrue);
    expect(back.strap?.label, 'Whoop');
  });

  test('malformed values fall back to defaults and clamp', () {
    final s = AppSettings.fromJson({
      'units': 'furlongs',
      'reps': 9,
      'recoverySeconds': 37,
      'cues': 'yes',
      'strap': {'name': 'no address'},
    });
    expect(s.units, Units.km);
    expect(s.reps, PresetRules.maxReps);
    expect(s.recoverySeconds, PresetRules.minRecovery);
    expect(s.cues, isTrue);
    expect(s.strap, isNull);
  });

  test('preset rules: work locked, recovery snaps to 15 s', () {
    expect(PresetRules.clampRecovery(172), 165);
    expect(PresetRules.clampRecovery(173), 180);
    expect(PresetRules.clampRecovery(600), 300);
    expect(PresetRules.clampReps(2), 3);
    final p = PresetRules.normalise(
      Preset(reps: 4, workSeconds: 300, recoverySeconds: 200),
    );
    expect(p.workSeconds, 240);
    expect(p.recoverySeconds, 195);
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
