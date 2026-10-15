import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../screens/trail_board_screen.dart';
import '../state/history_store.dart';
import '../state/trails.dart';
import '../theme/theme.dart';
import 'trail_override_controls.dart';
import 'trail_runs_chart.dart';

/// "Your runs on this trail" on a Trail run's detail: the bars for every run
/// over the same route (moving time, faster taller, best dashed) and a link
/// to the trail board. Reads the index rows only. A run with no route
/// (indoors, no GPS) shows nothing; the first run on a trail says so.
///
/// The runner has the final say: "Not this trail" moves the run out of its
/// trail, "Same trail as..." joins a run that was not grouped to one of the
/// nearest trails, and "Back to automatic" hands the call back to the match.
/// A [free] run shows the section only when it is on a trail with others or
/// has a trail it could join.
class TrailRunsSection extends StatefulWidget {
  const TrailRunsSection({super.key, required this.runId, this.free = false});
  final String runId;
  final bool free;

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

  void _reload() {
    if (!mounted) return;
    setState(() => _runs = AppServices.of(context).history.list());
  }

  Future<void> _join(
    engine.TrailRunFacts me,
    List<engine.TrailCandidate> candidates,
  ) async {
    final units = AppServices.of(context).settings.settings.units;
    final picked = await showTrailPicker(
      context,
      candidates: candidates,
      units: units,
    );
    if (picked == null || !mounted) return;
    await applyTrailOverride(
      context,
      runId: me.id,
      override: engine.TrailOverride.join(picked.anchor.id),
      message: 'Joined ${picked.name}.',
      after: _reload,
    );
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
        final me = group.runs.firstWhere((r) => r.id == widget.runId);
        final candidates = group.runs.length < 2
            ? engine.Trails.candidates(me, groups)
            : const <engine.TrailCandidate>[];
        final set = me.override != null;
        if (widget.free &&
            group.runs.length < 2 &&
            candidates.isEmpty &&
            !set) {
          return const SizedBox.shrink();
        }
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
                me.override?.isSplit == true
                    ? 'You moved this run off its trail. It is on its own '
                          'until you join it to one.'
                    : set
                    ? 'The run you joined this to has moved on, so this one '
                          'is on its own until you join it to a trail.'
                    : 'First run on ${group.name}. Run it again to see how '
                          'you stack up.',
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
              Align(
                alignment: Alignment.centerLeft,
                child: NotThisTrailButton(
                  key: const ValueKey('detail-not-this-trail'),
                  onPressed: () => applyTrailOverride(
                    context,
                    runId: me.id,
                    override: const engine.TrailOverride.split(),
                    message: 'Moved out of ${group.name}.',
                    after: _reload,
                  ),
                ),
              ),
            ],
            if (candidates.isNotEmpty)
              TextButton(
                key: const ValueKey('same-trail-as'),
                onPressed: () => _join(me, candidates),
                child: const Text('SAME TRAIL AS...'),
              ),
            if (set)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('trail-back-to-automatic'),
                  onPressed: () => applyTrailOverride(
                    context,
                    runId: me.id,
                    override: null,
                    message: 'Back to the automatic match.',
                    after: _reload,
                  ),
                  child: const Text('BACK TO AUTOMATIC'),
                ),
              ),
            const SizedBox(height: Space.x24),
          ],
        );
      },
    );
  }
}
