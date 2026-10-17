import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/quests/quest_build.dart';
import 'package:run_solo/state/quests/quest_store.dart';
import 'package:run_solo/state/quests/quest_wire.dart';

engine.QuestRun qr(String id, DateTime wall, {double km = 5}) =>
    engine.QuestRun(id: id, start: wall, distanceM: km * 1000);

const distance = engine.QuestDef(
  id: 'q_2026-11_distance_month_aaaa',
  kind: engine.QuestKind.distanceMonth,
  month: '2026-11',
  target: 20,
  baseline: 15,
);
const visits = engine.QuestDef(
  id: 'q_2026-11_trail_visits_cccc',
  kind: engine.QuestKind.trailVisits,
  month: '2026-11',
  target: 5,
  baseline: 4,
  trailKey: 'trail:r0',
  trailName: 'Saddle',
  trailRunIds: ['r0', 'r1', 'r2'],
);
const best = engine.QuestDef(
  id: 'q_2026-11_trail_best_dddd',
  kind: engine.QuestKind.trailBest,
  month: '2026-11',
  target: 2472,
  baseline: 2472,
  trailKey: 'trail:r0',
  trailName: 'Saddle',
);

final now = DateTime.utc(2026, 11, 10, 12);

QuestInputs inputs(List<engine.QuestRun> runs) =>
    QuestInputs(runs: runs, trailNames: const {}, modes: const {});

Map<String, Object?>? wire(
  QuestState s,
  List<engine.QuestRun> runs, {
  String runId = 'now',
  bool names = true,
}) => questWire(s, inputs(runs), now, runId: runId, names: names, offsetMin: 0);

