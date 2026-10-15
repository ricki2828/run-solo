import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'run_card.dart';

/// The quiet "looks off" hint for a run that sits near a matching gate of its
/// trail: the gate it is nearest to, in words ("9% longer"). The caller adds
/// the "Looks off:" lead.
String trailMarginLabel(engine.MatchMargin m) {
  switch (m.kind) {
    case engine.MatchMarginKind.length:
      final pct = (m.value.abs() * 100).round();
      return '$pct% ${m.value < 0 ? 'shorter' : 'longer'}';
    case engine.MatchMarginKind.cover:
      return 'only ${(m.value * 100).round()}% same ground';
    case engine.MatchMarginKind.turn:
      return 'turn point ${m.value.round()} m off';
  }
}

/// "Not this trail": a quiet link on a run of a trail's board.
class NotThisTrailButton extends StatelessWidget {
  const NotThisTrailButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: Space.x8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: t.inkSecondary,
      ),
      child: Text(
        'Not this trail',
        style: RunSoloType.label13.copyWith(
          color: t.inkSecondary,
          decoration: TextDecoration.underline,
          decorationColor: t.inkSecondary,
        ),
      ),
    );
  }
}

/// Saves the runner's call on [runId]'s trail, refreshes the index so every
/// board, verdict and ghost reads it, and offers an undo. [after] runs once
/// the call is saved (and again after an undo).
Future<void> applyTrailOverride(
  BuildContext context, {
  required String runId,
  required engine.TrailOverride? override,
  required String message,
  VoidCallback? after,
}) async {
  final svc = AppServices.of(context);
  final messenger = ScaffoldMessenger.of(context);
  // [after] reloads the index (one list()); without it, reload here.
  Future<void> refresh() async {
    if (after != null) {
      after();
    } else {
      await svc.history.list();
    }
  }

  final previous = (await svc.history.list())
      .where((r) => r.id == runId)
      .firstOrNull
      ?.trailOverride;
  await svc.history.setTrailOverride(runId, override);
  await refresh();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            await svc.history.setTrailOverride(runId, previous);
            await refresh();
          },
        ),
      ),
    );
}

/// The "Same trail as..." picker: the nearest trails, each with its run count,
/// best time and how far its start is from this run's. Returns the trail the
/// runner picked, null when dismissed.
Future<engine.TrailGroup?> showTrailPicker(
  BuildContext context, {
  required List<engine.TrailCandidate> candidates,
  required Units units,
}) => showModalBottomSheet<engine.TrailGroup>(
  context: context,
  isScrollControlled: true,
  builder: (context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x24,
          Space.screenGutter,
          Space.x16,
        ),
        child: Column(
          key: const ValueKey('trail-picker'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('SAME TRAIL AS', style: RunSoloType.title28),
            const SizedBox(height: Space.x4),
            Text(
              'Nearest first. This run joins the trail you pick.',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x16),
            for (final c in candidates)
              _CandidateTile(
                candidate: c,
                units: units,
                onTap: () => Navigator.of(context).pop(c.group),
              ),
          ],
        ),
      ),
    );
  },
);

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.units,
    required this.onTap,
  });
  final engine.TrailCandidate candidate;
  final Units units;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final g = candidate.group;
    final gap = candidate.startGapM;
    final away = gap < 1000
        ? 'starts ${gap.round()} m away'
        : 'starts ${Fmt.distance1(gap, units)} away';
    final runs = g.runs.length == 1 ? '1 run' : '${g.runs.length} runs';
    return Semantics(
      button: true,
      label: '${g.name}, $runs',
      excludeSemantics: true,
      child: RunCard(
        key: ValueKey('trail-candidate-${g.key}'),
        accent: t.typeTrail,
        onTap: onTap,
        margin: const EdgeInsets.only(bottom: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x8,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      g.name,
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    Text(
                      '$runs · best ${Fmt.clock(g.normMs(g.best))}',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                    Text(
                      '${(candidate.similarity * 100).round()}% same ground · '
                      '$away',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ],
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
