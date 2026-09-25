import 'package:run_engine/run_engine.dart';
import 'package:run_engine/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 3 I3 (plan §3.7): generalised detection, metric per session kind,
/// floors per key, rep time for distance reps, fartlek summary, priors and
/// the D4 note by key.
void main() {
  const hrProfile = UserProfile(maxHr: 185);
  final day0 = DateTime.utc(2026, 9, 1, 6);

  /// A structured run through the generator: open warm-up, one segment per
  /// step (a 0:00 recovery writes none), open cool-down; auto-laps at every
  /// boundary as the I2 recorder writes them. Distance steps become time
  /// segments at [workMps] / [recoveryMps] (400 m at 4 m/s = 100 s).
  RunFile sessionRun(
    SessionSpec spec, {
    int n = 1,
    double workMps = 4.0,
    double recoveryMps = 2.0,
    Map<int, int> workSecondsOverride = const {},
    int? stopAfterRep,
    bool hr = true,
    LapStyle lapStyle = LapStyle.auto,
    List<Span> gaps = const [],
    DateTime? start,
  }) {
    final segs = <Segment>[const Segment.warmup(300, 2.8)];
    int? lastWorkSeconds;
    for (final st in spec.steps) {
      if (stopAfterRep != null && st.rep > stopAfterRep) break;
      if (st.isWork) {
        final secs =
            workSecondsOverride[st.rep] ??
            switch (st.target) {
              TargetKind.time => st.value,
              TargetKind.distance => (st.value / workMps).round(),
              TargetKind.equalToPreviousWork => throw StateError('work'),
            };
        lastWorkSeconds = secs;
        segs.add(Segment.work(secs, workMps));
      } else {
        if (stopAfterRep != null && st.rep >= stopAfterRep) break;
        final secs = switch (st.target) {
          TargetKind.time => st.value,
          TargetKind.distance => (st.value / recoveryMps).round(),
          TargetKind.equalToPreviousWork => lastWorkSeconds!,
        };
        if (secs == 0) continue;
        segs.add(Segment.recovery(secs, recoveryMps));
      }
    }
    segs.add(const Segment.cooldown(300, 2.5));
    return generator
        .generate(
          SyntheticSpec(
            name: 'i3_${spec.templateId}_$n',
            id: '00000000-0000-4000-8000-${(9000 + n).toString().padLeft(12, '0')}',
            session: spec,
            lapStyle: lapStyle,
            segments: segs,
            hr: hr,
            gaps: gaps,
            start: start ?? day0.add(Duration(days: n)),
          ),
        )
        .run;
  }

  RunAnalysis analyze(RunFile run, {List<PriorRun> priors = const []}) =>
      engine.analyze(run, priors: priors, profile: hrProfile, now: fixedNow);

  /// Analyse runs oldest first, each feeding the next as a prior.
  List<RunAnalysis> staged(List<RunFile> runs) {
    final priors = <PriorRun>[];
    final out = <RunAnalysis>[];
    for (final r in runs) {
      final a = analyze(r, priors: List.of(priors));
      out.add(a);
      final p = a.asPrior(r.start);
      if (p != null) priors.add(p);
    }
    return out;
  }

  final fourHundreds = SessionCatalogue.fourHundreds.defaults;

  group('distance reps: rep time (8 × 400 m)', () {
    test('detected from auto-laps; headline is the time for 400 m', () {
      final a = analyze(sessionRun(fourHundreds));
      expect(a.comparisonKey, 'd400x*');
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps.length, 8);
      expect(a.detection!.warmup.length, 1);
      expect(a.detection!.cooldown.length, 1);
      final m = a.intervals!;
      expect(m.kind, IntervalMetricKind.repTime);
      expect(m.nominalRepMetres, 400);
      // 4 m/s → 100 s per 400 m; measured over the whole lap.
      expect(m.avgRepSeconds, closeTo(100, 2.5));
      final v = a.verdict!;
      expect(v.headline, VerdictHeadline.baselineSet);
      expect(v.nominalRepMetres, 400);
      expect(v.subline, startsWith('400 m in 1:'));
      expect(v.subline, endsWith('Next 8 × 400 m session gets a verdict.'));
      expect(v.hrLine, isNull, reason: 'the 400s carry no HR band');
      expect(v.floorSecPerKm, 10, reason: '16 min at the nominal pace');
    });

    test('vs last and vs median read in seconds per rep', () {
      final runs = [
        sessionRun(fourHundreds, n: 1, workMps: 4.0),
        sessionRun(fourHundreds, n: 2, workMps: 4.4),
        sessionRun(fourHundreds, n: 3, workMps: 4.0),
        sessionRun(fourHundreds, n: 4, workMps: 4.0),
      ];
      final a = staged(runs);
      expect(a[1].verdict!.headline, VerdictHeadline.faster);
      expect(
        a[1].verdict!.subline,
        matches(
          RegExp(
            r'^Rep time \d+ s faster than your first 8 × 400 m session '
            r'\(1:\d\d vs 1:\d\d\)\.',
          ),
        ),
      );
      expect(a[3].verdict!.stage, VerdictStage.vsMedian);
      expect(a[3].verdict!.subline, contains('your recent 8 × 400 m sessions'));
    });

    test('a rep cut short: "Rep 2 was 352 m, the session expected 400 m."', () {
      final a = analyze(sessionRun(fourHundreds, workSecondsOverride: {2: 89}));
      expect(a.detection!.consistent, isFalse);
      expect(a.detection!.inconsistency, InconsistencyKind.phaseOutsideWindow);
      expect(
        a.detection!.inconsistencyDetail,
        matches(RegExp(r'^Rep 2 was 3\d\d m, the session expected 400 m\.$')),
      );
      expect(a.verdict!.headline, VerdictHeadline.noVerdict);
      expect(
        a.verdict!.subline,
        'Laps do not match the session. Fix laps to get a verdict.',
      );
    });

    test('fix-laps keep accepts the short rep', () {
      final run = sessionRun(fourHundreds, workSecondsOverride: {2: 89});
      final bad = analyze(run);
      final short = bad.detection!.laps.firstWhere(
        (l) => l.distanceM < 380 && l.distanceM > 300,
      );
      final a = engine.analyze(
        run,
        sidecar: RunSidecar(runId: run.id)
            .withLapEdit(LapEdit.keep(short.index)),
        now: fixedNow,
      );
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps[1].workOutsideWindow, isTrue);
    });

    test('stopped one rep early still counts; two early does not', () {
      final one = analyze(sessionRun(fourHundreds, stopAfterRep: 7));
      expect(one.detection!.consistent, isTrue);
      expect(one.detection!.reps.length, 7);
      final two = analyze(sessionRun(fourHundreds, stopAfterRep: 6));
      expect(two.detection!.consistent, isFalse);
      expect(
        two.detection!.inconsistencyDetail,
        'Found 6 reps, the session expected 8.',
      );
    });

    test('no laps: no speed-stream fallback, NO VERDICT', () {
      final a = analyze(sessionRun(fourHundreds, lapStyle: LapStyle.none));
      expect(a.detection!.fromSpeedStream, isFalse);
      expect(a.detection!.consistent, isFalse);
      expect(a.verdict!.headline, VerdictHeadline.noVerdict);
    });

    test('an interrupted rep is named, as for a 4x4', () {
      final run = sessionRun(fourHundreds, gaps: const [Span(530000, 545000)]);
      final a = analyze(run);
      expect(a.verdict!.headline, VerdictHeadline.noVerdict);
      expect(a.verdict!.subline, startsWith("Recording stopped in rep 2."));
    });
  });

  group('Yasso 800s and pyramid: equal-time recoveries', () {
    test('Yasso recovery matches the time of the rep before it', () {
      final a = analyze(sessionRun(SessionCatalogue.yasso.defaults));
      expect(a.comparisonKey, 'd800x*');
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps.length, 6);
      expect(
        a.detection!.reps.first.recoveryStep!.target,
        TargetKind.equalToPreviousWork,
      );
      expect(a.intervals!.avgRepSeconds, closeTo(200, 4));
      expect(a.verdict!.subline, startsWith('800 m in 3:'));
    });

    test('pyramid: ladder detected, trimmed pace, own key', () {
      final a = analyze(sessionRun(SessionCatalogue.pyramid.defaults));
      expect(a.comparisonKey, 'pyr:60,120,180,240,180,120,60');
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps.length, 7);
      expect(a.intervals!.kind, IntervalMetricKind.trimmedPace);
      expect(a.verdict!.subline, contains('work pace'));
      expect(
        a.verdict!.subline,
        endsWith('Next Pyramid session gets a verdict.'),
      );
    });

    test('a pyramid never compares with a 4x4', () {
      final fourByFour = analyze(fixture('preset_4x4_auto_standard').run);
      final p = fourByFour.asPrior(day0)!;
      expect(p.comparisonKey, 't240x*');
      final a = analyze(
        sessionRun(SessionCatalogue.pyramid.defaults),
        priors: [p],
      );
      expect(a.verdict!.stage, VerdictStage.baseline);
    });
  });

  group('short reps: untrimmed, wider floor, no zone (D5)', () {
    test('30/30s: total work distance ÷ total work time, untrimmed', () {
      final spec = SessionCatalogue.thirtyThirty.defaults;
      final a = analyze(sessionRun(spec, workMps: 4.5));
      expect(a.comparisonKey, 't30x*');
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps.length, 20);
      final m = a.intervals!;
      expect(m.kind, IntervalMetricKind.untrimmedPace);
      // Untrimmed: every rep's trimmed window is the whole lap.
      for (final r in m.reps) {
        expect(r.trimmedT0Ms, r.lap.t0Ms);
        expect(r.trimmedT1Ms, r.lap.t1Ms);
        expect(r.metresPerBeat, isNull, reason: 'm/beat only for >= 90 s');
      }
      // GPS lag attenuates a 30 s rep's measured speed toward the recovery
      // (plan §3.7): slower than 222 s/km, never faster.
      expect(m.avgWorkPaceSecPerKm!, greaterThan(1000 / 4.5 - 1));
      expect(m.timeInZoneSeconds, isNull);
      final v = a.verdict!;
      expect(v.floorSecPerKm, closeTo(12.65, 0.01));
      expect(v.hrLine, isNull);
      expect(v.subline, endsWith('Next 30/30s session gets a verdict.'));
    });

    test('1-minute reps: a 0:52 rep is out of the ±7.5 s window, 0:54 in', () {
      final spec = SessionCatalogue.oneMinute.defaults;
      final out = analyze(sessionRun(spec, workSecondsOverride: {3: 52}));
      expect(
        out.detection!.inconsistencyDetail,
        'Rep 3 was 0:52, the session expected 1:00.',
      );
      final inWindow = analyze(sessionRun(spec, workSecondsOverride: {3: 54}));
      expect(inWindow.detection!.consistent, isTrue);
    });

    test('a 0:00 recovery (straight into the next rep) writes no lap', () {
      final spec = SessionSpec(
        templateId: 'custom:straight',
        templateVersion: 1,
        name: '6 × 2:00 no rest',
        steps: SessionSpec.uniform(
          reps: 6,
          work: (r) => SessionStep.work(120, rep: r),
          recovery: (r) => SessionStep.recovery(0, rep: r),
        ),
      );
      final a = analyze(sessionRun(spec));
      expect(a.detection!.consistent, isTrue);
      expect(a.detection!.reps.length, 6);
      expect(a.detection!.reps.every((r) => r.recovery == null), isTrue);
    });
  });

  group('tempo: trimmed, the session HR band', () {
    test('time in zone uses 80–90% of max HR', () {
      final spec = SessionCatalogue.tempo.defaults;
      final a = analyze(sessionRun(spec));
      expect(a.intervals!.kind, IntervalMetricKind.trimmedPace);
      expect(a.intervals!.timeInZoneSeconds, isNotNull);
      expect(a.verdict!.floorSecPerKm, 10, reason: '24 min clamps to 10');
    });
  });

  group('comparison key and the D4 note', () {
    test('a custom 5 × 4:00 / 2:30 shares 4x4 history on the 4x4 path, '
        'with "Last time: 4 reps, 3:00 recovery."', () {
      final custom = SessionSpec(
        templateId: 'custom:five',
        templateVersion: 1,
        name: '5 × 4:00 · 2:30 jog',
        steps: SessionSpec.uniform(
          reps: 5,
          work: (r) => SessionStep.work(240, rep: r),
          recovery: (r) => SessionStep.recovery(150, rep: r),
        ),
      );
      final a = staged([
        sessionRun(SessionSpec.norwegian4x4(), n: 1),
        sessionRun(custom, n: 2),
      ]);
      expect(a[1].comparisonKey, 't240x*');
      expect(a[1].verdict!.stage, VerdictStage.vsLast);
      expect(a[1].verdict!.subline, contains('your first 4x4'));
      expect(a[1].verdict!.comparisonNote, 'Last time: 4 reps, 3:00 recovery.');
      expect(a[1].verdict!.floorSecPerKm, closeTo(10 * 1.41421356, 1e-6));
    });

    test('same reps and recovery: no note', () {
      final a = staged([
        sessionRun(fourHundreds, n: 1),
        sessionRun(fourHundreds, n: 2),
      ]);
      expect(a[1].verdict!.comparisonNote, isNull);
    });

    test('400s with a timed recovery: the note names the old one', () {
      final timed = SessionCatalogue.expand(
        '400s',
        reps: 10,
        recovery: const SessionStep.recovery(90, rep: 1),
      );
      final a = staged([
        sessionRun(fourHundreds, n: 1),
        sessionRun(timed, n: 2),
      ]);
      expect(a[1].comparisonKey, 'd400x*');
      expect(a[1].verdict!.comparisonNote, 'Last time: 8 reps, 200 m jog.');
    });

    test('recovery labels', () {
      expect(
        VerdictBuilder.recoveryLabelOf(SessionSpec.norwegian4x4()),
        '3:00 recovery',
      );
      expect(VerdictBuilder.recoveryLabelOf(fourHundreds), '200 m jog');
      expect(
        VerdictBuilder.recoveryLabelOf(SessionCatalogue.yasso.defaults),
        'equal-time jog',
      );
      expect(VerdictBuilder.recoveryLabelOf(SessionSpec.cooper), 'no recovery');
    });

    test('a 2-rep custom needs only its 2 clean reps', () {
      final two = SessionSpec(
        templateId: 'custom:two',
        templateVersion: 1,
        name: '2 × 10:00',
        steps: SessionSpec.uniform(
          reps: 2,
          work: (r) => SessionStep.work(600, rep: r),
          recovery: (r) => SessionStep.recovery(180, rep: r),
        ),
      );
      final a = analyze(sessionRun(two));
      expect(a.detection!.consistent, isTrue);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
      expect(a.eligibleAsPrior, isTrue);
    });
  });

  group('fartlek (D3): summary only', () {
    test('surges are the even laps; easy laps between them; no verdict', () {
      final run = generator
          .generate(
            SyntheticSpec(
              name: 'fartlek',
              mode: RunMode.laps,
              session: SessionSpec.fartlek,
              lapStyle: LapStyle.auto,
              hr: true,
              segments: const [
                Segment.warmup(600, 2.8),
                Segment.work(60, 4.5),
                Segment.recovery(120, 2.6),
                Segment.work(90, 4.4),
                Segment.recovery(120, 2.6),
                Segment.work(45, 4.8),
                Segment.cooldown(300, 2.5),
              ],
            ),
          )
          .run;
      final a = analyze(run);
      expect(a.comparisonKey, 'fartlek');
      expect(a.verdict, isNull);
      final f = a.fartlek!;
      expect(f.surgeCount, 3);
      expect(f.surgeSeconds, closeTo(195, 1));
      expect(f.avgSurgePaceSecPerKm!, lessThan(f.avgEasyPaceSecPerKm!));
      expect(f.avgEasyPaceSecPerKm, closeTo(1000 / 2.6, 15));
      // A plain Laps run has no fartlek block.
      expect(analyze(fixture('laps_run_manual_clean_hr').run).fartlek, isNull);
    });
  });

  group('stateless builder (#21 review P3)', () {
    test('one builder, two keys: each floor is its own', () {
      const b = VerdictBuilder(EngineConstants.defaults);
      final short = analyze(sessionRun(SessionCatalogue.thirtyThirty.defaults));
      final four = analyze(fixture('preset_4x4_auto_standard').run);
      Verdict build(RunAnalysis a) => b.build(
        run: fixture('preset_4x4_auto_standard').run,
        detection: a.detection!,
        metrics: a.intervals!,
        gates: const VerdictGates(indoor: false, noisy: false, gpsQuality: 1),
        priors: const [],
        now: fixedNow,
        comparisonKey: a.comparisonKey!,
        templateDefault: a.session,
      );
      expect(build(short).floorSecPerKm, closeTo(12.65, 0.01));
      expect(build(four).floorSecPerKm, 10);
      expect(build(short).floorSecPerKm, closeTo(12.65, 0.01));
    });
  });

  test('PriorRun carries rep count and recovery through JSON', () {
    final a = analyze(sessionRun(fourHundreds));
    final p = a.asPrior(day0)!;
    expect(p.repCount, 8);
    expect(p.recoveryLabel, '200 m jog');
    final back = PriorRun.fromJson(p.toJson());
    expect(back.repCount, 8);
    expect(back.recoveryLabel, '200 m jog');
    expect(back.comparisonKey, 'd400x*');
  });
}
