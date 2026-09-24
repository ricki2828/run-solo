import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// The 200 dp LAP button with signature moment M2 (design brief §3):
/// press-down scales to 0.96 on `spring.tap` + heavy haptic; release fires a
/// 2 px Bone ring from the button edge to screen width over 220 ms. The ring
/// also replays on [pulse] so notification / volume-key laps are confirmed on
/// screen. Reduced motion: no ring, no scale.
class LapButton extends StatefulWidget {
  const LapButton({
    super.key,
    required this.onLap,
    required this.pulse,
    this.height = 200,
    this.haptics = true,
    this.label = 'LAP',
  });

  final VoidCallback onLap;

  /// Bumped by the controller for laps from any source.
  final ValueListenable<int> pulse;
  final double height;
  final bool haptics;
  final String label;

  @override
  State<LapButton> createState() => _LapButtonState();
}

class _LapButtonState extends State<LapButton> with TickerProviderStateMixin {
  late final AnimationController _scale = AnimationController(
    vsync: this,
    lowerBound: 0.9,
    upperBound: 1.0,
    value: 1.0,
  );
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  int _seenPulse = 0;

  @override
  void initState() {
    super.initState();
    _seenPulse = widget.pulse.value;
    widget.pulse.addListener(_onPulse);
  }

  @override
  void didUpdateWidget(LapButton old) {
    super.didUpdateWidget(old);
    if (old.pulse != widget.pulse) {
      old.pulse.removeListener(_onPulse);
      _seenPulse = widget.pulse.value;
      widget.pulse.addListener(_onPulse);
    }
  }

  void _onPulse() {
    if (widget.pulse.value == _seenPulse) return;
    _seenPulse = widget.pulse.value;
    _fireRing();
  }

  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  void _fireRing() {
    if (_reduced) return;
    _ring.forward(from: 0);
  }

  void _springTo(double target) {
    if (_reduced) return;
    final s = MotionSprings.tap;
    _scale.animateWith(
      SpringSimulation(
        SpringDescription(
          mass: s.mass,
          stiffness: s.stiffness,
          damping: s.damping,
        ),
        _scale.value,
        target,
        0,
      ),
    );
  }

  @override
  void dispose() {
    widget.pulse.removeListener(_onPulse);
    _scale.dispose();
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          if (widget.haptics) HapticFeedback.heavyImpact();
          _springTo(0.96);
        },
        onTapUp: (_) => _springTo(1.0),
        onTapCancel: () => _springTo(1.0),
        onTap: widget.onLap,
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              ScaleTransition(
                scale: _scale,
                child: Container(
                  height: widget.height,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: t.inkPrimary,
                    borderRadius: BorderRadius.circular(Radii.lap),
                  ),
                  alignment: Alignment.center,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      softWrap: false,
                      style: RunSoloType.display96.copyWith(color: t.bgBase),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _ring,
                    builder: (context, _) {
                      if (_ring.isDismissed || _ring.isCompleted) {
                        return const SizedBox.shrink();
                      }
                      final v = MotionCurves.exit.transform(_ring.value);
                      return CustomPaint(
                        painter: _RingPainter(
                          progress: v,
                          color: t.inkPrimary,
                          radius: Radii.lap,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.radius,
  });
  final double progress;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final grow = 24.0 + progress * size.width;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).inflate(grow);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: (1 - progress).clamp(0, 1));
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius + grow)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}
