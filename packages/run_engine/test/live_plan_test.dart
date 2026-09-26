import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Phase 4 LC1 builder (plan §3.2): which boards a Start races and what
/// each board carries.
void main() {
  final day0 = DateTime.utc(2026, 6, 1, 6);
  const names = EventNames(parkrun: 'parkrun');

  /// A Free run with a 5K effort of [secs] and [km] from-start splits.
  LiveCandidate freeRun(
    int n,
    int secs, {
    int km = 10,
    int? k10,
    List<double?> kmHr = const [],
    List<FiredNudge> fired = const [],
  }) {
    final splits = [for (var k = 1; k <= km; k++) k * secs * 200];
    return LiveCandidate(
      BoardInput(
        runId: 'free-$n',
        date: day0.add(Duration(days: n)),
        mode: RunMode.free,
        efforts: {
          BestEffortDistance.k5: BestEffort(
            distance: BestEffortDistance.k5,
            elapsedMs: secs * 1000,
            startMs: 0,
            startOffsetM: 0,
            splitsMs: const [],
          ),
          if (k10 != null)
            BestEffortDistance.k10: BestEffort(
              distance: BestEffortDistance.k10,
              elapsedMs: k10 * 1000,
              startMs: 0,
              startOffsetM: 0,
              splitsMs: const [],
            ),
        },
      ),
      RunDerived(
        bestEfforts: RunBestEfforts(
          efforts: const {},
          fromStartSplitsMs: splits,
        ),
        live: LiveFigures(kmHr: kmHr),
        nudgesFired: fired,
      ),
    );
  }

  LiveCandidate intervals(int n, double pace, {String key = 'd400x*'}) =>
      LiveCandidate(
        BoardInput(
          runId: 'int-$n',
          date: day0.add(Duration(days: n)),
          mode: RunMode.intervals,
          comparisonKey: key,
          headlineSecPerKm: pace,
          verdictGrade: true,
        ),
        RunDerived(
          bestEfforts: RunBestEfforts.none,
          live: LiveFigures(repPacesSecPerKm: [pace, pace + 1, null]),
        ),
      );

  LiveCandidate cooper(int n, double vo2, List<double> minutes) =>
      LiveCandidate(
        BoardInput(
          runId: 'cooper-$n',
          date: day0.add(Duration(days: n)),
          mode: RunMode.cooper,
          comparisonKey: ComparisonKey.cooper,
          cooperVo2: vo2,
        ),
        RunDerived(
          bestEfforts: RunBestEfforts.none,
          live: LiveFigures(cooperMinuteM: minutes),
        ),
      );

  List<double> minutes(double perMin) => [
    for (var m = 1; m <= 12; m++) perMin * m,
  ];

  group('Free / Laps', () {
    test('5K then 10K boards, only entries with enough splits', () {
      final plan = LivePlanner.plan(
        mode: RunMode.free,
        runs: [
          freeRun(1, 1500, k10: 3100),
          freeRun(2, 1480, k10: 3050),
          freeRun(3, 1470, km: 5), // a 5K only: no 10K entry
        ],
      );
      expect(plan.boards.map((b) => b.key), ['be:5000', 'be:10000']);
      final k5 = plan.boards[0];
      expect(k5.kind, LiveBoardPlanKind.distance);
      expect(k5.targetM, 5000);
      expect(k5.entries.map((e) => e.runId), ['free-3', 'free-2', 'free-1']);
      expect(k5.entries.first.fromStartSplitsMs, hasLength(5));
      expect(k5.entries.first.finalMetric, 1470);
      expect(plan.boards[1].entries, hasLength(2));
      expect(plan.boards[1].entries.first.fromStartSplitsMs, hasLength(10));
    });

    test('a board with one entry is left out ("vs your only 5K" needs 2)', () {
      final plan = LivePlanner.plan(
        mode: RunMode.laps,
        runs: [freeRun(1, 1500)],
      );
      expect(plan.boards, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('an effort with no from-start splits never races live (WARN-1)', () {
      final plan = LivePlanner.plan(
        mode: RunMode.free,
        runs: [freeRun(1, 1500, km: 2), freeRun(2, 1480, km: 3)],
      );
      expect(plan.boards, isEmpty);
    });

    test('20-entry cap: the best 10 and the newest 10, deduped', () {
      // 30 runs: faster with age, so the best 10 are the oldest.
      final runs = [for (var n = 1; n <= 30; n++) freeRun(n, 1400 + n)];
      final k5 = LivePlanner.plan(mode: RunMode.free, runs: runs).boards.first;
      expect(k5.entries, hasLength(20));
      final ids = k5.entries.map((e) => e.runId).toSet();
      for (var n = 1; n <= 10; n++) {
        expect(ids, contains('free-$n'), reason: 'top 10');
      }
      for (var n = 21; n <= 30; n++) {
        expect(ids, contains('free-$n'), reason: 'newest 10');
      }
      // Overlap is deduped: 12 runs where top and newest overlap.
      final few = LivePlanner.plan(
        mode: RunMode.free,
        runs: [for (var n = 1; n <= 12; n++) freeRun(n, 1400 + n)],
      ).boards.first;
      expect(few.entries, hasLength(12));
    });
  });

  group('Intervals', () {
    final spec = SessionCatalogue.fourHundreds.defaults;

    test('the session key board with live rep paces', () {
      final plan = LivePlanner.plan(
        mode: RunMode.intervals,
        session: spec,
        runs: [
          intervals(1, 240),
          intervals(2, 236),
          intervals(3, 230, key: 't240x*'),
        ],
      );
      expect(plan.boards.single.key, spec.comparisonKey);
      expect(plan.boards.single.label, spec.name);
      expect(plan.boards.single.kind, LiveBoardPlanKind.intervals);
      expect(plan.boards.single.entries.map((e) => e.runId), [
        'int-2',
        'int-1',
      ]);
      expect(plan.boards.single.entries.first.liveRepPacesSecPerKm, [
        236,
        237,
        null,
      ]);
    });
  });

  group('the Saturday 5 km', () {
    final spec = SessionSpec.parkrun(names.parkrun);

    test('course board when known, labelled with the injected name', () {
      LiveCandidate course(int n, int secs) {
        final f = freeRun(n, secs, km: 5);
        return LiveCandidate(
          BoardInput(
            runId: 'park-$n',
            date: f.input.date,
            mode: RunMode.intervals,
            comparisonKey: 'parkrun:c-1',
            efforts: f.input.efforts,
          ),
          f.derived,
        );
      }

      final plan = LivePlanner.plan(
        mode: RunMode.intervals,
        session: spec,
        courseKey: 'parkrun:c-1',
        runs: [course(1, 1500), course(2, 1490)],
        names: names,
      );
      expect(plan.boards.single.key, 'parkrun:c-1');
      expect(plan.boards.single.label, 'parkrun');
      expect(plan.boards.single.targetM, 5000);
    });

    test('no course yet: the 5K board', () {
      final plan = LivePlanner.plan(
        mode: RunMode.intervals,
        session: spec,
        runs: [freeRun(1, 1500), freeRun(2, 1490)],
      );
      expect(plan.boards.single.key, 'be:5000');
    });
  });

  group('Cooper', () {
    test('board, curve (default before test 3, personal after), history', () {
      final one = LivePlanner.plan(
        mode: RunMode.cooper,
        runs: [cooper(1, 48, minutes(230))],
      );
      expect(one.boards, isEmpty, reason: 'one entry');
      expect(one.cooperCurve, CooperCurve.defaultCurve.fractions);
      expect(one.cooperHistory, [48]);

      final three = LivePlanner.plan(
        mode: RunMode.cooper,
        runs: [
          cooper(1, 48, minutes(230)),
          cooper(2, 50, minutes(235)),
          cooper(3, 49, minutes(232)),
        ],
      );
      expect(three.boards.single.key, ComparisonKey.cooper);
      expect(three.boards.single.entries.first.runId, 'cooper-2');
      expect(three.boards.single.entries.first.cooperMinuteM, hasLength(12));
      expect(three.cooperCurve, isNot(CooperCurve.defaultCurve.fractions));
      expect(three.cooperCurve!.last, 1);
      expect(three.cooperHistory, [48, 50, 49]);
    });
  });

  group('nudges (CR1 on the first board)', () {
    test('three even 5Ks: a fast-start rule for the 5K board', () {
      final plan = LivePlanner.plan(
        mode: RunMode.free,
        runs: [freeRun(1, 1500), freeRun(2, 1480), freeRun(3, 1470)],
      );
      expect(plan.boards.first.key, 'be:5000');
      final n = plan.nudges!;
      expect(n.fastStart, isNotNull);
      // The best 5K (1470 s) went out at 294 s a km; 4% quicker fires.
      expect(n.fastStart!.km1MaxMs, lessThan(294000));
      expect(n.fastStart!.text, contains('5K'));
    });

    test('two runs: no rule has enough history', () {
      final plan = LivePlanner.plan(
        mode: RunMode.free,
        runs: [freeRun(1, 1500), freeRun(2, 1480)],
      );
      expect(plan.boards, isNotEmpty);
      expect(plan.nudges, isNull);
    });

    group('Free past 5 km: the 10K board takes over (#70 review P3)', () {
      List<double?> hr(int km, double bpm) => [
        for (var k = 0; k < km; k++) bpm,
      ];

      test('HR drift km 1 to 5 off the 5K runs, km 6 on off the 10K runs', () {
        final plan = LivePlanner.plan(
          mode: RunMode.free,
          runs: [
            for (var n = 1; n <= 3; n++)
              freeRun(n, 1500, km: 5, kmHr: hr(5, 150)),
            for (var n = 4; n <= 6; n++)
              freeRun(n, 1500, k10: 3100, kmHr: hr(10, 160)),
          ],
        );
        expect([for (final b in plan.boards) b.key], ['be:5000', 'be:10000']);
        final kms = plan.nudges!.hrDrift!.kmSamples;
        expect(kms, hasLength(10));
        // The 5K board holds all six runs; the 10K board only the 10 km ones.
        expect(kms[4].map((p) => p.$2), containsAll([150.0, 160.0]));
        expect(kms[4], hasLength(6));
        for (var k = 5; k < 10; k++) {
          expect(kms[k].map((p) => p.$2).toSet(), {
            160.0,
          }, reason: 'km ${k + 1}');
        }
        expect(plan.nudges!.fastStart!.text, contains('5K'));
      });

      test('no 10K board: the 5K plan alone, 5 km long', () {
        final plan = LivePlanner.plan(
          mode: RunMode.free,
          runs: [
            for (var n = 1; n <= 3; n++)
              freeRun(n, 1500, km: 5, kmHr: hr(5, 150)),
          ],
        );
        expect(plan.nudges!.hrDrift!.kmSamples, hasLength(5));
      });

      test('blocked: the 5K board\'s pairs, plus the 10K\'s past km 5', () {
        final plan = LivePlanner.plan(
          mode: RunMode.free,
          runs: [
            for (var n = 1; n <= 3; n++)
              freeRun(n, 1500, km: 5, kmHr: hr(5, 150)),
            for (var n = 4; n <= 5; n++)
              freeRun(n, 1500, k10: 3100, kmHr: hr(10, 160)),
            freeRun(
              6,
              1500,
              k10: 3100,
              kmHr: hr(10, 160),
              fired: const [
                FiredNudge(NudgeRule.hrDrift, 4),
                FiredNudge(NudgeRule.hrDrift, 7),
              ],
            ),
          ],
        );
        // Run 6 is the newest on both boards: its km 4 comes via the 5K
        // board, its km 7 via the 10K board; neither is doubled.
        expect(plan.nudges!.blocked, ['hr_drift:4', 'hr_drift:7']);
      });

      test('Laps hands over the same way', () {
        final plan = LivePlanner.plan(
          mode: RunMode.laps,
          runs: [
            for (var n = 1; n <= 3; n++)
              freeRun(n, 1500, k10: 3100, kmHr: hr(10, 160)),
          ],
        );
        expect(plan.nudges!.hrDrift!.kmSamples, hasLength(10));
      });
    });

    test('Cooper never gets nudges', () {
      final plan = LivePlanner.plan(
        mode: RunMode.cooper,
        runs: [for (var n = 1; n <= 4; n++) cooper(n, 48.0 + n, minutes(230))],
      );
      expect(plan.boards, isNotEmpty);
      expect(plan.nudges, isNull);
    });
  });

  test('never more than 3 boards', () {
    expect(LivePlanner.maxBoards, 3);
  });
}
