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

Map<String, Object?> distanceJson() => {
  'id': 'q_2026-11_distance_month_aaaa',
  'kind': 'distance_month',
  'month': '2026-11',
  'target': 20,
  'baseline': 15,
  'endsOn': '2026-12-02',
};

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

    test('visits target is at least 3 and always above the baseline', () {
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
      // Twelve runs in 12 days: baseline 12, so 13 (never below baseline+1).
      expect(Quests.candidates(many, now).first.baseline, 12);
      expect(Quests.candidates(many, now).first.target, 13);
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

    test('accept sets a 30 day window, the first day included', () {
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
      // 2 Nov plus 29 days: 30 calendar days with the 2nd as day one.
      expect(d.endsOn, '2026-12-01');
      expect(Quests.daysLeft(d, DateTime(2026, 11, 2)), 30);
      expect(Quests.daysLeft(d, DateTime(2026, 11, 20)), 12);
      expect(Quests.expired(d, DateTime(2026, 12, 1, 23)), isFalse);
      expect(Quests.expired(d, DateTime(2026, 12, 2)), isTrue);
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
        run('c', DateTime(2026, 12, 1, 6), trail: 'trail:x'),
        run('late', DateTime(2026, 12, 2, 6), trail: 'trail:x'),
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
    ).accept(DateTime.utc(2026, 11, 2, 18), source: 'coach');
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

  group('review fixes', () {
    test('only distance_month: the last quest kind is still offered again', () {
      final runs = [
        run('a', DateTime(2026, 10, 20)),
        run('b', DateTime(2026, 10, 25)),
        run('c', DateTime(2026, 10, 30)),
      ];
      final first = Quests.candidates(runs, now).single;
      final closed = [first.accept(DateTime(2026, 10, 1))];
      final again = Quests.candidates(runs, now, closed: closed);
      expect(again.single.kind, QuestKind.distanceMonth);
    });

    test('the last kind is skipped while there is something else', () {
      final runs = [
        for (var i = 0; i < 4; i++)
          run('r$i', DateTime(2026, 10, 1 + i * 5), trail: 'trail:x'),
      ];
      final first = Quests.candidates(runs, now).first;
      expect(first.kind, QuestKind.trailVisits);
      final again = Quests.candidates(runs, now, closed: [first]);
      expect(again.any((d) => d.kind == QuestKind.trailVisits), isFalse);
      expect(again, isNotEmpty);
    });

    test('trail_best target floors, so a hair slower than the best fails', () {
      final runs = [
        for (var i = 0; i < 3; i++)
          run(
            'r$i',
            DateTime(2026, 10, 10 + i * 5),
            trail: 'trail:x',
            normMs: 2472600 + i * 1000,
          ),
      ];
      final best = Quests.candidates(
        runs,
        now,
      ).firstWhere((d) => d.kind == QuestKind.trailBest);
      expect(best.target, 2472);
      final at = DateTime(2026, 11, 3);
      final d = best.accept(at);
      // 2472.8 s is slower than the 2472.6 s best: not done.
      final slower = run(
        's',
        DateTime(2026, 11, 4),
        trail: 'trail:x',
        normMs: 2472800,
      );
      expect(Quests.progress(d, [slower]).complete, isFalse);
      final faster = run(
        'f',
        DateTime(2026, 11, 5),
        trail: 'trail:x',
        normMs: 2471900,
      );
      expect(Quests.progress(d, [faster]).complete, isTrue);
    });

    test('trail_best remembers its runs too, and remaps end to end', () {
      final runs = [
        for (var i = 0; i < 4; i++)
          run(
            'r$i',
            DateTime(2026, 10, 1 + i * 5),
            trail: 'trail:r0',
            normMs: 2600000 - i * 10000,
          ),
      ];
      final best = Quests.candidates(
        runs,
        now,
      ).firstWhere((d) => d.kind == QuestKind.trailBest);
      expect(best.trailRunIds, ['r0', 'r1', 'r2', 'r3']);
      final active = best.accept(DateTime(2026, 11, 3));
      // r0 deleted: r1..r3 re-key to trail:r1, times re-normalised longer.
      final after = [
        run('r1', DateTime(2026, 10, 6), trail: 'trail:r1', normMs: 2650000),
        run('r2', DateTime(2026, 10, 11), trail: 'trail:r1', normMs: 2640000),
        run('r3', DateTime(2026, 10, 16), trail: 'trail:r1', normMs: 2630000),
        run('n1', DateTime(2026, 11, 5), trail: 'trail:r1', normMs: 2600000),
      ];
      final d = Quests.remapTrail(active, after, const {});
      expect(d.trailKey, 'trail:r1');
      expect(d.target, 2630);
      expect(d.baseline, 2630);
      final p = Quests.progress(d, after);
      expect(p.complete, isTrue);
      expect(p.completedByRunId, 'n1');
    });

    test('an acceptedAt saved by an older build keeps its wall clock', () {
      final json = distanceJson()..['acceptedAt'] = '2026-11-02T10:00:00.000';
      final d = QuestDef.fromJson(json)!;
      expect(d.acceptedAt, DateTime.utc(2026, 11, 2, 10));
      final z = distanceJson()..['acceptedAt'] = '2026-11-02T10:00:00.000Z';
      expect(QuestDef.fromJson(z)!.acceptedAt, DateTime.utc(2026, 11, 2, 10));
    });

    test('trail runs are remembered and survive a json round trip', () {
      final runs = [
        for (var i = 0; i < 4; i++)
          run('r$i', DateTime(2026, 10, 1 + i * 5), trail: 'trail:r0'),
      ];
      final d = Quests.candidates(runs, now).first;
      expect(d.trailRunIds, ['r0', 'r1', 'r2', 'r3']);
      expect(QuestDef.fromJson(d.toJson())!.trailRunIds, d.trailRunIds);
    });

    group('remapTrail', () {
      QuestDef visits() => const QuestDef(
        id: 'q_2026-11_trail_visits_ab12',
        kind: QuestKind.trailVisits,
        month: '2026-11',
        target: 4,
        baseline: 3,
        trailKey: 'trail:r0',
        trailName: 'Saddle',
        trailRunIds: ['r0', 'r1', 'r2'],
      ).accept(DateTime(2026, 11, 2));

      test('the anchor was deleted: the group re-keys, the quest follows', () {
        // r0 is gone; r1 is now the anchor of the same group.
        final runs = [
          run('r1', DateTime(2026, 10, 6), trail: 'trail:r1'),
          run('r2', DateTime(2026, 10, 11), trail: 'trail:r1'),
          run('n1', DateTime(2026, 11, 4), trail: 'trail:r1'),
        ];
        final d = Quests.remapTrail(visits(), runs, {'trail:r1': 'Saddle'});
        expect(d.trailKey, 'trail:r1');
        expect(Quests.progress(d, runs).value, 1);
        // Left alone it would have counted nothing.
        expect(Quests.progress(visits(), runs).value, 0);
      });

      test('the anchor was split off: the quest stays on the main trail', () {
        // r0 is a one-run group still keyed trail:r0; r1 and r2 (and the new
        // run) kept together under trail:r1.
        final runs = [
          run('r0', DateTime(2026, 10, 1), trail: 'trail:r0'),
          run('r1', DateTime(2026, 10, 6), trail: 'trail:r1'),
          run('r2', DateTime(2026, 10, 11), trail: 'trail:r1'),
          run('n1', DateTime(2026, 11, 4), trail: 'trail:r1'),
        ];
        final d = Quests.remapTrail(visits(), runs, {'trail:r1': 'Saddle'});
        expect(d.trailKey, 'trail:r1');
        expect(Quests.progress(d, runs).value, 1);
        // And once r0 is deleted as well, the same.
        final without = runs.sublist(1);
        expect(
          Quests.remapTrail(visits(), without, const {}).trailKey,
          'trail:r1',
        );
      });

      test('the quest stays when its own key still holds the most', () {
        final runs = [
          run('r0', DateTime(2026, 10, 1), trail: 'trail:r0'),
          run('r1', DateTime(2026, 10, 6), trail: 'trail:r0'),
          run('r2', DateTime(2026, 10, 11), trail: 'trail:r9'),
        ];
        final d = visits();
        expect(identical(Quests.remapTrail(d, runs, const {}), d), isTrue);
      });

      test('one stray run does not move it', () {
        // Three runs remembered; only r2 is left, on another key.
        final runs = [run('r2', DateTime(2026, 10, 11), trail: 'trail:r9')];
        final d = visits();
        expect(identical(Quests.remapTrail(d, runs, const {}), d), isTrue);
      });

      test('trail_best is re-based on the new anchor\'s times', () {
        const old = QuestDef(
          id: 'q_2026-11_trail_best_ab12',
          kind: QuestKind.trailBest,
          month: '2026-11',
          target: 2500,
          baseline: 2500,
          trailKey: 'trail:r0',
          trailRunIds: ['r1', 'r2'],
        );
        final d0 = old.accept(DateTime(2026, 11, 2));
        final runs = [
          run('r1', DateTime(2026, 10, 6), trail: 'trail:r1', normMs: 2600500),
          run('r2', DateTime(2026, 10, 11), trail: 'trail:r1', normMs: 2580900),
          run('n1', DateTime(2026, 11, 4), trail: 'trail:r1', normMs: 2400000),
        ];
        final d = Quests.remapTrail(d0, runs, const {});
        expect(d.trailKey, 'trail:r1');
        // Best before accepting, floored; the new run (2400 s) is not in it.
        expect(d.target, 2580);
        expect(Quests.progress(d, runs).complete, isTrue);
      });

      test('nothing remembered is found: the quest is left as it was', () {
        final runs = [run('z', DateTime(2026, 10, 6), trail: 'trail:z')];
        final d = visits();
        expect(identical(Quests.remapTrail(d, runs, const {}), d), isTrue);
      });
    });
  });
}
