import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/perf_diagnostics.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/history_weeks.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/choice_chips.dart';
import '../widgets/delta_glyph.dart';
import '../widgets/recent_activity.dart' show runTypeColor;
import '../widgets/run_card.dart';
import '../widgets/where_when_line.dart';
import '../widgets/zone_strip.dart';
import 'trend_screen.dart';

enum HistoryFilter { all, intervals, laps, free, trail, tests }

/// The first History list of the session, timed for Settings → Diagnostics
/// (dogfood only).
Future<List<RunSummary>> _timedFirstList(Future<List<RunSummary>> list) {
  if (!kPerfDiagnostics) return list;
  final sw = Stopwatch()..start();
  return list.then((runs) {
    PerfDiagnostics.instance.recordHistoryOpen(sw.elapsed);
    return runs;
  });
}

/// History list (design brief §4.8, plan §3.8): newest first, grouped by
/// week (this week, last week, date ranges, then months) with each period's
/// totals, filter chips All / Intervals / Laps / Free / Trail / Tests, each
/// row titled by its session, verdict arrow in the semantic colour, tap opens
/// the verdict (4x4) or the run detail.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.onStart});

  /// Empty-state button; null hides it (e.g. inside the recording flow).
  final VoidCallback? onStart;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryFilter _filter = HistoryFilter.all;
  // 1 = CHRONOLOGICAL, 2 = TRENDS (keys history-view-N are kept stable).
  int _view = 1;
  Future<List<RunSummary>>? _runs;
  RunStore? _history;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final history = AppServices.of(context).history;
    if (_history != history) {
      _history?.derivedChanged.removeListener(_refresh);
      _history = history..derivedChanged.addListener(_refresh);
      _runs = _timedFirstList(history.list());
    }
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _runs = AppServices.of(context).history.list());
  }

  @override
  void dispose() {
    _history?.derivedChanged.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final units = AppServices.of(context).settings.settings.units;
    return Scaffold(
      appBar: const RunAppBar(title: 'HISTORY'),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x8,
                Space.screenGutter,
                Space.x8,
              ),
              child: Row(
                // Intrinsic widths, left aligned. Boards and records live on
                // the Progress tab; History is the run log only.
                children: [
                  for (final (i, label) in const [
                    (1, 'CHRONOLOGICAL'),
                    (2, 'TRENDS'),
                  ])
                    Semantics(
                      button: true,
                      selected: _view == i,
                      child: InkWell(
                        key: ValueKey('history-view-$i'),
                        onTap: () => setState(() => _view = i),
                        child: Container(
                          alignment: Alignment.center,
                          height: 48,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.x8,
                          ),
                          decoration: BoxDecoration(
                            color: _view == i ? t.bgRaised : null,
                            borderRadius: BorderRadius.circular(Radii.button),
                          ),
                          child: Text(
                            label,
                            maxLines: 1,
                            style: RunSoloType.label13.copyWith(
                              fontWeight: FontWeight.w600,
                              color: _view == i ? t.inkPrimary : t.inkSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _view - 1,
                children: [
                  FutureBuilder<List<RunSummary>>(
                    future: _runs,
                    builder: (context, snap) {
                      final all = snap.data;
                      if (all == null) return const SizedBox.shrink();
                      final runs = all.where((r) {
                        return switch (_filter) {
                          HistoryFilter.all => true,
                          HistoryFilter.intervals =>
                            r.mode == RecordMode.intervals,
                          HistoryFilter.laps => r.mode == RecordMode.laps,
                          HistoryFilter.free => r.mode == RecordMode.free,
                          HistoryFilter.trail => r.mode == RecordMode.trail,
                          HistoryFilter.tests => r.mode == RecordMode.cooper,
                        };
                      }).toList();
                      if (all.isEmpty) return _Empty(onStart: widget.onStart);
                      return ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.screenGutter,
                        ),
                        children: [
                          const SizedBox(height: Space.x8),
                          ChoiceChips(
                            labels: const [
                              'All',
                              'Intervals',
                              'Laps',
                              'Free',
                              'Trail',
                              'Tests',
                            ],
                            selected: HistoryFilter.values.indexOf(_filter),
                            onSelect: (i) => setState(
                              () => _filter = HistoryFilter.values[i],
                            ),
                          ),
                          const SizedBox(height: Space.x16),
                          if (runs.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: Space.x32),
                              child: Text(
                                'Nothing here yet.',
                                style: text.bodyLarge?.copyWith(
                                  color: t.inkSecondary,
                                ),
                              ),
                            ),
                          if (runs.isNotEmpty) ..._grouped(runs, units, t),
                          const SizedBox(height: Space.x24),
                        ],
                      );
                    },
                  ),
                  const TrendScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Delete a run: confirm sheet, then file + sidecar go together. The run
  /// still being recorded is refused (its file does not exist yet anyway).
  Future<void> _confirmDelete(RunSummary r) async {
    final services = AppServices.of(context);
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    if (services.recording.snapshot.active &&
        services.recording.snapshot.runId == r.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That run is still recording.')),
      );
      return;
    }
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: t.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.screenGutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DELETE THIS RUN?',
                key: const ValueKey('delete-sheet'),
                style: RunSoloType.title28.copyWith(color: t.inkPrimary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                '${runTitle(r)}, ${Fmt.dayDate(r.start)}. The run, its '
                'edits and its verdict go with it. There is no undo.',
                style: RunSoloType.body17.copyWith(color: t.inkPrimary),
              ),
              const SizedBox(height: Space.x24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(
                        'KEEP',
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: t.semDanger,
                        foregroundColor: t.inkPrimary,
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('DELETE'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await services.history.delete(r.id);
    if (!mounted) return;
    final refreshed = services.history.list();
    setState(() {
      _runs = refreshed;
    });
  }

  List<Widget> _grouped(List<RunSummary> runs, Units units, RunSoloTokens t) {
    final out = <Widget>[];
    final now = AppServices.of(context).now();
    for (final g in groupByWeek(runs, now)) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: Space.x16, bottom: Space.x8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                g.header,
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x4),
              Text(
                g.runs.isEmpty ? 'No runs yet this week' : g.totals(units),
                key: ValueKey('history-totals-${g.header}'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ),
        ),
      );
      for (final r in g.runs) {
        out.add(
          HistoryRow(
            run: r,
            units: units,
            onLongPress: () => _confirmDelete(r),
            onTap: r.missing
                ? null
                : () async {
                    await Navigator.of(context).pushNamed(
                      r.isFourByFour ? Routes.verdict : Routes.runDetail,
                      arguments: r.id,
                    );
                    if (mounted) {
                      setState(() {
                        _runs = AppServices.of(context).history.list();
                      });
                    }
                  },
          ),
        );
      }
    }
    return out;
  }
}

/// Verdict arrow + colour for a row (up = faster in mint, down = slower in
/// Vermillion, flat = holding / no real change, a dot for baseline, "!" for
/// no verdict, nothing for other run types).
(DeltaDirection?, String, Color) verdictGlyph(
  engine.Verdict? v,
  RunSoloTokens t,
) => switch (v?.headline) {
  engine.VerdictHeadline.faster => (DeltaDirection.up, '', t.semImproving),
  engine.VerdictHeadline.slower => (DeltaDirection.down, '', t.semSlower),
  engine.VerdictHeadline.holding => (DeltaDirection.flat, '', t.semHolding),
  engine.VerdictHeadline.noRealChange => (DeltaDirection.flat, '', t.semNoise),
  engine.VerdictHeadline.baselineSet => (null, '·', t.inkSecondary),
  engine.VerdictHeadline.noVerdict ||
  engine.VerdictHeadline.indoorRun => (null, '!', t.semNoise),
  null => (null, '', t.inkSecondary),
};

class HistoryRow extends StatelessWidget {
  const HistoryRow({
    super.key,
    required this.run,
    required this.units,
    this.onTap,
    this.onLongPress,
  });
  final RunSummary run;
  final Units units;
  final VoidCallback? onTap;

  /// Long-press → delete confirm sheet (founder field test, 25-Sep).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final muted = run.missing ? t.inkMuted : t.inkPrimary;
    final (direction, glyph, glyphColor) = verdictGlyph(run.verdict, t);
    final label = runIdentityTitle(run);
    // The run's time in zone under its row; none without a strap.
    final zoneSeconds = run.missing
        ? null
        : run.hrHist?.zoneSeconds(AppServices.of(context).hrZones);
    return Semantics(
      button: onTap != null,
      label:
          '$label, ${runWhereWhen(run)}${run.verdict == null ? '' : ', ${run.verdict!.headline.text}'}',
      child: RunCard(
        accent: run.missing ? t.inkMuted : runTypeColor(run, t),
        onTap: onTap,
        onLongPress: onLongPress,
        margin: const EdgeInsets.only(bottom: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 56,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    // The run type as a pill in its own colour.
                    child: RunTypePill(
                      label: runLabel(run),
                      fill: run.missing ? t.bgRaised : runTypeColor(run, t),
                    ),
                  ),
                ),
                const SizedBox(width: Space.x12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: RunSoloType.body17.copyWith(color: muted),
                      ),
                      WhereWhenLine(
                        place: run.place,
                        street: run.street,
                        start: run.start,
                        utcOffsetMin: run.utcOffsetMin,
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                      Row(
                        children: [
                          // Follow a route: a small badge on a run that followed one.
                          if (run.routeName != null)
                            Padding(
                              padding: const EdgeInsets.only(right: Space.x4),
                              child: Icon(
                                Icons.alt_route,
                                key: ValueKey('route-badge-${run.id}'),
                                size: 14,
                                color: t.inkSecondary,
                                semanticLabel: 'Followed ${run.routeName}',
                              ),
                            ),
                          Flexible(
                            child: Text(
                              run.missing
                                  ? 'File missing'
                                  : switch (run.mode) {
                                      RecordMode.intervals =>
                                        run.detectedReps != null
                                            ? '${run.detectedReps} reps · ${Fmt.distance(run.distanceM, units)}'
                                            : run.spec != null
                                            ? '${run.spec!.name} · ${Fmt.distance(run.distanceM, units)}'
                                            : '${run.laps} laps · ${Fmt.distance(run.distanceM, units)}',
                                      RecordMode.laps
                                          when run.spec?.templateId ==
                                              engine.SessionSpec.fartlekId =>
                                        'Fartlek · ${Fmt.distance(run.distanceM, units)}',
                                      RecordMode.laps =>
                                        '${run.laps} laps · ${Fmt.distance(run.distanceM, units)}',
                                      RecordMode.free || RecordMode.trail =>
                                        Fmt.distance(run.distanceM, units),
                                      // The test's own window (27-Sep field test:
                                      // total distance counted the cool-down).
                                      RecordMode.cooper => Fmt.distance(
                                        run.cooper?.testDistanceM ??
                                            run.distanceM,
                                        units,
                                      ),
                                    },
                              style: RunSoloType.label13.copyWith(
                                color: run.missing ? t.semWarn : t.inkSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (direction != null)
                          Padding(
                            padding: const EdgeInsets.only(right: Space.x8),
                            child: DeltaGlyph(
                              key: ValueKey('verdict-glyph-${run.id}'),
                              direction: direction,
                              color: glyphColor,
                              size: 14,
                            ),
                          )
                        else if (glyph.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: Space.x8),
                            child: Text(
                              glyph,
                              key: ValueKey('verdict-glyph-${run.id}'),
                              style: RunSoloType.title28.copyWith(
                                fontSize: 24,
                                color: glyphColor,
                              ),
                            ),
                          ),
                        Text(
                          run.mode == RecordMode.cooper &&
                                  run.cooper?.primeVo2 != null
                              ? '${run.cooper!.primeVo2!.round()}'
                              : Fmt.paceUnit(run.headlineSecPerKm, units),
                          style: RunSoloType.title28.copyWith(
                            fontSize: 26,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      run.mode == RecordMode.cooper
                          ? (run.cooper?.valid == true
                                ? '12:00'
                                : Fmt.clock(
                                    run.durationMs <
                                            engine
                                                    .CooperProjection
                                                    .testSeconds *
                                                1000
                                        ? run.durationMs
                                        : engine.CooperProjection.testSeconds *
                                              1000,
                                  ))
                          : Fmt.clock(run.durationMs),
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (zoneSeconds != null) ...[
              const SizedBox(height: Space.x8),
              ZoneStrip(
                key: ValueKey('zone-strip-${run.id}'),
                seconds: zoneSeconds,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.onStart});
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LapLineMark(height: 40),
          const SizedBox(height: Space.x24),
          Text(
            'Your first 4x4 sets the baseline.',
            style: RunSoloType.body17.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x24),
          if (onStart != null)
            FilledButton(onPressed: onStart, child: const Text('START')),
        ],
      ),
    );
  }
}
