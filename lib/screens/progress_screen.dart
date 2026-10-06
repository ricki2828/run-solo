import 'package:flutter/material.dart';

import '../widgets/chrome.dart';
import 'score_analysis.dart';

/// Progress is the dedicated analysis view. Boards and run trends live in
/// History, so the two tabs answer different questions.

class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const RunAppBar(title: 'PROGRESS'),
    body: const SafeArea(child: ScoreAnalysis()),
  );
}
