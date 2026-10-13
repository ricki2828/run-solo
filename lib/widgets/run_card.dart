import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/lanes.dart';
import '../theme/pack_look.dart';
import '../theme/theme.dart';
import 'home_b/block_chip.dart';

/// Direction B run card: the run type's colour as a light wash with a 6 dp
/// accent down the left edge, on the light page, like Home's lane cards.
/// History rows, Home's recent activity, board cards and ranked rows all
/// wear it. The accent is the run type's colour (colour means the run
/// type; cyan stays PB/best, mint faster, vermillion slower).
class RunCard extends StatelessWidget {
  const RunCard({
    super.key,
    required this.accent,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(Space.x16),
    this.margin = EdgeInsets.zero,
    this.wash = PackLook.laneTint,
  });

  final Color accent;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// How strongly [accent] tints the card.
  final double wash;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: margin,
      child: Material(
        color: Color.alphaBlend(accent.withValues(alpha: wash), t.bgRaised),
        borderRadius: BorderRadius.circular(Radii.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 6, color: accent),
                Expanded(
                  child: Padding(padding: padding, child: child),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The run type's name as a pill in the type colour ("FREE", "4x4"), ink
/// picked for contrast on the fill.
class RunTypePill extends StatelessWidget {
  const RunTypePill({super.key, required this.label, required this.fill});

  final String label;
  final Color fill;

  @override
  Widget build(BuildContext context) =>
      BlockChip(label: label, fill: fill, ink: readableOn(fill));
}

/// A board's colour: its run type's, never cyan (cyan is the best).
Color boardAccent(RunSoloTokens t, engine.BoardKind kind) => switch (kind) {
  engine.BoardKind.interval => t.typeIntervals,
  engine.BoardKind.cooper => t.typeTests,
  engine.BoardKind.course || engine.BoardKind.goalDistance => t.typeGoal,
  engine.BoardKind.bestEffort || engine.BoardKind.distanceInTime => t.typeFree,
};
