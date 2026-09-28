/// The Bronco test's result (manual sets, founder 28-Sep): the total time
/// for the 5 x 240 m shuttle sets and a split per set. Time only - the
/// 12-minute test stays the fitness measure, so no VO2, no board, no
/// verdict dressing. A measurement, like the Cooper result.
library;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';

class BroncoResultScreen extends StatelessWidget {
  const BroncoResultScreen({
    super.key,
    required this.detail,
    this.justFinished = false,
  });
  final RunDetail detail;
  final bool justFinished;

  /// The set laps: the runner's manual taps in order. Past
  /// [engine.SessionSpec.broncoSets] the test had already paused itself,
  /// so only the first five count.
  @visibleForTesting
  static List<engine.Lap> setsOf(engine.RunFile run) => [
    for (final l in run.laps)
      if (l.kind == engine.LapKind.manual) l,
  ].take(engine.SessionSpec.broncoSets).toList();

  /// The Bronco time: the sets back to back, clock running throughout.
  @visibleForTesting
  static int totalMsOf(List<engine.Lap> sets) =>
      sets.fold(0, (a, l) => a + l.durationMs);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = detail;
    final sets = setsOf(d.run);
    final complete = sets.length == engine.SessionSpec.broncoSets;
    final totalMs = totalMsOf(sets);
    final avgMs = sets.isEmpty ? 0 : totalMs ~/ sets.length;
    final fastestMs = sets.isEmpty
        ? 0
        : sets.map((l) => l.durationMs).reduce((a, b) => a < b ? a : b);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          children: [
            const SizedBox(height: Space.x16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'BRONCO · ${Fmt.dayDate(d.run.start)}',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ),
                if (!justFinished)
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                  ),
              ],
            ),
            const SizedBox(height: Space.x24),
            Text(
              Fmt.clock(totalMs),
              key: const ValueKey('bronco-total'),
              textAlign: TextAlign.center,
              style: RunSoloType.display96.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              complete
                  ? 'total for 5 x 240 m'
                  : 'total for ${sets.length} of 5 sets - ended early',
              key: const ValueKey('bronco-total-caption'),
              textAlign: TextAlign.center,
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x24),
            Divider(color: t.inkSecondary.withValues(alpha: 0.3)),
            for (var i = 0; i < sets.length; i++) ...[
              const SizedBox(height: Space.x12),
              Row(
                key: ValueKey('bronco-set-${i + 1}'),
                children: [
                  Expanded(
                    child: Text(
                      'SET ${i + 1}',
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                  ),
                  Text(
                    Fmt.clock(sets[i].durationMs),
                    style: RunSoloType.body17.copyWith(
                      color: sets[i].durationMs == fastestMs && complete
                          ? t.accentArc
                          : t.inkPrimary,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: Space.x24),
            Divider(color: t.inkSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: Space.x12),
            Text(
              'Average set ${Fmt.clock(avgMs)}.',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              'Time only. The 12-minute test stays the fitness measure.',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x24),
          ],
        ),
      ),
    );
  }
}
