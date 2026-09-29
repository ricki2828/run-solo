import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';

/// The Home RECENT ACTIVITY strip (signed off 27-Sep): the last three
/// sessions of any kind, newest first, each tappable into its verdict or
/// detail, plus the "All activity" link to History. Replaces the old
/// 4x4-only last-run card - the dashboard covers every mode.
class RecentActivity extends StatelessWidget {
  const RecentActivity({
    super.key,
    required this.runs,
    required this.units,
    required this.now,
    this.onOpen,
    this.onShowAll,
  });

  /// All sessions, newest first; the strip takes the first three.
  final List<RunSummary> runs;
  final Units units;
  final DateTime now;
  final ValueChanged<RunSummary>? onOpen;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final shown = runs.where((r) => !r.missing).take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'RECENT ACTIVITY',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        if (shown.isEmpty)
          Text(
            'Nothing yet. Sessions of any kind - 4x4, Laps, Free, tests - '
            'land here, newest first.',
            style: text.bodyMedium?.copyWith(color: t.inkSecondary),
          )
        else ...[
          for (final r in shown) ...[
            _ActivityRow(
              run: r,
              units: units,
              now: now,
              onTap: onOpen == null ? null : () => onOpen!(r),
            ),
            const SizedBox(height: Space.x8),
          ],
          if (onShowAll != null)
            InkWell(
              onTap: onShowAll,
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
  });

  final RunSummary run;
  final Units units;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final title = runHeaderTitle(run);
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: title.toUpperCase(),
                            style: RunSoloType.heading19.copyWith(
                              color: typeColor,
                            ),
                          ),
                          TextSpan(
                            text:
                                '  ·  ${Fmt.ago(run.start, now).toLowerCase()}',
                            style: RunSoloType.body15.copyWith(
                              color: t.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.x4),
                    Text(
                      _subline(run, units),
                      style: text.bodyMedium?.copyWith(color: t.inkSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.x12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: stat, style: RunSoloType.heading26),
                        if (statSmall != null)
                          TextSpan(
                            text: statSmall,
                            style: RunSoloType.label13.copyWith(
                              color: t.inkSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (word != null)
                    Text(
                      '▲ ${word.toUpperCase()}',
                      style: RunSoloType.micro11.copyWith(color: wordColor),
                    ),
                ],
              ),
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

  static String _subline(RunSummary r, Units units) {
    if (r.mode == RecordMode.cooper) {
      final c = r.cooper;
      if (c != null && c.valid && c.testDistanceM > 0) {
        final base = '${c.testDistanceM.round()} m in 12:00';
        return c.vo2Adjusted == null
            ? base
            : '$base · heat-adj from ${c.vo2?.toStringAsFixed(1)}';
      }
      return Fmt.clock(r.durationMs);
    }
    if (r.isFourByFour) {
      return '${r.laps} laps · ${Fmt.clock(r.durationMs)}';
    }
    return '${Fmt.clock(r.durationMs)} · '
        '${Fmt.paceUnit(r.headlineSecPerKm, units)}';
  }
}
