import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

QuestRun run(
  String id,
  DateTime start, {
  double km = 5,
  double? climb,
  bool baro = false,
  String? trail,
  int? normMs,
}) => QuestRun(
  id: id,
  start: start,
  distanceM: km * 1000,
  climbM: climb,
  baro: baro,
  trailKey: trail,
  normMs: normMs,
);

void main() {
  final now = DateTime(2026, 11, 2, 18);

  group('candidates', () {
    test('fewer than 3 runs: no offer', () {
      final runs = [
        run('a', DateTime(2026, 10, 20)),
        run('b', DateTime(2026, 10, 25)),
      ];
      expect(Quests.candidates(runs, now), isEmpty);
    });

    test('distance_month is always there from the 3rd run', () {
      final runs = [
        run('a', DateTime(2026, 10, 20)),
        run('b', DateTime(2026, 10, 25)),
        run('c', DateTime(2026, 10, 30)),
      ];
      final c = Quests.candidates(runs, now);
      expect(c.single.kind, QuestKind.distanceMonth);
      // 15 km best 30 days * 1.1 = 16.5, up to the next 5 = 20.
      expect(c.single.target, 20);
      expect(c.single.baseline, 15);
      expect(c.single.id, startsWith('q_2026-11_distance_month_'));
      expect(RegExp(r'^q_[a-z0-9_-]{1,48}$').hasMatch(c.single.id), isTrue);
    });

    test('same inputs, same ids', () {
      final runs = [
        for (var i = 0; i < 6; i++)
          run('r$i', DateTime(2026, 10, 1 + i * 4), trail: 'trail:x'),
      ];
      final a = Quests.candidates(runs, now, trailNames: {'trail:x': 'Saddle'});
      final b = Quests.candidates(runs, now, trailNames: {'trail:x': 'Saddle'});
      expect([for (final d in a) d.id], [for (final d in b) d.id]);
    });

    test('trail runner: visits first, target is own best plus one', () {
      // Six runs of one trail inside a 30 day span: busiest 30 days = 6...
      final runs = [
        for (var i = 0; i < 4; i++)
          run(
            'r$i',
            DateTime(2026, 9, 1 + i * 5),
            trail: 'trail:x',
            normMs: 2500000 - i * 1000,
          ),
      ];
      final c = Quests.candidates(runs, now, trailNames: {'trail:x': 'Saddle'});
      expect(c.first.kind, QuestKind.trailVisits);
      expect(c.first.baseline, 4);
      expect(c.first.target, 5);
      expect(c.first.title, 'SADDLE ×5');
      expect(
        c.first.line,
        'Five runs of Saddle in 30 days. Your best 30 days so far: 4 runs.',
      );
      expect(c[1].kind, QuestKind.trailBest);
      expect(c[1].target, 2497);
      expect(c[1].title, 'BEAT 41:37 ON SADDLE');
    });

    test('visits target is clamped to 3..8', () {
      final few = [
        for (var i = 0; i < 3; i++)
          run('r$i', DateTime(2026, 8, 20 + i * 35), trail: 'trail:x'),
      ];
      // Three runs 35 days apart: busiest 30 days is 1, target 3 (min).
      expect(Quests.candidates(few, now).first.target, 3);
      final many = [
        for (var i = 0; i < 12; i++)
          run('r$i', DateTime(2026, 10, 1 + i), trail: 'trail:x'),
      ];
      expect(Quests.candidates(many, now).first.target, 8);
    });

    test('a trail with fewer than 3 runs in 120 days gets no trail quest', () {
      final runs = [
        run('a', DateTime(2026, 5, 1), trail: 'trail:x'),
        run('b', DateTime(2026, 5, 8), trail: 'trail:x'),
        run('c', DateTime(2026, 5, 15), trail: 'trail:x'),
        run('d', DateTime(2026, 10, 20)),
      ];
      final c = Quests.candidates(runs, now);
      expect(c.every((d) => d.trailKey == null), isTrue);
    });

    test('climb_month needs baro in half the last 60 days', () {
      final baro = [
        for (var i = 0; i < 5; i++)
          run('r$i', DateTime(2026, 10, 5 + i * 5), climb: 200, baro: true),
      ];
      final c = Quests.candidates(baro, now);
      final climb = c.firstWhere((d) => d.kind == QuestKind.climbMonth);
      // Best 30 days: 7 days span -> runs on Oct 5,10,15,20,25 = 1000 m.
      expect(climb.baseline, 1000);
      expect(climb.target, 1100);
      expect(climb.title, '1,100 M UP');
      final gps = [for (final r in baro) run(r.id, r.start, climb: 200)];
      expect(
        Quests.candidates(gps, now).any((d) => d.kind == QuestKind.climbMonth),
        isFalse,
      );
    });

    test('climb_best uses a sane climb on the top trail', () {
      final runs = [
        for (var i = 0; i < 4; i++)
          run('r$i', DateTime(2026, 10, 1 + i * 5), trail: 'trail:x'),
      ];
      const climb = QuestClimb(
        trailKey: 'trail:x',
        idx: 0,
        startM: 1200,
        endM: 2400,
        gainM: 70,
        bestMs: 580000,
        runCount: 4,
      );
      final c = Quests.candidates(
        runs,
        now,
        climbs: [climb],
        trailNames: {'trail:x': 'Saddle'},
      );
      final q = c.firstWhere((d) => d.kind == QuestKind.climbBest);
      expect(q.title, 'THE 1.2 K CLIMB, SADDLE');
      expect(q.line, 'Your best up it is 9:40. 70 m up, 6%.');
    });

    test('never the same kind and trail as the quest that just ended', () {
      final runs = [
        for (var i = 0; i < 4; i++)
          run('r$i', DateTime(2026, 10, 1 + i * 5), trail: 'trail:x'),
      ];
      final first = Quests.candidates(runs, now).first;
      expect(first.kind, QuestKind.trailVisits);
      final next = Quests.candidates(runs, now, closed: [first]);
      expect(
        next.any(
          (d) => d.kind == QuestKind.trailVisits && d.trailKey == 'trail:x',
        ),
        isFalse,
      );
    });

    test('at most three, offer[0] is the default', () {
      final runs = [
        for (var i = 0; i < 6; i++)
          run(
            'r$i',
            DateTime(2026, 10, 1 + i * 4),
            trail: 'trail:x',
            climb: 100,
            baro: true,
            normMs: 2400000,
          ),
      ];
      final c = Quests.candidates(runs, now);
      expect(c.length, 3);
      expect(c.first.kind, QuestKind.trailVisits);
    });
  });

  group('progress', () {
    final at = DateTime(2026, 11, 2, 18);
    QuestDef accepted(QuestDef d) => d.accept(at);

    test('accept sets a 30 day window', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_trail_visits_ab12',
          kind: QuestKind.trailVisits,
          month: '2026-11',
          target: 3,
          baseline: 2,
          trailKey: 'trail:x',
        ),
      );
      expect(d.endsOn, '2026-12-02');
      expect(Quests.daysLeft(d, DateTime(2026, 11, 20)), 13);
      expect(Quests.expired(d, DateTime(2026, 12, 2, 23)), isFalse);
      expect(Quests.expired(d, DateTime(2026, 12, 3)), isTrue);
    });

    test('trail visits count only runs after acceptance, on that trail', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_trail_visits_ab12',
          kind: QuestKind.trailVisits,
          month: '2026-11',
          target: 3,
          baseline: 2,
          trailKey: 'trail:x',
        ),
      );
      final runs = [
        run('before', DateTime(2026, 11, 2, 7), trail: 'trail:x'),
        run('a', DateTime(2026, 11, 4), trail: 'trail:x'),
        run('other', DateTime(2026, 11, 5), trail: 'trail:y'),
        run('b', DateTime(2026, 11, 8), trail: 'trail:x'),
        run('c', DateTime(2026, 12, 2, 6), trail: 'trail:x'),
        run('late', DateTime(2026, 12, 3, 6), trail: 'trail:x'),
      ];
      final p = Quests.progress(d, runs);
      expect(p.value, 3);
      expect(p.complete, isTrue);
      expect(p.completedByRunId, 'c');
      expect(p.contributingRunIds, ['a', 'b', 'c']);
      expect(Quests.progress(d, runs.sublist(0, 4)).complete, isFalse);
    });

    test('a deleted run takes its count with it', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_trail_visits_ab12',
          kind: QuestKind.trailVisits,
          month: '2026-11',
          target: 2,
          baseline: 1,
          trailKey: 'trail:x',
        ),
      );
      final runs = [
        run('a', DateTime(2026, 11, 4), trail: 'trail:x'),
        run('b', DateTime(2026, 11, 8), trail: 'trail:x'),
      ];
      expect(Quests.progress(d, runs).complete, isTrue);
      expect(Quests.progress(d, [runs.first]).complete, isFalse);
    });

    test('trail_best: a hot day still counts (normMs is heat-adjusted)', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_trail_best_ab12',
          kind: QuestKind.trailBest,
          month: '2026-11',
          target: 2400,
          baseline: 2400,
          trailKey: 'trail:x',
        ),
      );
      final slow = run(
        'a',
        DateTime(2026, 11, 4),
        trail: 'trail:x',
        normMs: 2400000,
      );
      final fast = run(
        'b',
        DateTime(2026, 11, 9),
        trail: 'trail:x',
        normMs: 2399000,
      );
      expect(Quests.progress(d, [slow]).complete, isFalse);
      final p = Quests.progress(d, [slow, fast]);
      expect(p.complete, isTrue);
      expect(p.completedByRunId, 'b');
      expect(p.bestMs, 2399000);
      expect(Quests.liveRemaining(d, Quests.progress(d, [slow])), isNull);
    });

    test('climb_best uses the climb times handed in', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_climb_best_ab12',
          kind: QuestKind.climbBest,
          month: '2026-11',
          target: 580,
          baseline: 580,
          trailKey: 'trail:x',
          climbIdx: 0,
        ),
      );
      final runs = [run('a', DateTime(2026, 11, 4), trail: 'trail:x')];
      expect(Quests.progress(d, runs).complete, isFalse);
      expect(
        Quests.progress(d, runs, climbTimes: {'a': 600000}).complete,
        isFalse,
      );
      final p = Quests.progress(d, runs, climbTimes: {'a': 570000});
      expect(p.complete, isTrue);
      expect(Quests.liveRemaining(d, Quests.progress(d, runs)), 580000);
    });

    test('climb_month sums baro runs only; live remaining is what is left', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_climb_month_ab12',
          kind: QuestKind.climbMonth,
          month: '2026-11',
          target: 1000,
          baseline: 880,
        ),
      );
      final runs = [
        run('a', DateTime(2026, 11, 4), climb: 400, baro: true),
        run('gps', DateTime(2026, 11, 5), climb: 900),
        run('b', DateTime(2026, 11, 8), climb: 250, baro: true),
      ];
      final p = Quests.progress(d, runs);
      expect(p.value, 650);
      expect(p.complete, isFalse);
      expect(Quests.liveRemaining(d, p), 350);
    });

    test('distance_month: running total and the run that crossed', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_distance_month_ab12',
          kind: QuestKind.distanceMonth,
          month: '2026-11',
          target: 20,
          baseline: 15,
        ),
      );
      final runs = [
        run('a', DateTime(2026, 11, 4), km: 8),
        run('b', DateTime(2026, 11, 8), km: 7),
        run('c', DateTime(2026, 11, 12), km: 6),
      ];
      final p = Quests.progress(d, runs);
      expect(p.complete, isTrue);
      expect(p.completedByRunId, 'c');
      final half = Quests.progress(d, runs.sublist(0, 2));
      expect(half.value, 15);
      expect(Quests.liveRemaining(d, half), 5000);
    });

    test('trail visits: live line only for the last visit', () {
      final d = accepted(
        const QuestDef(
          id: 'q_2026-11_trail_visits_ab12',
          kind: QuestKind.trailVisits,
          month: '2026-11',
          target: 3,
          baseline: 2,
          trailKey: 'trail:x',
        ),
      );
      final one = Quests.progress(d, [
        run('a', DateTime(2026, 11, 4), trail: 'trail:x'),
      ]);
      expect(Quests.liveRemaining(d, one), isNull);
      final two = Quests.progress(d, [
        run('a', DateTime(2026, 11, 4), trail: 'trail:x'),
        run('b', DateTime(2026, 11, 5), trail: 'trail:x'),
      ]);
      expect(Quests.liveRemaining(d, two), 1);
    });
  });

  test('json round trip keeps every field', () {
    final d = const QuestDef(
      id: 'q_2026-11_climb_best_ab12',
      kind: QuestKind.climbBest,
      month: '2026-11',
      target: 580,
      baseline: 580,
      trailKey: 'trail:x',
      trailName: 'Saddle',
      climbIdx: 1,
      climbLengthM: 1200,
      climbGainM: 70,
    ).accept(DateTime(2026, 11, 2, 18), source: 'coach');
    final back = QuestDef.fromJson(d.toJson())!;
    expect(back.toJson(), d.toJson());
    expect(back.source, 'coach');
    expect(QuestDef.fromJson({'id': 1}), isNull);
  });

  test('copy has no em dashes', () {
    for (final k in QuestKind.values) {
      final d = QuestDef(
        id: 'q_x',
        kind: k,
        month: '2026-11',
        target: 5,
        baseline: 4,
        trailName: 'Saddle',
        climbLengthM: 1200,
        climbGainM: 70,
      );
      expect('${d.title}${d.line}${d.doneLine(23)}'.contains('—'), isFalse);
    }
  });
}
