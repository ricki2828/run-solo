import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// A10.3 board chip: a hairline rank ("#2 of 4 tests"), a first entry
/// ("First test on your board"), or the Arc PB chip, which plays M5 once.
/// 36 dp tall inside a 56 dp hit area.
class RankChip extends StatefulWidget {
  const RankChip({
    super.key,
    required this.label,
    this.pb = false,
    this.celebrate = true,
    this.haptics = true,
    this.onTap,
  });

  final String label;

  /// Arc fill (a new best); M5 plays unless [celebrate] is false.
  final bool pb;
  final bool celebrate;
  final bool haptics;
  final VoidCallback? onTap;

  @override
  State<RankChip> createState() => _RankChipState();
}

class _RankChipState extends State<RankChip>
    with SingleTickerProviderStateMixin {
  /// M5 (design brief §3): an Arc ring draws round the chip, then a 1 px
  /// Arc line sweeps the full width behind it; 900 ms, one long pulse.
  late final AnimationController _m5 = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || !widget.pb || !widget.celebrate) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _m5.value = 1; // reduced motion: the final frame, no movement
    } else {
      _m5.forward();
    }
    if (widget.haptics) HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _m5.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final chip = Container(
      key: ValueKey(widget.pb ? 'pb-chip' : 'rank-chip'),
      // 36 dp for one line; a long label wraps rather than overflow.
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.x16,
        vertical: Space.x4,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.pb ? t.accentArc : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: widget.pb ? null : Border.all(color: t.lineHair),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A drawn diamond: the bundled fonts carry no ◆ glyph.
          if (widget.pb) ...[
            Transform.rotate(
              angle: 0.785398,
              child: Container(width: 7, height: 7, color: t.accentArcInk),
            ),
            const SizedBox(width: Space.x8),
          ],
          Flexible(
            child: Text(
              widget.label,
              style: RunSoloType.body15.copyWith(
                color: widget.pb ? t.accentArcInk : t.inkPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    // Sized to its label, left-aligned: a list gives it the full width.
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: widget.onTap != null,
        label: widget.label,
        excludeSemantics: true,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              child: !widget.pb
                  ? chip
                  : AnimatedBuilder(
                      animation: _m5,
                      builder: (context, child) => CustomPaint(
                        foregroundPainter: _M5Painter(
                          progress: _m5.value,
                          color: t.accentArc,
                        ),
                        child: child,
                      ),
                      child: chip,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _M5Painter extends CustomPainter {
  _M5Painter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    // 0–60%: the ring draws round the chip, 4 dp out.
    final ring = (progress / 0.6).clamp(0.0, 1.0);
    final r = RRect.fromRectAndRadius(
      (Offset.zero & size).inflate(4),
      Radius.circular(size.height / 2 + 4),
    );
    final path = Path()..addRRect(r);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * ring), paint);
    }
    // 40–100%: the 1 px lap line sweeps out from the chip's right edge.
    final sweep = ((progress - 0.4) / 0.6).clamp(0.0, 1.0);
    if (sweep > 0) {
      final y = size.height / 2;
      canvas.drawLine(
        Offset(size.width + 8, y),
        Offset(size.width + 8 + 400 * sweep, y),
        Paint()
          ..color = color
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_M5Painter old) =>
      old.progress != progress || old.color != color;
}