void main() {
  group('questWire', () {
    test('nothing to say is no block', () {
      expect(wire(QuestState.empty, const []), isNull);
    });

    test('an open offer: up to 3 offers with exactly the offer keys', () {
      final s = QuestState(
        offer: const QuestOffer(
          month: '2026-11',
          candidates: [visits, best, distance],
        ),
      );
      final b = wire(s, const [])!;
      final offers = b['offers']! as List;
      expect(offers, hasLength(3));
      expect((offers[0] as Map).keys.toSet(), {
        'id',
        'kind',
        'target',
        'baseline',
        'unit',
        'trail_name',
      });
      expect(offers[0], {
        'id': visits.id,
        'kind': 'trail_visits',
        'target': 5,
        'baseline': 4,
        'unit': 'runs',
        'trail_name': 'Saddle',
      });
      expect((offers[1] as Map)['unit'], 's');
      expect((offers[2] as Map)['unit'], 'km');
      expect((offers[2] as Map).containsKey('trail_name'), isFalse);
      expect(b.containsKey('active'), isFalse);
      for (final o in offers.cast<Map>()) {
        expect(o['target'], isA<int>());
        expect(o['baseline'], isA<int>());
      }
    });

    test('trail names only with the opt-in, and never over 30 characters', () {
      final s = QuestState(
        offer: const QuestOffer(month: '2026-11', candidates: [visits]),
      );
      final off = wire(s, const [], names: false)!;
      expect(
        ((off['offers']! as List).single as Map).containsKey('trail_name'),
        isFalse,
      );
      final long = engine.QuestDef(
        id: visits.id,
        kind: visits.kind,
        month: visits.month,
        target: 5,
        baseline: 4,
        trailKey: 'trail:r0',
        trailName: 'A trail with a name that is much too long',
      );
      final b = wire(
        QuestState(
          offer: QuestOffer(month: '2026-11', candidates: [long]),
        ),
        const [],
      )!;
      expect(
        ((b['offers']! as List).single as Map).containsKey('trail_name'),
        isFalse,
      );
    });

    test('a skipped, taken or closed offer sends no offers', () {
      final skipped = QuestState(
        offer: const QuestOffer(
          month: '2026-11',
          candidates: [distance],
          state: 'skipped',
        ),
      );
      final b = wire(skipped, const [])!;
      expect(b.containsKey('offers'), isFalse);
      expect(b['month_skipped'], '2026-11');
      // Another month's skip says nothing now.
      final old = QuestState(
        offer: const QuestOffer(
          month: '2026-10',
          candidates: [distance],
          state: 'skipped',
        ),
      );
      expect(wire(old, const []), isNull);
    });

    test(
      'the active quest carries whole-number progress and only its keys',
      () {
        final a = distance.accept(DateTime.utc(2026, 11, 2, 10));
        final b = wire(QuestState(active: a), [
          qr('x', DateTime.utc(2026, 11, 3, 7), km: 7.58),
        ])!;
        final w = b['active']! as Map;
        expect(w.keys.toSet(), {'id', 'kind', 'target', 'value', 'ends_on'});
        expect(w['value'], 7);
        expect(w['value'], isA<int>());
        expect(w['ends_on'], '2026-12-01');
        expect(b.containsKey('done_now'), isFalse);
      },
    );

    test('the run that finishes it names it and sends value = target', () {
      final a = distance.accept(DateTime.utc(2026, 11, 2, 10));
      final b = wire(QuestState(active: a), [
        qr('big', DateTime.utc(2026, 11, 3, 7), km: 21),
      ], runId: 'big')!;
      expect(b['done_now'], distance.id);
      expect((b['active']! as Map)['value'], 20);
    });

    test('a later run does not name a quest another run finished', () {
      final a = distance.accept(DateTime.utc(2026, 11, 2, 10));
      final b = wire(QuestState(active: a), [
        qr('big', DateTime.utc(2026, 11, 3, 7), km: 21),
      ], runId: 'other')!;
      expect(b.containsKey('done_now'), isFalse);
    });

    test('already closed as done: still names it and sends its row', () {
      final a = distance.accept(DateTime.utc(2026, 11, 2, 10));
      final s = QuestState(
        history: [
          QuestHistoryEntry(
            def: a,
            result: 'done',
            closedOn: '2026-11-03',
            doneRunId: 'big',
          ),
        ],
      );
      final b = wire(s, const [], runId: 'big')!;
      expect(b['done_now'], distance.id);
      expect((b['active']! as Map)['value'], 20);
      // Not also `closed`: it is the same quest.
      expect(b.containsKey('closed'), isFalse);
    });

    test('a quest that just ended is closed, for two weeks', () {
      final a = distance.accept(DateTime.utc(2026, 11, 2, 10));
      QuestState ended(String day) => QuestState(
        history: [QuestHistoryEntry(def: a, result: 'dropped', closedOn: day)],
      );
      expect(wire(ended('2026-11-08'), const [])!['closed'], {
        'id': distance.id,
        'result': 'dropped',
      });
      expect(wire(ended('2026-10-20'), const []), isNull);
    });

    test('run ids and internals never reach the block', () {
      final a = visits.accept(DateTime.utc(2026, 11, 2, 10));
      final s = QuestState(
        active: a,
        offer: const QuestOffer(month: '2026-11', candidates: [visits]),
        history: [
          QuestHistoryEntry(def: a, result: 'expired', closedOn: '2026-11-09'),
        ],
      );
      final b = wire(s, [qr('r0', DateTime.utc(2026, 11, 3, 7))])!;
      final text = jsonEncode(b);
      expect(text.contains('trailRunIds'), isFalse);
      expect(text.contains('r0'), isFalse);
      expect(text.contains('trail:'), isFalse);
      expect(text.contains('acceptedAt'), isFalse);
    });

    test('a best-time quest sends 0 until it is beaten', () {
      final a = best.accept(DateTime.utc(2026, 11, 2, 10));
      final slow = engine.QuestRun(
        id: 's',
        start: DateTime.utc(2026, 11, 3, 7),
        distanceM: 5000,
        trailKey: 'trail:r0',
        normMs: 2480000,
      );
      final fast = engine.QuestRun(
        id: 'f',
        start: DateTime.utc(2026, 11, 4, 7),
        distanceM: 5000,
        trailKey: 'trail:r0',
        normMs: 2460000,
      );
      expect(
        (wire(QuestState(active: a), [slow])!['active']! as Map)['value'],
        0,
      );
      final b = wire(QuestState(active: a), [slow, fast], runId: 'f')!;
      expect((b['active']! as Map)['value'], 2472);
      expect(b['done_now'], best.id);
    });
  });

  group('the server contract', () {
    test('units fit the kinds', () {
      expect(questUnit(engine.QuestKind.trailVisits), 'runs');
      expect(questUnit(engine.QuestKind.trailBest), 's');
      expect(questUnit(engine.QuestKind.climbBest), 's');
      expect(questUnit(engine.QuestKind.climbMonth), 'm');
      expect(questUnit(engine.QuestKind.distanceMonth), 'km');
    });
  });
}
