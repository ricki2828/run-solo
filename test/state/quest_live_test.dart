import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/quests/quest_chip.dart';
import 'package:run_solo/state/quests/quest_build.dart';
import 'package:run_solo/state/quests/quest_live.dart';
import 'package:run_solo/state/quests/quest_store.dart';
import 'package:run_solo/state/quests/quests_controller.dart';

import '../helpers.dart' show summary;

engine.QuestProgress progress(
  num value,
  int target, {
  bool complete = false,
  List<String> ids = const [],
  String? by,
}) => engine.QuestProgress(
  value: value,
  target: target,
  contributingRunIds: ids,
  complete: complete,
  completedByRunId: by,
);

engine.QuestDef def(
  engine.QuestKind kind, {
  int target = 5,
  String? trailKey,
  String? name,
}) => engine.QuestDef(
  id: 'q_2026-11_${kind.wire}_aa',
  kind: kind,
  month: '2026-11',
  target: target,
  baseline: 1,
  trailKey: trailKey,
  trailName: name,
).accept(DateTime.utc(2026, 11, 2, 10));

void main() {
  group('liveQuestOf', () {
    test('distance and climb: the threshold is what is left, in metres', () {
      final d = liveQuestOf(
        def(engine.QuestKind.distanceMonth, target: 20),
        progress(12.5, 20),
      )!;
      expect(d.kind, 'distance_month');
      expect(d.remaining, 7500);
      expect(d.line, '20 kilometres run this month. Quest done.');
      expect(d.title, '20 KM');
      expect(d.trailId, isNull);
      final c = liveQuestOf(
        def(engine.QuestKind.climbMonth, target: 1000),
        progress(640, 1000),
      )!;
      expect(c.remaining, 360);
    });

    test('trail visits: only the last visit, on its own trail', () {
      final d = def(
        engine.QuestKind.trailVisits,
        trailKey: 'trail:r0',
        name: 'Saddle',
      );
      expect(liveQuestOf(d, progress(3, 5)), isNull);
      final last = liveQuestOf(d, progress(4, 5))!;
      expect(last.remaining, 1);
      expect(last.trailId, 'trail:r0');
      expect(last.line, 'Saddle number five. Quest done.');
    });

    test('no live beat for a best-time quest, a done quest or no trail', () {
      expect(
        liveQuestOf(
          def(engine.QuestKind.trailBest, trailKey: 'trail:r0'),
          progress(0, 2472),
        ),
        isNull,
      );
      expect(
        liveQuestOf(
          def(engine.QuestKind.climbBest, trailKey: 'trail:r0'),
          progress(0, 580),
        ),
        isNull,
      );
      expect(
        liveQuestOf(
          def(engine.QuestKind.distanceMonth, target: 20),
          progress(20, 20, complete: true),
        ),
        isNull,
      );
      expect(
        liveQuestOf(def(engine.QuestKind.trailVisits), progress(4, 5)),
        isNull,
      );
    });
  });

  group('withLiveQuest', () {
    final now = DateTime.utc(2026, 11, 10, 12);
    late QuestsController quests;
    late MemoryRunStore history;

    setUp(() {
      final active = def(engine.QuestKind.distanceMonth, target: 20);
      quests = QuestsController(MemoryQuestStore(QuestState(active: active)));
      history = MemoryRunStore(
        runs: [
          summary(
            id: 'a',
            start: DateTime.utc(2026, 11, 4, 7),
            fourByFour: false,
          ),
        ],
      );
    });

    LiveContext ctx() => LiveContext(
      boards: const [],
      coachingMuted: false,
      builtAtMs: 1,
      engineVersion: 1,
    );

    test('a free run gets the quest in a context of its own', () async {
      final out = await withLiveQuest(
        null,
        mode: RecordMode.free,
        quests: quests,
        history: history,
        now: now,
        offsetMin: 0,
      );
      expect(out, isNotNull);
      expect(out!.boards, isEmpty);
      expect(out.coachingMuted, isTrue);
      final q = out.quest!;
      expect(q.kind, 'distance_month');
      // 6.8 km of the one run in the window: 20 km - 6.8 km left.
      expect(q.remaining, closeTo(13200, 1));
    });

    test('it rides in an existing context without replacing it', () async {
      final c = ctx();
      final out = await withLiveQuest(
        c,
        mode: RecordMode.trail,
        quests: quests,
        history: history,
        now: now,
        offsetMin: 0,
      );
      expect(identical(out, c), isTrue);
      expect(c.quest, isNotNull);
      expect(c.coachingMuted, isFalse);
    });

    test('a structured session or no quest changes nothing', () async {
      final c = ctx();
      expect(
        await withLiveQuest(
          c,
          mode: RecordMode.intervals,
          quests: quests,
          history: history,
          now: now,
          offsetMin: 0,
        ),
        same(c),
      );
      expect(c.quest, isNull);
      final none = QuestsController(MemoryQuestStore());
      expect(
        await withLiveQuest(
          null,
          mode: RecordMode.free,
          quests: none,
          history: history,
          now: now,
        ),
        isNull,
      );
    });

    test('a quest past its last day is not packed', () async {
      final out = await withLiveQuest(
        null,
        mode: RecordMode.free,
        quests: quests,
        history: history,
        now: DateTime.utc(2026, 12, 5),
        offsetMin: 0,
      );
      expect(out, isNull);
    });
  });

  group('questChipFor', () {
    QuestInputs inputs(List<engine.QuestRun> runs) =>
        QuestInputs(runs: runs, trailNames: const {}, modes: const {});
    engine.QuestRun qr(String id, DateTime wall, double km) =>
        engine.QuestRun(id: id, start: wall, distanceM: km * 1000);

    test('a run that counts shows the progress, the finisher shows DONE', () {
      final a = def(engine.QuestKind.distanceMonth, target: 20);
      final s = QuestState(active: a);
      final runs = [
        qr('a', DateTime.utc(2026, 11, 4, 7), 8),
        qr('b', DateTime.utc(2026, 11, 6, 7), 8),
      ];
      expect(questChipFor(s, inputs(runs), 'b')!.label, 'QUEST 16 OF 20 KM');
      expect(questChipFor(s, inputs(runs), 'zzz'), isNull);
      final more = [...runs, qr('c', DateTime.utc(2026, 11, 8, 7), 8)];
      final done = questChipFor(s, inputs(more), 'c')!;
      expect(done.label, 'QUEST DONE');
      expect(done.done, isTrue);
      // The earlier runs of a finished quest show nothing.
      expect(questChipFor(s, inputs(more), 'a'), isNull);
    });

    test('after it was closed as done, its run still shows DONE', () {
      final a = def(engine.QuestKind.distanceMonth, target: 20);
      final s = QuestState(
        history: [
          QuestHistoryEntry(
            def: a,
            result: 'done',
            closedOn: '2026-11-08',
            doneRunId: 'c',
          ),
        ],
      );
      expect(questChipFor(s, inputs(const []), 'c')!.done, isTrue);
      expect(questChipFor(s, inputs(const []), 'a'), isNull);
    });

    test('trail visits and climbs read as "n of target"', () {
      final v = def(
        engine.QuestKind.trailVisits,
        trailKey: 'trail:x',
        name: 'Saddle',
      );
      final runs = [
        for (var i = 0; i < 3; i++)
          engine.QuestRun(
            id: 'r$i',
            start: DateTime.utc(2026, 11, 3 + i, 7),
            distanceM: 5000,
            trailKey: 'trail:x',
          ),
      ];
      expect(
        questChipFor(QuestState(active: v), inputs(runs), 'r2')!.label,
        'QUEST 3 OF 5',
      );
      final c = def(engine.QuestKind.climbMonth, target: 1000);
      final climbs = [
        engine.QuestRun(
          id: 'c1',
          start: DateTime.utc(2026, 11, 3, 7),
          distanceM: 5000,
          climbM: 640,
          baro: true,
        ),
      ];
      expect(
        questChipFor(QuestState(active: c), inputs(climbs), 'c1')!.label,
        'QUEST 640 OF 1,000 M',
      );
    });

    test('a best-time quest has no running chip', () {
      final b = def(
        engine.QuestKind.trailBest,
        target: 2472,
        trailKey: 'trail:x',
      );
      final r = engine.QuestRun(
        id: 'r',
        start: DateTime.utc(2026, 11, 3, 7),
        distanceM: 5000,
        trailKey: 'trail:x',
        normMs: 2600000,
      );
      expect(questChipFor(QuestState(active: b), inputs([r]), 'r'), isNull);
    });
  });
}
