import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/history_store.dart';
import '../theme/theme.dart';
import 'section_card.dart';

/// Home: one plain line from the strap, "Recovered: resting HR normal" or
/// "Take it easy: resting HR up 6 bpm", against the runner's own 7-day
/// baseline. Hidden without enough strap runs. The (i) opens the numbers and
/// the research-based caveat. Reads index-row fields only.
class ReadinessLine extends StatelessWidget {
  const ReadinessLine({super.key, required this.runs, required this.now});

  /// Every run (any order); only those with a resting-HR reading count.
  final List<RunSummary> runs;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final r = engine.Readiness.of([
      for (final run in runs)
        if (run.restingHrBpm != null && !run.missing)
          (date: run.start, bpm: run.restingHrBpm!),
    ], now: now);
    if (r == null) return const SizedBox.shrink();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x16),
      child: SectionCard(
        padding: const EdgeInsets.only(left: Space.x16, right: Space.x4),
        child: Row(
          children: [
            Icon(Icons.favorite, size: 16, color: t.hrZone),
            const SizedBox(width: Space.x8),
            Expanded(
              child: Text(
                r.line,
                key: const ValueKey('readiness-line'),
                style: RunSoloType.body15.copyWith(
                  color: r.takeItEasy ? t.semWarn : t.inkPrimary,
                ),
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                key: const ValueKey('readiness-info'),
                tooltip: 'About this',
                icon: Icon(Icons.info_outline, size: 20, color: t.inkSecondary),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Resting heart rate'),
                    content: Text(r.detail),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
