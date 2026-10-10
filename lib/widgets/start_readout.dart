/// Trail runs, relative to where the run began: HEIGHT vs the start (an up or
/// down arrow and the metres, always there once there is an elevation) and,
/// while the runner is back on their own earlier track, BACK TO START (the
/// distance along that track). The retrace state is a Bone-outlined, dimmed
/// plate behind the figures, never a colour: it must sit on any HR zone flood
/// without borrowing the zone ramp, mint/vermillion (faster/slower) or cyan
/// (PB). The flood itself is untouched (founder: the whole-screen zone colour
/// is the wow). Every figure keeps the record screen's 36 sp floor (A8); the
/// numbers come from the recorder's own fixes, so the voice says the same.
library;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

final double _figureSize = RunSoloType.runSize(36);

class StartReadout extends StatelessWidget {
  const StartReadout({
    super.key,
    required this.heightVsStartM,
    required this.backToStartM,
    required this.units,
    required this.labelColor,
    required this.valueColor,
  });

  /// Metres above (+) or below (-) the start; null without an elevation.
  final double? heightVsStartM;

  /// Distance along the recorded track back to the start while heading back
  /// over it; null otherwise (no plate, no BACK TO START).
  final double? backToStartM;
  final Units units;
  final Color labelColor;
  final Color valueColor;

  bool get retracing => backToStartM != null;

  /// What the readout adds around its figures (plate padding + outline), so a
  /// layout can budget for it. Always reserved, so the row does not jump when
  /// the retrace starts or ends.
  static const double chrome = 2 * Space.x8 + 2 * _outline;
  static const double _outline = 2;

  /// A height that rounds to zero reads as level, never "-0 m".
  static bool isLevel(double m) => m.abs() < 0.5;

  @override
  Widget build(BuildContext context) {
    final h = heightVsStartM;
    final back = backToStartM;
    final style = RunSoloType.display44.copyWith(
      fontSize: _figureSize,
      color: valueColor,
    );
    final label = RunSoloType.runLabel.copyWith(color: labelColor);
    final cells = <Widget>[
      if (back != null)
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.u_turn_left, size: 18, color: labelColor),
                  const SizedBox(width: Space.x4),
                  Flexible(
                    child: Text(
                      'BACK TO START',
                      key: const ValueKey('back-to-start-label'),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: label,
                    ),
                  ),
                ],
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  Fmt.distance1(back, units),
                  key: const ValueKey('back-to-start'),
                  softWrap: false,
                  style: style,
                ),
              ),
            ],
          ),
        ),
      if (back != null && h != null) const SizedBox(width: Space.x12),
      if (h != null)
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('VS START', style: label),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isLevel(h)) ...[
                    Icon(
                      h > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                      key: ValueKey(h > 0 ? 'height-up' : 'height-down'),
                      size: _figureSize * 0.8,
                      color: valueColor,
                    ),
                    const SizedBox(width: Space.x4),
                  ],
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        isLevel(h)
                            ? 'LEVEL'
                            : '${h > 0 ? '+' : '−'}'
                                  '${Fmt.elevationAbs(h, units)}',
                        key: const ValueKey('height-vs-start'),
                        softWrap: false,
                        style: style,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    ];
    return Container(
      key: ValueKey(retracing ? 'start-readout-retrace' : 'start-readout'),
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      decoration: BoxDecoration(
        color: retracing ? NightSession.overlayGround : null,
        borderRadius: BorderRadius.circular(Space.x8),
        border: Border.all(
          color: retracing ? valueColor : Colors.transparent,
          width: _outline,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.x8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: cells),
      ),
    );
  }
}
