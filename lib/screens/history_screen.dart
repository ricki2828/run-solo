import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/delta_glyph.dart';

enum HistoryFilter { all, fourByFour, laps, free }

/// History list (design brief §4.8, plan §18.2): newest first, grouped by
/// month, filter chips All / 4x4 / Laps / Free, verdict arrow in the
/// semantic colour, tap opens the verdict (4x4) or the run detail.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.onStart});

  /// Empty-state button; null hides it (e.g. inside the recording flow).
  final VoidCallback? onStart;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryFilter _filter = HistoryFilter.all;
  Future<List<RunSummary>>? _runs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= AppServices.of(context).history.list();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final units = AppServices.of(context).settings.settings.units;
    return Scaffold(
      appBar: AppBar(title: const Text('HISTORY')),
      body: SafeArea(
        child: FutureBuilder<List<RunSummary>>(
          future: _runs,
          builder: (context, snap) {
            final all = snap.data;
            if (all == null) return const SizedBox.shrink();
            final runs = all.where((r) {
              return switch (_filter) {
                HistoryFilter.all => true,
                HistoryFilter.fourByFour => r.isFourByFour,
                HistoryFilter.laps => r.mode == RecordMode.laps,
                HistoryFilter.free => r.mode == RecordMode.free,
              };
            }).toList();
            if (all.isEmpty) return _Empty(onStart: widget.onStart);
            return ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x8),
                Row(
                  children: [
                    for (final f in HistoryFilter.values) ...[
                      _FilterChip(
                        label: switch (f) {
                          HistoryFilter.all => 'All',
                          HistoryFilter.fourByFour => '4x4',
                          HistoryFilter.laps => 'Laps',
                          HistoryFilter.free => 'Free',
                        },
                        selected: _filter == f,
                        onTap: () => setState(() => _filter = f),
                      ),
                      const SizedBox(width: Space.x8),
                    ],
                  ],
                ),
                const SizedBox(height: Space.x16),
                if (runs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x32),
                    child: Text(
                      'Nothing here yet.',
                      style: text.bodyLarge?.copyWith(color: t.inkSecondary),
                    ),
                  ),
                ..._grouped(runs, units, t),
                const SizedBox(height: Space.x24),
              ],
            );
          },
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
                '${modeTitle(r.mode)}, ${Fmt.dayDate(r.start)}. The run, its '
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
    String? month;
    for (final r in runs) {
      final m = Fmt.monthYear(r.start);
      if (m != month) {
        month = m;
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: Space.x16, bottom: Space.x8),
            child: Text(
              m.toUpperCase(),
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
          ),
        );
      }
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
    return out;
  }
}

/// Verdict arrow + colour for a row (up = faster in Arc, down = slower in
/// Vermillion, flat = holding / no real change, a dot for baseline, "!" for
/// no verdict, nothing for other run types).
(DeltaDirection?, String, Color) verdictGlyph(
  engine.Verdict? v,
  RunSoloTokens t,
) => switch (v?.headline) {
  engine.VerdictHeadline.faster => (DeltaDirection.up, '', t.semFaster),
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
    final label = modeTitle(run.mode);
    return Semantics(
      button: onTap != null,
      label:
          '$label, ${Fmt.dayDate(run.start)}${run.verdict == null ? '' : ', ${run.verdict!.headline.text}'}',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: Space.x12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.lineHair)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  modeLabel(run.mode),
                  style: RunSoloType.title28.copyWith(
                    fontSize: 20,
                    color: muted,
                  ),
                ),
              ),
              const SizedBox(width: Space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Fmt.dayDate(run.start),
                      style: RunSoloType.body17.copyWith(color: muted),
                    ),
                    Text(
                      run.missing
                          ? 'File missing'
                          : switch (run.mode) {
                              RecordMode.intervals =>
                                run.analysis?.intervals != null
                                    ? '${run.analysis!.intervals!.reps.length} reps · ${Fmt.distance(run.distanceM, units)}'
                                    : '${run.laps} laps · ${Fmt.distance(run.distanceM, units)}',
                              RecordMode.laps =>
                                '${run.laps} laps · ${Fmt.distance(run.distanceM, units)}',
                              RecordMode.free || RecordMode.cooper =>
                                Fmt.distance(run.distanceM, units),
                            },
                      style: RunSoloType.label13.copyWith(
                        color: run.missing ? t.semWarn : t.inkSecondary,
                      ),
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
                              fontSize: 22,
                              color: glyphColor,
                            ),
                          ),
                        ),
                      Text(
                        Fmt.paceUnit(run.headlineSecPerKm, units),
                        style: RunSoloType.title28.copyWith(
                          fontSize: 22,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    Fmt.clock(run.durationMs),
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: Space.x16),
          alignment: Alignment.center,
          // Selected = 2 px Bone border, like the mode chips (brief §5).
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.chip),
            border: Border.all(
              color: selected ? t.inkPrimary : t.lineHair,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: RunSoloType.label13.copyWith(
              color: selected ? t.inkPrimary : t.inkSecondary,
            ),
          ),
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
          const TallyMark(height: 40, earned: false),
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
