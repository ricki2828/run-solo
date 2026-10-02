import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/trails.dart';
import '../theme/theme.dart';
import '../widgets/trail_runs_chart.dart';
import 'run_detail_screen.dart';

/// The board of one trail (two or more runs over the same route): the best
/// moving time, the bars for every run, and the table. Matched by route in
/// the engine, so it opens from the result, the run detail and the Boards
/// tab; [trailKey] is the group's `trail:<first run id>`.
class TrailBoardScreen extends StatefulWidget {
  const TrailBoardScreen({super.key, required this.trailKey});
  final String trailKey;

  @override
  State<TrailBoardScreen> createState() => _TrailBoardScreenState();
}

class _TrailBoardScreenState extends State<TrailBoardScreen> {
  Future<List<RunSummary>>? _runs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= AppServices.of(context).history.list();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final units = AppServices.of(context).settings.settings.units;
    return FutureBuilder<List<RunSummary>>(
      future: _runs,
      builder: (context, snap) {
        final runs = snap.data;
        final group = runs == null
            ? null
            : trailBoards(runs)
                  .where((g) => g.key == widget.trailKey)
                  .firstOrNull;
        return Scaffold(
          appBar: AppBar(title: Text((group?.name ?? 'TRAIL').toUpperCase())),
          body: group == null
              ? Padding(
                  padding: const EdgeInsets.all(Space.screenGutter),
                  child: Text(
                    runs == null
                        ? 'Checking your trail'
                        : 'This trail needs two runs for a board.',
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                )
              : _Body(group: group, units: units),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.group, required this.units});
  final engine.TrailGroup group;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final best = group.best;
    final ranked = [...group.runs]
      ..sort((a, b) {
        final c = a.movingMs.compareTo(b.movingMs);
        return c != 0 ? c : a.start.compareTo(b.start);
      });
    final last = group.runs.last;
    final lastRank = ranked.indexWhere((r) => r.id == last.id) + 1;
    return ListView(
      key: const ValueKey('trail-board'),
      padding: const EdgeInsets.fromLTRB(
        Space.screenGutter,
        Space.x8,
        Space.screenGutter,
        Space.x32,
      ),
      children: [
        Text(
          'BEST ON THIS TRAIL',
          style: RunSoloType.micro11.copyWith(color: t.accentArc),
        ),
        const SizedBox(height: Space.x4),
        Text(
          Fmt.clock(best.movingMs),
          key: const ValueKey('trail-board-best'),
          style: RunSoloType.display44.copyWith(color: t.inkPrimary),
        ),
        Text(
          '${Fmt.dayDate(best.start)} · ${group.runs.length} runs · '
          '${lastRank == 1 ? 'last was your best' : 'last was #$lastRank'}',
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x24),
        TrailRunsChart(
          group: group,
          chartKey: const ValueKey('trail-board-chart'),
          showValues: false,
        ),
        const SizedBox(height: Space.x24),
        for (var i = 0; i < ranked.length; i++)
          _RunRow(
            rank: i + 1,
            run: ranked[i],
            best: best,
            units: units,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RunDetailScreen(runId: ranked[i].id),
              ),
            ),
          ),
      ],
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({
    required this.rank,
    required this.run,
    required this.best,
    required this.units,
    required this.onTap,
  });
  final int rank;
  final engine.TrailRunFacts run;
  final engine.TrailRunFacts best;
  final Units units;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final off = run.movingMs - best.movingMs;
    final climb = run.climbM == null
        ? ''
        : ' · ${Fmt.elevation(run.climbM, units)} climb';
    return Semantics(
      button: true,
      label: '#$rank, ${Fmt.clock(run.movingMs)}, ${Fmt.dayDate(run.start)}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '#$rank',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      Fmt.clock(run.movingMs),
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    Text(
                      '${Fmt.dayDate(run.start)}$climb',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ],
                ),
              ),
              Text(
                off <= 0 ? 'Best' : '+${Fmt.clock(off)}',
                style: RunSoloType.body15.copyWith(
                  color: off <= 0 ? t.accentArc : t.inkSecondary,
                ),
              ),
              Icon(Icons.chevron_right, color: t.inkSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
