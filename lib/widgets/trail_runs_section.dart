import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../screens/trail_board_screen.dart';
import '../state/history_store.dart';
import '../state/trails.dart';
import '../theme/theme.dart';
import 'trail_runs_chart.dart';

/// "Your runs on this trail" on a Trail run's detail: the bars for every run
/// over the same route (moving time, faster taller, best dashed) and a link
/// to the trail board. Reads the index rows only. A run with no route
/// (indoors, no GPS) shows nothing; the first run on a trail says so.
class TrailRunsSection extends StatefulWidget {
  const TrailRunsSection({super.key, required this.runId});
  final String runId;

  @override
  State<TrailRunsSection> createState() => _TrailRunsSectionState();
}

class _TrailRunsSectionState extends State<TrailRunsSection> {
  Future<List<RunSummary>>? _runs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= AppServices.of(context).history.list();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return FutureBuilder<List<RunSummary>>(
      future: _runs,
      builder: (context, snap) {
        final runs = snap.data;
        if (runs == null) return const SizedBox.shrink();
        final groups = engine.Trails.group(trailFactsOfAll(runs));
        final group = engine.Trails.groupOf(widget.runId, groups);
        if (group == null) return const SizedBox.shrink();
        return Column(
          key: const ValueKey('trail-runs-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'YOUR RUNS ON THIS TRAIL',
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x8),
            if (group.runs.length < 2)
              Text(
                'First run on ${group.name}. Run it again to see how you '
                'stack up.',
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              )
            else ...[
              TrailRunsChart(
                group: group,
                chartKey: const ValueKey('trail-runs-chart'),
              ),
              const SizedBox(height: Space.x8),
              TextButton(
                key: const ValueKey('trail-board-link'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TrailBoardScreen(trailKey: group.key),
                  ),
                ),
                child: Text('${group.name} board'.toUpperCase()),
              ),
            ],
            const SizedBox(height: Space.x24),
          ],
        );
      },
    );
  }
}
