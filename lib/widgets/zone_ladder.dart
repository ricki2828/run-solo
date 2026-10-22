import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/zones.dart';

/// The zone ladder on the run screen's right edge (Full Instrument): five
/// rungs, Z1 at the bottom to Z5 at the top, each labelled 1-5 and filled
/// from the chart ramp ([HrZones.distributionLight]). Inactive rungs sit at
/// 30 % opacity; the lit one is full with a Bone outline and a small pointer
/// facing in; the pointer's height shows where HR sits within the zone
/// ([position], 0 = bottom, 1 = top). [zone] is the engine tracker's zone (hysteresis applied), so
/// the ladder never flickers; 0 (no HR) hides it. Colour is never the only
/// cue: every rung carries its number.
class ZoneLadder extends StatelessWidget {
  const ZoneLadder({super.key, required this.zone, this.position = 0.5});
  final int zone;

  /// 0 = bottom of the lit rung, 1 = top (`HrZones.positionInZone`).
  final double position;

  /// The ladder's width; the screen reserves [reserve] for it and its pointer.
  static const double width = 18;
  static const double pointer = 6;

  /// A clear 8 dp between the ladder's pointer and the numbers: the big
  /// figures scale to fit the gutter, never under the ladder (21-Oct).
  static const double reserve = width + pointer + 8;

  /// Rung numerals: 16 sp, bold (the review floor was 14).
  static const double numeralSize = 16;

  static const double _inactiveAlpha = 0.30;

  /// On the bright Z3 / Z4 floods the unlit rungs carry only a whisper of
  /// their hue so their ink numbers stay >= 7:1 on the rung (D1, 11-Oct).
  static const double inactiveAlphaOnInk = 0.06;

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
                child: _Rung(z: z, lit: z == zone, position: position, t: t),
              ),
          ],
        ),
      ),
    );
  }
}

class _Rung extends StatelessWidget {
  const _Rung({
    required this.z,
    required this.lit,
    required this.position,
    required this.t,
  });
  final int z;
  final bool lit;
  final double position;
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) {
    final fill = HrZones.distributionLight[z];
    // On an ink flood (Z3, Z4) the lit rung is a solid ink block with the
    // flood's colour as its number (>= 7:1 by the flood's own contrast); the
    // others stay quiet. Elsewhere: dark ink or Bone, whichever reads on the
    // rung's own colour.
    final onInk = HrZones.isInk(t);
    final ink = onInk
        ? t.bgBase
        : HrZones.contrast(t.inkPrimary, fill) >=
              HrZones.contrast(t.bgBase, fill)
        ? t.inkPrimary
        : t.bgBase;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: ZoneLadder.pointer,
            child: lit
                ? TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: position.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    builder: (context, p, _) => CustomPaint(
                      key: const ValueKey('ladder-pointer'),
                      painter: _PointerPainter(t.inkPrimary, p),
                    ),
                  )
                : null,
          ),
          Expanded(
            child: Container(
              key: ValueKey('ladder-rung-$z'),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: lit
                    ? (onInk ? t.inkPrimary : fill)
                    : fill.withValues(
                        alpha: onInk
                            ? ZoneLadder.inactiveAlphaOnInk
                            : ZoneLadder._inactiveAlpha,
                      ),
                borderRadius: BorderRadius.circular(4),
                border: lit
                    ? Border.all(color: t.inkPrimary, width: 3)
                    : onInk
                    ? Border.all(color: t.lineHair)
                    : null,
              ),
              child: Text(
                '$z',
                style: RunSoloType.label13.copyWith(
                  fontSize: ZoneLadder.numeralSize,
                  color: lit ? ink : t.inkPrimary,
                  fontWeight: lit ? FontWeight.w900 : FontWeight.w700,
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

/// A small triangle at the rung's left edge, pointing in (right); [position]
/// (0 bottom, 1 top) sets its height, kept clear of the rung's ends.
class _PointerPainter extends CustomPainter {
  _PointerPainter(this.colour, this.position);
  final Color colour;
  final double position;

  static const double _margin = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = _margin + (1 - position) * (size.height - 2 * _margin);
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
  bool shouldRepaint(_PointerPainter old) =>
      old.colour != colour || old.position != position;
}
