import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import '../tool/companion_facts_lib.dart';
import 'helpers.dart';

RunBundle _bundle(String fixtureName) {
  final r = fixture(fixtureName).run;
  return RunBundle(
    run: r,
    sidecar: RunSidecar(
      runId: r.id,
      zoneId: 'Asia/Singapore',
      utcOffsetMin: 480,
    ),
  );
}

void main() {
  group('coachIntervalFacts', () {
    test('names the session and gives work pace, reps, spread, recovery', () {
      final m = coachIntervalFacts(
        sessionName: 'Norwegian 4x4',
        workPaceSecPerKm: 257.04,
        repsDone: 4,
        cleanRepPacesSecPerKm: [254.0, 260.3, 257.1, 258.0],
        recoveryPaceSecPerKm: 461.44,
      );
      expect(m, {
        'session_name': 'Norwegian 4x4',
        'work_pace_s_per_km': 257.0,
        'reps_done': 4,
        'rep_spread_s': 6.3,
        'recovery_pace_s_per_km': 461.4,
      });
    });

    test('no work pace sends nothing; a long name is cut to 40', () {
      expect(
        coachIntervalFacts(
          sessionName: 'x',
          workPaceSecPerKm: null,
          repsDone: 4,
          cleanRepPacesSecPerKm: const [],
          recoveryPaceSecPerKm: null,
        ),
        isEmpty,
      );
      final m = coachIntervalFacts(
        sessionName: 'n' * 60,
        workPaceSecPerKm: 300,
        repsDone: null,
        cleanRepPacesSecPerKm: const [300],
        recoveryPaceSecPerKm: null,
      );
      expect((m['session_name']! as String).length, 40);
      expect(m.keys, ['session_name', 'work_pace_s_per_km']);
    });
  });

  test('a 4x4 export carries the interval fields, a laps export none', () {
    final p = companionFactsFor([_bundle('four_by_four_manual_clean_hr')]);
    final facts = p.single!;
    expect(facts['session_name'], SessionCatalogue.norwegian4x4.name);
    expect(facts['work_pace_s_per_km'], isA<double>());
    expect(facts['reps_done'], 4);
    expect(facts['rep_spread_s'], isA<double>());
    final laps = companionFactsFor([_bundle('laps_run_manual_clean_hr')]);
    expect(laps.single!.containsKey('session_name'), isFalse);
    expect(laps.single!.containsKey('work_pace_s_per_km'), isFalse);
  });
}
