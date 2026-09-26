import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 4 LB1 (plan §3.1): fastest 1 km, mile, 5K and 10K inside any run,
/// from-start splits for the Free-run ghost, gates and the GPS guard.
void main() {
  const finder = BestEffortFinder();

  /// One piece of a synthetic trace: [seconds] at [mps], or a pause (no
  /// samples, distance frozen), or a sample gap (no samples, distance keeps
  /// growing), or a GPS jump of [jumpM] in one sample.
  RunFile build(
    List<(int seconds, double mps)> pieces, {
    RunMode mode = RunMode.free,
    Map<int, int> pauseAfterPiece = const {},
    Map<int, int> gapAfterPiece = const {},
    Map<int, double> jumpAtSecond = const {},
    List<Lap> laps = const [],
    bool hr = false,
    SessionSpec? session,
    int noFixSeconds = 0,
  }) {
    final samples = <Sample>[];
    final pauses = <Span>[];
    var t = 0;
    var d = 0.0;
    var second = 0;
    void add({bool fix = true}) => samples.add(
      Sample(
        tMs: t,
        lat: fix ? -33.87 : null,
        lon: fix ? 151.21 : null,
        accM: fix ? 5 : null,
        distM: d,
        hr: hr ? 150 : null,
      ),
    );
    // No fix yet: the recorder writes samples but no distance.
    for (var i = 0; i < noFixSeconds; i++) {
      add(fix: false);
      t += 1000;
    }
    add();
    for (var i = 0; i < pieces.length; i++) {
      final (secs, mps) = pieces[i];
      for (var s = 0; s < secs; s++) {
        t += 1000;
        d += mps + (jumpAtSecond[second] ?? 0);
        second++;
        add();
      }
      final pause = pauseAfterPiece[i];
      if (pause != null) {
        pauses.add(Span(t + 1, t + pause * 1000));
        t += pause * 1000;
      }
      final gap = gapAfterPiece[i];
      if (gap != null) {
        t += gap * 1000;
        d += gap * mps;
        add();
      }
    }
    return RunFile(
      id: '00000000-0000-4000-8000-0000000000be',
      device: 'test',
      app: 'test',
      start: fixedNow,
      end: fixedNow.add(Duration(milliseconds: t)),
      tz: 'UTC',
      mode: mode,
      session: session,
      units: Units.km,
      laps: laps,
      pauses: pauses,
      samples: samples,
    );
  }

  RunBestEfforts find(RunFile run) =>
      finder.find(run, engine.analyze(run, now: fixedNow));

  BestEffort effort(RunBestEfforts r, BestEffortDistance d) => r.efforts[d]!;

  test('even 4 m/s for 12 km: every distance, exact times and splits', () {
    final r = find(build([(3000, 4.0)]));
    expect(effort(r, BestEffortDistance.km1).elapsedMs, 250000);
    expect(effort(r, BestEffortDistance.km1).splitsMs, [100000, 200000]);
    expect(effort(r, BestEffortDistance.mile).elapsedMs, 402336);
    expect(effort(r, BestEffortDistance.mile).splitsMs, [
      100000,
      200000,
      300000,
      400000,
    ]);
    final k5 = effort(r, BestEffortDistance.k5);
    expect(k5.elapsedMs, 1250000);
    expect(k5.splitsMs, [250000, 500000, 750000, 1000000]);
    expect(k5.startMs, 0, reason: 'ties keep the earliest window');
    expect(k5.startOffsetM, 0);
    expect(effort(r, BestEffortDistance.k10).elapsedMs, 2500000);
    expect(r.fromStartSplitsMs, [for (var k = 1; k <= 10; k++) k * 250000]);
  });

  test('window edges between samples are interpolated', () {
    // 3.3 m/s: 1000 m is crossed between samples, at 303.03 s.
    final r = find(build([(1000, 3.3)]));
    expect(effort(r, BestEffortDistance.km1).elapsedMs, 303030);
    expect(r.fromStartSplitsMs, [303030, 606061, 909091]);
  });

  test('the fastest window is found wherever it sits', () {
    // 1500 m easy, 1500 m fast, 1500 m easy: the 1 km best is inside the
    // fast block, 1500 m in.
    final r = find(build([(500, 3.0), (300, 5.0), (500, 3.0)]));
    final km = effort(r, BestEffortDistance.km1);
    expect(km.elapsedMs, 200000);
    expect(km.startOffsetM, closeTo(1500, 0.01));
    expect(km.startMs, 500000);
  });

  test('warm-up jog then a 5K (WARN-1): board window starts late, '
      'from-start splits start at the Start press', () {
    final r = find(build([(400, 2.5), (1250, 4.0), (400, 2.5)]));
    final k5 = effort(r, BestEffortDistance.k5);
    expect(k5.elapsedMs, 1250000);
    expect(k5.startOffsetM, closeTo(1000, 0.01));
    expect(k5.startMs, 400000);
    // The ghost races from Start, warm-up included.
    expect(r.fromStartSplitsMs, [
      400000,
      650000,
      900000,
      1150000,
      1400000,
      1650000,
      2050000,
    ]);
  });

  test('a pause breaks every window and ends the from-start splits', () {
    // 4 km, 60 s pause, 4 km: no 5K, no 10K.
    final r = find(build([(1000, 4.0), (1000, 4.0)], pauseAfterPiece: {0: 60}));
    expect(r.efforts.keys, {BestEffortDistance.km1, BestEffortDistance.mile});
    expect(r.fromStartSplitsMs, [250000, 500000, 750000, 1000000]);
  });

  test('a sample gap over 10 s breaks windows; 10 s does not', () {
    final broken = find(
      build([(1000, 4.0), (1000, 4.0)], gapAfterPiece: {0: 15}),
    );
    expect(broken.efforts.containsKey(BestEffortDistance.k5), isFalse);
    expect(broken.fromStartSplitsMs, hasLength(4));
    final ok = find(build([(1000, 4.0), (1000, 4.0)], gapAfterPiece: {0: 9}));
    expect(ok.efforts.containsKey(BestEffortDistance.k5), isTrue);
  });

  test('a 300 m GPS jump (WARN-7) is cut out: bests come from clean '
      'running either side, from-start splits stop before it', () {
    final r = find(build([(3000, 4.0)], jumpAtSecond: {600: 300}));
    expect(effort(r, BestEffortDistance.km1).elapsedMs, 250000);
    expect(effort(r, BestEffortDistance.k5).elapsedMs, 1250000);
    // Only ~9.4 km of clean running is left after the jump.
    expect(r.efforts.containsKey(BestEffortDistance.k10), isFalse);
    final k5 = effort(r, BestEffortDistance.k5);
    expect(
      k5.startMs >= 600000 || k5.endMs <= 600000,
      isTrue,
      reason: 'no window may contain the jump',
    );
    expect(r.fromStartSplitsMs, [250000, 500000]);
  });

  test('a one-sample spike (60 m in 1 s) is cut out, not a rejection', () {
    final r = find(build([(900, 4.0)], jumpAtSecond: {400: 60}));
    final km = effort(r, BestEffortDistance.km1);
    expect(km.elapsedMs, 250000);
    expect(km.startMs >= 401000 || km.endMs <= 400000, isTrue);
  });

  test('a jump smeared over 12 samples (9.5 m/s steps, under the step cap) '
      'is cut by the 100 m cap', () {
    final r = find(
      build(
        [(900, 4.0)],
        jumpAtSecond: {for (var i = 400; i < 412; i++) i: 5.5},
      ),
    );
    final km = effort(r, BestEffortDistance.km1);
    expect(km.elapsedMs, 250000);
    expect(km.startMs >= 412000 || km.endMs <= 400000, isTrue);
  });

  test('an easy run with one hard km keeps its 5K (review #31 P2): '
      'pace change is never a GPS guard', () {
    // 4 km at 6:00, one 4:00 km, 1.7 km at 6:00.
    final r = find(
      build([(1440, 1000 / 360), (240, 1000 / 240), (612, 1000 / 360)]),
    );
    final k5 = effort(r, BestEffortDistance.k5);
    expect(k5.elapsedMs, 1680000);
    expect(effort(r, BestEffortDistance.km1).elapsedMs, 240000);
  });

  test('known limit: drift under every cap reads as a real surge and '
      'stays in', () {
    // 1 km at 5.5 m/s (under every cap) inside a 3.3 m/s run.
    final r = find(build([(606, 3.3), (182, 5.5), (212, 3.3), (1300, 3.3)]));
    final k5 = effort(r, BestEffortDistance.k5);
    expect(k5.startMs <= 606000 && k5.endMs >= 788000, isTrue);
  });

  group('genuine finishing kicks must pass (review #31 P1-1)', () {
    test('mile at 52 s per 200 m, last 200 m in 41 s', () {
      const easy = (300, 2.5);
      final r = find(build([easy, (366, 200 / 52), (41, 200 / 41), easy]));
      expect(
        effort(r, BestEffortDistance.mile).elapsedMs,
        closeTo(407000, 3000),
      );
    });

    test('1 km at 48 s per 200 m, last 200 m in 38 s', () {
      const easy = (300, 2.5);
      final r = find(build([easy, (192, 200 / 48), (38, 200 / 38), easy]));
      expect(effort(r, BestEffortDistance.km1).elapsedMs, 230000);
    });

    test('5K of 5:00 kms with a 4:15 last km', () {
      final r = find(build([(1200, 1000 / 300), (255, 1000 / 255)]));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, 1455000);
    });
  });

  test('a genuinely fast km in a Laps run passes', () {
    final laps = [
      const Lap(
        index: 0,
        t0Ms: 0,
        t1Ms: 333000,
        d0M: 0,
        d1M: 999,
        kind: LapKind.manual,
      ),
      const Lap(
        index: 1,
        t0Ms: 333000,
        t1Ms: 583000,
        d0M: 999,
        d1M: 1999,
        kind: LapKind.manual,
      ),
      const Lap(
        index: 2,
        t0Ms: 583000,
        t1Ms: 916000,
        d0M: 1999,
        d1M: 2998,
        kind: LapKind.manual,
      ),
    ];
    final r = find(
      build(
        [(333, 3.0), (250, 4.0), (333, 3.0)],
        mode: RunMode.laps,
        laps: laps,
      ),
    );
    final km = effort(r, BestEffortDistance.km1);
    expect(km.elapsedMs, 250000);
    expect(km.startMs, 333000);
  });

  test('a hard last km inside one long lap is kept (laps come from the '
      'same GPS stream, so they are no guard; review #31 P1-2)', () {
    final laps = [
      const Lap(
        index: 0,
        t0Ms: 0,
        t1Ms: 556000,
        d0M: 0,
        d1M: 2000,
        kind: LapKind.manual,
      ),
    ];
    final r = find(
      build([(334, 3.0), (222, 4.5)], mode: RunMode.laps, laps: laps),
    );
    expect(effort(r, BestEffortDistance.km1).elapsedMs, closeTo(222000, 500));
  });

  test('parkrun: first fix 5 s after Start, auto-stop at 5.00 km', () {
    const parkrun = SessionSpec(
      templateId: SessionSpec.parkrunId,
      templateVersion: 1,
      name: 'parkrun',
      warmupSeconds: 0,
      cooldownSeconds: 0,
      autoStop: true,
      steps: [SessionStep.workDistance(5000, rep: 1)],
    );
    final run = build(
      [(1250, 4.0)],
      mode: RunMode.intervals,
      session: parkrun,
      noFixSeconds: 5,
      laps: const [
        Lap(
          index: 0,
          t0Ms: 0,
          t1Ms: 1255000,
          d0M: 0,
          d1M: 5000,
          kind: LapKind.auto,
        ),
      ],
    );
    final a = engine.analyze(run, now: fixedNow);
    expect(a.comparisonKey, ComparisonKey.parkrun);
    final r = finder.find(run, a);
    final k5 = effort(r, BestEffortDistance.k5);
    expect(k5.elapsedMs, 1250000);
    expect(k5.startMs, 5000);
    // The ghost counts from Start, the 5 s without a fix included.
    expect(r.fromStartSplitsMs, [255000, 505000, 755000, 1005000, 1255000]);
  });

  test('intervals: a window must sit inside one clean work rep', () {
    final f = fixture('four_by_four_manual_clean');
    final a = engine.analyze(f.run, now: fixedNow);
    final r = finder.find(f.run, a);
    expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
    expect(r.fromStartSplitsMs, isEmpty);
    final reps = a.intervals!.reps.where((x) => x.clean).toList();
    for (final e in r.efforts.values) {
      expect(
        reps.any((x) => e.startMs >= x.lap.t0Ms && e.endMs <= x.lap.t1Ms),
        isTrue,
        reason: '${e.distance.key} window must be inside a rep',
      );
    }
  });

  test('indoor and noisy runs have no best efforts', () {
    for (final name in ['treadmill_indoor', 'very_noisy_gps_no_verdict']) {
      final f = fixture(name);
      final r = finder.find(f.run, engine.analyze(f.run, now: fixedNow));
      expect(r.efforts, isEmpty, reason: name);
      expect(r.fromStartSplitsMs, isEmpty, reason: name);
    }
  });

  test('a Cooper test keeps its bests but races no distance board', () {
    final r = find(build([(720, 4.0)], mode: RunMode.cooper));
    expect(effort(r, BestEffortDistance.km1).elapsedMs, 250000);
    expect(r.fromStartSplitsMs, isEmpty);
  });

  test('average HR over the window', () {
    final r = find(build([(1300, 4.0)], hr: true));
    expect(effort(r, BestEffortDistance.k5).avgHr, closeTo(150, 0.01));
  });

  RunFile contract(String name) => RunFile.fromJson(
    jsonDecode(File('test/fixtures/contract/$name.json').readAsStringSync())
        as Map<String, Object?>,
  );

  test('Kotlin contract Cooper: bests match the stream to 1 m', () {
    final run = contract('cooper_12min');
    final r = find(run);
    final trace = Trace(run.samples);
    for (final d in [BestEffortDistance.km1, BestEffortDistance.mile]) {
      final e = effort(r, d);
      expect(
        trace.distAt(e.endMs) - trace.distAt(e.startMs),
        closeTo(d.metres, 1),
        reason: d.key,
      );
    }
  });

  test('Kotlin contract free run with a 15 s pause at 725 m: no stretch '
      'reaches 1 km, so no best and no from-start split', () {
    final r = find(contract('free_run_no_laps'));
    expect(r.efforts, isEmpty);
    expect(r.fromStartSplitsMs, isEmpty);
  });

  test('JSON round trip', () {
    final r = find(build([(1300, 4.0)], hr: true));
    final back = RunBestEfforts.fromJson(
      jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
    );
    expect(jsonEncode(back.toJson()), jsonEncode(r.toJson()));
    expect(back.efforts[BestEffortDistance.k5]!.elapsedMs, 1250000);
  });

  test('board keys use the reserved be: prefix', () {
    for (final d in BestEffortDistance.values) {
      expect(d.key.startsWith(BestEffortDistance.keyPrefix), isTrue);
      expect(BestEffortDistance.ofKey(d.key), d);
    }
  });

  test('perf: a 2 h run is well inside the 50 ms phone budget on the '
      'host', () {
    final run = build([
      for (var i = 0; i < 24; i++) (300, i.isEven ? 3.2 : 3.6),
    ]);
    final a = engine.analyze(run, now: fixedNow);
    finder.find(run, a); // warm up
    final sw = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      finder.find(run, a);
    }
    final perRun = sw.elapsedMilliseconds / 5;
    expect(perRun, lessThan(50), reason: '$perRun ms per 2 h run');
  });
}
