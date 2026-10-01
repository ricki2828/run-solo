import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../map/map_surface.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';

/// Home's recent activities in the page's normal vertical scroll: the last
/// three sessions, each with a static route thumbnail when one exists. An
/// estimated-times table sits after activity one, before activity two.
class RecentActivity extends StatefulWidget {
  const RecentActivity({
    super.key,
    required this.runs,
    required this.units,
    required this.now,
    this.onOpen,
    this.onShowAll,
    this.estimates,
  });

  /// All sessions, newest first; Home shows the first three as map cards.
  final List<RunSummary> runs;
  final Units units;
  final DateTime now;
  final ValueChanged<RunSummary>? onOpen;
  final VoidCallback? onShowAll;
  final engine.HomeEstimates? estimates;

  @override
  State<RecentActivity> createState() => _RecentActivityState();
}

class _RecentActivityState extends State<RecentActivity> {
  final _details = <String, Future<RunDetail?>>{};
  RunStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = AppServices.of(context).history;
    if (_store != store) {
      _store = store;
      _details.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final shown = widget.runs.where((r) => !r.missing).take(3).toList();
    final ids = shown.map((r) => r.id).toSet();
    _details.removeWhere((id, _) => !ids.contains(id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RECENT ACTIVITY',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        if (shown.isEmpty) ...[
          Text(
            'Nothing yet. Sessions of any kind - 4x4, Laps, Free, tests - '
            'land here, newest first.',
            style: text.bodyMedium?.copyWith(color: t.inkSecondary),
          ),
          if (widget.estimates case final e?) ...[
            const SizedBox(height: Space.x16),
            _EstimatesTable(estimates: e),
          ],
        ] else ...[
          for (var i = 0; i < shown.length; i++) ...[
            _ActivityRow(
              run: shown[i],
              units: widget.units,
              now: widget.now,
              detail: _details.putIfAbsent(
                shown[i].id,
                () => _store!.load(shown[i].id),
              ),
              onTap: widget.onOpen == null
                  ? null
                  : () => widget.onOpen!(shown[i]),
            ),
            const SizedBox(height: Space.x12),
            if (widget.estimates case final e? when i == 0) ...[
              _EstimatesTable(estimates: e),
              const SizedBox(height: Space.x12),
            ],
          ],
          if (widget.onShowAll != null)
            InkWell(
              onTap: widget.onShowAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x4),
                child: Center(
                  child: Text(
                    'All activity ›',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// The Aurora run-type colour: only ever on the session name and the
/// figures, never on the title's time-of-day word.
Color runTypeColor(RunSummary run) => switch (run.mode) {
  RecordMode.free => AuroraRunType.free,
  RecordMode.laps when run.spec?.templateId == engine.SessionSpec.broncoId =>
    AuroraRunType.tests,
  RecordMode.laps => AuroraRunType.laps,
  RecordMode.cooper => AuroraRunType.tests,
  RecordMode.intervals when run.spec?.isGoal == true || run.isParkrun =>
    AuroraRunType.goal,
  RecordMode.intervals => AuroraRunType.intervals,
};

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.run,
    required this.units,
    required this.now,
    this.onTap,
    required this.detail,
  });

  final Future<RunDetail?> detail;
  final RunSummary run;
  final Units units;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final sessionName = run.mode == RecordMode.cooper
        ? 'VO2 max test'
        : runSessionName(run);
    final custom = run.customTitle;
    final timeWord = engine.RunIdentity.timeOfDay(run.start.toLocal());
    final title = custom ?? '$timeWord $sessionName';
    final typeColor = runTypeColor(run);
    final (stat, statSmall) = _stat(run, units);
    // An interval run's card shows the pace of the work reps, the figure
    // Home and the verdict use, not the whole-run average (which includes
    // the jogs and reads far slower).
    final workPace = run.isFourByFour && run.workPaceSecPerKm != null;
    final verdict = run.isFourByFour ? run.verdict : null;
    final word = verdict?.headline.text;
    final wordColor = switch (verdict?.headline) {
      engine.VerdictHeadline.faster => t.accentArc,
      _ => t.inkPrimary,
    };
    return Semantics(
      button: onTap != null,
      label: '$title, ${runWhereWhen(run)}${word == null ? '' : ', $word'}',
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x16,
            vertical: Space.x12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ActivityMap(detail: detail),
              Row(
                children: [
                  Expanded(
                    // The run-type colour stays on the session name only.
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (custom == null)
                            TextSpan(
                              text: '$timeWord ',
                              style: TextStyle(color: t.inkPrimary),
                            ),
                          TextSpan(
                            text: custom ?? sessionName,
                            style: TextStyle(color: typeColor),
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RunSoloType.heading19,
                    ),
                  ),
                  if (run.mode == RecordMode.cooper)
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: 'VO2 max test info',
                        icon: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: t.inkSecondary,
                        ),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('VO2 max test'),
                            content: const Text(
                              'Cooper test: a 12-minute run used to estimate VO2 max from the distance covered. This is a running estimate, not a lab measurement.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Space.x4),
              Text(
                runWhereWhen(run),
                key: const ValueKey('activity-where-when'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x12),
              Row(
                children: [
                  Expanded(
                    child: _ActivityStat(
                      label: units == Units.km ? 'KM' : 'MI',
                      value: Fmt.distanceBare(run.distanceM, units),
                      color: typeColor,
                    ),
                  ),
                  Expanded(
                    child: _ActivityStat(
                      label: 'TIME',
                      value: Fmt.clock(run.durationMs),
                      color: typeColor,
                    ),
                  ),
                  Expanded(
                    child: _ActivityStat(
                      label: workPace ? 'WORK PACE' : 'AVG PACE',
                      value: Fmt.paceUnit(
                        workPace ? run.workPaceSecPerKm : run.avgSecPerKm,
                        units,
                      ),
                      color: typeColor,
                    ),
                  ),
                ],
              ),
              if (word != null || run.mode == RecordMode.cooper) ...[
                const SizedBox(height: Space.x8),
                Text(
                  word != null ? word.toUpperCase() : '$stat${statSmall ?? ''}',
                  style: RunSoloType.micro11.copyWith(color: wordColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The right-hand headline figure per mode: pace for a 4x4, the prime
  /// figure for a test, distance otherwise.
  static (String, String?) _stat(RunSummary r, Units units) {
    if (r.mode == RecordMode.cooper) {
      final c = r.cooper;
      final prime = c == null ? null : (c.vo2Adjusted ?? c.vo2);
      if (prime != null) return (prime.toStringAsFixed(1), ' VO2');
    }
    if (r.isFourByFour) {
      return (Fmt.paceUnit(r.headlineSecPerKm, units), null);
    }
    // A goal run's figure is its result: the finish time for a distance
    // goal, the distance covered for a time goal (29-Sep field test).
    final g = r.row?.goal ?? r.analysis?.goal;
    if (g != null && g.reached) {
      if (g.kind == engine.GoalKind.distance && g.goalMs != null) {
        return (Fmt.clock(g.goalMs!), null);
      }
      if (g.kind == engine.GoalKind.time && g.goalDistanceM != null) {
        final d = Fmt.distanceBare(g.goalDistanceM!, units);
        return (d, units == Units.km ? ' km' : ' mi');
      }
    }
    final d = Fmt.distanceBare(r.distanceM, units);
    return (d, units == Units.km ? ' km' : ' mi');
  }
}

class _ActivityStat extends StatelessWidget {
  const _ActivityStat({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        maxLines: 1,
        style: RunSoloType.heading19.copyWith(color: color),
      ),
      const SizedBox(height: Space.x4),
      Text(
        label,
        style: RunSoloType.micro11.copyWith(
          color: Theme.of(context).extension<RunSoloTokens>()!.inkSecondary,
        ),
      ),
    ],
  );
}

/// One static map per activity. There is no fake route for indoor runs or
/// incomplete GPS tracks; the card says so and still opens run detail.
class _ActivityMap extends StatelessWidget {
  const _ActivityMap({required this.detail});
  final Future<RunDetail?> detail;

  @override
  Widget build(BuildContext context) => FutureBuilder<RunDetail?>(
    future: detail,
    builder: (context, snap) {
      final d = snap.data;
      if (d == null || d.analysis.indoor) return const SizedBox.shrink();
      final route = RouteBuilder.build(d.run);
      if (route.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.x12),
        child: SizedBox(
          height: 148,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.card),
            child: RouteShape(route: route),
          ),
        ),
      );
    },
  );
}

class _EstimatesTable extends StatefulWidget {
  const _EstimatesTable({required this.estimates});
  final engine.HomeEstimates estimates;

  @override
  State<_EstimatesTable> createState() => _EstimatesTableState();
}

class _EstimatesTableState extends State<_EstimatesTable> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final estimates = widget.estimates;
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: estimates.message == null,
      toggled: estimates.message == null ? _open : null,
      child: InkWell(
        onTap: estimates.message == null
            ? () => setState(() => _open = !_open)
            : null,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          key: const ValueKey('recent-estimates-table'),
          width: double.infinity,
          padding: const EdgeInsets.all(Space.x16),
          decoration: BoxDecoration(
            color: t.bgBase,
            border: Border.all(color: t.lineHair),
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                engine.HomeEstimates.title,
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x12),
              if (estimates.message case final message?)
                Text(
                  message,
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                )
              else ...[
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(),
                    1: IntrinsicColumnWidth(),
                  },
                  children: [
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.x8),
                          child: Text(
                            'DISTANCE',
                            style: RunSoloType.micro11.copyWith(
                              color: t.inkMuted,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.x8),
                          child: Text(
                            'EST. TIME',
                            style: RunSoloType.micro11.copyWith(
                              color: t.inkMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    for (final row in estimates.rows)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: Space.x8,
                            ),
                            child: ExcludeSemantics(
                              child: Text(
                                row.label,
                                style: RunSoloType.body17.copyWith(
                                  color: t.inkPrimary,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: Space.x8,
                            ),
                            child: Semantics(
                              container: true,
                              label: row.semantics,
                              excludeSemantics: true,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    row.time,
                                    textAlign: TextAlign.right,
                                    style: RunSoloType.heading19.copyWith(
                                      color: t.inkPrimary,
                                      fontFeatures: RunSoloType.tabular,
                                    ),
                                  ),
                                  if (_open && row.band != null)
                                    Text(
                                      row.band!,
                                      textAlign: TextAlign.right,
                                      style: RunSoloType.label13.copyWith(
                                        color: t.inkSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                for (final source in estimates.sourceLines)
                  Text(
                    source,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
