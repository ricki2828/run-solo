import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/zones.dart';

/// The zone ladder on the run screen's right edge (Full Instrument): five
/// rungs, Z1 at the bottom to Z5 at the top, each labelled 1-5 and filled
/// from the chart ramp ([HrZones.distributionLight]). Inactive rungs sit at
/// 30 % opacity; the lit one is full with a Bone outline and a full-width
/// tick across it, with the bpm beside the tick; the tick's height shows where
/// HR sits within the zone ([position], 0 = bottom, 1 = top). [zone] is the engine tracker's zone (hysteresis applied), so
/// the ladder never flickers; 0 (no HR) hides it. Colour is never the only
/// cue: every rung carries its number.
class ZoneLadder extends StatelessWidget {
  const ZoneLadder({
    super.key,
    required this.zone,
    this.position = 0.5,
    this.hr,
  });
  final int zone;

  /// The bpm printed beside the tick; null prints nothing.
  final int? hr;

  /// 0 = bottom of the lit rung, 1 = top (`HrZones.positionInZone`).
  final double position;

  /// The ladder's width; the screen reserves [reserve] for it and its bpm
  /// label slot ([pointer], left of the rungs).
  static const double width = 18;
  static const double pointer = 30;

  /// The tick's thickness and the bpm label's size (>= 14 sp review floor).
  static const double tickThickness = 3;
  static const double labelSize = 14;

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
                child: _Rung(
                  z: z,
                  lit: z == zone,
                  position: position,
                  hr: hr,
                  t: t,
                ),
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
    required this.hr,
    required this.t,
  });
  final int z;
  final bool lit;
  final double position;
  final int? hr;
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
    final row = Row(
      children: [
        SizedBox(width: ZoneLadder.pointer),
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
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: lit
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                row,
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: position.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    builder: (context, p, _) => CustomPaint(
                      key: const ValueKey('ladder-pointer'),
                      painter: _TickPainter(
                        tick: ink,
                        label: t.inkPrimary,
                        position: p,
                        hr: hr,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : row,
    );
  }
}

/// A full-width tick across the lit rung with the bpm to its left, in the
/// label slot; [position] (0 bottom, 1 top) sets its height, kept clear of the
/// rung's ends. [yFor] is the one mapping the tests also use.
class _TickPainter extends CustomPainter {
  _TickPainter({
    required this.tick,
    required this.label,
    required this.position,
    required this.hr,
  });
  final Color tick;
  final Color label;
  final double position;
  final int? hr;

  static const double _margin = 5;

  static double yFor(double position, double height) =>
      _margin + (1 - position) * (height - 2 * _margin);

  @override
  void paint(Canvas canvas, Size size) {
    final cy = yFor(position, size.height);
    const t = ZoneLadder.tickThickness;
    // The tick spans the rung and runs on through the label slot's inner edge.
    canvas.drawRect(
      Rect.fromLTWH(ZoneLadder.pointer - 6, cy - t / 2, 6, t),
      Paint()..color = label,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        ZoneLadder.pointer,
        cy - t / 2,
        size.width - ZoneLadder.pointer,
        t,
      ),
      Paint()..color = tick,
    );
    final bpm = hr;
    if (bpm == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: '$bpm',
        style: RunSoloType.label13.copyWith(
          fontSize: ZoneLadder.labelSize,
          fontWeight: FontWeight.w900,
          color: label,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: ZoneLadder.pointer - 8);
    tp.paint(
      canvas,
      Offset(ZoneLadder.pointer - 8 - tp.width, cy - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(_TickPainter old) =>
      old.tick != tick ||
      old.label != label ||
      old.position != position ||
      old.hr != hr;
}
