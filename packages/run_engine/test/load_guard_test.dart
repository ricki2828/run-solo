import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

final now = DateTime(2026, 10, 14, 9); // a Wednesday

LoadRun run(
  int daysAgo, {
  double min = 40,
  double km = 6.5,
  double? pace,
  double? avgHr,
  double? cov,
  bool intervals = false,
  double? workPace,
}) => LoadRun(
  start: DateTime(2026, 10, 14 - daysAgo, 7),
  movingMin: min,
  distanceM: km * 1000,
  truePaceSecPerKm: pace,
  workTruePaceSecPerKm: workPace,
  isIntervals: intervals,
  avgHr: avgHr,
  hrCoverage: cov,
);

/// Three steady weeks of 3 runs (days 28..8), then [thisWeek] in the last 7.
List<LoadRun> steady({
  List<LoadRun> thisWeek = const [],
  double? pace,
  double km = 6.5,
}) => [
  for (final d in [27, 25, 23, 20, 18, 16, 13, 11, 9])
    run(d, pace: pace, km: km),
  ...thisWeek,
];

void main() {
  const vdot = 45.0;
  final th = BlockPaces.threshold(vdot)!;
  final easyPace = th * 1.25;

  group('weights', () {
    test('threshold pace is heavier than easy, on one 1-5 scale', () {
      final easy = LoadGuard.weight(
        run(0, pace: easyPace),
        maxHr: 190,
        vdot: vdot,
      );
      final hard = LoadGuard.weight(run(0, pace: th), maxHr: 190, vdot: vdot);
      expect(easy.$2, LoadBasis.pace);
      expect(easy.$1, closeTo(2, 0.1));
      expect(hard.$1, closeTo(4, 0.1));
    });

    test('heart rate wins when the strap covered the run', () {
      final w = LoadGuard.weight(
        run(0, pace: easyPace, avgHr: 0.85 * 190, cov: 0.95),
        maxHr: 190,
        vdot: vdot,
      );
      expect(w.$2, LoadBasis.heartRate);
      expect(w.$1, closeTo(4, 0.05));
    });

    test('a patchy strap falls back to pace, then to an assumed weight', () {
      expect(
        LoadGuard.weight(
          run(0, pace: easyPace, avgHr: 150, cov: 0.4),
          maxHr: 190,
          vdot: vdot,
        ).$2,
        LoadBasis.pace,
      );
      final none = LoadGuard.weight(run(0), maxHr: null, vdot: null);
      expect(none.$2, LoadBasis.assumed);
      expect(none.$1, 2.5);
    });

    test('weights stay inside 1 to 5', () {
      expect(
        LoadGuard.weight(run(0, pace: th * 0.5), maxHr: 190, vdot: vdot).$1,
        5,
      );
      expect(
        LoadGuard.weight(run(0, pace: th * 3), maxHr: 190, vdot: vdot).$1,
        1,
      );
    });

    test('intervals count the work reps for half the time', () {
      final w = LoadGuard.weight(
        run(0, intervals: true, pace: easyPace, workPace: th * 0.9),
        maxHr: null,
        vdot: vdot,
      );
      expect(w.$1, greaterThan(3));
      expect(w.$1, lessThan(5));
    });
  });

  group('check', () {
    test('not enough history is not a flag', () {
      expect(
        LoadGuard.check([run(1), run(2)], now: now, vdot: vdot).state,
        LoadState.notEnoughData,
      );
      // 3 runs, all inside the last 10 days: the usual week is not known yet.
      expect(
        LoadGuard.check([run(1), run(3), run(8)], now: now, vdot: vdot).state,
        LoadState.notEnoughData,
      );
    });

    test('a quiet runner is not judged on noise', () {
      final tiny = [
        for (final d in [27, 20, 13, 1]) run(d, min: 8, km: 1),
      ];
      expect(
        LoadGuard.check(tiny, now: now, vdot: vdot).state,
        LoadState.notEnoughData,
      );
    });

    test('a usual week is ok', () {
      final runs = steady(
        pace: easyPace,
        thisWeek: [
          run(5, pace: easyPace),
          run(3, pace: easyPace),
          run(1, pace: easyPace),
        ],
      );
      final c = LoadGuard.check(runs, now: now, vdot: vdot);
      expect(c.state, LoadState.ok);
      expect(c.flag, isNull);
      expect(c.loadRatio, inInclusiveRange(0.9, 1.2));
    });

    test('load more than 30% above usual flags, with the plain message', () {
      final runs = steady(
        pace: easyPace,
        thisWeek: [
          for (final d in [6, 5, 4, 3, 2, 1, 0])
            run(d, min: 55, km: 9, pace: easyPace),
        ],
      );
      final c = LoadGuard.check(runs, now: now, vdot: vdot);
      expect(c.state, LoadState.flagged);
      expect(c.flag!.trigger, LoadTrigger.load);
      expect(c.loadRatio, greaterThan(LoadGuard.loadRatio));
      expect(
        c.flag!.message,
        'This week is ${c.flag!.percent}% above your usual. '
        'An easy run today is the safer choice.',
      );
    });

    test('exactly at the line is not flagged; just over is', () {
      // 3 steady weeks of weight*min W; this week lands on the ratio.
      final base = steady(pace: easyPace);
      double acuteFor(double ratio) {
        final c = LoadGuard.check(base, now: now, vdot: vdot);
        return c.chronicWeekly * ratio;
      }

      // One run sized so (acute / chronicWeekly) hits the target, where the
      // chronic average itself includes that run.
      LoadCheck at(double target) {
        for (var min = 10.0; min < 600; min += 0.5) {
          final c = LoadGuard.check(
            [...base, run(0, min: min, km: 1, pace: easyPace)],
            now: now,
            vdot: vdot,
          );
          if (c.loadRatio! >= target) return c;
        }
        throw StateError('no size reached $target');
      }

      expect(acuteFor(1), greaterThan(0));
      final just = at(LoadGuard.loadRatio + 0.001);
      expect(just.state, LoadState.flagged);
      final under = LoadGuard.check(
        [...base, run(0, min: 20, km: 1, pace: easyPace)],
        now: now,
        vdot: vdot,
      );
      expect(under.loadRatio, lessThan(LoadGuard.loadRatio));
      expect(under.state, LoadState.ok);
    });

    test('distance up more than 25% flags even when load looks fine', () {
      // Same minutes, faster-but-light weights: distance is the trigger.
      final runs = steady(
        pace: easyPace,
        thisWeek: [
          run(5, min: 30, km: 14, pace: easyPace * 1.6),
          run(3, min: 30, km: 14, pace: easyPace * 1.6),
        ],
      );
      final c = LoadGuard.check(runs, now: now, vdot: vdot);
      expect(c.distanceRatio, greaterThan(LoadGuard.distanceRatio));
      expect(c.loadRatio, lessThanOrEqualTo(LoadGuard.loadRatio));
      expect(c.flag!.trigger, LoadTrigger.distance);
      expect(c.flag!.message, contains('more distance than your usual week'));
    });

    test('15 days of steady running is steady, not a spike', () {
      final runs = [
        for (final d in [14, 12, 10, 8, 6, 4, 2, 0]) run(d, pace: easyPace),
      ];
      final c = LoadGuard.check(runs, now: now, vdot: vdot);
      expect(c.state, LoadState.ok);
      expect(c.loadRatio, inInclusiveRange(0.8, 1.3));
    });

    test('a normal week back after three weeks off is not flagged', () {
      final runs = [
        // One old week, then nothing, then a normal week.
        for (final d in [27, 25, 23]) run(d, pace: easyPace),
        for (final d in [6, 4, 2]) run(d, pace: easyPace),
      ];
      expect(
        LoadGuard.check(runs, now: now, vdot: vdot).state,
        LoadState.notEnoughData,
      );
    });

    test('a spike on top of a short history is still caught', () {
      final runs = [
        for (final d in [14, 12, 10, 8]) run(d, pace: easyPace),
        for (final d in [6, 5, 4, 3, 2, 1, 0]) run(d, min: 70, pace: easyPace),
      ];
      expect(
        LoadGuard.check(runs, now: now, vdot: vdot).state,
        LoadState.flagged,
      );
    });

    test('a high ratio eases two sessions, a mild one eases one', () {
      const mild = LoadFlag(
        trigger: LoadTrigger.load,
        loadRatio: 1.4,
        distanceRatio: 1,
      );
      const high = LoadFlag(
        trigger: LoadTrigger.load,
        loadRatio: 1.6,
        distanceRatio: 1,
      );
      expect(mild.easeCount, 1);
      expect(high.easeCount, 2);
      expect(mild.percent, 40);
    });

    test('rules text states both thresholds and the research label', () {
      expect(LoadGuard.rules, contains('30%'));
      expect(LoadGuard.rules, contains('25%'));
      expect(LoadGuard.rules, contains('research'));
      expect(LoadGuard.rules, contains('never blocks'));
      expect(LoadGuard.rules, isNot(contains('—')));
    });

    test('week key is the Monday', () {
      expect(LoadGuard.weekKey(DateTime(2026, 10, 14)), '2026-10-12');
      expect(LoadGuard.weekKey(DateTime(2026, 10, 12)), '2026-10-12');
      expect(LoadGuard.weekKey(DateTime(2026, 10, 18, 23)), '2026-10-12');
      expect(LoadGuard.weekKey(DateTime(2026, 10, 19)), '2026-10-19');
    });
  });

  group('plan softening', () {
    final start = DateTime(2026, 10, 12);
    final plan = BlockPlanner.build(
      lane: IdentityLane.aerobic,
      perWeek: 4,
      start: start,
    );

    test('a flag eases the next session; the plan says why', () {
      const flag = LoadFlag(
        trigger: LoadTrigger.load,
        loadRatio: 1.4,
        distanceRatio: 1,
      );
      final v = BlockResolver.resolve(plan, [], now: start, load: flag);
      expect(v.next!.softened, isTrue);
      expect(v.next!.session.kind, BlockKind.easy);
      expect(v.next!.session.reason, flag.planReason);
      expect(v.weeks[0][1].softened, isFalse);
    });

    test('a high flag eases two, and skips the test', () {
      const high = LoadFlag(
        trigger: LoadTrigger.load,
        loadRatio: 1.6,
        distanceRatio: 1,
      );
      final v = BlockResolver.resolve(plan, [], now: start, load: high);
      expect(v.weeks[0][0].softened, isTrue);
      expect(v.weeks[0][1].softened, isTrue);
      expect(v.weeks[0][2].softened, isFalse);
      final week4 = start.add(const Duration(days: 21));
      final runs = [
        for (var w = 0; w < 3; w++)
          PlanRun(
            id: 'r$w',
            start: start.add(Duration(days: 7 * w, hours: 7)),
            movingMs: 40 * 60000,
            distanceM: 6000,
            kind: PlanRunKind.other,
          ),
      ];
      final v4 = BlockResolver.resolve(plan, runs, now: week4, load: high);
      expect(v4.next!.session.isTest, isTrue);
      expect(v4.next!.softened, isFalse);
    });

    test('no flag, no change: same view as before', () {
      final a = BlockResolver.resolve(plan, [], now: start);
      final b = BlockResolver.resolve(plan, [], now: start, load: null);
      expect(
        [for (final s in a.all) s.session.toJson().toString()],
        [for (final s in b.all) s.session.toJson().toString()],
      );
      expect(a.next!.softened, isFalse);
    });

    test(
      'a very hard run and a flag together ease once, with the run reason',
      () {
        final th = BlockPaces.threshold(45)!;
        final runs = [
          PlanRun(
            id: 'hard',
            start: start.add(const Duration(hours: 7)),
            movingMs: 35 * 60000,
            distanceM: 7000,
            kind: PlanRunKind.other,
            truePaceSecPerKm: th * 0.97,
          ),
        ];
        const flag = LoadFlag(
          trigger: LoadTrigger.load,
          loadRatio: 1.4,
          distanceRatio: 1,
        );
        final v = BlockResolver.resolve(
          plan,
          runs,
          now: start.add(const Duration(days: 1)),
          vdot: 45,
          load: flag,
        );
        expect(v.next!.session.reason, contains('very hard'));
        expect(v.weeks[0].where((s) => s.softened), hasLength(1));
      },
    );
  });
}
