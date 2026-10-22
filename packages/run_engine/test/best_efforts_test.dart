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
    expect(r.fromStartSplitsMs, [for (var k = 1; k <= 12; k++) k * 250000]);
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

  test('a sample gap over a minute breaks windows; 10 s does not', () {
    final broken = find(
      build([(1000, 4.0), (1000, 4.0)], gapAfterPiece: {0: 90}),
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

  test('intervals: short windows stay inside one clean work rep', () {
    final f = fixture('four_by_four_manual_clean');
    final a = engine.analyze(f.run, now: fixedNow);
    final r = finder.find(f.run, a);
    expect(r.efforts.containsKey(BestEffortDistance.k5), isTrue);
    expect(r.fromStartSplitsMs, isEmpty);
    final reps = a.intervals!.reps.where((x) => x.clean).toList();
    for (final e in r.efforts.values.where(
      (e) =>
          e.distance == BestEffortDistance.km1 ||
          e.distance == BestEffortDistance.mile,
    )) {
      expect(
        reps.any((x) => e.startMs >= x.lap.t0Ms && e.endMs <= x.lap.t1Ms),
        isTrue,
        reason: '${e.distance.key} window must be inside a rep',
      );
    }
  });

  test('INT without reps still earns a clean continuous 5K, not SPEED', () {
    final run = build([(2760, 8.01 * 1000 / 2760)], mode: RunMode.intervals);
    final a = engine.analyze(run, now: fixedNow);
    final r = finder.find(run, a);
    expect(r.efforts[BestEffortDistance.k5], isNotNull);
    expect(r.efforts[BestEffortDistance.km1], isNull);
  });

  test('INT with a pause before 5K cannot stitch two stretches into MID', () {
    final run = build(
      [(720, 4.0), (720, 4.0)],
      mode: RunMode.intervals,
      pauseAfterPiece: {0: 60},
    );
    final r = find(run);
    expect(r.efforts[BestEffortDistance.k5], isNull);
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

  group('a 5K goal run that reaches 5K counts despite a short break', () {
    final goal5k = SessionSpec.goalDistance(5000, '5K');
    // 800 s at 4 m/s (3.2 km), a break, then 453 s more: 5.012 km.
    RunFile goalRun({
      int? pause,
      int? gap,
      Map<int, double> jump = const {},
      SessionSpec? session,
      RunMode mode = RunMode.intervals,
    }) => build(
      [(800, 4.0), (453, 4.0)],
      mode: mode,
      session: session ?? goal5k,
      pauseAfterPiece: {0: ?pause},
      gapAfterPiece: {0: ?gap},
      jumpAtSecond: jump,
    );

    test('a 30 s pause: counted, at moving time (the pause comes out)', () {
      final r = find(goalRun(pause: 30));
      final k5 = effort(r, BestEffortDistance.k5);
      expect(
        k5.elapsedMs,
        closeTo(1250000, 5),
        reason: '5000 m at 4 m/s, no pause time',
      );
      expect(r.miss, isNull);
    });

    test('a long GPS drop with distance accrued is never bridged', () {
      // 90 s of silence in which the position moved on: not a measured
      // effort, so the clean-stretch rule applies.
      final r = find(goalRun(gap: 90));
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.gpsDropped);
    });

    test('a short GPS drop is bridged like it is in any other run', () {
      final r = find(goalRun(gap: 15));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      expect(r.miss, isNull);
    });

    test('a pause and a GPS dropout combine their bridges', () {
      // 30 s pause after 800 s, then 453 s with a 40 s dropout in it (no-fix
      // samples, distance frozen, then the chord).
      final base = goalRun(pause: 30);
      final dropAt = 900000, dropMs = 40000;
      final samples = <Sample>[];
      for (final s in base.samples) {
        if (s.tMs > dropAt && s.tMs < dropAt + dropMs) {
          samples.add(Sample(tMs: s.tMs, distM: s.distM - 0));
          continue;
        }
        samples.add(s);
      }
      // Freeze distance in the hole, then it is already the chord at its end.
      final frozen = samples.firstWhere((s) => s.tMs == dropAt).distM;
      for (var i = 0; i < samples.length; i++) {
        final s = samples[i];
        if (s.tMs > dropAt && s.tMs < dropAt + dropMs) {
          samples[i] = Sample(tMs: s.tMs, distM: frozen);
        }
      }
      final run = RunFile(
        id: base.id,
        device: base.device,
        app: base.app,
        start: base.start,
        end: base.end,
        tz: base.tz,
        mode: base.mode,
        session: goal5k,
        units: base.units,
        laps: base.laps,
        pauses: base.pauses,
        samples: samples,
      );
      final r = find(run);
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      expect(r.miss, isNull);
    });

    test('a recording gap (kill and resume) is never bridged', () {
      final run = goalRun();
      final stopped = RunFile(
        id: run.id,
        device: run.device,
        app: run.app,
        start: run.start,
        end: run.end,
        tz: run.tz,
        mode: run.mode,
        session: goal5k,
        units: run.units,
        laps: run.laps,
        gaps: [Span(799001, 801000)],
        samples: run.samples,
      );
      final r = find(stopped);
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.recordingStopped);
    });

    test('a long pause is not bridged: no fake-fast effort', () {
      final r = find(goalRun(pause: 120));
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.pausedLong);
      expect(r.miss!.reason, 'paused for over a minute');
      expect(r.miss!.goalM, 5000);
    });

    test('pauses add up against the limit', () {
      final r = find(
        build(
          [(500, 4.0), (500, 4.0), (253, 4.0)],
          mode: RunMode.intervals,
          session: goal5k,
          pauseAfterPiece: {0: 35, 1: 35},
        ),
      );
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.pausedLong);
    });

    test('pauses after the goal distance do not count against it', () {
      // 20 s pause at 2 km, 5 km reached at 1250 s of running, then a walk
      // with 90 s of cool-down pauses: the 5K still counts.
      final r = find(
        build(
          [(500, 4.0), (750, 4.0), (100, 1.0), (100, 1.0)],
          mode: RunMode.intervals,
          session: goal5k,
          pauseAfterPiece: {0: 20, 1: 45, 2: 45},
        ),
      );
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      expect(r.miss, isNull);
    });

    test('the bridged window sits on the run clock for grade and HR', () {
      final r = find(goalRun(pause: 30));
      final k5 = effort(r, BestEffortDistance.k5);
      expect(k5.startMs, 0);
      expect(k5.pausedMs, closeTo(30000, 5));
      expect(k5.endMs, closeTo(1280000, 5), reason: 'moving time + pause');
      final back = BestEffort.fromJson(BestEffortDistance.k5, k5.toJson());
      expect(back.endMs, k5.endMs);
      expect(back.pausedMs, k5.pausedMs);
      // A clean effort carries no paused time.
      final clean = find(build([(1300, 4.0)]));
      expect(effort(clean, BestEffortDistance.k5).pausedMs, 0);
    });

    test('a GPS jump is never bridged', () {
      final r = find(goalRun(pause: 20, jump: {300: 300}));
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.gpsJump);
    });

    test('a run short of the goal distance has nothing to bridge', () {
      final r = find(
        build(
          [(600, 4.0), (400, 4.0)],
          mode: RunMode.intervals,
          session: goal5k,
          pauseAfterPiece: {0: 30},
        ),
      );
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss, isNull, reason: 'under 5 km: nothing to explain');
    });

    test('a 10K goal run bridges its 10K, not a 5K goal bridge', () {
      final r = find(
        build(
          [(1000, 4.0), (1000, 4.0), (503, 4.0)],
          mode: RunMode.intervals,
          session: SessionSpec.goalDistance(10000, '10K'),
          pauseAfterPiece: {0: 30},
        ),
      );
      expect(effort(r, BestEffortDistance.k10).elapsedMs, closeTo(2500000, 5));
    });

    test('a Free run keeps the clean-stretch rule: no bridge', () {
      final r = find(build([(800, 4.0), (453, 4.0)], pauseAfterPiece: {0: 30}));
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.reason, 'paused at 3.2 km');
      expect(r.miss!.goalM, isNull);
    });
  });

  group('why a run of 5 km or more has no 5K', () {
    RunFile free({int? pause, int? gap, Map<int, double> jump = const {}}) =>
        build(
          [(800, 4.0), (453, 4.0)],
          pauseAfterPiece: {0: ?pause},
          gapAfterPiece: {0: ?gap},
          jumpAtSecond: jump,
        );

    test('pause', () {
      expect(find(free(pause: 30)).miss!.reason, 'paused at 3.2 km');
    });

    test('GPS dropped', () {
      final m = find(free(gap: 90)).miss!;
      expect(m.kind, EffortMissKind.gpsDropped);
      expect(m.reason, 'GPS dropped for 90 s at 3.2 km');
    });

    test('GPS jump', () {
      final m = find(free(jump: {300: 300})).miss!;
      expect(m.kind, EffortMissKind.gpsJump);
      expect(m.reason, startsWith('GPS jumped at '));
    });

    test('recording stopped (a declared gap)', () {
      final run = free();
      final stopped = RunFile(
        id: run.id,
        device: run.device,
        app: run.app,
        start: run.start,
        end: run.end,
        tz: run.tz,
        mode: run.mode,
        units: run.units,
        laps: run.laps,
        gaps: [Span(799001, 801000)],
        samples: run.samples,
      );
      expect(find(stopped).miss!.reason, 'recording stopped at 3.2 km');
    });

    test('a clean run, or one under 5 km, has no miss', () {
      expect(find(free()).miss, isNull);
      expect(find(build([(600, 4.0)], pauseAfterPiece: {0: 30})).miss, isNull);
    });

    test('miss round-trips through the index JSON', () {
      final r = find(free(pause: 30));
      final back = RunBestEfforts.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
      );
      expect(back.miss!.reason, 'paused at 3.2 km');
      expect(RunBestEfforts.none.toJson().containsKey('miss'), isFalse);
    });
  });

  group('short GPS dropouts are bridged for 5K and 10K', () {
    const mps = 4.0;

    /// A run at a steady 4 m/s sampled at 1 Hz for [seconds]. Each dropout
    /// is (start second, length in seconds): the recorder keeps writing
    /// no-fix samples with the distance frozen, then the first fix back
    /// adds [chord] of the ground really covered (1 = all of it; a chord
    /// across a bend is shorter than the path). [extraJumpM] is added on top
    /// at the first fix back (a GPS leap).
    RunFile dropRun(
      int seconds,
      List<(int, int)> dropouts, {
      double chord = 1,
      double extraJumpM = 0,
      RunMode mode = RunMode.free,
      bool lowAccuracy = false,
    }) {
      final samples = <Sample>[];
      var recorded = 0.0;
      for (var t = 0; t <= seconds; t++) {
        final drop = dropouts.where((d) => t > d.$1 && t <= d.$1 + d.$2);
        if (drop.isNotEmpty) {
          final (start, len) = drop.first;
          if (t == start + len) {
            // First fix back: the straight line from the last fix.
            recorded += chord * mps * len + extraJumpM;
            samples.add(
              Sample(
                tMs: t * 1000,
                lat: -33.87,
                lon: 151.21,
                accM: 5,
                distM: recorded,
              ),
            );
          } else if (lowAccuracy) {
            // The recorder journals a fix it rejects (accuracy over 25 m)
            // with lat/lon and the distance frozen.
            samples.add(
              Sample(
                tMs: t * 1000,
                lat: -33.87,
                lon: 151.21,
                accM: 60,
                distM: recorded,
              ),
            );
          } else {
            samples.add(Sample(tMs: t * 1000, distM: recorded));
          }
          continue;
        }
        recorded += t == 0 ? 0 : mps;
        samples.add(
          Sample(
            tMs: t * 1000,
            lat: -33.87,
            lon: 151.21,
            accM: 5,
            distM: recorded,
          ),
        );
      }
      return RunFile(
        id: '00000000-0000-4000-8000-0000000000bf',
        device: 'test',
        app: 'test',
        start: fixedNow,
        end: fixedNow.add(Duration(seconds: seconds)),
        tz: 'UTC',
        mode: mode,
        units: Units.km,
        laps: const [],
        samples: samples,
      );
    }

    test('a 5K with a 20 s and a 45 s dropout counts at the true time', () {
      // 8 km: a 5K window can hold one or both dropouts.
      final r = find(dropRun(2000, [(300, 20), (1200, 45)]));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      expect(r.miss, isNull);
    });

    test('20 s and 45 s dropouts in a run of exactly 5K count', () {
      final r = find(dropRun(1250, [(300, 20), (800, 45)]));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      expect(r.miss, isNull);
    });

    test('3 x 55 s of dropouts in exactly 5K count', () {
      final r = find(dropRun(1250, [(200, 55), (550, 55), (900, 55)]));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
    });

    test('4 min of dropouts in exactly 5K do not count, and it says why', () {
      final r = find(
        dropRun(1250, [(150, 60), (450, 60), (750, 60), (1050, 60)]),
      );
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.gpsDropped);
      expect(r.miss!.reason, 'GPS dropped 4 times, 4 min in all');
    });

    test('an 8 s dropout in exactly 5K counts (under the old 10 s rule)', () {
      final r = find(dropRun(1250, [(600, 8)]));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      expect(r.miss, isNull);
    });

    test('30 s of low-accuracy fixes (a tunnel) count as a dropout', () {
      final r = find(dropRun(1250, [(600, 30)], lowAccuracy: true));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
    });

    test('the allowance is max(180 s, 15% of the window): 184 s in a 1250 s '
        '5K counts, 192 s does not, and the miss says so', () {
      final ok = find(
        dropRun(1250, [(100, 46), (400, 46), (700, 46), (1000, 46)]),
      );
      expect(effort(ok, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      final no = find(
        dropRun(1250, [(100, 48), (400, 48), (700, 48), (1000, 48)]),
      );
      expect(no.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(no.miss!.reason, 'GPS dropped 4 times, 3 min in all');
    });

    test('a single 45 s dropout in exactly 5K counts', () {
      final r = find(dropRun(1250, [(600, 45)]));
      expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
    });

    test('the same holds for a gap in the timestamps (no no-fix samples)', () {
      final r = find(build([(600, 4.0), (650, 4.0)], gapAfterPiece: {0: 30}));
      expect(effort(r, BestEffortDistance.k5), isNotNull);
    });

    test('a 90 s dropout is not bridged and the miss says how long', () {
      final r = find(dropRun(1300, [(800, 90)]));
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.gpsDropped);
      expect(r.miss!.reason, 'GPS dropped for 90 s at 3.2 km');
    });

    test('a 2 minute dropout reads in minutes', () {
      final r = find(dropRun(1300, [(800, 120)]));
      expect(r.miss!.reason, 'GPS dropped for 2 min at 3.2 km');
    });

    test('an implausible jump across a short dropout still cuts', () {
      // 20 s dropout, then a 600 m leap: 680 m in 20 s is 34 m/s.
      final r = find(dropRun(1300, [(800, 20)], extraJumpM: 600));
      expect(r.efforts.containsKey(BestEffortDistance.k5), isFalse);
      expect(r.miss!.kind, EffortMissKind.gpsJump);
    });

    test('a bridged time is never faster than the true time', () {
      // The recorder only adds the straight line across the dropout, which
      // is shorter than the path run: 15% short here. The window can only
      // read slower than the true 1250 s, never faster.
      for (final chord in [1.0, 0.95, 0.85, 0.6]) {
        final r = find(dropRun(1400, [(500, 45)], chord: chord));
        final ms = effort(r, BestEffortDistance.k5).elapsedMs;
        expect(ms, greaterThanOrEqualTo(1250000 - 5), reason: 'chord $chord');
        // Slower by about the distance lost at 4 m/s.
        final lostS = (1 - chord) * mps * 45 / mps;
        expect(ms, lessThan(1250000 + (lostS + 2) * 1000));
      }
    });

    test('a window with an edge inside a dropout is refused', () {
      // The dropout straddles where a window could end if it ended at 5000
      // m: a fast window must hold the whole hole or none of it.
      final r = find(dropRun(1400, [(600, 45)], chord: 1));
      final k5 = effort(r, BestEffortDistance.k5);
      final holeStart = 600000, holeEnd = 645000;
      final touches = k5.startMs < holeEnd && k5.endMs > holeStart;
      final whole = k5.startMs <= holeStart && k5.endMs >= holeEnd;
      expect(!touches || whole, isTrue);
    });

    test('1K and mile windows stay strict: no window spans a dropout', () {
      final r = find(dropRun(260, [(100, 15)]));
      expect(r.efforts.containsKey(BestEffortDistance.km1), isFalse);
      expect(r.efforts.containsKey(BestEffortDistance.mile), isFalse);
    });

    test('Laps, Trail and a goal run bridge too', () {
      for (final mode in [RunMode.laps, RunMode.trail]) {
        final r = find(dropRun(1300, [(500, 30)], mode: mode));
        expect(effort(r, BestEffortDistance.k5).elapsedMs, closeTo(1250000, 5));
      }
      final goal = dropRun(1300, [(500, 30)], mode: RunMode.intervals);
      final g = RunFile(
        id: goal.id,
        device: goal.device,
        app: goal.app,
        start: goal.start,
        end: goal.end,
        tz: goal.tz,
        mode: goal.mode,
        session: SessionSpec.goalDistance(5000, '5K'),
        units: goal.units,
        laps: goal.laps,
        samples: goal.samples,
      );
      expect(
        effort(find(g), BestEffortDistance.k5).elapsedMs,
        closeTo(1250000, 5),
      );
    });

    test('the miss with its duration round-trips through the index JSON', () {
      final r = find(dropRun(1300, [(800, 90)]));
      final back = RunBestEfforts.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
      );
      expect(back.miss!.reason, 'GPS dropped for 90 s at 3.2 km');
    });

    test('a bridged 5K feeds Estimated Times and MID', () {
      final run = dropRun(2000, [(300, 20), (1200, 45)]);
      final a = engine.analyze(run, now: fixedNow);
      final efforts = finder.find(run, a);
      final inputs = PredictionInput.ofRun(
        run,
        a,
        efforts,
        localDate: DateTime(2026, 9, 24),
      );
      expect(
        inputs.map((i) => i.kind),
        contains(PredictionSourceKind.bestEffort5k),
      );
      const predictor = Predictor(names: EventNames(parkrun: 'parkrun'));
      final p = predictor.predict(
        PredictionTarget.k10,
        inputs,
        now: DateTime(2026, 9, 26, 9),
      );
      expect(p, isNotNull);
      final candidate = LiveCandidate(
        BoardInput(
          runId: run.id,
          date: DateTime(2026, 9, 24),
          mode: RunMode.free,
          efforts: efforts.efforts,
        ),
        RunDerived(bestEfforts: efforts),
      );
      final mid = IdentityScores.of([
        candidate,
      ], now: DateTime(2026, 9, 26, 9))[IdentityLane.mid];
      expect(mid, isNotNull);
    });
  });
}
