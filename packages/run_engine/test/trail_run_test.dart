import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// [base] with a synthetic altitude: [alt] metres at each sample, given its
/// index and distance. Distance is stretched so the run covers [km].
RunFile withAltitude(
  RunFile base,
  double km,
  double? Function(int i, double distM) alt, {
  RunMode mode = RunMode.free,
}) {
  final n = base.samples.length;
  final scale = km * 1000 / base.samples.last.distM;
  return base.copyWith(
    mode: mode,
    samples: [
      for (final (i, s) in base.samples.indexed)
        s.copyWith(distM: s.distM * scale, altM: alt(i, s.distM * scale)),
    ].sublist(0, n),
  );
}

void main() {
  final base = fixture('easy_free_run').run;

  group('mode', () {
    test('trail round-trips through the run file', () {
      final run = base.copyWith(mode: RunMode.trail);
      final back = RunFileCodec.decode(RunFileCodec.encode(run));
      expect(back.mode, RunMode.trail);
      expect(RunFileCodec.encode(back), RunFileCodec.encode(run));
    });

    test('trail takes no session and no laps', () {
      expect(RunMode.trail.lapCapable, isFalse);
      final json = base.copyWith(mode: RunMode.trail).toJson()
        ..['session'] = SessionSpec.norwegian4x4().toJson();
      expect(
        () => RunFile.fromJson(json),
        throwsA(isA<RunFileFormatException>()),
      );
    });

    test('an override to trail is kept in the sidecar', () {
      final s = RunSidecar(runId: base.id).withOverride(RunMode.trail);
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.runTypeOverride, RunMode.trail);
    });
  });

  group('analysis', () {
    test('a trail run has a summary and no verdict, key or boards', () {
      final run = base.copyWith(mode: RunMode.trail);
      final a = engine.analyze(run, now: fixedNow);
      expect(a.mode, RunMode.trail);
      expect(a.verdict, isNull);
      expect(a.comparisonKey, isNull);
      expect(a.freeRun, isNotNull);
    });

    test('re-tagging a free run as trail recomputes it as trail', () {
      final free = engine.analyze(base, now: fixedNow);
      final tagged = engine.analyze(
        base,
        sidecar: RunSidecar(runId: base.id).withOverride(RunMode.trail),
        now: fixedNow,
      );
      expect(free.mode, RunMode.free);
      expect(tagged.mode, RunMode.trail);
      expect(tagged.freeRun, isNotNull);
      expect(tagged.verdict, isNull);
    });
  });

  group('auto-suggest rule', () {
    // ~5 km: a climb of 8 m per 100 m of run time for the first half.
    double hills(int i, double d) =>
        30 * (1 - math.cos(d / 5000 * 2 * math.pi * 3));

    test('real climbing suggests trail', () {
      final run = withAltitude(base, 5, (i, d) => hills(i, d));
      expect(TrailSuggestion.gainPerKm(run)!, greaterThan(25));
      expect(TrailSuggestion.suggests(run), isTrue);
    });

    test('a flat run does not', () {
      final run = withAltitude(base, 5, (i, d) => 12);
      expect(TrailSuggestion.gainM(run), 0);
      expect(TrailSuggestion.suggests(run), isFalse);
    });

    test('GPS altitude noise on a flat run does not', () {
      final rng = math.Random(7);
      final run = withAltitude(
        base,
        5,
        (i, d) => 20 + (rng.nextDouble() - 0.5) * 5, // +-2.5 m of wobble
      );
      expect(TrailSuggestion.suggests(run), isFalse);
    });

    test('a single altitude spike is filtered out', () {
      final run = withAltitude(base, 5, (i, d) => i == 600 ? 80 : 20);
      expect(TrailSuggestion.gainM(run), 0);
    });

    test('stored barometer climb wins over the raw GPS altitude', () {
      // GPS altitude says flat, the stored (barometer) elevation says hilly.
      final flatGps = withAltitude(base, 5, (i, d) => 12);
      final hilly = withAltitude(base, 5, (i, d) => hills(i, d));
      final baro = hilly.copyWith(
        elevSrc: ElevSource.baro,
        samples: [for (final s in hilly.samples) s.copyWith(elevM: s.altM)],
      );
      expect(RunElevation.of(baro), isNotNull);
      expect(TrailSuggestion.gainM(baro), RunElevation.of(baro)!.ascentM);
      expect(TrailSuggestion.suggests(baro), isTrue);
      expect(TrailSuggestion.suggests(flatGps), isFalse);
    });

    test('too short, or without altitude, is not judged', () {
      final short = withAltitude(base, 1, (i, d) => hills(i, d * 5));
      expect(TrailSuggestion.gainPerKm(short), isNull);
      expect(TrailSuggestion.suggests(short), isFalse);
      final none = withAltitude(base, 5, (i, d) => null);
      expect(TrailSuggestion.gainM(none), isNull);
      expect(TrailSuggestion.suggests(none), isFalse);
    });

    test('only a Free run is offered it', () {
      for (final mode in [
        RunMode.laps,
        RunMode.intervals,
        RunMode.cooper,
        RunMode.trail,
      ]) {
        final run = withAltitude(
          base,
          5,
          (i, d) => hills(i, d),
          mode: RunMode.free,
        );
        expect(
          TrailSuggestion.suggests(run, mode: mode),
          isFalse,
          reason: '$mode',
        );
      }
      // The override wins over the file's own mode.
      final laps = withAltitude(
        base,
        5,
        (i, d) => hills(i, d),
        mode: RunMode.laps,
      );
      expect(TrailSuggestion.suggests(laps, mode: RunMode.free), isTrue);
    });
  });
}
