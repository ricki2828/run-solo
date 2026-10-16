import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/quests/quest_build.dart';
import 'package:run_solo/state/quests/quest_store.dart';
import 'package:run_solo/state/quests/quests_controller.dart';

import '../helpers.dart' show summary;

engine.QuestRun qr(String id, DateTime wall, {double km = 5}) =>
    engine.QuestRun(id: id, start: wall, distanceM: km * 1000);

const distance = engine.QuestDef(
  id: 'q_2026-11_distance_month_aaaa',
  kind: engine.QuestKind.distanceMonth,
  month: '2026-11',
  target: 20,
  baseline: 15,
);
const climb = engine.QuestDef(
  id: 'q_2026-11_climb_month_bbbb',
  kind: engine.QuestKind.climbMonth,
  month: '2026-11',
  target: 400,
  baseline: 300,
);
const visits = engine.QuestDef(
  id: 'q_2026-11_trail_visits_cccc',
  kind: engine.QuestKind.trailVisits,
  month: '2026-11',
  target: 4,
  baseline: 3,
  trailKey: 'trail:x',
);

QuestOffer threeOffers() =>
    const QuestOffer(month: '2026-11', candidates: [distance, climb, visits]);

class CountingStore extends MemoryQuestStore {
  CountingStore([super.state]);
  int loads = 0;

  @override
  Future<QuestState> load() {
    loads++;
    return super.load();
  }
}

