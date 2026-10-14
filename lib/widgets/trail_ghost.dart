/// The known-trail readouts on the run screen: how far ahead of (or behind)
/// the best and the last run on this trail, the Off the trail state and the
/// big TURN AROUND card. All of it comes from `RecordingSnapshot.trail`.
library;

import 'package:flutter/material.dart';

import '../platform/platform_api.g.dart' show TrailProgress;
import '../theme/theme.dart';

/// "12 s", "1:05": the size of a gap, never signed.
String trailGap(int ms) {
  final s = (ms.abs() / 1000).round();
  if (s < 60) return '$s s';
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "12 s ahead of best", "8 s behind last", "Level with best". Positive
/// [ms] is ahead.
String trailGapLine(int ms, String against) {
  if ((ms.abs() / 1000).round() < 1) return 'Level with $against';
  return '${trailGap(ms)} ${ms > 0 ? 'ahead of' : 'behind'} $against';
}

/// Ahead is mint, behind is vermillion, on a dark plate so both read on any
/// zone flood (the plate's ground is the app's near-black in both themes).
class TrailGhostReadout extends StatelessWidget {
  const TrailGhostReadout({
    super.key,
    required this.trail,
    this.compact = false,
    this.showLast = true,
  });
  final TrailProgress trail;

  /// Short phone: one step smaller.
  final bool compact;

  /// Page 1 also says how the last run compares when it was not the best.
  final bool showLast;

  static const Color _ground = NightSession.bgBase;

  @override
  Widget build(BuildContext context) {
    final best = trail.aheadBestMs;
    final last = trail.aheadLastMs;
    final lines = <(String, Color)>[
      if (trail.off)
        ('Off the trail', NightSession.inkPrimary)
      else ...[
        if (best != null) (trailGapLine(best, 'best'), _tone(best)),
        if (showLast && !trail.lastIsBest && last != null)
          (trailGapLine(last, 'last'), _tone(last)),
      ],
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final lead = lines.first.$2;
    return Semantics(
      liveRegion: true,
      container: true,
      label: [for (final l in lines) l.$1].join('. '),
      child: Container(
        key: const ValueKey('trail-ghost'),
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x4,
        ),
        decoration: BoxDecoration(
          color: _ground,
          borderRadius: BorderRadius.circular(Radii.chip),
          border: Border.all(color: lead, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, l) in lines.indexed)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  l.$1,
                  key: ValueKey(
                    i == 0 ? 'trail-ghost-best' : 'trail-ghost-last',
                  ),
                  softWrap: false,
                  style: RunSoloType.display44.copyWith(
                    fontSize: RunSoloType.runSize(
                      i == 0 ? (compact ? 36 : 44) : 36,
                    ),
                    fontWeight: FontWeight.w800,
                    color: l.$2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Color _tone(int ms) => (ms.abs() / 1000).round() < 1
      ? NightSession.inkPrimary
      : (ms > 0 ? NightSession.semImproving : NightSession.semSlower);
}

/// TURN AROUND, in the end-of-route card's style: a Bone card with ink text.
class TrailTurnCard extends StatelessWidget {
  const TrailTurnCard({
    super.key,
    required this.fill,
    required this.ink,
    this.compact = false,
  });
  final Color fill;
  final Color ink;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = RunSoloType.runSize(compact ? 36 : 44);
    return Semantics(
      liveRegion: true,
      label: 'Turn around.',
      child: Container(
        key: const ValueKey('trail-turn-card'),
        margin: const EdgeInsets.only(top: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x8,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Row(
          children: [
            Icon(Icons.u_turn_left_rounded, size: size, color: ink),
            const SizedBox(width: Space.x12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'TURN AROUND',
                  key: const ValueKey('trail-turn-text'),
                  softWrap: false,
                  style: RunSoloType.display44.copyWith(
                    fontSize: size,
                    color: ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
