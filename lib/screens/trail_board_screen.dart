import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/trails.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/run_card.dart';
import '../widgets/trail_override_controls.dart';
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

  /// A run of this trail the board follows, so it stays on the same trail
  /// when the runner moves a run out (the key follows the anchor, and the
  /// anchor can be the run that left). Starts as the key's anchor.
  late String _memberId = widget.trailKey.replaceFirst('trail:', '');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= AppServices.of(context).history.list();
  }

  engine.TrailGroup? _groupIn(List<RunSummary> runs) {
    final groups = engine.Trails.group(trailFactsOfAll(runs));
    final g = engine.Trails.groupOf(_memberId, groups);
    return g == null || g.runs.length < 2 ? null : g;
  }

  Future<void> _notThisTrail(
    engine.TrailGroup group,
    engine.TrailRunFacts run,
  ) async {
    final nav = Navigator.of(context);
    final left = group.runs.where((r) => r.id != run.id).toList();
    if (_memberId == run.id) _memberId = left.first.id;
    await applyTrailOverride(
      context,
      runId: run.id,
      override: const engine.TrailOverride.split(),
      message: 'Moved out of ${group.name}.',
      after: () {
        if (!mounted) return;
        setState(() => _runs = AppServices.of(context).history.list());
      },
    );
    // A trail left with one run has no board: back to where it opened from.
    if (left.length < 2 && nav.mounted) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final units = AppServices.of(context).settings.settings.units;
    return FutureBuilder<List<RunSummary>>(
      future: _runs,
      builder: (context, snap) {
        final runs = snap.data;
        final group = runs == null ? null : _groupIn(runs);
        return Scaffold(
          appBar: RunAppBar(title: group?.name ?? 'TRAIL'),
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
              : _Body(
                  group: group,
                  units: units,
                  onNotThisTrail: (r) => _notThisTrail(group, r),
                ),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.group,
    required this.units,
    required this.onNotThisTrail,
  });
  final engine.TrailGroup group;
  final Units units;
  final void Function(engine.TrailRunFacts run) onNotThisTrail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final best = group.best;
    // Only a best nobody ties is Best; level runs are just on the board.
    final uniqueBest =
        group.runs.where((r) => group.normMs(r) == group.normMs(best)).length ==
        1;
    final ranked = [...group.runs]
      ..sort((a, b) {
        final c = group.normMs(a).compareTo(group.normMs(b));
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
          Fmt.clock(group.normMs(best)),
          key: const ValueKey('trail-board-best'),
          style: RunSoloType.display44.copyWith(color: t.inkPrimary),
        ),
        Text(
          '${Fmt.dayDate(best.start)} · ${group.runs.length} runs · '
          '${lastRank == 1 ? 'last was your best' : 'last was #$lastRank'}',
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x4),
        Text(
          'Compared on pace over ${Fmt.distance1(group.refDistanceM, units)}, '
          'heat taken out.',
          key: const ValueKey('trail-board-basis'),
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
            group: group,
            units: units,
            uniqueBest: uniqueBest,
            onNotThisTrail: () => onNotThisTrail(ranked[i]),
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
    required this.group,
    required this.units,
    required this.uniqueBest,
    required this.onNotThisTrail,
    required this.onTap,
  });
  final int rank;
  final engine.TrailRunFacts run;
  final engine.TrailRunFacts best;
  final engine.TrailGroup group;
  final Units units;

  /// Only a best nobody ties gets the cyan accent and the word Best.
  final bool uniqueBest;
  final VoidCallback onNotThisTrail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final norm = group.normMs(run);
    final off = norm - group.normMs(best);
    // A run of another length says so, since its time is worked out on pace.
    final ref = group.refDistanceM;
    final gapM = run.distanceM - ref;
    final far =
        ref > 0 && gapM.abs() / ref > engine.TrailVerdict.distanceTolerance
        ? ' · ${Fmt.distance1(gapM.abs(), units)} '
              '${gapM < 0 ? 'shorter' : 'longer'}'
        : '';
    final margin = engine.Trails.marginOf(group, run);
    final climb = run.climbM == null
        ? ''
        : ' · ${Fmt.elevation(run.climbM, units)} climb';
    final main = Semantics(
      button: true,
      label: '#$rank, ${Fmt.clock(norm)}, ${Fmt.dayDate(run.start)}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
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
                    Fmt.clock(norm),
                    style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                  ),
                  Text(
                    '${Fmt.dayDate(run.start)}$far$climb',
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
            ),
            Text(
              off <= 0 ? (uniqueBest ? 'Best' : 'Level') : '+${Fmt.clock(off)}',
              style: RunSoloType.body15.copyWith(
                color: off <= 0 && uniqueBest ? t.accentArc : t.inkSecondary,
              ),
            ),
            Icon(Icons.chevron_right, color: t.inkSecondary),
          ],
        ),
      ),
    );
    final accent = off <= 0 && uniqueBest ? t.accentArc : t.typeTrail;
    // "Not this trail" shows on a row only where the match looks marginal;
    // the run's own screen always offers it.
    if (margin == null) {
      return RunCard(
        accent: accent,
        onTap: onTap,
        margin: const EdgeInsets.only(bottom: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x8,
        ),
        child: main,
      );
    }
    return RunCard(
      accent: accent,
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: Space.x8),
      padding: const EdgeInsets.fromLTRB(
        Space.x12,
        Space.x8,
        Space.x4,
        Space.x4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          main,
          Row(
            children: [
              const SizedBox(width: 36),
              Expanded(
                child: Text(
                  'Looks off: ${trailMarginLabel(margin)}',
                  key: ValueKey('looks-off-${run.id}'),
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              NotThisTrailButton(
                key: ValueKey('not-this-trail-${run.id}'),
                onPressed: onNotThisTrail,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
