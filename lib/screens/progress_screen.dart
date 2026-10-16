import 'package:flutter/material.dart';

import '../state/progress_snapshot.dart';
import '../state/quests/quest_build.dart';
import '../widgets/chrome.dart';
import 'score_analysis.dart';

/// Progress: YOUR PACK (age band from published norms), BOARDS & RECORDS and
/// the per-lane evidence. History is the run log only.
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key, this.snapshot, this.questBoard});

  /// Goldens and tests pass a fixture; production builds one from history.
  final ProgressSnapshot? snapshot;

  /// Goldens pass a fixed QUESTS board.
  final QuestBoard? questBoard;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const RunAppBar(title: 'PROGRESS'),
    body: SafeArea(child: ScoreAnalysis(snapshot: snapshot, questBoard: questBoard)),
  );
}
