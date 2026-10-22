import 'package:flutter/material.dart';

import '../state/inrun_moments.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';

/// The in-run moment (21-Oct UI review, finding 2): a plate that scales in
/// over the zone flood, glows, holds, and goes, in [shownFor]. Calm between
/// moments, drama at one. Never takes a tap, never outlasts [shownFor], and
/// with [reduced] it only appears and disappears (no scale, no glow).
///
/// Colours come from the flood theme: a plate of the flood's ink with the
/// headline in the flood's own colour ([accent]) where that reads, else in
/// the flood's background colour. Every figure is 64 sp or more.
class InrunMomentOverlay extends StatefulWidget {
  const InrunMomentOverlay({
    super.key,
    required this.moment,
    required this.accent,
    this.reduced = false,
    this.onDone,
  });

  final InrunMoment moment;

  /// The zone flood the plate sits on (its own colour for the headline).
  final Color accent;
  final bool reduced;
  final VoidCallback? onDone;

  /// How long a moment is on the screen.
  static const Duration shownFor = Duration(milliseconds: 1500);

  /// Headline and label sizes (sp): both clear the 36 sp number floor.
  static const double headlineSize = 88;
  static const double labelSize = 28;

  @override
  State<InrunMomentOverlay> createState() => _InrunMomentOverlayState();
}

class _InrunMomentOverlayState extends State<InrunMomentOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: InrunMomentOverlay.shownFor,
  );

  // 0 to 0.16 in, to 0.84 hold, to 1 out.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.82,
        end: 1.0,
      ).chain(CurveTween(curve: MotionCurves.emphasized)),
      weight: 16,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 84),
  ]).animate(_c);

  late final Animation<double> _fade = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 12),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 72),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 16),
  ]).animate(_c);

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() {
      if (mounted) widget.onDone?.call();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final m = widget.moment;
    final plate = t.inkPrimary;
    // The headline in the flood's own colour where it reads on the plate
    // (3:1, large type), else the flood's base.
    final headline = HrZones.contrast(widget.accent, plate) >= 3
        ? widget.accent
        : t.bgBase;
    final reduced = widget.reduced;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: '${m.label} ${m.headline}${m.sub == null ? '' : ', ${m.sub}'}',
        excludeSemantics: true,
        child: Align(
          alignment: const Alignment(0, -0.1),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final fade = reduced
                  ? (_c.value < 0.96 ? 1.0 : 0.0)
                  : _fade.value;
              final scale = reduced ? 1.0 : _scale.value;
              return Opacity(
                opacity: fade,
                child: Transform.scale(scale: scale, child: child),
              );
            },
            child: Container(
              key: ValueKey('inrun-moment-${m.kind.name}'),
              margin: const EdgeInsets.symmetric(horizontal: Space.x24),
              padding: const EdgeInsets.symmetric(
                horizontal: Space.x24,
                vertical: Space.x16,
              ),
              decoration: BoxDecoration(
                color: plate,
                borderRadius: BorderRadius.circular(20),
                boxShadow: reduced
                    ? null
                    : [
                        BoxShadow(
                          color: plate.withValues(alpha: 0.55),
                          blurRadius: 48,
                          spreadRadius: 6,
                        ),
                      ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    m.label,
                    key: const ValueKey('inrun-moment-label'),
                    textAlign: TextAlign.center,
                    style: RunSoloType.title28.copyWith(
                      fontSize: InrunMomentOverlay.labelSize,
                      color: t.bgBase,
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      m.headline,
                      key: const ValueKey('inrun-moment-headline'),
                      softWrap: false,
                      style: RunSoloType.display44.copyWith(
                        fontSize: RunSoloType.runSize(
                          InrunMomentOverlay.headlineSize,
                        ),
                        fontWeight: FontWeight.w800,
                        color: headline,
                        height: 1.0,
                      ),
                    ),
                  ),
                  if (m.sub != null) ...[
                    const SizedBox(height: Space.x4),
                    Text(
                      m.sub!,
                      key: const ValueKey('inrun-moment-sub'),
                      textAlign: TextAlign.center,
                      style: RunSoloType.title28.copyWith(
                        fontSize: InrunMomentOverlay.labelSize,
                        color: t.bgBase,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
