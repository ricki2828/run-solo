import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

final start = DateTime(2026, 10, 5); // a Monday

BlockPlan build(IdentityLane lane, int n, {BlockBaseline? b}) =>
    BlockPlanner.build(
      lane: lane,
      perWeek: n,
      start: start,
      baseline: b ?? const BlockBaseline(),
    );

PlanRun steady(
  String id,
  DateTime at, {
  int min = 35,
  double? pace,
  double? m,
}) => PlanRun(
  id: id,
  start: at,
  movingMs: min * 60000,
  distanceM: m ?? min * 160.0,
  kind: PlanRunKind.other,
  truePaceSecPerKm: pace,
);

PlanRun interval(String id, DateTime at, String template) => PlanRun(
  id: id,
  start: at,
  movingMs: 40 * 60000,
  distanceM: 6000,
  kind: PlanRunKind.intervals,
  templateId: template,
);

void main() {
  group('build', () {
    for (final lane in IdentityLane.values) {
      for (var n = 2; n <= 6; n++) {
        test('${lane.name} x$n: 4 weeks, $n a week, test in week 4', () {
          final p = build(lane, n);
          for (var w = 1; w <= 4; w++) {
            expect(p.sessions.where((s) => s.week == w), hasLength(n));
          }
          final tests = p.sessions.where((s) => s.isTest).toList();
          expect(tests, hasLength(1));
          expect(tests.single.week, 4);
          expect(tests.single.role, BlockRole.key);
          expect(p.sessions.every((s) => s.reason.isNotEmpty), isTrue);
          expect(
            p.sessions.any((s) => s.reason.contains('—')),
            isFalse,
            reason: 'no em dashes in user copy',
          );
          // One session per day, in order.
          for (var w = 1; w <= 4; w++) {
            final days = [
              for (final s in p.sessions)
                if (s.week == w) s.dayOffset,
            ];
            expect(days.toSet(), hasLength(n));
            expect(days, [...days]..sort());
          }
        });
      }
    }

    test('reps stay inside each preset range', () {
      for (final lane in IdentityLane.values) {
        for (final s in build(lane, 6).sessions) {
          if (s.kind != BlockKind.interval) continue;
          final p = SessionCatalogue.byId(s.presetId!)!;
          expect(s.reps, inInclusiveRange(p.minReps!, p.maxReps!));
        }
      }
    });

    test('progressive then lighter: AEROBIC key reps 3,4,5 then test 4', () {
      final keys = build(
        IdentityLane.aerobic,
        3,
      ).sessions.where((s) => s.role == BlockRole.key).toList();
      expect(keys.map((s) => s.reps), [3, 4, 5, 4]);
      expect(keys.last.presetId, SessionSpec.norwegian4x4Id);
    });

    test('week 4 is lighter for AEROBIC, week 3 for LONG', () {
      int longMin(BlockPlan p, int w) => p.sessions
          .firstWhere((s) => s.week == w && s.kind == BlockKind.long)
          .minutes!;
      final a = build(IdentityLane.aerobic, 3);
      expect(longMin(a, 4), lessThan(longMin(a, 3)));
      final l = build(IdentityLane.long, 3);
      expect(longMin(l, 3), lessThan(longMin(l, 2)));
      final test = l.sessions.firstWhere((s) => s.isTest);
      expect(test.minDistanceM, 15000);
    });

    test('tests per lane re-measure that lane', () {
      expect(
        build(
          IdentityLane.speed,
          3,
        ).sessions.firstWhere((s) => s.isTest).presetId,
        '400s',
      );
      expect(
        build(IdentityLane.mid, 3).sessions.firstWhere((s) => s.isTest).goalId,
        'd5000',
      );
    });

    test('baseline sizes easy and long runs', () {
      final p = build(
        IdentityLane.aerobic,
        3,
        b: const BlockBaseline(typicalRunMin: 50),
      );
      expect(
        p.sessions
            .firstWhere((s) => s.kind == BlockKind.easy && s.week == 1)
            .minutes,
        50,
      );
      expect(
        p.sessions
            .firstWhere((s) => s.kind == BlockKind.long && s.week == 1)
            .minutes,
        75,
      );
    });

    test('perWeek is clamped to 2..6', () {
      expect(build(IdentityLane.mid, 1).perWeek, 2);
      expect(build(IdentityLane.mid, 9).perWeek, 6);
    });
  });

  group('json', () {
    test('round trips', () {
      final p = build(IdentityLane.speed, 4);
      final back = BlockPlan.tryParse(p.toJson())!;
      expect(back.toJson(), p.toJson());
    });

    test('damaged or newer files read as no plan', () {
      expect(BlockPlan.tryParse(null), isNull);
      expect(BlockPlan.tryParse({'schema': 99}), isNull);
      expect(BlockPlan.tryParse({'schema': 1, 'lane': 'x'}), isNull);
      final j = build(IdentityLane.mid, 3).toJson();
      (j['sessions'] as List)[0] = {'id': 'x'};
      expect(BlockPlan.tryParse(j), isNull);
    });
  });

  group('resolve', () {
    final plan = build(IdentityLane.aerobic, 3); // key, easy, long
    final key1 = plan.sessions.first;

    test('fresh plan: first session is next, nothing done', () {
      final v = BlockResolver.resolve(plan, [], now: start);
      expect(v.currentWeek, 1);
      expect(v.next!.session.id, 'w1s1');
      expect(v.next!.status, BlockStatus.next);
      expect(v.weekDone, 0);
      expect(v.weekTotal, 3);
      expect(v.nextIsNextWeek, isFalse);
    });

    test('a 4x4 ticks the key, an easy run ticks the easy one', () {
      final runs = [
        interval('a', start.add(const Duration(hours: 7)), key1.presetId!),
        steady('b', start.add(const Duration(days: 1, hours: 7))),
      ];
      final v = BlockResolver.resolve(
        plan,
        runs,
        now: start.add(const Duration(days: 2)),
      );
      expect(v.weeks[0][0].status, BlockStatus.done);
      expect(v.weeks[0][0].runId, 'a');
      expect(v.weeks[0][1].status, BlockStatus.done);
      expect(v.weekDone, 2);
      expect(v.next!.session.kind, BlockKind.long);
    });

    test('a run before the plan started does not count', () {
      final v = BlockResolver.resolve(plan, [
        interval(
          'old',
          start.subtract(const Duration(days: 1)),
          key1.presetId!,
        ),
      ], now: start);
      expect(v.weekDone, 0);
    });

    test('another interval type does not tick the key session', () {
      final v = BlockResolver.resolve(plan, [
        interval('x', start.add(const Duration(hours: 7)), '400s'),
      ], now: start.add(const Duration(days: 1)));
      expect(v.weeks[0][0].status, isNot(BlockStatus.done));
    });

    test('one run ticks one session only', () {
      final v = BlockResolver.resolve(plan, [
        steady('b', start.add(const Duration(hours: 7)), min: 90),
      ], now: start.add(const Duration(days: 1)));
      expect(v.weekDone, 1);
    });

    test('missed session is dropped, never crammed into the next week', () {
      // Week 1: only the key done. Week 2 now.
      final runs = [
        interval('a', start.add(const Duration(hours: 7)), key1.presetId!),
      ];
      final now = start.add(const Duration(days: 8));
      final v = BlockResolver.resolve(plan, runs, now: now);
      expect(v.currentWeek, 2);
      expect(v.weeks[0][1].status, BlockStatus.missed);
      expect(v.weeks[0][2].status, BlockStatus.missed);
      expect(
        v.weeks[1].where((s) => s.status != BlockStatus.missed),
        hasLength(3),
      );
      expect(v.weekTotal, 3);
      expect(v.shifts, 0);
    });

    test('too few days left: lowest priority is skipped, key kept', () {
      final p6 = build(IdentityLane.aerobic, 6);
      // Day 5 of week 1 (Sat) with nothing done: 2 days left (Sat, Sun).
      final v = BlockResolver.resolve(
        p6,
        [],
        now: start.add(const Duration(days: 5, hours: 8)),
      );
      final live = v.weeks[0].where((s) => s.status != BlockStatus.missed);
      expect(live, hasLength(2));
      expect(live.any((s) => s.session.role == BlockRole.key), isTrue);
      expect(live.any((s) => s.session.role == BlockRole.support), isTrue);
    });

    test('a week with nothing done shifts the block back, twice at most', () {
      var v = BlockResolver.resolve(
        plan,
        [],
        now: start.add(const Duration(days: 7)),
      );
      expect(v.shifts, 1);
      expect(v.currentWeek, 1);
      expect(v.weeks[0].first.date, DateTime(2026, 10, 12));
      v = BlockResolver.resolve(
        plan,
        [],
        now: start.add(const Duration(days: 28)),
      );
      expect(v.shifts, BlockPlanner.maxShifts);
    });

    test('block ends after week 4', () {
      final v = BlockResolver.resolve(
        plan,
        [],
        now: start.add(const Duration(days: 60)),
      );
      expect(v.currentWeek, isNull);
      expect(v.finished, isTrue);
      expect(v.next, isNull);
    });

    test('nothing left this week: next is next week, flagged', () {
      final runs = [
        interval('a', start.add(const Duration(hours: 7)), key1.presetId!),
        steady('b', start.add(const Duration(days: 1, hours: 7))),
        steady('c', start.add(const Duration(days: 2, hours: 7)), min: 80),
      ];
      final v = BlockResolver.resolve(
        plan,
        runs,
        now: start.add(const Duration(days: 3)),
      );
      expect(v.weekDone, 3);
      expect(v.next!.session.week, 2);
      expect(v.nextIsNextWeek, isTrue);
    });

    test('very hard steady run makes the next session easier', () {
      const vdot = 45.0;
      final th = BlockPaces.threshold(vdot)!;
      final runs = [
        steady(
          'hard',
          start.add(const Duration(hours: 7)),
          min: 35,
          pace: th * 0.97,
        ),
      ];
      final v = BlockResolver.resolve(
        plan,
        runs,
        now: start.add(const Duration(days: 1)),
        vdot: vdot,
      );
      expect(v.next!.softened, isTrue);
      expect(v.next!.session.kind, isNot(BlockKind.interval));
      expect(v.next!.session.reason, contains('very hard'));
    });

    test('an easy run does not soften anything', () {
      const vdot = 45.0;
      final th = BlockPaces.threshold(vdot)!;
      final runs = [
        steady('easy', start.add(const Duration(hours: 7)), pace: th * 1.25),
      ];
      final v = BlockResolver.resolve(
        plan,
        runs,
        now: start.add(const Duration(days: 1)),
        vdot: vdot,
      );
      expect(v.next!.softened, isFalse);
    });

    test('the test session is never softened away', () {
      const vdot = 45.0;
      final th = BlockPaces.threshold(vdot)!;
      final week4 = start.add(const Duration(days: 21));
      final v = BlockResolver.resolve(
        plan,
        [
          for (var w = 0; w < 3; w++)
            steady('w$w', start.add(Duration(days: 7 * w, hours: 7))),
          steady('hard', week4.add(const Duration(hours: 7)), pace: th * 0.97),
        ],
        now: week4.add(const Duration(days: 1)),
        vdot: vdot,
      );
      expect(v.next!.session.isTest, isTrue);
      expect(v.next!.softened, isFalse);
    });

    test('same inputs, same view', () {
      final a = BlockResolver.resolve(plan, [], now: start);
      final b = BlockResolver.resolve(plan, [], now: start);
      expect(
        [for (final s in a.all) '${s.session.id}${s.status}'],
        [for (final s in b.all) '${s.session.id}${s.status}'],
      );
    });
  });

  group('swap', () {
    test('interval alternatives keep the slot and are marked swapped', () {
      final s = build(IdentityLane.aerobic, 3).sessions.first;
      final alts = BlockPlanner.alternatives(s);
      expect(alts, isNotEmpty);
      expect(alts.every((a) => a.id == s.id && a.week == s.week), isTrue);
      expect(alts.every((a) => a.swapped), isTrue);
      expect(alts.any((a) => a.presetId == s.presetId), isFalse);
    });

    test('the test cannot be swapped', () {
      final t = build(IdentityLane.mid, 3).sessions.firstWhere((s) => s.isTest);
      expect(BlockPlanner.alternatives(t), isEmpty);
    });
  });

  group('paces', () {
    test('faster runners get faster targets, hard work faster than easy', () {
      final slow = BlockPaces.threshold(35)!;
      final fast = BlockPaces.threshold(55)!;
      expect(fast, lessThan(slow));
      final plan = build(IdentityLane.speed, 3);
      final easy = plan.sessions.firstWhere((s) => s.kind == BlockKind.easy);
      final rep = plan.sessions.firstWhere((s) => s.presetId == '400s');
      expect(
        BlockPaces.target(rep, 45)!,
        lessThan(BlockPaces.target(easy, 45)!),
      );
      expect(BlockPaces.target(easy, null), isNull);
    });

    test('threshold of VDOT 50 is near 4:00 per km', () {
      expect(BlockPaces.threshold(50)!, inInclusiveRange(235, 255));
    });

    test('median vdot ignores junk', () {
      expect(BlockPaces.medianVdot([40, 50, double.nan, 0]), 45);
      expect(BlockPaces.medianVdot([]), isNull);
    });
  });
}
