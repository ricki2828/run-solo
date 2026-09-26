import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The spoken nudges reach the run file (`nudges_fired`, written by the
/// Kotlin Finaliser from the journal's `cue_fired` lines) and from there
/// `RunDerived.nudgesFired`, which CR1 blocks on the next run. Nothing
/// filled it before.
void main() {
  final run = fixture('preset_4x4_auto_standard').run;
  const fired = [FiredNudge('fast_start', 1), FiredNudge('hr_drift', 4)];

  test('round trip; absent when none, so older files are unchanged', () {
    expect(run.toJson().containsKey('nudges_fired'), isFalse);
    final withNudges = run.copyWith(nudgesFired: fired);
    final json = jsonDecode(jsonEncode(withNudges.toJson())) as Map;
    expect(json['nudges_fired'], [
      ['fast_start', 1],
      ['hr_drift', 4],
    ]);
    final back = RunFile.fromJson(json.cast<String, Object?>());
    expect(
      [for (final n in back.nudgesFired) n.toJson()],
      [for (final n in fired) n.toJson()],
    );
    expect(RunFile.fromJson(run.toJson()).nudgesFired, isEmpty);
  });

  test('a malformed list is a format error, not a crash', () {
    expect(
      () => RunFile.fromJson(run.toJson()..['nudges_fired'] = 'x'),
      throwsA(isA<RunFileFormatException>()),
    );
    expect(
      () => RunFile.fromJson(
        run.toJson()
          ..['nudges_fired'] = [
            [1, 'a'],
          ],
      ),
      throwsA(isA<RunFileFormatException>()),
    );
  });

  test('derived data carries them', () {
    final r = run.copyWith(nudgesFired: fired);
    final d = RunDerived.of(r, engine.analyze(r, now: fixedNow));
    expect(
      [for (final n in d.nudgesFired) n.toJson()],
      [for (final n in fired) n.toJson()],
    );
    expect(
      RunDerived.of(run, engine.analyze(run, now: fixedNow)).nudgesFired,
      isEmpty,
    );
  });
}
