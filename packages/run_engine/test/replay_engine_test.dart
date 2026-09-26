import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 3 I5, engine side of the per-kind replay fixtures (rs-native-opus
/// records them in core-jvm; the emulator job checks the device path against
/// the same files). Pins what a runner reads: the verdict subline word for
/// word, the noise floor per key, warm-up/cool-down split, and what a second
/// identical session gets (inside the floor, never faster or slower).
void main() {
  Map<String, Object?> raw(String name) =>
      jsonDecode(File('test/fixtures/contract/$name.json').readAsStringSync())
          as Map<String, Object?>;
  RunFile load(String name) => RunFile.fromJson(raw(name));

  /// The same recording a week later under another id.
  RunFile weekLater(String name, int n) {
    final j = raw(name);
    DateTime plus(Object? t) =>
        DateTime.parse(t! as String).add(const Duration(days: 7));
    return RunFile.fromJson({
      ...j,
      'id': '00000000-0000-4000-8000-${(500 + n).toString().padLeft(12, '0')}',
      'start': plus(j['start']).toIso8601String(),
      'end': plus(j['end']).toIso8601String(),
    });
  }

  // (fixture, subline, floor s/km)
  const structured = {
    '4x4': (
      '3:58/km work pace. Reps within 0 s of each other. Recovery 8:21. '
          'Next 4x4 gets a verdict.',
      10.0,
    ),
    '400s': (
      '400 m in 1:40 average. Reps within 0 s of each other. Recovery 8:19. '
          'Next 4 × 400 m session gets a verdict.',
      10.0,
    ),
    '30_30s': (
      '3:42/km work pace. Reps within 0 s of each other. Recovery 8:21. '
          'Next 30/30s session gets a verdict.',
      12.649,
    ),
    'yasso_800s': (
      '800 m in 3:20 average. Reps within 0 s of each other. Recovery 8:20. '
          'Next Yasso 800s session gets a verdict.',
      10.0,
    ),
    '1km_repeats': (
      '1000 m in 4:10 average. Reps within 0 s of each other. Recovery 8:19. '
          'Next 1 km repeats session gets a verdict.',
      10.0,
    ),
  };

  for (final MapEntry(key: kind, value: (subline, floor))
      in structured.entries) {
    group('replay_$kind', () {
      final run = load('replay_$kind');
      final a = engine.analyze(run, now: fixedNow);

      test('warm-up and cool-down are the manual laps around the steps', () {
        expect(a.detection!.warmup, hasLength(1));
        expect(a.detection!.cooldown, hasLength(1));
        expect(a.detection!.warmup.single.t0Ms, 0);
        expect(a.intervals!.cleanRepCount, a.intervals!.reps.length);
        expect(a.noisy, isFalse);
      });

      test('baseline subline word for word; floor for the key', () {
        expect(a.verdict!.stage, VerdictStage.baseline);
        expect(a.verdict!.subline, subline);
        expect(a.verdict!.floorSecPerKm, closeTo(floor, 0.001));
      });

      test('the same session again: vs last, inside the floor', () {
        final again = engine.analyze(
          weekLater('replay_$kind', kind.length),
          priors: [a.asPrior(run.start)!],
          now: fixedNow,
        );
        expect(again.verdict!.stage, VerdictStage.vsLast);
        expect(
          again.verdict!.headline,
          isNot(anyOf(VerdictHeadline.faster, VerdictHeadline.slower)),
        );
      });
    });
  }

  group('distance laps read their step distance (lap interpolation)', () {
    for (final (kind, metres) in [
      ('400s', 400),
      ('yasso_800s', 800),
      ('1km_repeats', 1000),
    ]) {
      test('$kind: every work lap $metres m to 0.01 m', () {
        final a = engine.analyze(load('replay_$kind'), now: fixedNow);
        for (final r in a.detection!.reps) {
          expect(r.work.distanceM, closeTo(metres, 0.01));
        }
      });
    }
  });

  group('replay_parkrun', () {
    final run = load('replay_parkrun');
    final a = engine.analyze(run, now: fixedNow);

    test('warm-up then the 5 km, no cool-down (auto-stop)', () {
      expect(a.detection!.warmup, hasLength(1));
      expect(a.detection!.cooldown, isEmpty);
      expect(a.detection!.reps.single.work.distanceM, closeTo(5000, 5));
      expect(run.laps.last.t1Ms, run.elapsedMs, reason: 'stopped at 5 km');
    });

    test('finish time subline, GPS floor 3 s/km', () {
      // The event name comes from EventNames (K1); only the shape is pinned.
      expect(
        a.verdict!.subline,
        matches(RegExp(r'^Finish 20:51\. Next .+ gets a verdict\.$')),
      );
      expect(a.verdict!.floorSecPerKm, 3);
    });
  });

  group('replay_cooper / replay_fartlek (no verdict, summary only)', () {
    test('Cooper: warm-up, one 12:00 lap from START REPS, cool-down', () {
      final run = load('replay_cooper');
      final work = run.laps.where((l) => l.kind != LapKind.pause).toList();
      expect(work, hasLength(3));
      expect(work[1].t0Ms, 60000);
      expect(work[1].durationMs, 720000);
      final a = engine.analyze(run, now: fixedNow);
      expect(a.verdict, isNull);
      expect(a.intervals, isNull);
    });

    test('fartlek: the laps are the laps, no verdict', () {
      final run = load('replay_fartlek');
      final a = engine.analyze(run, now: fixedNow);
      expect(a.verdict, isNull);
      expect(a.laps!.laps, hasLength(run.laps.length));
      expect(a.fartlek, isNotNull);
    });
  });
}
