import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../state/voice_coach_plan.dart' show CoachTarget;
import '../theme/theme.dart';

/// The coach layer's target band bar: the pace the session aims at as a
/// highlighted range, and a marker where the smoothed live True Pace sits.
/// Faster is to the right, as on the pace dial. Colour is not the only cue:
/// the marker's place against the band is, and the label names the target.
/// An easy or long run's pace is a ceiling ([CoachTarget.slowerIsFine]):
/// the band then runs from its fast edge out to the slow end.
class TargetBand extends StatelessWidget {
  const TargetBand({
    super.key,
    required this.target,
    required this.paceSecPerKm,
    required this.units,
    required this.labelColor,
    this.spanSecPerKm = 20,
  });

  final CoachTarget target;

  /// The smoothed live True Pace, s/km; null until there is one.
  final double? paceSecPerKm;
  final Units units;
  final Color labelColor;

  /// The bar covers the target ± this many s/km.
  final double spanSecPerKm;

  static const double barHeight = 14;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final unit = units == Units.mi ? 'mi' : 'km';
    return Semantics(
      label:
          'Target pace ${Fmt.pace(target.paceSecPerKm, units)} per $unit'
          '${paceSecPerKm == null ? '' : ', now ${Fmt.pace(paceSecPerKm, units)}'}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'TARGET ${Fmt.pace(target.paceSecPerKm, units)} /$unit'
            '${target.slowerIsFine ? ' OR SLOWER' : ''}',
            key: const ValueKey('target-label'),
            style: RunSoloType.micro11.copyWith(color: labelColor),
          ),
          const SizedBox(height: Space.x4),
          SizedBox(
            height: barHeight + 8,
            child: CustomPaint(
              key: const ValueKey('target-band'),
              size: Size.infinite,
              painter: _BandPainter(
                target: target,
                pace: paceSecPerKm,
                span: spanSecPerKm,
                ink: t.inkPrimary,
                ground: t.bgBase,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BandPainter extends CustomPainter {
  _BandPainter({
    required this.target,
    required this.pace,
    required this.span,
    required this.ink,
    required this.ground,
  });
  final CoachTarget target;
  final double? pace;
  final double span;
  final Color ink;
  final Color ground;

  /// x for a pace: the target is the centre, faster is right.
  double _x(double sec, double w) =>
      w / 2 + ((target.paceSecPerKm - sec) / span).clamp(-1.0, 1.0) * w / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final cy = size.height / 2;
    const h = TargetBand.barHeight;
    final track = RRect.fromLTRBR(
      0,
      cy - h / 2,
      w,
      cy + h / 2,
      const Radius.circular(h / 2),
    );
    canvas.drawRRect(track, Paint()..color = ink.withValues(alpha: 0.22));
    // The band: target ± band; a ceiling runs on to the slow end.
    final fastEdge = _x(target.paceSecPerKm - target.bandSecPerKm, w);
    final slowEdge = target.slowerIsFine
        ? 0.0
        : _x(target.paceSecPerKm + target.bandSecPerKm, w);
    canvas.save();
    canvas.clipRRect(track);
    canvas.drawRect(
      Rect.fromLTRB(slowEdge, cy - h / 2, fastEdge, cy + h / 2),
      Paint()..color = ink.withValues(alpha: 0.7),
    );
    canvas.restore();
    final p = pace;
    if (p == null) return;
    final x = _x(p, w).clamp(3.0, w - 3.0);
    // The marker: Bone with a dark edge so it reads on the band and off it.
    canvas.drawRRect(
      RRect.fromLTRBR(
        x - 4.5,
        0,
        x + 4.5,
        size.height,
        const Radius.circular(3),
      ),
      Paint()..color = ground,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(
        x - 2.5,
        1.5,
        x + 2.5,
        size.height - 1.5,
        const Radius.circular(2),
      ),
      Paint()..color = ink,
    );
  }

  @override
  bool shouldRepaint(_BandPainter old) =>
      old.pace != pace || old.target != target || old.ink != ink;
}
