import 'package:flutter/material.dart';

import '../../state/progress_snapshot.dart';
import '../../theme/theme.dart';
import '../section_card.dart';

String _clock(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// "You last month": the same effort now against a month ago, as two bars so
/// the gap reads without maths.
class GhostCard extends StatelessWidget {
  const GhostCard({super.key, required this.ghost});

  final GhostCompare ghost;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final gap = ghost.then - ghost.now;
    final faster = gap > Duration.zero;
    final line = gap == Duration.zero
        ? 'Same as ${ghost.thenLabel}. Steady.'
        : faster
        ? '${gap.inSeconds} seconds faster than ${ghost.thenLabel}.'
        : '${-gap.inSeconds} seconds slower than ${ghost.thenLabel}.';
    final slow = ghost.then > ghost.now ? ghost.then : ghost.now;
    double frac(Duration d) =>
        slow.inSeconds == 0 ? 0 : d.inSeconds / slow.inSeconds;
    Widget bar(String label, Duration d, Color fill, Color ink) => Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Container(
              width: c.maxWidth * frac(d),
              height: 28,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: Space.x8),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(Radii.chip),
              ),
              child: Text(
                _clock(d),
                style: RunSoloType.label13.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w700,
                  fontFeatures: RunSoloType.tabular,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return SectionCard(
      key: const ValueKey('home-ghost'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'YOU LAST MONTH, ${ghost.label}',
            style: RunSoloType.micro11.copyWith(
              color: t.inkSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Space.x8),
          bar('Now', ghost.now, t.inkPrimary, t.bgBase),
          const SizedBox(height: Space.x8),
          bar(ghost.thenLabel, ghost.then, t.lineHair, t.inkPrimary),
          const SizedBox(height: Space.x8),
          Text(
            line,
            style: RunSoloType.body15.copyWith(
              color: faster ? t.semImproving : t.inkPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
