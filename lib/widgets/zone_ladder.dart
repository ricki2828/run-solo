import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/zones.dart';

/// The zone ladder on the run screen's right edge (Full Instrument): five
/// rungs, Z1 at the bottom to Z5 at the top, each labelled 1-5 and filled
/// from the chart ramp ([HrZones.distributionLight]). Inactive rungs sit at
/// 30 % opacity; the lit one is full with a Bone outline and a small pointer
/// facing in. [zone] is the engine tracker's zone (hysteresis applied), so
/// the ladder never flickers; 0 (no HR) hides it. Colour is never the only
/// cue: every rung carries its number.
class ZoneLadder extends StatelessWidget {
  const ZoneLadder({super.key, required this.zone});
  final int zone;

  /// The ladder's width; the screen reserves [reserve] for it and its pointer.
  static const double width = 18;
  static const double pointer = 6;
  static const double reserve = width + pointer + 2;

  static const double _inactiveAlpha = 0.30;

  @override
  Widget build(BuildContext context) {
    if (zone <= 0) return const SizedBox.shrink();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      label: 'Heart rate zone $zone of ${HrZones.count}',
      excludeSemantics: true,
      child: SizedBox(
        width: width + pointer,
        child: Column(
          children: [
            for (var z = HrZones.count; z >= 1; z--)
              Expanded(
                child: _Rung(z: z, lit: z == zone, t: t),
              ),
          ],
        ),
      ),
    );
  }
}

class _Rung extends StatelessWidget {
  const _Rung({required this.z, required this.lit, required this.t});
  final int z;
  final bool lit;
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) {
    final fill = HrZones.distributionLight[z];
    // Dark ink or Bone, whichever reads on the rung's own colour.
    final ink =
        HrZones.contrast(t.inkPrimary, fill) >= HrZones.contrast(t.bgBase, fill)
        ? t.inkPrimary
        : t.bgBase;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: ZoneLadder.pointer,
            child: lit
                ? CustomPaint(
                    key: const ValueKey('ladder-pointer'),
                    painter: _PointerPainter(t.inkPrimary),
                  )
                : null,
          ),
          Expanded(
            child: Container(
              key: ValueKey('ladder-rung-$z'),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: lit
                    ? fill
                    : fill.withValues(alpha: ZoneLadder._inactiveAlpha),
                borderRadius: BorderRadius.circular(4),
                border: lit ? Border.all(color: t.inkPrimary, width: 2) : null,
              ),
              child: Text(
                '$z',
                style: RunSoloType.label13.copyWith(
                  color: lit ? ink : t.inkPrimary,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small triangle at the rung's left edge, pointing in (right).
class _PointerPainter extends CustomPainter {
  _PointerPainter(this.colour);
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    canvas.drawPath(
      Path()
        ..moveTo(0, cy - 5)
        ..lineTo(size.width, cy)
        ..lineTo(0, cy + 5)
        ..close(),
      Paint()..color = colour,
    );
  }

  @override
  bool shouldRepaint(_PointerPainter old) => old.colour != colour;
}
