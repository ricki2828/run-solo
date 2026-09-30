import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// A10.3 board chip: a hairline rank ("#2 of 4 tests"), a first entry
/// ("First test on your board"), or a PB: a plain Bone text line led by one
/// small cyan diamond, which flashes once (600-900 ms into the result's
/// reveal). Cyan is only for a PB. 36 dp tall inside a 56 dp hit area.
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

  /// A new best: cyan diamond marker; it flashes unless [celebrate] is false.
  final bool pb;
  final bool celebrate;
  final bool haptics;
  final VoidCallback? onTap;

  @override
  State<RankChip> createState() => _RankChipState();
}

class _RankChipState extends State<RankChip>
    with SingleTickerProviderStateMixin {
  /// One cyan flash on the marker in the last third of 900 ms (600-900 ms),
  /// so it lands with the verdict word.
  late final AnimationController _flash = AnimationController(
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
      _flash.value = 1; // reduced motion: the resting marker, no movement
    } else {
      _flash.forward();
    }
    if (widget.haptics) HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final pb = widget.pb;
    final chip = Container(
      key: ValueKey(pb ? 'pb-chip' : 'rank-chip'),
      // 36 dp for one line; a long label wraps rather than overflow.
      constraints: const BoxConstraints(minHeight: 36),
      padding: EdgeInsets.symmetric(
        horizontal: pb ? 0 : Space.x16,
        vertical: Space.x4,
      ),
      decoration: pb
          ? null
          : BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.pill),
              border: Border.all(color: t.lineHair),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A drawn diamond: the bundled fonts carry no ◆ glyph.
          if (pb) ...[
            AnimatedBuilder(
              animation: _flash,
              builder: (context, child) {
                // 0 outside the 600-900 ms window, a 0 -> 1 -> 0 pulse in it.
                final w = ((_flash.value - 2 / 3) * 3).clamp(0.0, 1.0);
                final pulse = math.sin(math.pi * w);
                return Transform.scale(
                  scale: 1 + 0.9 * pulse,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: t.accentArc.withValues(alpha: 0.7 * pulse),
                          blurRadius: 10 * pulse,
                        ),
                      ],
                    ),
                    child: child,
                  ),
                );
              },
              child: Transform.rotate(
                angle: 0.785398,
                child: Container(
                  key: const ValueKey('pb-marker'),
                  width: 8,
                  height: 8,
                  color: t.accentArc,
                ),
              ),
            ),
            const SizedBox(width: Space.x12),
          ],
          Flexible(
            child: Text(
              widget.label,
              style: RunSoloType.body15.copyWith(
                color: t.inkPrimary,
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
              child: chip,
            ),
          ),
        ),
      ),
    );
  }
}
