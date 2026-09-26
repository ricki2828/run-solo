import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 4 CR1 (plan §3.5, §3.6): the NudgePlan the engine hands native,
/// the after-run observation and suggestion, research norms and their
/// labels. Every rule has "never fires" cases.
void main() {
  const rules = CoachingRules();
  const reporter = CoachReporter();
  final day0 = DateTime.utc(2026, 8, 1, 6);
  DateTime day(int n) => day0.add(Duration(days: n));

  /// A Free run with even-ish from-start km splits (ms per km) and HR per km.
  CoachRun distanceRun(
    String id,
    int n,
    List<int> kmMs, {
    List<double?> kmHr = const [],
    List<FiredNudge> fired = const [],
    int? durationMs,
  }) {
    final cum = <int>[];
    var t = 0;
    for (final k in kmMs) {
      t += k;
      cum.add(t);
    }
    final efforts = <BestEffortDistance, BestEffort>{
      if (cum.length >= 5)
        BestEffortDistance.k5: BestEffort(
          distance: BestEffortDistance.k5,
          elapsedMs: cum[4],
          startMs: 0,
          startOffsetM: 0,
          splitsMs: cum.sublist(0, 4),
        ),
      if (cum.length >= 10)
        BestEffortDistance.k10: BestEffort(
          distance: BestEffortDistance.k10,
          elapsedMs: cum[9],
          startMs: 0,
          startOffsetM: 0,
          splitsMs: cum.sublist(0, 9),
        ),
    };
    return CoachRun(
      runId: id,
      date: day(n),
      mode: RunMode.free,
      durationMs: durationMs ?? t,
      derived: RunDerived(
        bestEfforts: RunBestEfforts(efforts: efforts, fromStartSplitsMs: cum),
        live: LiveFigures(kmHr: kmHr),
        nudgesFired: fired,
      ),
    );
  }

  CoachRun session(
    String id,
    int n,
    List<double?> repPaces, {
    String key = 't240x*',
    List<FiredNudge> fired = const [],
  }) => CoachRun(
    runId: id,
    date: day(n),
    mode: RunMode.intervals,
    comparisonKey: key,
    durationMs: 40 * 60000,
    derived: RunDerived(
      bestEfforts: RunBestEfforts.none,
      live: LiveFigures(repPacesSecPerKm: repPaces),
      nudgesFired: fired,
    ),
  );

  CoachRun cooper(String id, int n, double vo2) => CoachRun(
    runId: id,
    date: day(n),
    mode: RunMode.cooper,
    comparisonKey: ComparisonKey.cooper,
    durationMs: 720000,
    cooperVo2: vo2,
    derived: const RunDerived(bestEfforts: RunBestEfforts.none),
  );

  List<int> even(int kms, int ms) => List.filled(kms, ms);

  group('NudgePlan: distance board', () {
    test('never fires with fewer than 3 ghosts on the board', () {
      expect(
        rules.forDistanceBoard(
          boardKm: 5,
          boardLabel: '5K',
          history: [
            distanceRun('a', 0, even(5, 300000)),
            distanceRun('b', 5, even(5, 300000)),
            distanceRun('c', 9, even(3, 300000)), // too short: not a ghost
          ],
        ),
        isNull,
      );
    });

    test('fast start: 4% under an even PB km 1; label injected', () {
      final plan = rules.forDistanceBoard(
        boardKm: 5,
        boardLabel: '5K time trial',
        history: [
          distanceRun('a', 0, even(5, 310000)),
          distanceRun('pb', 5, even(5, 300000)),
          distanceRun('c', 9, even(5, 305000)),
        ],
      )!;
      expect(plan.fastStart!.km1MaxMs, 288000);
      expect(
        plan.fastStart!.text,
        'Fast start. Ease off a little. Your best 5K time trial started slower.',
      );
      expect(plan.repFade, isNull);
    });

    test('never a fast-start rule when the PB itself went out fast', () {
      final plan = rules.forDistanceBoard(
        boardKm: 5,
        boardLabel: '5K',
        history: [
          distanceRun('a', 0, even(5, 310000)),
          // km 1 is 3.3% under this PB's average km: not an even PB.
          distanceRun('pb', 5, [290000, 302500, 302500, 302500, 302500]),
          distanceRun('c', 9, even(5, 305000)),
        ],
      );
      expect(plan?.fastStart, isNull);
    });

    test('HR drift: prior (pace, HR) pairs per km from km 4', () {
      List<double?> hr(double base) => [base, base, base, base + 2, base + 4];
      final plan = rules.forDistanceBoard(
        boardKm: 5,
        boardLabel: '5K',
        history: [
          distanceRun('a', 0, even(5, 300000), kmHr: hr(150)),
          distanceRun('b', 5, even(5, 310000), kmHr: hr(152)),
          distanceRun('c', 9, even(5, 305000), kmHr: hr(154)),
        ],
      )!;
      final h = plan.hrDrift!;
      expect(h.kmSamples.take(3), everyElement(isEmpty));
      expect(h.kmSamples[3], [(300.0, 152.0), (310.0, 154.0), (305.0, 156.0)]);
      expect(
        h.text,
        "Heart rate's up for this pace today. Fine to ease a touch.",
      );
      // Median HR of the similar-pace runs at km 4 is 154: fires at 159.
      expect(h.firesAt(4, paceSecPerKm: 305, hr: 159), isTrue);
      expect(h.firesAt(4, paceSecPerKm: 305, hr: 158), isFalse);
      expect(h.firesAt(3, paceSecPerKm: 305, hr: 190), isFalse, reason: 'km 3');
    });

    test('HR drift with mixed easy and hard history compares like with '
        'like (#56 review P2)', () {
      List<double?> hr(double v) => [v, v, v, v, v];
      final plan = rules.forDistanceBoard(
        boardKm: 5,
        boardLabel: '5K',
        history: [
          // Three hard 5Ks at 4:30 and HR 170, three easy ones at 6:00, 140.
          for (var i = 0; i < 3; i++)
            distanceRun('hard$i', i * 2, even(5, 270000), kmHr: hr(170)),
          for (var i = 0; i < 3; i++)
            distanceRun('easy$i', i * 2 + 1, even(5, 360000), kmHr: hr(140)),
        ],
      )!;
      final h = plan.hrDrift!;
      // An easy run at 6:00 with HR 150 is 10 bpm over its like: fires.
      expect(h.firesAt(4, paceSecPerKm: 360, hr: 150), isTrue);
      // A hard run at 4:30 with HR 172 is only 2 over: never fires. (A
      // median of all six, 155 bpm at 5:15, would have fired here.)
      expect(h.firesAt(4, paceSecPerKm: 270, hr: 172), isFalse);
      // A pace nobody ran (5:15): fewer than 3 similar, never fires.
      expect(h.firesAt(4, paceSecPerKm: 315, hr: 200), isFalse);
    });

    test('never an HR rule without a strap on 3 ghosts', () {
      final plan = rules.forDistanceBoard(
        boardKm: 5,
        boardLabel: '5K',
        history: [
          distanceRun('a', 0, even(5, 300000), kmHr: [150, 150, 150, 150, 150]),
          distanceRun('b', 5, even(5, 310000)),
          distanceRun('c', 9, even(5, 305000)),
        ],
      );
      expect(plan?.hrDrift, isNull);
    });

    test('the previous run\'s nudges are blocked (WARN-5)', () {
      final plan = rules.forDistanceBoard(
        boardKm: 5,
        boardLabel: '5K',
        history: [
          // Not a 5K ghost (3 km): its nudges are another board's.
          distanceRun(
            'short',
            12,
            even(3, 300000),
            fired: const [FiredNudge(NudgeRule.hrDrift, 2)],
          ),
          distanceRun(
            'old',
            0,
            even(5, 300000),
            fired: const [FiredNudge(NudgeRule.hrDrift, 5)],
          ),
          distanceRun('b', 5, even(5, 310000)),
          distanceRun(
            'last',
            9,
            even(5, 305000),
            fired: const [FiredNudge(NudgeRule.fastStart, 1)],
          ),
        ],
      )!;
      expect(plan.blocked, ['fast_start:1']);
      final json = plan.toJson();
      expect(json.keys, [
        'version',
        'fastStart',
        'repFade',
        'hrDrift',
        'blocked',
      ]);
      expect(json['version'], 1);
    });
  });

  test('shared Dart/Kotlin hrDrift vectors (fixtures/phase4/'
      'hr_drift_vectors.json, from native #62)', () {
    final fx = jsonDecode(
      File('test/fixtures/phase4/hr_drift_vectors.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final plans = {
      for (final e in (fx['plans']! as Map<String, Object?>).entries)
        e.key: HrDriftRule.fromJson(e.value! as Map<String, Object?>),
    };
    final cases = (fx['cases']! as List).cast<Map<String, Object?>>();
    expect(cases, hasLength(14));
    for (final c in cases) {
      final rule = plans[c['plan']]!;
      expect(
        rule.firesAt(
          c['km']! as int,
          paceSecPerKm: (c['pace']! as num).toDouble(),
          hr: (c['hr']! as num).toDouble(),
        ),
        c['fires'],
        reason: jsonEncode(c),
      );
    }
    // Round trip: the engine's JSON is the fixture's shape.
    final again = HrDriftRule.fromJson(plans['median_154']!.toJson());
    expect(again.kmSamples, plans['median_154']!.kmSamples);
  });

  group('NudgePlan: interval board', () {
    test('never fires with fewer than 3 sessions', () {
      expect(
        rules.forIntervalBoard(
          key: 't240x*',
          history: [
            session('a', 0, [260, 262, 265, 268]),
            session('b', 5, [258, 262, 264, 266]),
          ],
        ),
        isNull,
      );
    });

    test('threshold = max(key floor, your usual fade at that rep); reps 1-2 '
        'never fire', () {
      final plan = rules.forIntervalBoard(
        key: 't240x*',
        history: [
          session('a', 0, [260, 262, 262, 272]),
          session('b', 5, [260, 263, 264, 275]),
          session('c', 9, [260, 262, 266, 280]),
        ],
      )!;
      final d = plan.repFade!.maxDropSecPerKm;
      expect(d[0], isNull);
      expect(d[1], isNull);
      expect(d[2], 10, reason: 'usual 4 s/km is under the 10 s/km floor');
      expect(d[3], 15, reason: 'usual 15 s/km is over the floor');
      expect(plan.fastStart, isNull);
    });

    test('an unclean rep never counts toward the usual fade', () {
      final plan = rules.forIntervalBoard(
        key: 't240x*',
        history: [
          session('a', 0, [260, 262, null, 272]),
          session('b', 5, [260, 263, null, 275]),
          session('c', 9, [260, 262, 266, 280]),
        ],
      )!;
      expect(plan.repFade!.maxDropSecPerKm[2], isNull);
    });
  });

  group('after-run observation', () {
    // 10 km at 300 s/km, the last 5 km at 312: 4% second-half fade.
    List<int> faded(int base, double fade) => [
      for (var i = 0; i < 5; i++) base,
      for (var i = 0; i < 5; i++) (base * (1 + fade)).round(),
    ];

    test('fade vs your usual', () {
      final history = [
        distanceRun('a', 0, faded(300000, 0.02)),
        distanceRun('b', 5, faded(300000, 0.02)),
        distanceRun('c', 9, faded(300000, 0.02)),
      ];
      final r = reporter.report(
        run: distanceRun('now', 12, faded(300000, 0.05)),
        history: history,
      );
      expect(
        r.observation!.text,
        'You slowed 5% in the second half. Your usual is 2%.',
      );
      final evener = reporter.report(
        run: distanceRun('now', 12, even(10, 300000)),
        history: [
          for (final h in history)
            distanceRun(
              h.runId,
              h.date.difference(day0).inDays,
              faded(300000, 0.04),
            ),
        ],
      );
      expect(
        evener.observation!.text,
        'You ran even halves. Your usual is 4% slower in the second half.',
      );
    });

    test('evener than usual, and a negative split', () {
      final history = [
        distanceRun('a', 0, faded(300000, 0.04)),
        distanceRun('b', 5, faded(300000, 0.04)),
        distanceRun('c', 9, faded(300000, 0.04)),
      ];
      expect(
        reporter
            .report(
              run: distanceRun('now', 12, faded(300000, 0.02)),
              history: history,
            )
            .observation!
            .text,
        'Evener than usual: 2% slower in the second half, your usual is 4%.',
      );
      expect(
        reporter
            .report(
              run: distanceRun('now', 12, faded(300000, -0.02)),
              history: history,
            )
            .observation!
            .text,
        'You finished faster than you started. Your usual is 4% slower in '
        'the second half.',
      );
    });

    test('never says anything within a point of your usual', () {
      final r = reporter.report(
        run: distanceRun('now', 12, faded(300000, 0.025)),
        history: [
          distanceRun('a', 0, faded(300000, 0.02)),
          distanceRun('b', 5, faded(300000, 0.02)),
          distanceRun('c', 9, faded(300000, 0.02)),
        ],
      );
      expect(r.observation, isNull);
    });

    test('no usual yet: the qualitative research line, labelled', () {
      final r = reporter.report(
        run: distanceRun('now', 12, faded(300000, 0.05)),
        history: const [],
      );
      expect(r.observation!.researchBased, isTrue);
      expect(r.observation!.text, ResearchNorms.fadeNormLine);
      expect(
        reporter
            .report(
              run: distanceRun('now', 12, even(10, 300000)),
              history: const [],
            )
            .observation,
        isNull,
        reason: 'an even run needs no norm',
      );
    });
  });

  group('suggestions (one at most, never a schedule)', () {
    List<int> faded(double f) => [
      for (var i = 0; i < 5; i++) 300000,
      for (var i = 0; i < 5; i++) (300000 * (1 + f)).round(),
    ];

    test('Zone 2 only on a fade in 2 of the last 3 10Ks and no long run', () {
      final history = [
        distanceRun('a', 0, faded(0.05)),
        distanceRun('b', 7, faded(0.0)),
      ];
      final r = reporter.report(
        run: distanceRun('now', 14, faded(0.05)),
        history: history,
      );
      expect(r.suggestion!.kind, SuggestionKind.zone2LongRun);
      expect(
        r.suggestion!.text,
        'Try a longer easy run this week, Zone 2, 60 to 75 min.',
      );
    });

    test('never Zone 2 off one faded run (science review)', () {
      final r = reporter.report(
        run: distanceRun('now', 14, faded(0.05)),
        history: [
          distanceRun('a', 0, faded(0.0)),
          distanceRun('b', 7, faded(0.0)),
        ],
      );
      expect(r.suggestion, isNull);
      expect(
        reporter
            .report(run: distanceRun('now', 14, faded(0.08)), history: const [])
            .suggestion,
        isNull,
      );
    });

    test('never Zone 2 with a 60-minute run in the last 4 weeks', () {
      final r = reporter.report(
        run: distanceRun('now', 14, faded(0.05)),
        history: [
          distanceRun('a', 0, faded(0.05)),
          distanceRun('b', 7, faded(0.05)),
          distanceRun('long', 10, even(12, 330000), durationMs: 66 * 60000),
        ],
      );
      expect(r.suggestion, isNull);
    });

    test('fewer reps on a rep fade in 3 of the last 4 sessions', () {
      final r = reporter.report(
        run: session('now', 20, [260, 262, 268, 275]),
        history: [
          session('a', 0, [260, 262, 268, 275]),
          session('b', 5, [260, 262, 263, 264]),
          session('c', 10, [260, 262, 268, 280]),
        ],
      );
      expect(r.suggestion!.kind, SuggestionKind.fewerReps);
      expect(r.suggestion!.key, 't240x*');
      expect(
        reporter
            .report(
              run: session('now', 20, [260, 262, 268, 275]),
              history: [
                session('a', 0, [260, 262, 263, 264]),
                session('b', 5, [260, 262, 263, 264]),
                session('c', 10, [260, 262, 268, 280]),
              ],
            )
            .suggestion,
        isNull,
        reason: '2 of 4 is not a pattern',
      );
    });

    test('Norwegian 4x4 after 3 flat Cooper tests', () {
      final r = reporter.report(
        run: cooper('now', 30, 48.4),
        history: [cooper('a', 0, 48.0), cooper('b', 14, 48.9)],
      );
      expect(r.suggestion!.kind, SuggestionKind.norwegian4x4);
      expect(
        reporter
            .report(
              run: cooper('now', 30, 50.5),
              history: [cooper('a', 0, 48.0), cooper('b', 14, 48.9)],
            )
            .suggestion,
        isNull,
      );
    });

    test('the Home card clears once the suggested session type is run', () {
      const z2 = CoachSuggestion(
        SuggestionKind.zone2LongRun,
        CoachSuggestion.zone2Text,
      );
      expect(z2.doneBy(distanceRun('x', 0, even(12, 330000))), isTrue);
      expect(z2.doneBy(distanceRun('x', 0, even(5, 300000))), isFalse);
      const n = CoachSuggestion(
        SuggestionKind.norwegian4x4,
        CoachSuggestion.norwegianText,
      );
      expect(n.doneBy(session('x', 0, [260])), isTrue);
    });
  });

  group('research norms and labels (WARN-4)', () {
    test('"People your age" stays off until the table is read', () {
      expect(ResearchNorms.peopleYourAgeEnabled, isFalse);
      expect(ResearchNorms.peopleYourAge(vo2: 48, age: 45), isNull);
      expect(ResearchNorms.fadeNormPercent, isNull);
    });

    test('research-derived lines carry a marker; no em dashes anywhere', () {
      for (final s in [
        ResearchNorms.fadeNormLine,
        ResearchNorms.peopleYourAgeSource,
      ]) {
        expect(carriesEstimateMarker(s), isTrue, reason: s);
      }
      for (final s in [
        ResearchNorms.fadeNormLine,
        ResearchNorms.peopleYourAgeSource,
        CoachingRules.fastStartText('5K'),
        CoachingRules.repFadeText,
        CoachingRules.hrDriftText,
        CoachSuggestion.zone2Text,
        CoachSuggestion.fewerRepsText,
        CoachSuggestion.norwegianText,
      ]) {
        expect(s.contains('\u2014'), isFalse, reason: s);
      }
      // Spoken nudges are their own line since #80, so the per-line budget
      // (WARN-2, 16 words) applies; keep them short.
      for (final s in [
        CoachingRules.fastStartText('5K time trial'),
        CoachingRules.repFadeText,
        CoachingRules.hrDriftText,
      ]) {
        expect(s.split(' ').length, lessThanOrEqualTo(16), reason: s);
      }
    });
  });

  test('km HR: plain mean of HR samples in the km; null under half '
      'coverage (the rule native mirrors)', () {
    final samples = [
      for (var t = 0; t <= 600; t++)
        Sample(
          tMs: t * 1000,
          lat: -33.87,
          lon: 151.21,
          accM: 5,
          distM: t * 4.0,
          // km 1 (0-250 s): HR 150; km 2 (250-500 s): strap drops for 60%.
          hr: t < 250 ? 150 : (t < 400 ? null : 160),
        ),
    ];
    final run = RunFile(
      id: '00000000-0000-4000-8000-0000000000c1',
      device: 'test',
      app: 'test',
      start: fixedNow,
      end: fixedNow.add(const Duration(seconds: 600)),
      tz: 'UTC',
      mode: RunMode.free,
      units: Units.km,
      laps: const [],
      samples: samples,
    );
    final d = RunDerived.of(run, engine.analyze(run, now: fixedNow));
    expect(d.bestEfforts.fromStartSplitsMs.take(2), [250000, 500000]);
    expect(d.live.kmHr[0], 150);
    expect(d.live.kmHr[1], isNull);
  });

  test('live figures carry per-km HR from Start (for HR drift)', () {
    final f = fixture('easy_free_run');
    final a = engine.analyze(f.run, now: fixedNow);
    final d = RunDerived.of(f.run, a);
    final splits = d.bestEfforts.fromStartSplitsMs;
    expect(splits, isNotEmpty);
    expect(d.live.kmHr, hasLength(splits.length));
    expect(d.live.kmHr.whereType<double>(), isNotEmpty);
  });

  // Shared with core-jvm SpokenCopyFixtureTest (#79 review).
  test(
    'fixtures/phase4/spoken_copy.json: the fast start is an instruction',
    () {
      final fx = jsonDecode(
        File('test/fixtures/phase4/spoken_copy.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final lines = (fx['fastStart']! as Map).cast<String, String>();
      expect(lines, isNotEmpty);
      for (final MapEntry(key: label, value: line) in lines.entries) {
        expect(CoachingRules.fastStartText(label), line);
        expect(line, startsWith('Fast start. Ease off'));
        expect(line.split(RegExp(r'\s+')).length, lessThanOrEqualTo(16));
        expect(line, isNot(contains('\u2014')));
      }
    },
  );
}