void main() {
  final threeRuns = QuestInputs(
    runs: [
      qr('a', DateTime.utc(2026, 10, 20, 7)),
      qr('b', DateTime.utc(2026, 10, 25, 7)),
      qr('c', DateTime.utc(2026, 10, 30, 7)),
    ],
    trailNames: const {},
    modes: const {},
  );

  group('reconcileQuests', () {
    test('the monthly offer rolls, and holds within the month', () {
      final nov = reconcileQuests(
        QuestState.empty,
        threeRuns,
        DateTime.utc(2026, 11, 2, 12),
        offsetMin: 0,
      );
      expect(nov.offer!.month, '2026-11');
      expect(nov.offer!.candidates.single.kind, engine.QuestKind.distanceMonth);
      final same = reconcileQuests(
        nov,
        threeRuns,
        DateTime.utc(2026, 11, 20, 12),
        offsetMin: 0,
      );
      expect(identical(same, nov), isTrue);
      final dec = reconcileQuests(
        nov,
        threeRuns,
        DateTime.utc(2026, 12, 3, 12),
        offsetMin: 0,
      );
      expect(dec.offer!.month, '2026-12');
    });

    test('not exposed: no offer', () {
      final out = reconcileQuests(
        QuestState.empty,
        threeRuns,
        DateTime.utc(2026, 11, 2, 12),
        exposed: false,
        offsetMin: 0,
      );
      expect(out.offer, isNull);
    });

    test('a finished quest goes to history as done, with its run', () {
      final active = distance.accept(DateTime.utc(2026, 11, 2, 10));
      final inputs = QuestInputs(
        runs: [qr('big', DateTime.utc(2026, 11, 3, 7), km: 21)],
        trailNames: const {},
        modes: const {},
      );
      final out = reconcileQuests(
        QuestState(active: active),
        inputs,
        DateTime.utc(2026, 11, 3, 12),
        offsetMin: 0,
      );
      expect(out.active, isNull);
      expect(out.history.single.result, 'done');
      expect(out.history.single.doneRunId, 'big');
      expect(out.history.single.closedOn, '2026-11-03');
    });

    test('a quest past its last day goes to history as expired', () {
      final active = distance.accept(DateTime.utc(2026, 11, 2, 10));
      expect(active.endsOn, '2026-12-01');
      final held = reconcileQuests(
        QuestState(active: active),
        threeRuns,
        DateTime.utc(2026, 12, 1, 23),
        offsetMin: 0,
      );
      expect(held.active, isNotNull);
      final out = reconcileQuests(
        QuestState(active: active),
        threeRuns,
        DateTime.utc(2026, 12, 2, 12),
        offsetMin: 0,
      );
      expect(out.active, isNull);
      expect(out.history.single.result, 'expired');
      expect(out.history.single.closedOn, '2026-12-02');
    });

    test('UTC-5: the last day ends at the runner\'s midnight', () {
      // Accepted 22:00 on 1 Nov, her time: ends 30 Nov.
      final active = distance.accept(DateTime.utc(2026, 11, 1, 22));
      expect(active.endsOn, '2026-11-30');
      final at2300 = reconcileQuests(
        QuestState(active: active),
        threeRuns,
        DateTime.utc(2026, 12, 1, 4), // 23:00 on 30 Nov, UTC-5
        offsetMin: -300,
      );
      expect(at2300.active, isNotNull);
      final at0030 = reconcileQuests(
        QuestState(active: active),
        threeRuns,
        DateTime.utc(2026, 12, 1, 5, 30), // 00:30 on 1 Dec, UTC-5
        offsetMin: -300,
      );
      expect(at0030.history.single.result, 'expired');
    });

    test('UTC+8: the last day ends at the runner\'s midnight', () {
      final active = distance.accept(DateTime.utc(2026, 11, 2, 10));
      final at2300 = reconcileQuests(
        QuestState(active: active),
        threeRuns,
        DateTime.utc(2026, 12, 1, 15), // 23:00 on 1 Dec, UTC+8
        offsetMin: 480,
      );
      expect(at2300.active, isNotNull);
      final at0030 = reconcileQuests(
        QuestState(active: active),
        threeRuns,
        DateTime.utc(2026, 12, 1, 16, 30), // 00:30 on 2 Dec, UTC+8
        offsetMin: 480,
      );
      expect(at0030.history.single.result, 'expired');
    });

    test('an active trail quest follows its trail when the group re-keys', () {
      final active = visits
          .rekeyed('trail:r0')
          .accept(DateTime.utc(2026, 11, 2, 10));
      final remembered = engine.QuestDef(
        id: active.id,
        kind: active.kind,
        month: active.month,
        target: active.target,
        baseline: active.baseline,
        trailKey: 'trail:r0',
        trailRunIds: const ['r1', 'r2'],
        acceptedAt: active.acceptedAt,
        endsOn: active.endsOn,
      );
      final inputs = QuestInputs(
        runs: [
          engine.QuestRun(
            id: 'r1',
            start: DateTime.utc(2026, 10, 6),
            distanceM: 5000,
            trailKey: 'trail:r1',
          ),
          engine.QuestRun(
            id: 'r2',
            start: DateTime.utc(2026, 10, 11),
            distanceM: 5000,
            trailKey: 'trail:r1',
          ),
          engine.QuestRun(
            id: 'n1',
            start: DateTime.utc(2026, 11, 4),
            distanceM: 5000,
            trailKey: 'trail:r1',
          ),
        ],
        trailNames: const {'trail:r1': 'Saddle'},
        modes: const {},
      );
      final out = reconcileQuests(
        QuestState(active: remembered),
        inputs,
        DateTime.utc(2026, 11, 5, 12),
        offsetMin: 0,
      );
      expect(out.active!.trailKey, 'trail:r1');
      expect(out.active!.trailName, 'Saddle');
    });
  });

  group('QuestsController', () {
    final noon = DateTime.utc(2026, 11, 2, 12);

    test('TAKE IT twice keeps the first quest', () async {
      final c = QuestsController(
        MemoryQuestStore(QuestState(offer: threeOffers())),
      );
      await c.accept(noon, offsetMin: 0);
      final first = c.state.active;
      expect(first!.id, distance.id);
      await c.accept(noon.add(const Duration(hours: 1)), offsetMin: 0);
      expect(identical(c.state.active, first), isTrue);
      expect(c.state.offer!.state, 'taken');
    });

    test('ANOTHER cycles the three and wraps', () async {
      final c = QuestsController(
        MemoryQuestStore(QuestState(offer: threeOffers())),
      );
      await c.load();
      expect(c.state.offer!.current!.id, distance.id);
      await c.another();
      expect(c.state.offer!.current!.id, climb.id);
      await c.another();
      expect(c.state.offer!.current!.id, visits.id);
      await c.another();
      expect(c.state.offer!.current!.id, distance.id);
      await c.another();
      await c.accept(noon, offsetMin: 0);
      expect(c.state.active!.id, climb.id);
    });

    test(
      'NOT THIS MONTH closes the offer: no more cards, no TAKE IT',
      () async {
        final c = QuestsController(
          MemoryQuestStore(QuestState(offer: threeOffers())),
        );
        await c.skip();
        expect(c.state.offer!.state, 'skipped');
        await c.another();
        await c.accept(noon, offsetMin: 0);
        expect(c.state.active, isNull);
        expect(c.state.offer!.shown, 0);
      },
    );

    test('drop closes the active quest into history', () async {
      final c = QuestsController(
        MemoryQuestStore(QuestState(offer: threeOffers())),
      );
      await c.accept(noon, offsetMin: 0);
      await c.drop(noon.add(const Duration(days: 3)), offsetMin: 0);
      expect(c.state.active, isNull);
      expect(c.state.history.single.result, 'dropped');
      expect(c.state.history.single.closedOn, '2026-11-05');
    });

    test('UTC+8: a run before TAKE IT that morning does not count', () async {
      final c = QuestsController(
        MemoryQuestStore(QuestState(offer: threeOffers())),
      );
      // 02:00 UTC is 10:00 in Singapore.
      await c.accept(DateTime.utc(2026, 11, 2, 2), offsetMin: 480);
      final a = c.state.active!;
      expect(a.acceptedAt, DateTime.utc(2026, 11, 2, 10));
      expect(a.endsOn, '2026-12-01');
      final early = qr('early', DateTime.utc(2026, 11, 2, 7), km: 8);
      final later = qr('later', DateTime.utc(2026, 11, 2, 11), km: 8);
      expect(engine.Quests.progress(a, [early]).value, 0);
      expect(engine.Quests.progress(a, [later]).value, 8);
    });

    test('UTC-5: the window starts on the runner\'s own day', () async {
      final c = QuestsController(
        MemoryQuestStore(QuestState(offer: threeOffers())),
      );
      // 03:00 UTC on 2 Nov is 22:00 on 1 Nov in New York (UTC-5).
      await c.accept(DateTime.utc(2026, 11, 2, 3), offsetMin: -300);
      final a = c.state.active!;
      expect(a.acceptedAt, DateTime.utc(2026, 11, 1, 22));
      expect(a.endsOn, '2026-11-30');
      final before = qr('before', DateTime.utc(2026, 11, 1, 20), km: 8);
      final after = qr('after', DateTime.utc(2026, 11, 1, 23), km: 8);
      expect(engine.Quests.progress(a, [before]).value, 0);
      expect(engine.Quests.progress(a, [after]).value, 8);
    });

    test('a quest the coach accepted in Telegram is adopted', () async {
      final runs = [
        summary(
          id: 'a',
          start: DateTime.utc(2026, 10, 20, 7),
          fourByFour: false,
        ),
        summary(
          id: 'b',
          start: DateTime.utc(2026, 10, 25, 7),
          fourByFour: false,
        ),
        summary(
          id: 'c',
          start: DateTime.utc(2026, 10, 30, 7),
          fourByFour: false,
        ),
      ];
      final c = QuestsController(MemoryQuestStore());
      await c.refresh(runs, noon, offsetMin: 0);
      final offer = c.state.offer!;
      expect(offer.open, isTrue);
      // An id that is not on offer changes nothing.
      await c.refresh(
        runs,
        noon,
        coachQuest: (id: 'q_nope', acceptedAt: noon),
        offsetMin: 0,
      );
      expect(c.state.active, isNull);
      await c.refresh(
        runs,
        noon,
        coachQuest: (
          id: offer.candidates.first.id,
          acceptedAt: DateTime.utc(2026, 11, 2, 2),
        ),
        offsetMin: 480,
      );
      final a = c.state.active!;
      expect(a.source, 'coach');
      // The instant is turned into the runner's wall clock, like TAKE IT.
      expect(a.acceptedAt, DateTime.utc(2026, 11, 2, 10));
      expect(a.endsOn, '2026-12-01');
      expect(c.state.offer!.state, 'taken');
    });

    test('load reads the store once, however many ask', () async {
      final store = CountingStore(QuestState(offer: threeOffers()));
      final c = QuestsController(store);
      await Future.wait([c.load(), c.load(), c.accept(noon, offsetMin: 0)]);
      expect(store.loads, 1);
    });

    test('the trail grouping is reused for the same history', () {
      final runs = [
        summary(
          id: 'a',
          start: DateTime.utc(2026, 10, 20, 7),
          fourByFour: false,
        ),
        summary(
          id: 'b',
          start: DateTime.utc(2026, 10, 25, 7),
          fourByFour: false,
        ),
      ];
      final c = QuestsController(MemoryQuestStore());
      final first = c.inputsFor(runs);
      expect(identical(c.inputsFor([...runs]), first), isTrue);
      final more = [
        ...runs,
        summary(
          id: 'c',
          start: DateTime.utc(2026, 10, 30, 7),
          fourByFour: false,
        ),
      ];
      expect(identical(c.inputsFor(more), first), isFalse);
    });
  });

  group('quests.json', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('quests_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('garbage starts empty and the next save repairs it', () async {
      File('${dir.path}/quests.json').writeAsStringSync('not json {{');
      final store = FileQuestStore(dir);
      final s = await store.load();
      expect(s.active, isNull);
      expect(s.history, isEmpty);
      await store.save(QuestState(offer: threeOffers()));
      expect((await store.load()).offer!.candidates, hasLength(3));
    });

    test('a different version starts empty', () async {
      File('${dir.path}/quests.json').writeAsStringSync('{"v":2,"active":{}}');
      final s = await FileQuestStore(dir).load();
      expect(s.active, isNull);
    });

    test('bad entries are dropped, good ones kept', () async {
      File('${dir.path}/quests.json').writeAsStringSync(
        '{"v":1,"active":{"kind":"bogus"},"offer":"x",'
        '"history":[5,{"id":"q_x","kind":"distance_month","month":"2026-11",'
        '"target":20,"baseline":15,"result":"done","closedOn":"2026-11-30"},'
        '{"kind":"nope"}],"pausedWeeks":[3,"x"],"climbCache":7}',
      );
      final s = await FileQuestStore(dir).load();
      expect(s.active, isNull);
      expect(s.offer, isNull);
      expect(s.history, hasLength(1));
      expect(s.history.single.result, 'done');
      expect(s.pausedWeeks, {3});
    });

    test('a controller on a corrupt file still works', () async {
      File('${dir.path}/quests.json').writeAsStringSync('}{');
      final c = QuestsController(FileQuestStore(dir));
      await c.load();
      expect(c.state.active, isNull);
      await c.pauseWeek(7);
      expect(c.pausedWeeks, {7});
    });
  });
}
