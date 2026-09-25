import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Review P1-1: the observed 30 s max must be *sustained*. A spike before a
/// strap dropout must never become the user's max HR.
void main() {
  List<Sample> samples(int seconds, int? Function(int t) hrAt) => [
    for (var t = 0; t < seconds; t++)
      Sample(tMs: t * 1000, distM: t * 3.0, hr: hrAt(t)),
  ];

  RunFile runOf(List<Sample> s) => RunFile(
    id: '00000000-0000-4000-8000-0000000000ff',
    device: 'test',
    app: 'test',
    start: fixedNow,
    end: fixedNow.add(Duration(milliseconds: s.last.tMs)),
    tz: 'UTC',
    mode: RunMode.laps,
    units: Units.km,
    laps: const [],
    samples: s,
  );

  test('10 min at 150, one 215 spike then 40 s dropout → max stays 150', () {
    final t = Trace(
      samples(600, (t) {
        if (t == 300) return 215;
        if (t > 300 && t <= 340) return null;
        return 150;
      }),
    );
    // The spike sits at the end of otherwise valid windows and shifts their
    // mean by a couple of bpm; it never becomes the max itself.
    expect(t.highest30sHr(), lessThan(156));
    expect(t.highest30sHr(), greaterThan(150));
    // End to end through the engine and the guard: no new max, no prompt.
    final a = engine.analyze(runOf(t.samples), now: fixedNow);
    final s = ObservedMaxHrGuard.defaults.fold(
      ObservedMaxHrState.none,
      runObserved30s: a.laps!.observedMaxHrThisRun,
      typedMaxHr: null,
      age: null,
    );
    expect(s.observed, lessThan(156));
    expect(s.pending, isNull);
    expect(
      MetricsCalculator.maxHrFor(s.profile(age: 40)),
      180,
      reason: '220−40 still wins over a 150 observed',
    );
  });

  test('a 5 s burst at 215 before a 40 s dropout never reaches the burst '
      'value; a 26-reading window is skipped', () {
    final t = Trace(
      samples(600, (t) {
        if (t >= 300 && t < 305) return 215;
        if (t >= 305 && t < 345) return null;
        return 150;
      }),
    );
    // Best valid window is [277, 307): 23 readings at 150 + 5 at 215 = 28
    // readings (the two nulls after the burst are not held).
    expect(t.highest30sHr(), closeTo((23 * 150 + 5 * 215) / 28, 0.01));
    // A window that holds only the burst plus 26 readings before the
    // dropout is not valid, so nothing exceeds that figure.
    expect(t.highest30sHr(), lessThan(165));
    // 26 readings then a dropout: skipped entirely.
    final short = Trace(
      samples(600, (t) {
        if (t >= 300 && t < 326) return 210;
        if (t >= 326 && t < 400) return null;
        return 150;
      }),
    );
    // Windows ending inside the burst still count (2 at 150 + 26 at 210 is
    // 28 readings of real HR); windows that need the hold do not.
    expect(short.highest30sHr(), lessThan(210));
    expect(
      Trace(samples(600, (t) => t >= 300 && t < 326 ? 210 : null))
          .highest30sHr(),
      isNull,
      reason: '26 readings alone never make a window',
    );
  });

  test('30 s of genuinely sustained 200 bpm counts', () {
    final t = Trace(samples(600, (t) => t >= 300 && t < 330 ? 200 : 150));
    expect(t.highest30sHr(), closeTo(200, 0.001));
    // Two missing readings (a 3 s gap, 28 readings) still count.
    final holed = Trace(
      samples(600, (t) {
        if (t >= 300 && t < 330) return (t >= 310 && t < 312) ? null : 200;
        return 150;
      }),
    );
    expect(holed.highest30sHr(), closeTo(200, 0.001));
    // Three missing readings (a 4 s gap) break every window across them;
    // the best remaining window mixes 17 s at 200 with 13 s at 150.
    final broken = Trace(
      samples(600, (t) {
        if (t >= 300 && t < 330) return (t >= 310 && t < 313) ? null : 200;
        return 150;
      }),
    );
    expect(broken.highest30sHr(), lessThan(180));
    expect(broken.highest30sHr(), greaterThan(150));
  });

  test('sample spacing wider than 3 s (GPS-gap file) never yields a max', () {
    final sparse = [
      for (var t = 0; t < 600; t += 15)
        Sample(tMs: t * 1000, distM: t * 3.0, hr: 190),
    ];
    expect(Trace(sparse).highest30sHr(), isNull);
  });

  test('API boundary, age 60: a 10 s burst lifting a 30 s window to 172 '
      'is held pending; the same run with no age applies', () {
    // 10 min at 150 with 10 s at 216: the best 30 s window averages 172.
    final t = Trace(samples(600, (t) => t >= 300 && t < 310 ? 216 : 150));
    final a = engine.analyze(runOf(t.samples), now: fixedNow);
    final observed = a.laps!.observedMaxHrThisRun;
    expect(observed, closeTo(172, 0.5));
    // The call the app makes (MaxHr.foldObserved): age is required, so a
    // caller cannot silently fall back to the 190 reference.
    final s = ObservedMaxHrGuard.defaults.fold(
      ObservedMaxHrState.none,
      runObserved30s: observed,
      typedMaxHr: null,
      age: 60,
    );
    expect(s.observed, isNull);
    expect(s.pending, closeTo(172, 0.5));
    expect(MetricsCalculator.maxHrFor(s.profile(age: 60)), 160);
    final noAge = ObservedMaxHrGuard.defaults.fold(
      ObservedMaxHrState.none,
      runObserved30s: observed,
      typedMaxHr: null,
      age: null,
    );
    expect(noAge.observed, closeTo(172, 0.5), reason: '172 <= 190 + 10');
    expect(noAge.pending, isNull);
  });

  test('no HR at all → null', () {
    expect(Trace(samples(120, (_) => null)).highest30sHr(), isNull);
  });

  test('Laps avgHr/maxHr exclude paused spans (P3)', () {
    final run = RunFileCodec.decode(
      File('test/fixtures/contract/free_run_no_laps.json').readAsStringSync(),
    );
    expect(run.pauses, [const Span(240000, 255000)]);
    final t = Trace(run.samples);
    final a = engine.analyze(
      run,
      sidecar: RunSidecar(runId: run.id).withOverride(RunMode.laps),
      now: fixedNow,
    );
    final l = a.laps!;
    expect(
      l.avgHr,
      closeTo(t.meanHrExcluding(t.startMs, t.endMs, run.pauses)!, 1e-9),
    );
    expect(l.maxHr, t.peakHrExcluding(t.startMs, t.endMs + 1, run.pauses));
    // Cross-check the exclusion against a hand-built stitch of the two
    // unpaused halves.
    final before = t.meanHr(t.startMs, 240000)!;
    final after = t.meanHr(255000, t.endMs)!;
    final w1 = (240000 - t.startMs) / 1000;
    final w2 = (t.endMs - 255000) / 1000;
    expect(l.avgHr, closeTo((before * w1 + after * w2) / (w1 + w2), 1e-6));
  });
}
