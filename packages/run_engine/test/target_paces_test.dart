import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Session target paces from the runner's own runs: the VDOT tables, heat
/// and grade, and the one-tap nudge.
void main() {
  final now = DateTime(2026, 10, 15, 9);
  DateTime daysAgo(int d) => DateTime(now.year, now.month, now.day - d, 12);

  BestEffort be(BestEffortDistance d, int seconds) => BestEffort(
    distance: d,
    elapsedMs: seconds * 1000,
    startMs: 0,
    startOffsetM: 0,
    splitsMs: const [],
  );

  LiveCandidate road(String id, int daysBack, int fiveKSeconds) {
    final e = RunBestEfforts(
      efforts: {BestEffortDistance.k5: be(BestEffortDistance.k5, fiveKSeconds)},
      fromStartSplitsMs: const [],
    );
    return LiveCandidate(
      BoardInput(
        runId: id,
        date: daysAgo(daysBack).toUtc(),
        mode: RunMode.free,
        efforts: e.efforts,
        heatFraction: 0,
      ),
      RunDerived(bestEfforts: e),
    );
  }

  /// A hilly trail run: 8 km in 52:00 on the clock, with hills that make
  /// it worth 12% less at true pace.
  LiveCandidate trail(String id, int daysBack) => LiveCandidate(
    BoardInput(
      runId: id,
      date: daysAgo(daysBack).toUtc(),
      mode: RunMode.trail,
      gradeFactor: 0.88,
      trailDistanceM: 8000,
      trailMovingMs: 52 * 60 * 1000,
    ),
    const RunDerived(
      bestEfforts: RunBestEfforts(efforts: {}, fromStartSplitsMs: []),
    ),
  );

  group('targets from runs', () {
    test('a 24:30 5K gives ordered paces, labelled with their method', () {
      final t = TargetPaces.of([road('a', 4, 24 * 60 + 30)], now: now)!;
      expect(t.vdot, closeTo(39.2, 0.3));
      final easy = t[PaceIntensity.easy]!.trueSecPerKm;
      final tempo = t[PaceIntensity.tempo]!.trueSecPerKm;
      final th = t[PaceIntensity.threshold]!.trueSecPerKm;
      final vo2 = t[PaceIntensity.vo2max]!.trueSecPerKm;
      expect(easy, greaterThan(tempo));
      expect(tempo, greaterThan(th));
      expect(th, greaterThan(vo2));
      // Threshold for a 24:30 5K runner sits near 5:05 to 5:15/km.
      expect(th, inInclusiveRange(300, 320));
      // The 5K pace itself (4:54) is faster than threshold, slower than VO2.
      expect(vo2, lessThan(294));
      expect(easy, closeTo(th * 1.25, 1e-6));
      for (final p in t.paces.values) {
        expect(p.method, contains(p.intensity.label.split(' ').first));
      }
      expect(t[PaceIntensity.threshold]!.method, contains('VDOT'));
      expect(t.sourceLine, startsWith('From your 5K on '));
    });

    test('no runs in 6 weeks, no targets', () {
      expect(TargetPaces.of([road('a', 60, 1500)], now: now), isNull);
      expect(TargetPaces.of(const [], now: now), isNull);
    });

    test('Ricki-like fixture: a road 5K and two hilly trail runs', () {
      final runs = [road('r1', 20, 25 * 60), trail('t1', 5), trail('t2', 12)];
      final t = TargetPaces.of(runs, now: now)!;
      // The trail run counts at true pace (52:00 x 0.88 over 8 km = 5:43/km)
      // so the trail run, not the slower road 5K, sets the figure only when
      // it is faster; here it is not, so the source stays the 5K.
      expect(t.sourceLine, startsWith('From your 5K'));
      final withBetterTrail = TargetPaces.of([
        road('r1', 20, 30 * 60),
        trail('t1', 5),
      ], now: now)!;
      expect(withBetterTrail.sourceLine, startsWith('From your trail run'));
      expect(withBetterTrail.vdot, greaterThan(33));
    });

    test('an accepted pace replaces the model and says so', () {
      final base = TargetPaces.of([road('a', 4, 1470)], now: now)!;
      final modelEasy = base[PaceIntensity.easy]!.trueSecPerKm;
      final t = TargetPaces.of(
        [road('a', 4, 1470)],
        now: now,
        adopted: {PaceIntensity.easy: modelEasy - 10},
      )!;
      final easy = t[PaceIntensity.easy]!;
      expect(easy.trueSecPerKm, modelEasy - 10);
      expect(easy.modelSecPerKm, closeTo(modelEasy, 1e-9));
      expect(easy.adopted, isTrue);
      expect(easy.method, endsWith('moved by you'));
      expect(t[PaceIntensity.tempo]!.adopted, isFalse);
    });
  });

  group('heat and grade', () {
    final t = TargetPaces.fromVdot(40)!;
    final th = t[PaceIntensity.threshold]!;

    test('a cool flat day leaves the pace alone', () {
      final a = TargetPaces.adjust(th, tempC: 12, dewPointC: 6, gradePct: 0);
      expect(a.secPerKm, th.trueSecPerKm);
      expect(a.notes, isEmpty);
    });

    test('28 C with a 21 C dew point slows the target by about 4.9%', () {
      final a = TargetPaces.adjust(th, tempC: 28, dewPointC: 21);
      expect(a.secPerKm, closeTo(th.trueSecPerKm / (1 - 0.047), 0.5));
      expect(a.notes.single, startsWith('heat +'));
    });

    test('a moderate climb slows it, a gentle descent speeds it', () {
      final up = TargetPaces.adjust(th, gradePct: 4);
      expect(up.secPerKm, closeTo(th.trueSecPerKm * Gap.ratio(0.04), 1e-6));
      expect(up.secPerKm, greaterThan(th.trueSecPerKm));
      final down = TargetPaces.adjust(th, gradePct: -3);
      expect(down.secPerKm, lessThan(th.trueSecPerKm));
    });

    test('heat and grade stack', () {
      final both = TargetPaces.adjust(
        th,
        tempC: 28,
        dewPointC: 21,
        gradePct: 4,
      );
      final heatOnly = TargetPaces.adjust(th, tempC: 28, dewPointC: 21);
      expect(both.secPerKm, greaterThan(heatOnly.secPerKm!));
      expect(both.notes, hasLength(2));
    });

    test('a steep grade gives a heart-rate zone, not a pace', () {
      final zones = HrZones.percentMax(190);
      final a = TargetPaces.adjust(th, gradePct: 12, zones: zones);
      expect(a.isEffort, isTrue);
      expect(a.secPerKm, isNull);
      expect(a.effort, 'Zone 4 effort (152 to 170 bpm)');
      final easy = TargetPaces.adjust(t[PaceIntensity.easy]!, gradePct: -10);
      expect(easy.effort, 'Zones 1 and 2 effort');
      expect(
        TargetPaces.adjust(
          t[PaceIntensity.vo2max]!,
          gradePct: 9,
          zones: zones,
        ).effort,
        startsWith('Zone 5 effort (171 bpm and up'),
      );
    });

    test('too hot to compare also falls back to effort', () {
      final a = TargetPaces.adjust(th, tempC: 45, dewPointC: 30);
      expect(a.isEffort, isTrue);
      expect(a.notes, contains('too hot to compare'));
    });
  });

  group('nudges', () {
    const current = 320.0; // 5:20
    PaceObservation obs(int daysBack, double pace) => PaceObservation(
      runId: 'r$daysBack',
      date: daysAgo(daysBack),
      trueSecPerKm: pace,
    );
    PaceNudge? nudge(
      List<PaceObservation> o, {
      PaceIntensity i = PaceIntensity.easy,
      DateTime? answered,
      bool? lastQuicker,
      double cur = current,
    }) => PaceNudges.evaluate(
      i,
      current: cur,
      observations: o,
      now: now,
      lastAnswerAt: answered,
      lastAcceptedQuicker: lastQuicker,
    );

    test('four easy runs over three weeks, all quicker: 5:20 to 5:10', () {
      final n = nudge([obs(2, 308), obs(9, 311), obs(15, 309), obs(22, 312)])!;
      expect(n.fromSecPerKm, 320);
      expect(n.toSecPerKm, 310);
      expect(n.quicker, isTrue);
      expect(
        n.line(Units.km),
        'Your easy pace looks quicker now: 5:20 to 5:10?',
      );
      expect(n.runCount, 4);
    });

    test('one fast run, or too few runs, is not evidence', () {
      expect(nudge([obs(2, 290)]), isNull);
      expect(nudge([obs(2, 308), obs(9, 311), obs(15, 309)]), isNull);
    });

    test('a mixed set does not nudge', () {
      expect(
        nudge([obs(2, 308), obs(9, 330), obs(15, 309), obs(22, 312)]),
        isNull,
      );
    });

    test('runs bunched inside ten days do not nudge', () {
      expect(
        nudge([obs(1, 308), obs(3, 311), obs(5, 309), obs(7, 312)]),
        isNull,
      );
    });

    test('runs barely quicker than target do not nudge', () {
      expect(
        nudge([obs(2, 316), obs(9, 317), obs(15, 316), obs(22, 317)]),
        isNull,
      );
    });

    test('an outlier is ignored, not counted against the set', () {
      final n = nudge([
        obs(2, 308),
        obs(5, 200), // GPS spike
        obs(9, 311),
        obs(15, 309),
        obs(22, 312),
      ]);
      expect(n, isNotNull);
      expect(n!.runCount, 4);
    });

    test('easy running slower than the ceiling never nudges', () {
      expect(
        nudge([obs(2, 335), obs(9, 338), obs(15, 336), obs(22, 337)]),
        isNull,
      );
    });

    test('a work pace running slower does nudge, with fewer runs', () {
      final n = nudge(
        [obs(2, 262), obs(10, 264), obs(18, 263)],
        i: PaceIntensity.vo2max,
        cur: 250,
      )!;
      expect(n.quicker, isFalse);
      expect(n.toSecPerKm, 265);
    });

    test('quiet for three weeks after any answer, evidence resets', () {
      final runs = [obs(2, 308), obs(9, 311), obs(15, 309), obs(22, 312)];
      expect(nudge(runs, answered: daysAgo(10)), isNull);
      // Past the cooldown, runs since the answer still count...
      expect(nudge(runs, answered: daysAgo(25)), isNotNull);
      // ...but runs from before the answer are spent evidence.
      final spent = [obs(30, 308), obs(34, 311), obs(38, 309), obs(41, 312)];
      expect(nudge(spent, answered: daysAgo(25)), isNull);
    });

    test('no flip-flop: a reversal needs twice the evidence', () {
      // Accepted a quicker target; now runs are 3% slower.
      final slower = [obs(2, 330), obs(9, 331), obs(15, 330), obs(22, 332)];
      expect(
        nudge(slower, i: PaceIntensity.threshold, lastQuicker: true),
        isNull,
      );
      // Same direction as the last move needs only the normal bar.
      expect(
        nudge(slower, i: PaceIntensity.threshold, lastQuicker: false),
        isNotNull,
      );
      // A clear 6% reversal still goes through.
      final far = [obs(2, 340), obs(9, 341), obs(15, 340), obs(22, 342)];
      expect(
        nudge(far, i: PaceIntensity.threshold, lastQuicker: true),
        isNotNull,
      );
    });

    test('a nudge never moves the targets by itself', () {
      final runs = [road('a', 4, 24 * 60 + 30)];
      final before = TargetPaces.of(runs, now: now)!;
      final th = before[PaceIntensity.threshold]!.trueSecPerKm;
      final n = nudge(
        [
          for (final d in [2, 9, 15, 22]) obs(d, th - 15),
        ],
        i: PaceIntensity.threshold,
        cur: th,
      );
      expect(n, isNotNull);
      final after = TargetPaces.of(runs, now: now)!;
      expect(after[PaceIntensity.threshold]!.trueSecPerKm, th);
      expect(after[PaceIntensity.threshold]!.adopted, isFalse);
    });
  });
}
