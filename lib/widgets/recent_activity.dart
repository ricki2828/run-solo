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
            if (i == 0 && widget.estimates case final e?) ...[
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
    final title = run.mode == RecordMode.cooper
        ? 'VO2 max test'
        : runHeaderTitle(run);
    final typeColor = switch (run.mode) {
      RecordMode.free => AuroraRunType.free,
      RecordMode.laps
          when run.spec?.templateId == engine.SessionSpec.broncoId =>
        AuroraRunType.tests,
      RecordMode.laps => AuroraRunType.laps,
      RecordMode.cooper => AuroraRunType.tests,
      RecordMode.intervals when run.spec?.isGoal == true || run.isParkrun =>
        AuroraRunType.goal,
      RecordMode.intervals => AuroraRunType.intervals,
    };
    final (stat, statSmall) = _stat(run, units);
    final verdict = run.isFourByFour ? run.verdict : null;
    final word = verdict?.headline.text;
    final wordColor = switch (verdict?.headline) {
      engine.VerdictHeadline.faster => t.accentArc,
      _ => t.inkPrimary,
    };
    return Semantics(
      button: onTap != null,
      label:
          '$title, ${Fmt.ago(run.start, now)}${word == null ? '' : ', $word'}',
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
              const SizedBox(height: Space.x12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      style: RunSoloType.heading19.copyWith(color: typeColor),
                    ),
                  ),
                  if (run.mode == RecordMode.cooper)
                    SizedBox(
                      width: 32,
                      height: 32,
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
                  Text(
                    Fmt.ago(run.start, now),
                    style: RunSoloType.label13.copyWith(color: t.inkMuted),
                  ),
                ],
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
                      label: 'AVG PACE',
                      value: Fmt.paceUnit(run.avgSecPerKm, units),
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
    final g = r.analysis?.goal;
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
  Widget build(BuildContext context) => SizedBox(
    height: 148,
    width: double.infinity,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Radii.card),
      child: FutureBuilder<RunDetail?>(
        future: detail,
        builder: (context, snap) {
          if (!snap.hasData) {
            return _MapPlaceholder(
              text: snap.connectionState == ConnectionState.done
                  ? 'Route unavailable'
                  : 'Loading route',
            );
          }
          final d = snap.data!;
          if (d.analysis.indoor) {
            return const _MapPlaceholder(text: 'Indoor run, no route');
          }
          final route = RouteBuilder.build(d.run);
          if (route.isEmpty) {
            return const _MapPlaceholder(text: 'No route recorded');
          }
          // Static route thumbnail. The whole card opens run detail;
          // embedding a Google platform view would steal its gestures and
          // force several live map instances into Home's scrolling viewport.
          return RouteShape(route: route);
        },
      ),
    ),
  );
}

class _MapPlaceholder extends StatelessWidget {
  const _MapPlaceholder({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ColoredBox(
      color: t.bgBase,
      child: Center(
        child: Text(
          text,
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      ),
    );
  }
}

/// Distinct non-run insert in the normal vertical stream, after activity 1.
class _EstimatesTable extends StatelessWidget {
  const _EstimatesTable({required this.estimates});
  final engine.HomeEstimates estimates;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
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
                        style: RunSoloType.micro11.copyWith(color: t.inkMuted),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x8),
                      child: Text(
                        'EST. TIME',
                        style: RunSoloType.micro11.copyWith(color: t.inkMuted),
                      ),
                    ),
                  ],
                ),
                for (final row in estimates.rows)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.x8),
                        child: Text(
                          row.label,
                          style: RunSoloType.body17.copyWith(
                            color: t.inkPrimary,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.x8),
                        child: Text(
                          row.time,
                          textAlign: TextAlign.right,
                          style: RunSoloType.heading19.copyWith(
                            color: t.inkPrimary,
                            fontFeatures: RunSoloType.tabular,
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
    );
  }
}
