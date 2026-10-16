import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/progress_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/quests/quest_build.dart';
import 'package:run_solo/state/quests/quest_store.dart';

import 'package:run_solo/platform/gateway.dart' show RecordMode;

import '../helpers.dart';

const _visits = engine.QuestDef(
  id: 'q_2026-10_trail_visits_abc',
  kind: engine.QuestKind.trailVisits,
  month: '2026-10',
  target: 5,
  baseline: 3,
  trailKey: 'saddle',
  trailName: 'Saddle',
  endsOn: '2026-10-28',
);

const _best = engine.QuestDef(
  id: 'q_2026-10_trail_best_abc',
  kind: engine.QuestKind.trailBest,
  month: '2026-10',
  target: 2412,
  baseline: 2472,
  trailKey: 'saddle',
  trailName: 'Saddle',
  endsOn: '2026-10-28',
);

QuestBoard _board(String variant) {
  final history = [
    const QuestHistoryEntry(
      def: _visits,
      result: 'done',
      closedOn: '2026-09-14',
    ),
  ];
  switch (variant) {
    case 'offer':
      return QuestBoard(offer: _visits, offerCount: 3, history: history);
    case 'counter':
      return QuestBoard(
        active: _visits,
        progress: const engine.QuestProgress(
          value: 3,
          target: 5,
          contributingRunIds: ['a', 'b', 'c'],
          complete: false,
        ),
        daysLeft: 12,
        segments: const [
          QuestSegment(runId: 'a', share: 0.2, mode: RecordMode.free),
          QuestSegment(runId: 'b', share: 0.2, mode: RecordMode.free),
          QuestSegment(runId: 'c', share: 0.2, mode: RecordMode.free),
        ],
        history: history,
      );
    default:
      return QuestBoard(
        active: _best,
        progress: const engine.QuestProgress(
          value: 0,
          target: 1,
          contributingRunIds: [],
          complete: false,
          bestMs: 2472000,
        ),
        daysLeft: 12,
        recentMs: const [2600, 2580, 2540, 2560, 2500, 2472]
            .map((s) => s * 1000)
            .toList(),
        recentDates: [
          for (var i = 0; i < 6; i++) DateTime(2026, 8, 1 + i * 7),
        ],
        history: history,
      );
  }
}

void main() {
  for (final stage in ['day1', 'week2', 'month3']) {
    for (final variant in ['none', 'offer', 'counter', 'best']) {
      if (variant == 'none' && stage != 'day1') continue;
      testWidgets('quests $stage $variant 360x800', (tester) async {
        await pumpApp(
          tester,
          fakeServices(),
          home: ProgressScreen(
            snapshot: ProgressSnapshot.sample(stage),
            questBoard: variant == 'none' ? QuestBoard.empty : _board(variant),
          ),
        );
        tester.view.physicalSize = const Size(1080, 800 * 3);
        await pumpTimes(tester, 8);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(
            variant == 'none'
                ? const ValueKey('quests-none')
                : const ValueKey('quests-section'),
          ),
          findsOneWidget,
        );
        final name = 'quests_${stage}_${variant}_360x800';
        expect(
          File('test/golden/goldens/$name.png').existsSync() ||
              autoUpdateGoldenFiles,
          isTrue,
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
      });
    }
  }
}
