import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../../theme/lanes.dart';
import '../../theme/pack_look.dart';
import '../../theme/theme.dart';

/// A flat lane-colour tile: the lane's name, a big number, a caption. [value]
/// null shows the lane as not set yet (a dash), still in its colour so week
/// one is not grey. Ink is picked for contrast on the fill.
class LaneBlock extends StatelessWidget {
  const LaneBlock({
    super.key,
    required this.lane,
    required this.value,
    required this.caption,
    this.onTap,
    this.change,
  });

  final engine.IdentityLane lane;
  final String? value;
  final String caption;
  final VoidCallback? onTap;

  /// Percentile points moved against a month ago; null or 0 shows nothing.
  final int? change;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final fill = t.laneFill(lane);
    final ink = readableOn(fill);
    return Semantics(
      button: onTap != null,
      label:
          '${lane.name}, ${value ?? 'not set yet'}'
          '${change == null || change == 0
              ? ''
              : change! > 0
              ? ', up $change'
              : ', down ${-change!}'}. $caption',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.fromLTRB(
            Space.x8,
            Space.x8,
            Space.x8,
            Space.x8,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                lane.name.toUpperCase(),
                maxLines: 1,
                style: RunSoloType.micro11.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: Space.x4),
              if (value != null)
                Text(
                  value!,
                  maxLines: 1,
                  style: RunSoloType.display44.copyWith(color: ink),
                )
              else
                // Not set yet: the caption is the way in, at a readable
                // size, instead of a lone dash (UI review 24-Oct #6).
                const SizedBox(height: Space.x16),
              if (change != null && change != 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.x4),
                  child: DecoratedBox(
                    key: ValueKey('lane-change-${lane.name}'),
                    decoration: BoxDecoration(
                      color: t.bgRaised,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.x8,
                        vertical: 2,
                      ),
                      child: Text(
                        change! > 0 ? '+$change' : '$change',
                        maxLines: 1,
                        style: RunSoloType.label13.copyWith(
                          color: change! > 0 ? t.semImproving : t.semSlower,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              Text(
                value == null && onTap != null ? '$caption ›' : caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: RunSoloType.label13.copyWith(
                  color: ink,
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: value == null ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The four scores side by side. [blocks] must be four, in lane order.
class LaneBlockRow extends StatelessWidget {
  const LaneBlockRow({super.key, required this.blocks});

  final List<LaneBlock> blocks;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(width: Space.x8),
          Expanded(child: blocks[i]),
        ],
      ],
    ),
  );
}

/// A block on the light page washed in a lane colour, with that colour as a
/// 4 dp accent down the left edge. For anything that belongs to a lane but
/// should stay calm: next session, a coach card, a result card.
class LaneTintCard extends StatelessWidget {
  const LaneTintCard({
    super.key,
    required this.lane,
    required this.child,
    this.padding = const EdgeInsets.all(Space.x16),
  });

  final engine.IdentityLane lane;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final fill = t.laneFill(lane);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          fill.withValues(alpha: PackLook.laneTint),
          t.bgRaised,
        ),
        borderRadius: BorderRadius.circular(Radii.sheet),
      ),
      clipBehavior: Clip.antiAlias,
      // A Stack, not IntrinsicHeight: a card can hold a LayoutBuilder (the
      // recent-bars chart), which cannot report intrinsic dimensions.
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 6,
            child: ColoredBox(color: fill),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Padding(padding: padding, child: child),
          ),
        ],
      ),
    );
  }
}
