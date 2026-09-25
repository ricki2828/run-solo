import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

/// Half-dial for the current (rolling 15 s) pace against a reference pace
/// (last rep, else the segment's own average): the founder asked for the
/// 4x4 screen not to be three identical big numbers. Faster than the
/// reference swings right; the scale is ±[spanSecPerKm] around it. Bone
/// needle, hairline arc, the number under it, so the meaning never rests
/// on the angle alone (design brief §2.2 colour-blind rule applies to
/// shape too).
class PaceDial extends StatelessWidget {
  const PaceDial({
    super.key,
    required this.currentSecPerKm,
    required this.referenceSecPerKm,
    required this.units,
    this.spanSecPerKm = 30,
    this.onZone = false,
    this.label = 'CURRENT PACE',
  });

  final double? currentSecPerKm;
  final double? referenceSecPerKm;
  final Units units;
  final double spanSecPerKm;
  final bool onZone;
  final String label;

  /// −1 (slower by the whole span) … 0 (on reference) … +1 (faster).
  double? get position {
    final c = currentSecPerKm;
    final r = referenceSecPerKm;
    if (c == null || r == null) return null;
    return ((r - c) / spanSecPerKm).clamp(-1.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = onZone ? const Color(0xCCEDEAE3) : t.inkSecondary;
    final p = position;
    return Semantics(
      label:
          '$label ${Fmt.pace(currentSecPerKm, units)}'
          '${p == null
              ? ''
              : p > 0.05
              ? ', faster than the reference'
              : p < -0.05
              ? ', slower than the reference'
              : ', on the reference'}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 2,
            child: CustomPaint(
              painter: _DialPainter(
                position: p,
                ink: t.inkPrimary,
                track: onZone ? const Color(0x33FFFFFF) : t.lineHair,
                secondary: secondary,
              ),
            ),
          ),
          const SizedBox(height: Space.x4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              Fmt.pace(currentSecPerKm, units),
              key: const ValueKey('dial-pace'),
              softWrap: false,
              style: RunSoloType.display64.copyWith(color: t.inkPrimary),
            ),
          ),
          Text(label, style: RunSoloType.micro11.copyWith(color: secondary)),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.position,
    required this.ink,
    required this.track,
    required this.secondary,
  });
  final double? position;
  final Color ink;
  final Color track;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width / 2, size.height) - 6;
    final c = Offset(size.width / 2, size.height - 2);
    final rect = Rect.fromCircle(center: c, radius: r);
    // Track: a half arc, left = slower, right = faster.
    canvas.drawArc(
      rect,
      math.pi,
      math.pi,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
    // Reference tick at the top, plus quarter ticks.
    for (final f in [-1.0, -0.5, 0.0, 0.5, 1.0]) {
      final a = math.pi + (f + 1) / 2 * math.pi;
      final major = f == 0;
      final p1 = c + Offset(math.cos(a), math.sin(a)) * (r - (major ? 14 : 8));
      final p2 = c + Offset(math.cos(a), math.sin(a)) * (r + 2);
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = major ? ink : secondary
          ..strokeWidth = major ? 3 : 2,
      );
    }
    final p = position;
    if (p == null) return;
    // Needle: from the hub to the arc at the position's angle.
    final a = math.pi + (p + 1) / 2 * math.pi;
    final tip = c + Offset(math.cos(a), math.sin(a)) * (r - 10);
    canvas.drawLine(
      c,
      tip,
      Paint()
        ..color = ink
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(c, 6, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.position != position || old.ink != ink || old.track != track;
}
