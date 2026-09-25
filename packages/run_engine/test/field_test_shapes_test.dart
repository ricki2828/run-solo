import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Founder field test (25-Sep-2026): a real 4x4 showed NO VERDICT. The
/// recorder had run a 4th recovery before stop. These pin that the engine
/// tolerates every ending shape and that a first-ever 4x4 is BASELINE SET.
void main() {
  for (final name in [
    'preset_4x4_auto_standard', // warm-up, 4 × (work, recovery), cool-down
    'preset_4x4_manual_standard',
    'preset_4x4_ends_after_final_recovery', // … no cool-down
    'preset_4x4_manual_ends_after_final_recovery',
    'preset_5x4_recovery_2_00_missing_final_recovery', // … no last recovery
  ]) {
    test('$name: complete 4x4, first-ever run is BASELINE SET', () {
      final f = fixture(name);
      final a = engine.analyze(f.run, profile: profile, now: fixedNow);
      expect(
        a.lapsInconsistent,
        isFalse,
        reason: a.detection!.inconsistencyDetail,
      );
      expect(a.indoor, isFalse);
      expect(a.noisy, isFalse);
      expect(a.intervals!.reps.length, f.run.preset!.reps);
      expect(a.intervals!.allRepsClean, isTrue);
      expect(a.verdict!.stage, VerdictStage.baseline);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(a.verdict!.headline.text, 'BASELINE SET');
      expect(a.verdict!.subline, contains('Next 4x4 gets a verdict.'));
      expect(a.eligibleAsPrior, isTrue);
    });
  }

  test('4 recoveries then stop: the 4th recovery is a recovery, not a '
      'cool-down, and the last rep still has its recovery pace', () {
    final a = engine.analyze(
      fixture('preset_4x4_ends_after_final_recovery').run,
      profile: profile,
      now: fixedNow,
    );
    final m = a.intervals!;
    expect(m.recoveries.length, 4);
    expect(m.recoveries.last.paceSecPerKm, isNotNull);
    expect(m.recoveryPaceSecPerKm, isNotNull);
    expect(a.detection!.cooldown, isEmpty);
  });
}
