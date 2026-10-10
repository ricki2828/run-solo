/// The MAP view's one-line version of `StartReadout`: arrow and height vs the
/// start, and while heading back over the old track a u-turn and the distance
/// back, on the same outlined plate (a Bone outline on a dimmed ground, never
/// a colour). Icons stand in for the labels so the figures keep the 36 sp
/// floor on one short line and the map keeps its room.
library;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'start_readout.dart';

final double _figureSize = RunSoloType.runSize(36);

class StartStrip extends StatelessWidget {
  const StartStrip({
    super.key,
    required this.heightVsStartM,
    required this.backToStartM,
    required this.units,
    required this.valueColor,
  });

  final double? heightVsStartM;
  final double? backToStartM;
  final Units units;
  final Color valueColor;

  bool get retracing => backToStartM != null;

  static const double _outline = 2;

  /// The strip's height: one 36 sp line, the plate's padding and outline.
  static double get height =>
      (_figureSize * 1.25).ceilToDouble() + 2 * Space.x4 + 2 * _outline;

  @override
  Widget build(BuildContext context) {
    final h = heightVsStartM;
    final back = backToStartM;
    final style = RunSoloType.display44.copyWith(
      fontSize: _figureSize,
      color: valueColor,
    );
    final iconSize = _figureSize * 0.8;
    final cells = <Widget>[
      if (h != null)
        Semantics(
          label: 'Height against the start',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!StartReadout.isLevel(h)) ...[
                Icon(
                  h > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                  key: ValueKey(
                    h > 0 ? 'strip-height-up' : 'strip-height-down',
                  ),
                  size: iconSize,
                  color: valueColor,
                ),
                const SizedBox(width: Space.x4),
              ],
              Text(
                StartReadout.isLevel(h)
                    ? 'LEVEL'
                    : '${h > 0 ? '+' : '−'}'
                          '${Fmt.elevationAbs(h, units)}',
                key: const ValueKey('strip-height'),
                softWrap: false,
                style: style,
              ),
            ],
          ),
        ),
      if (back != null)
        Semantics(
          label: 'Back to start',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.u_turn_left, size: iconSize, color: valueColor),
              const SizedBox(width: Space.x4),
              Text(
                Fmt.distance1(back, units),
                key: const ValueKey('strip-back'),
                softWrap: false,
                style: style,
              ),
            ],
          ),
        ),
    ];
    return Container(
      key: ValueKey(retracing ? 'start-strip-retrace' : 'start-strip'),
      padding: const EdgeInsets.symmetric(
        vertical: Space.x4,
        horizontal: Space.x8,
      ),
      decoration: BoxDecoration(
        color: retracing ? NightSession.overlayGround : null,
        borderRadius: BorderRadius.circular(Space.x8),
        border: Border.all(
          color: retracing ? valueColor : Colors.transparent,
          width: _outline,
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              if (i > 0) const SizedBox(width: Space.x24),
              cells[i],
            ],
          ],
        ),
      ),
    );
  }
}
