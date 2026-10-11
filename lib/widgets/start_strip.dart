/// The MAP view's readouts relative to the start, with words (founder,
/// 10-Oct): [HeightFigure] ("VS START", arrow, signed metres) rides in the
/// free half of the DISTANCE row so it costs the map no height, and
/// [StartStrip] ("BACK TO START", u-turn, km) is the one extra line, shown
/// only while heading back over the old track, on a Bone-outlined, dimmed
/// plate (never a colour). Labels use the run-label size, numbers stay the
/// 36 sp floor and the loudest thing on the line.
library;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'start_readout.dart';

final double _figureSize = RunSoloType.runSize(36);

/// "VS START" over an arrow and the height against the start.
class HeightFigure extends StatelessWidget {
  const HeightFigure({
    super.key,
    required this.heightVsStartM,
    required this.units,
    required this.labelColor,
    required this.valueColor,
  });

  final double heightVsStartM;
  final Units units;
  final Color labelColor;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final h = heightVsStartM;
    final level = StartReadout.isLevel(h);
    return Semantics(
      label: 'Height against the start',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'VS START',
            maxLines: 1,
            softWrap: false,
            style: RunLabelScope.style(context, labelColor),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!level) ...[
                Icon(
                  h > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                  key: ValueKey(
                    h > 0 ? 'strip-height-up' : 'strip-height-down',
                  ),
                  size: _figureSize * 0.8,
                  color: valueColor,
                ),
                const SizedBox(width: Space.x4),
              ],
              Text(
                level
                    ? 'LEVEL'
                    : '${h > 0 ? '+' : '−'}'
                          '${Fmt.elevationAbs(h, units)}',
                key: const ValueKey('strip-height'),
                softWrap: false,
                style: RunSoloType.display44.copyWith(
                  fontSize: _figureSize,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "BACK TO START" with a u-turn and the distance back, on one plate line.
class StartStrip extends StatelessWidget {
  const StartStrip({
    super.key,
    required this.backToStartM,
    required this.units,
  });

  final double backToStartM;
  final Units units;

  static const double _outline = 2;

  /// The plate is its own dark ground (black 85 %), so it carries Bone on
  /// every flood, bright ones included (D1: 12:1 or better over Z3 / Z4).
  static const Color valueColor = NightSession.inkPrimary;
  static const Color labelColor = NightSession.overlayInk;

  /// The strip's height: one 36 sp line, the plate's padding and outline.
  static double get height =>
      (_figureSize * 1.25).ceilToDouble() + 2 * Space.x4 + 2 * _outline;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('start-strip-retrace'),
      padding: const EdgeInsets.symmetric(
        vertical: Space.x4,
        horizontal: Space.x8,
      ),
      decoration: BoxDecoration(
        color: NightSession.overlayGround,
        borderRadius: BorderRadius.circular(Space.x8),
        border: Border.all(color: valueColor, width: _outline),
      ),
      child: Semantics(
        label: 'Back to start',
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'BACK TO START',
                softWrap: false,
                style: RunLabelScope.style(context, labelColor),
              ),
              const SizedBox(width: Space.x8),
              Icon(
                Icons.u_turn_left,
                size: _figureSize * 0.8,
                color: valueColor,
              ),
              const SizedBox(width: Space.x4),
              Text(
                Fmt.distance1(backToStartM, units),
                key: const ValueKey('strip-back'),
                softWrap: false,
                style: RunSoloType.display44.copyWith(
                  fontSize: _figureSize,
                  color: valueColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
