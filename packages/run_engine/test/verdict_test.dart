import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Staged verdict transitions, noise-floor wording and the copy pinned to
/// the design brief's verdict copy set (run-solo-design-brief.md §1).
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);
  final d2 = DateTime.utc(2026, 9, 5, 6);
  final d3 = DateTime.utc(2026, 9, 9, 6);

  group('staged transitions', () {
    final run1 = runWithPaces(
      [285, 287, 289, 291],
      id: '00000000-0000-4000-8000-000000000101',
      start: d1,
    );
    final run2 = runWithPaces(
      [284, 284, 284, 284],
      id: '00000000-0000-4000-8000-000000000102',
      start: d2,
    );
    final run3 = runWithPaces(
      [270, 270, 270, 270],
      id: '00000000-0000-4000-8000-000000000103',
      start: d3,
    );

    test(
      'run 1 → baseline, run 2 → vs last with √2 floor, run 3 → vs median',
      () {
        final a1 = engine.analyze(run1, now: fixedNow);
        expect(a1.verdict!.stage, VerdictStage.baseline);
        expect(a1.verdict!.headline, VerdictHeadline.baselineSet);
        expect(a1.eligibleAsPrior, isTrue);

        final p1 = a1.asPrior(run1.start)!;
        final a2 = engine.analyze(run2, priors: [p1], now: fixedNow);
        expect(a2.verdict!.stage, VerdictStage.vsLast);
        expect(a2.verdict!.floorSecPerKm, closeTo(14.142, 0.001));
        expect(a2.verdict!.setIds, [run1.id]);
        expect(a2.verdict!.headline, VerdictHeadline.noRealChange);

        final p2 = a2.asPrior(run2.start)!;
        final a3 = engine.analyze(run3, priors: [p1, p2], now: fixedNow);
        expect(a3.verdict!.stage, VerdictStage.vsMedian);
        expect(a3.verdict!.floorSecPerKm, 10);
        expect(a3.verdict!.setIds, [run1.id, run2.id]);
        expect(a3.verdict!.headline, VerdictHeadline.faster);
        expect(a3.verdict!.rank, 2);
        expect(a3.verdict!.setSize, 2);
      },
    );

    test('a later run is never a prior', () {
      final future = engine.analyze(run3, now: fixedNow).asPrior(run3.start)!;
      final a1 = engine.analyze(run1, priors: [future], now: fixedNow);
      expect(a1.verdict!.stage, VerdictStage.baseline);
    });

    test('run 3+ uses only the last 6 priors and ranks against them', () {
      final priors = [
        for (var i = 0; i < 9; i++)
          prior(
            '00000000-0000-4000-8000-0000000002${i.toString().padLeft(2, '0')}',
            DateTime.utc(2026, 6 + i ~/ 4, 1 + (i % 4) * 7),
            300 + i.toDouble(),
          ),
      ];
      final a = engine.analyze(run3, priors: priors, now: fixedNow);
      expect(a.verdict!.setSize, 6);
      expect(a.verdict!.setIds, priors.sublist(3).map((p) => p.id).toList());
      // Median of 303..308 = 305.5.
      expect(a.verdict!.baselineSecPerKm, 305.5);
      expect(a.verdict!.rank, 6);
      expect(a.verdict!.bestIn365Days, isTrue);
    });

    test('365-day best needs > 1% over every prior in the window', () {
      final priors = [
        prior('00000000-0000-4000-8000-000000000301', d1, 271),
        prior('00000000-0000-4000-8000-000000000302', d2, 300),
      ];
      final a = engine.analyze(run3, priors: priors, now: fixedNow);
      // 270 vs best prior 271: 0.4% better, not a badge.
      expect(a.verdict!.bestIn365Days, isFalse);
    });

    test('Theil–Sen slope appears once 5 runs span 4 weeks', () {
      final priors = [
        for (var i = 0; i < 4; i++)
          prior(
            '00000000-0000-4000-8000-0000000004${i.toString().padLeft(2, '0')}',
            d3.subtract(Duration(days: 7 * (4 - i))),
            300 - i * 5.0,
          ),
      ];
      final a = engine.analyze(run3, priors: priors, now: fixedNow);
      expect(a.verdict!.trendSecPerKmPerWeek, isNotNull);
      expect(a.verdict!.trendSecPerKmPerWeek!, lessThan(0));
      final fewer = engine.analyze(
        run3,
        priors: priors.sublist(1),
        now: fixedNow,
      );
      expect(fewer.verdict!.trendSecPerKmPerWeek, isNull);
    });
  });

  group('copy pinned to the design brief', () {
    test('Faster (run 3+)', () {
      final run = runWithPaces(
        [282, 283, 285, 287],
        recoveryPace: 362,
        hr: true,
        start: d3,
      );
      final own = engine
          .analyze(run, profile: profile, now: fixedNow)
          .intervals!;
      final pct = own.meanWorkHrFraction!;
      final priors = [
        prior(
          '00000000-0000-4000-8000-000000000501',
          d1,
          298,
          fade: 8,
          hrFraction: pct,
        ),
        prior(
          '00000000-0000-4000-8000-000000000502',
          d2,
          298,
          fade: 8,
          hrFraction: pct,
        ),
      ];
      final v = engine
          .analyze(run, priors: priors, profile: profile, now: fixedNow)
          .verdict!;
      expect(v.headline.text, 'FASTER');
      expect(
        v.subline,
        'Work pace 14 s/km faster than your recent 4x4s (4:44 vs 4:58/km). Fade 5 s, was 8 s.',
      );
      expect(
        v.hrLine,
        'Same effort: ${(pct * 100).round()}% max HR both runs.',
      );
    });

    test('Holding (run 3+)', () {
      final run = runWithPaces(
        [295, 295, 295, 295],
        recoveryPace: 362,
        hr: true,
        start: d3,
      );
      final own = engine
          .analyze(run, profile: profile, now: fixedNow)
          .intervals!;
      final priors = [
        prior(
          '00000000-0000-4000-8000-000000000511',
          d1,
          298,
          recovery: 370,
          tiz: own.timeInZoneSeconds! - 40,
        ),
        prior(
          '00000000-0000-4000-8000-000000000512',
          d2,
          298,
          recovery: 370,
          tiz: own.timeInZoneSeconds! - 40,
        ),
      ];
      final v = engine
          .analyze(run, priors: priors, profile: profile, now: fixedNow)
          .verdict!;
      expect(v.headline.text, 'HOLDING');
      expect(
        v.subline,
        'Within 3 s/km of your recent 4x4s (4:55 vs 4:58/km). Recovery pace 6:02, was 6:10.',
      );
      expect(
        v.hrLine,
        'Time in zone ${PaceFormat.mmss(own.timeInZoneSeconds!)}, up 40 s.',
      );
    });

    test('Slower (run 3+)', () {
      final run = runWithPaces([303, 308, 312, 317], hr: true, start: d3);
      final own = engine
          .analyze(run, profile: profile, now: fixedNow)
          .intervals!;
      final priors = [
        prior(
          '00000000-0000-4000-8000-000000000521',
          d1,
          298,
          fade: 8,
          meanHr: own.meanWorkHr! + 4,
        ),
        prior(
          '00000000-0000-4000-8000-000000000522',
          d2,
          298,
          fade: 8,
          meanHr: own.meanWorkHr! + 4,
        ),
      ];
      final v = engine
          .analyze(run, priors: priors, profile: profile, now: fixedNow)
          .verdict!;
      expect(v.headline.text, 'SLOWER');
      expect(
        v.subline,
        'Work pace 12 s/km slower than your recent 4x4s (5:10 vs 4:58/km). Fade 14 s, was 8 s.',
      );
      expect(v.hrLine, 'HR 4 bpm lower: easier day, not a worse one.');
    });

    test('No real change (run 2)', () {
      final run = runWithPaces([290, 290, 290, 290], start: d2);
      final v = engine
          .analyze(
            run,
            priors: [prior('00000000-0000-4000-8000-000000000531', d1, 298)],
            now: fixedNow,
          )
          .verdict!;
      expect(v.headline.text, 'NO REAL CHANGE');
      expect(
        v.subline,
        '8 s/km faster than your first 4x4 (4:50 vs 4:58/km). Inside what phone GPS can tell (14 s/km).',
      );
      expect(v.hrLine, isNull);
    });

    test('Run 2 faster/slower say "vs your first 4x4"', () {
      final faster = runWithPaces([280, 280, 280, 280], start: d2);
      final vf = engine
          .analyze(
            faster,
            priors: [
              prior('00000000-0000-4000-8000-000000000541', d1, 298, fade: 8),
            ],
            now: fixedNow,
          )
          .verdict!;
      expect(vf.headline.text, 'FASTER');
      expect(
        vf.subline,
        'Work pace 18 s/km faster than your first 4x4 (4:40 vs 4:58/km). Fade 0 s, was 8 s.',
      );
      final slower = runWithPaces([316, 316, 316, 316], start: d2);
      final vs = engine
          .analyze(
            slower,
            priors: [prior('00000000-0000-4000-8000-000000000542', d1, 298)],
            now: fixedNow,
          )
          .verdict!;
      expect(vs.headline.text, 'SLOWER');
      expect(
        vs.subline,
        'Work pace 18 s/km slower than your first 4x4 (5:16 vs 4:58/km). Fade 0 s.',
      );
    });

    test('Baseline (run 1)', () {
      final run = runWithPaces([285, 287, 289, 291], hr: true, start: d1);
      final v = engine.analyze(run, profile: profile, now: fixedNow).verdict!;
      expect(v.headline.text, 'BASELINE SET');
      expect(
        v.subline,
        '4:48/km work pace. Reps within 6 s of each other. Recovery 6:10. Next 4x4 gets a verdict.',
      );
      expect(v.hrLine, matches(RegExp(r'^Time in zone \d+:\d\d of 16:00\.$')));
    });

    test('Baseline outside the rep band says "spread"', () {
      final run = runWithPaces([280, 285, 290, 300], start: d1);
      final v = engine.analyze(run, now: fixedNow).verdict!;
      expect(v.subline, contains('Reps spread 20 s.'));
      expect(v.subline, isNot(contains('within')));
    });

    test('Interrupted', () {
      final v = engine
          .analyze(fixture('gps_dropout_rep2').run, now: fixedNow)
          .verdict!;
      expect(v.headline.text, 'NO VERDICT');
      expect(
        v.subline,
        'GPS dropped in rep 2. Three clean reps are not enough to compare.',
      );
      expect(v.stage, VerdictStage.none);
    });

    test('Indoor', () {
      final v = engine
          .analyze(
            fixture('treadmill_indoor').run,
            profile: profile,
            now: fixedNow,
          )
          .verdict!;
      expect(v.headline.text, 'INDOOR RUN');
      expect(
        v.subline,
        matches(RegExp(r'^No pace verdict\. Time in zone \d+:\d\d\.$')),
      );
    });

    test('no em-dashes, no exclamation marks, no shame words in any copy', () {
      final banned = RegExp(
        '—|!|bad|weak|off day|crushed|beast|smashed',
        caseSensitive: false,
      );
      for (final f in loadFixtures()) {
        final v = engine
            .analyze(f.run, profile: profile, now: fixedNow)
            .verdict;
        if (v == null) continue;
        expect(v.subline, isNot(matches(banned)), reason: f.name);
        expect(v.hrLine ?? '', isNot(matches(banned)), reason: f.name);
      }
    });
  });

  group('noise floor', () {
    test('run 2 delta exactly at √2 × 10 is "about the same"', () {
      // 298 − 283.9 = 14.1 < 14.142: inside the floor.
      final run = runWithPaces([283.9, 283.9, 283.9, 283.9], start: d2);
      final v = engine
          .analyze(
            run,
            priors: [prior('00000000-0000-4000-8000-000000000601', d1, 298)],
            now: fixedNow,
          )
          .verdict!;
      expect(v.headline, VerdictHeadline.noRealChange);
      expect(v.subline, contains('Inside what phone GPS can tell (14 s/km).'));
    });

    test('run 3+ delta of 10.5 is FASTER, 9.5 is HOLDING', () {
      final priors = [
        prior('00000000-0000-4000-8000-000000000611', d1, 298),
        prior('00000000-0000-4000-8000-000000000612', d2, 298),
      ];
      final f = engine
          .analyze(
            runWithPaces([287.5, 287.5, 287.5, 287.5], start: d3),
            priors: priors,
            now: fixedNow,
          )
          .verdict!;
      expect(f.headline, VerdictHeadline.faster);
      final h = engine
          .analyze(
            runWithPaces([288.5, 288.5, 288.5, 288.5], start: d3),
            priors: priors,
            now: fixedNow,
          )
          .verdict!;
      expect(h.headline, VerdictHeadline.holding);
    });

    test('miles convert the floor and paces', () {
      final run = fixture('preset_4x4_auto_standard').run;
      final mi = RunFile.fromJson(run.toJson()..['units'] = 'mi');
      final v = engine
          .analyze(
            mi,
            priors: [prior('00000000-0000-4000-8000-000000000621', d1, 298)],
            now: fixedNow,
          )
          .verdict!;
      expect(v.subline, contains('/mi'));
      expect(v.subline, contains('(23 s/mi)'));
    });

    test('a custom floor and band are stored on the verdict', () {
      const custom = RunEngine(
        constants: EngineConstants(runFloorSecPerKm: 8, repBandSecPerKm: 12),
      );
      final v = custom
          .analyze(fixture('preset_4x4_auto_standard').run, now: fixedNow)
          .verdict!;
      expect(v.floorSecPerKm, 8);
      expect(v.bandSecPerKm, 12);
    });
  });
}
