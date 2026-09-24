import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// Destructive actions are 2 s holds (design brief §4): a ring fills around
/// the button while held; letting go early resets it. Reduced motion keeps
/// the hold but shows the ring stepping rather than sweeping.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.label,
    required this.onHeld,
    this.icon,
    this.holdFor = const Duration(seconds: 2),
    this.color,
    this.height = 56,
    this.haptics = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onHeld;
  final Duration holdFor;
  final Color? color;
  final double height;
  final bool haptics;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: widget.holdFor,
  )..addStatusListener(_onStatus);

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      if (widget.haptics) HapticFeedback.heavyImpact();
      _fill.reset();
      widget.onHeld();
    }
  }

  void _down() {
    if (widget.haptics) HapticFeedback.selectionClick();
    _fill.forward(from: 0);
  }

  void _up() {
    if (!_fill.isCompleted) _fill.reverse();
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final color = widget.color ?? t.semDanger;
    return Semantics(
      button: true,
      label: '${widget.label}, hold for ${widget.holdFor.inSeconds} seconds',
      // TalkBack double-tap is an instant down/up, so a screen reader gets the
      // long-press action instead of the timed hold.
      onLongPress: widget.onHeld,
      onLongPressHint: widget.label.toLowerCase(),
      // A raw Listener, not GestureDetector: a tap recognizer gives up when a
      // long press wins the arena and a sweaty thumb drifting past touch slop
      // would cancel the hold. Pointer down/up is all a hold needs.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedBuilder(
          animation: _fill,
          builder: (context, child) => CustomPaint(
            painter: _FillPainter(
              progress: _fill.value,
              color: color,
              track: t.lineHair,
              radius: Radii.button,
            ),
            child: child,
          ),
          child: Container(
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: Space.x16),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 20, color: t.inkPrimary),
                  const SizedBox(width: Space.x8),
                ],
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      softWrap: false,
                      style: RunSoloType.label13.copyWith(
                        color: t.inkPrimary,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FillPainter extends CustomPainter {
  _FillPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.radius,
  });
  final double progress;
  final Color color;
  final Color track;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );
    if (progress <= 0) return;
    final path = Path()..addRRect(rrect.deflate(1));
    for (final metric in path.computeMetrics()) {
      final seg = metric.extractPath(0, metric.length * progress);
      canvas.drawPath(
        seg,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_FillPainter old) =>
      old.progress != progress || old.color != color;
}
